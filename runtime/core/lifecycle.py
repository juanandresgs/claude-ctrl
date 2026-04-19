"""Agent lifecycle handlers.

Owns the start/stop marker transitions for agent identity. These are thin
wrappers over runtime.core.markers that give callers a semantic interface
without needing to know the marker table schema.

Called by the CLI ``cc-policy dispatch agent-start`` / ``agent-stop``
subcommands, which post-task.sh and subagent-start.sh will call in lieu
of direct rt_marker_set / rt_marker_deactivate calls.

@decision DEC-LIFECYCLE-001
Title: lifecycle.py owns agent start/stop marker transitions
Status: accepted
Rationale: Marker activation and deactivation is a distinct concern from
  dispatch routing. Separating it into lifecycle.py makes both modules
  independently testable and avoids conflating routing logic (dispatch_engine.py)
  with agent identity tracking. The module is intentionally thin — all
  persistence is delegated to runtime.core.markers, which owns the
  agent_markers table.

@decision DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001
Title: Compound-stage equality via lease_role_for_stage canonicalization (Part B)
Status: accepted
Rationale: Bug B: on_stop_by_role compared active.get("role") (compound form,
  e.g. "guardian:land") against agent_type (base short form, e.g. "guardian").
  These are string-unequal, so the equality at line 135 never matched for
  compound-stage dispatches. SubagentStop hooks (check-guardian.sh, etc.)
  always call `cc-policy lifecycle on-stop guardian` with the base short form
  because AGENT_TYPE in the SubagentStop payload is the harness-level agent_type
  (short form), while subagent-start.sh seats the marker with the compound
  stage_id from the CLAUDEX_CONTRACT_BLOCK (e.g. "guardian:land"). The
  mismatch caused markers to accumulate as is_active=1 indefinitely.

  Fix: canonicalize BOTH sides via authority_registry.lease_role_for_stage
  before the equality compare. This function maps compound stages ("guardian:land",
  "guardian:provision") to their base role ("guardian"), and returns the input
  unchanged for base roles and simple stages. The `or <side>` fallback handles
  the case where lease_role_for_stage returns None (e.g. plain "guardian" is not
  in STAGE_CAPABILITIES, so None is returned; `or agent_type` preserves it).

  This reuses the EXISTING canonical authority at authority_registry.py:672 —
  no new primitive, no ad-hoc compound-stripping (no role.split(':')[0]).
"""

from __future__ import annotations

import sqlite3

from runtime.core import markers
from runtime.core.authority_registry import lease_role_for_stage


def on_agent_start(
    conn: sqlite3.Connection,
    agent_type: str,
    agent_id: str,
    project_root: str | None = None,
    workflow_id: str | None = None,
) -> None:
    """Mark agent_id as active with the given role.

    Calls markers.set_active(), which upserts on conflict so a re-start
    correctly resets started_at and clears any previous stopped_at.

    W-CONV-2: project_root and workflow_id are now forwarded to set_active()
    so that get_active(project_root=X) can scope marker queries to a single
    project. Callers that do not supply these continue to work — the columns
    default to NULL and the unscoped get_active() path remains available.

    Args:
        conn:         Open SQLite connection with schema applied.
        agent_type:   Role string (implementer, reviewer, guardian, planner).
        agent_id:     Unique agent identifier (e.g. session UUID or pid).
        project_root: Optional canonical project root (normalize_path applied
                      by caller). Stored in agent_markers.project_root.
        workflow_id:  Optional workflow identifier. Stored in agent_markers.
    """
    markers.set_active(
        conn, agent_id, agent_type, project_root=project_root, workflow_id=workflow_id
    )


def on_agent_stop(conn: sqlite3.Connection, agent_type: str, agent_id: str) -> None:
    """Deactivate the marker for agent_id.

    Calls markers.deactivate(), which is a no-op when agent_id is not found,
    so callers do not need to guard against unknown agent IDs.

    Args:
        conn:       Open SQLite connection with schema applied.
        agent_type: Role string — accepted for symmetry with on_agent_start
                    but not used for the deactivation query (agent_id is the
                    primary key). Retained so callers can log it if needed.
        agent_id:   Unique agent identifier matching the one passed to
                    on_agent_start.
    """
    markers.deactivate(conn, agent_id)


def on_stop_by_role(
    conn: sqlite3.Connection,
    agent_type: str,
    project_root: str | None = None,
    workflow_id: str | None = None,
) -> dict:
    """Deactivate the active marker whose role matches agent_type.

    This is the single authority for marker deactivation in SubagentStop hooks
    (DEC-LIFECYCLE-002). The hooks previously resolved the active marker and
    called deactivate in bash; this function centralises that logic so the shell
    does not need to own the query-and-decide pattern.

    Returns a dict with:
        found     — True if an active marker with matching role was found
        deactivated — True if deactivation was performed
        agent_id  — the agent_id that was deactivated (or None)
        role      — the role that was matched (or None)

    No-op (found=False, deactivated=False) when there is no active marker or
    the active marker's role does not match agent_type.

    @decision DEC-LIFECYCLE-003
    @title on_stop_by_role is the single authority for role-matched deactivation
    @status accepted
    @rationale SubagentStop hooks run in a different process from SubagentStart
      so they cannot use the original agent_id directly. They must query the
      active marker, match its role to the stopping agent_type, and deactivate
      by the stored agent_id. Duplicating this query-and-decide pattern in four
      check-*.sh hooks creates four places to get it wrong. Centralising in
      on_stop_by_role gives one implementation reachable via
      `cc-policy lifecycle on-stop <agent_type>`.

    @decision DEC-LIFECYCLE-004
    @title Scoped deactivation by project_root and workflow_id (ENFORCE-RCA-6-ext / #26)
    @status accepted
    @rationale Pre-scoping, on_stop_by_role called markers.get_active() unscoped.
      In a multi-project environment — or a dual-checkout symlinked repo like
      ~/.claude → claude-ctrl-hardFork — the globally-newest active marker may
      belong to a different logical project. Stopping agent X in project A
      could silently deactivate an active marker in project B, or fail to
      deactivate agent X because a newer marker from B holds the "globally
      newest" slot. Forwarding project_root and workflow_id to
      markers.get_active() ensures the lookup is strictly scoped to the
      caller's project, eliminating cross-project contamination and orphan-
      marker poisoning.

      Backward compatibility: when both params are None (old callers),
      behaviour is identical to the pre-scoping path — statusline.py and any
      other context-less caller continues to work.

    Args:
        conn:         Open SQLite connection with schema applied.
        agent_type:   Role string to match (implementer, reviewer, guardian, planner).
        project_root: Optional canonical project root to scope the lookup.
                      When None, falls back to unscoped global query.
        workflow_id:  Optional workflow_id to further scope within a project.
    """
    active = markers.get_active(conn, project_root=project_root, workflow_id=workflow_id)
    if active is None:
        return {"found": False, "deactivated": False, "agent_id": None, "role": None}
    # DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001 (Part B):
    # Canonicalize both sides via lease_role_for_stage before equality compare.
    # The active marker stores the compound stage_id (e.g. "guardian:land")
    # because subagent-start.sh uses _MARKER_ROLE="$_EFFECTIVE_STAGE_ID".
    # SubagentStop hooks call `cc-policy lifecycle on-stop <agent_type>` with
    # the base short form (e.g. "guardian"). Without canonicalization,
    # "guardian:land" != "guardian" → found=False → no deactivation → accumulation.
    # With canonicalization: both sides map to "guardian" → equal → deactivated.
    # The `or <side>` fallback handles cases where lease_role_for_stage returns
    # None (e.g. plain "guardian" is not in STAGE_CAPABILITIES; see authority_registry
    # line ~681). No ad-hoc compound-stripping; authority_registry is the sole canonicalizer.
    active_role = active.get("role") or ""
    canonical_active = lease_role_for_stage(active_role) or active_role
    canonical_agent = lease_role_for_stage(agent_type) or agent_type
    if canonical_active != canonical_agent:
        return {"found": False, "deactivated": False, "agent_id": None, "role": None}
    agent_id = active["agent_id"]
    markers.deactivate(conn, agent_id)
    return {"found": True, "deactivated": True, "agent_id": agent_id, "role": agent_type}

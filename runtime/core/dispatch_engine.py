"""Dispatch emission and routing authority.

Ports the dispatch state machine from hooks/post-task.sh into Python so it can
be unit-tested without subprocess overhead and called directly from cli.py.

After this module lands, hooks/post-task.sh becomes a thin adapter (~20 lines)
that pipes JSON through ``cc-policy dispatch process-stop`` and echoes the
hookSpecificOutput result.

@decision DEC-DISPATCH-ENGINE-001
Title: dispatch_engine.process_agent_stop is the authoritative dispatch state machine
Status: accepted
Rationale: post-task.sh contained ~200 lines of routing logic in bash including
  lease resolution, completion-record lookup, eval_state mutation, and routing.
  Porting to Python provides: (1) unit tests without subprocess overhead; (2) direct
  reuse of domain modules (leases, completions, evaluation, events) without going
  through the CLI subprocess layer; (3) a single source of truth for the routing
  state machine that the CLI can call and tests can exercise directly. The bash
  adapter is intentionally thin — no routing logic remains there.

  Key invariant preserved from DEC-ROUTING-002: lease is released AFTER routing
  is determined. Releasing before routing made completion records unreachable
  because leases.get_current() only returns active leases.

  Key invariant from DEC-COMPLETION-001: routing for tester and guardian is
  exclusively via completions.determine_next_role(). No case statement maps
  verdicts to roles in this module — that table lives only in completions.py.

  Key invariant from DEC-EVAL-001: eval_state is written to 'pending' only for
  the implementer role (post-task.sh was the sole writer for this transition).
  Tester and guardian do not write eval_state here; check-tester.sh owns the
  ready_for_guardian write.
"""

from __future__ import annotations

import sqlite3
from typing import Optional

from runtime.core import completions, evaluation, events, leases

# ---------------------------------------------------------------------------
# Public interface
# ---------------------------------------------------------------------------


def process_agent_stop(
    conn: sqlite3.Connection,
    agent_type: str,
    project_root: str,
) -> dict:
    """Process an agent stop event and return a structured dispatch result.

    Mirrors the logic in hooks/post-task.sh without the bash subprocess layer.
    Called by the CLI ``cc-policy dispatch process-stop`` subcommand, which is
    in turn called by the thinned-down post-task.sh adapter.

    Args:
        conn:         Open SQLite connection with schema applied.
        agent_type:   Role string from the hook input (planner, implementer,
                      tester, guardian). Unknown types return silently.
        project_root: Filesystem path to the project root. Used to resolve the
                      active lease via worktree path when no explicit lease_id
                      is supplied. May be empty string when unavailable.

    Returns:
        dict with:
          next_role   str | None  — None means cycle complete or unknown type.
          workflow_id str         — resolved from active lease or empty string.
          suggestion  str         — human-readable dispatch hint for
                                    additionalContext in hookSpecificOutput.
          error       str | None  — PROCESS ERROR string when contract violated.
          events      list[dict]  — events emitted during processing.
    """
    result: dict = {
        "next_role": None,
        "workflow_id": "",
        "suggestion": "",
        "error": None,
        "events": [],
    }

    # Normalise capitalisation variants (matches bash `Plan` alias).
    normalised = agent_type.lower() if agent_type else ""
    if normalised == "plan":
        normalised = "planner"

    # Exit silently for unknown types — hooks must not interfere with inputs
    # they do not own.
    _known_types = {"planner", "implementer", "tester", "guardian"}
    if normalised not in _known_types:
        return result

    # Emit agent_complete audit event.
    try:
        evt_id = events.emit(conn, type="agent_complete", detail=f"Agent {agent_type} completed")
        result["events"].append({"type": "agent_complete", "id": evt_id})
    except Exception:
        pass  # Audit emission is best-effort; never block routing.

    # ---------------------------------------------------------------------------
    # Resolve workflow_id and active lease from the project root.
    #
    # WS1 invariant: lease workflow_id takes priority over branch-derived id.
    # Branch-derived id is only the fallback when no lease exists.
    # ---------------------------------------------------------------------------
    workflow_id, active_lease_id = _resolve_lease_context(conn, project_root)
    result["workflow_id"] = workflow_id

    # ---------------------------------------------------------------------------
    # Role-specific routing
    # ---------------------------------------------------------------------------
    if normalised == "planner":
        result["next_role"] = "implementer"

    elif normalised == "implementer":
        result["next_role"] = "tester"
        # Set eval_state = pending so the tester knows fresh work awaits.
        # This is the sole post-task writer for the pending transition
        # (DEC-EVAL-001). Skip for the claude meta-repo (no workflow to track).
        if workflow_id:
            try:
                evaluation.set_status(conn, workflow_id, "pending")
                evt_id = events.emit(conn, type="eval_pending", detail=workflow_id)
                result["events"].append({"type": "eval_pending", "id": evt_id})
            except Exception:
                pass  # Best-effort; routing is not gated on eval write.

    elif normalised == "tester":
        next_role, error = _route_from_completion(
            conn,
            role="tester",
            workflow_id=workflow_id,
            active_lease_id=active_lease_id,
        )
        result["next_role"] = next_role
        result["error"] = error

    elif normalised == "guardian":
        next_role, error = _route_from_completion(
            conn,
            role="guardian",
            workflow_id=workflow_id,
            active_lease_id=active_lease_id,
        )
        result["next_role"] = next_role
        result["error"] = error

    # ---------------------------------------------------------------------------
    # Build suggestion for hookSpecificOutput additionalContext
    # ---------------------------------------------------------------------------
    if result["error"]:
        result["suggestion"] = result["error"]
    elif result["next_role"]:
        suggestion = f"Canonical flow suggests dispatching: {result['next_role']}"
        if workflow_id:
            suggestion += f" (workflow_id={workflow_id})"
        result["suggestion"] = suggestion
    elif normalised == "guardian" and not result["error"]:
        # Terminal state — cycle complete.
        try:
            events.emit(
                conn, type="cycle_complete", detail="Guardian completed — dispatch cycle done"
            )
        except Exception:
            pass
        result["suggestion"] = ""

    return result


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _resolve_lease_context(
    conn: sqlite3.Connection,
    project_root: str,
) -> tuple[str, str]:
    """Resolve workflow_id and active_lease_id from the active lease.

    Priority: active lease → empty strings (branch-derived fallback is handled
    in the bash adapter, not here — the engine only knows SQLite state).

    Returns:
        (workflow_id, active_lease_id) — both may be empty string if no active
        lease exists for the project root.
    """
    if not project_root:
        return "", ""

    try:
        lease = leases.get_current(conn, worktree_path=project_root)
        if lease and lease.get("status") == "active":
            wf_id = lease.get("workflow_id") or ""
            lease_id = lease.get("lease_id") or ""
            return wf_id, lease_id
    except Exception:
        pass

    return "", ""


def _route_from_completion(
    conn: sqlite3.Connection,
    role: str,
    workflow_id: str,
    active_lease_id: str,
) -> tuple[Optional[str], Optional[str]]:
    """Look up the completion record for role+lease and determine next_role.

    Implements the routing invariants from DEC-ROUTING-002:
      - Lease must be active (checked before this call via active_lease_id).
      - Completion record must exist and be valid.
      - Routing is exclusively via completions.determine_next_role().
      - Lease is released AFTER routing is determined.

    Returns:
        (next_role, error) — exactly one will be non-None on failure,
        next_role may be None for cycle-complete terminal states.
    """
    if not workflow_id:
        # No workflow_id resolvable at all — cannot route.
        error = (
            f"PROCESS ERROR: {role.capitalize()} completed but no workflow_id could be resolved. "
            "Cannot route."
        )
        return None, error

    if not active_lease_id:
        # No active lease — tester/guardian must run under a lease.
        error = (
            f"PROCESS ERROR: {role.capitalize()} completed without an active lease for "
            f"workflow {workflow_id}. Cannot route."
        )
        return None, error

    # Read the completion record BEFORE releasing the lease.
    try:
        comp = completions.latest(conn, lease_id=active_lease_id)
    except Exception as exc:
        error = (
            f"PROCESS ERROR: Failed to read completion record for {role} "
            f"lease {active_lease_id}: {exc}"
        )
        _safe_release(conn, active_lease_id)
        return None, error

    if comp is None:
        # Lease exists but no completion record — contract not fulfilled.
        try:
            events.emit(
                conn,
                type="completion_missing",
                detail=(
                    f"{role} lease {active_lease_id} has no completion record "
                    f"for workflow {workflow_id}"
                ),
            )
        except Exception:
            pass
        error = (
            f"PROCESS ERROR: {role.capitalize()} completed with active lease "
            f"{active_lease_id} but no completion record. Contract not fulfilled."
        )
        _safe_release(conn, active_lease_id)
        return None, error

    # Completion record found — check validity.
    comp_valid = comp.get("valid")
    is_valid = comp_valid == 1 or comp_valid is True

    if not is_valid:
        try:
            events.emit(
                conn,
                type="post_task_error",
                detail=f"{role} completion record invalid for workflow {workflow_id}",
            )
        except Exception:
            pass
        error = (
            f"PROCESS ERROR: {role.capitalize()} completion record invalid for "
            f"workflow {workflow_id} lease {active_lease_id}. Contract not fulfilled."
        )
        _safe_release(conn, active_lease_id)
        return None, error

    # Valid completion — route via determine_next_role() (DEC-COMPLETION-001).
    verdict = comp.get("verdict") or ""
    next_role = completions.determine_next_role(role, verdict)

    # Release lease AFTER routing is determined (DEC-ROUTING-002).
    _safe_release(conn, active_lease_id)

    return next_role, None


def _safe_release(conn: sqlite3.Connection, lease_id: str) -> None:
    """Release a lease without raising. Fire-and-forget."""
    try:
        leases.release(conn, lease_id)
    except Exception:
        pass

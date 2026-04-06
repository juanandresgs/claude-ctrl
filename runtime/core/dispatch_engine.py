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

@decision DEC-STOP-ASSESS-002
Title: agent_complete vs agent_stopped gating via stop_assessment event
Status: accepted
Rationale: Claude Code's Agent tool returns status=completed on any subagent stop,
  regardless of whether the agent actually finished. check-implementer.sh emits a
  stop_assessment event when it detects future-tense trailing patterns without test
  evidence (DEC-STOP-ASSESS-001). dispatch_engine reads that event within a 30-second
  window and gates the stop event type: agent_stopped when interrupted, agent_complete
  otherwise. The assessment is advisory — errors in the lookup never block routing.
  The emission is placed AFTER lease context resolution so workflow_id is available
  for the correlation key match, preventing false positives from concurrent stops.

@decision DEC-IMPL-CONTRACT-001
Title: Implementer completion contract overrides stop-assessment heuristic
Status: accepted
Rationale: The heuristic (DEC-STOP-ASSESS-001) detects interrupted implementers
  via future-tense trailing signals — a narrow proxy. When IMPL_STATUS and
  IMPL_HEAD_SHA trailers are present and valid, the structured contract is
  authoritative for agent_complete vs agent_stopped. The heuristic is fallback
  only when no valid completion record exists. Routing (implementer → tester)
  is unchanged — the contract affects stop quality, not routing.

  Implementation: stop-event emission is deferred past the implementer role block
  so the contract lookup can override is_interrupted before the event is written.
  For all other roles the behaviour is unchanged (heuristic computed and emitted
  in the same pass as before).
"""

from __future__ import annotations

import sqlite3
import time
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
        "auto_dispatch": False,
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

    # ---------------------------------------------------------------------------
    # Resolve workflow_id and active lease from the project root.
    #
    # WS1 invariant: lease workflow_id takes priority over branch-derived id.
    # Branch-derived id is only the fallback when no lease exists.
    # ---------------------------------------------------------------------------
    workflow_id, active_lease_id = _resolve_lease_context(conn, project_root)
    result["workflow_id"] = workflow_id

    # Compute heuristic interruption signal BEFORE role blocks, but defer
    # stop-event emission until AFTER the implementer contract check.
    # For all non-implementer roles the deferred emission is equivalent to the
    # old immediate-emission behaviour (DEC-STOP-ASSESS-002).
    # For the implementer role, a valid completion contract overrides the
    # heuristic result before the event is written (DEC-IMPL-CONTRACT-001).
    is_interrupted = False
    _interrupt_reason = ""
    try:
        is_interrupted, _interrupt_reason = _detect_interrupted(conn, normalised, project_root)
    except Exception:
        pass  # Heuristic is advisory; never block routing.

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

        # Check for structured completion contract (DEC-IMPL-CONTRACT-001).
        # When present and valid, trust IMPL_STATUS over the stop-assessment
        # heuristic. When absent or invalid, the heuristic from above still
        # applies. Routing (→ tester) is unchanged in all cases.
        if active_lease_id:
            try:
                impl_comp = completions.latest(conn, lease_id=active_lease_id)
                if impl_comp and impl_comp.get("role") == "implementer":
                    comp_valid = impl_comp.get("valid")
                    if comp_valid == 1 or comp_valid is True:
                        # Valid contract — override the heuristic.
                        impl_status = impl_comp.get("verdict", "")
                        is_interrupted = impl_status != "complete"
                        _interrupt_reason = (
                            f"contract: IMPL_STATUS={impl_status}" if is_interrupted else ""
                        )
                    else:
                        # Present but invalid — emit advisory, heuristic stands.
                        try:
                            events.emit(
                                conn,
                                type="impl_contract_invalid",
                                detail=f"Implementer completion invalid for {workflow_id}",
                            )
                            result["events"].append({"type": "impl_contract_invalid"})
                        except Exception:
                            pass
            except Exception:
                pass  # Contract lookup is best-effort; never block routing.

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
    # Emit stop audit event (deferred so implementer contract can override
    # is_interrupted before the event is written — DEC-IMPL-CONTRACT-001).
    # For all other roles this is equivalent to the original immediate emission.
    # ---------------------------------------------------------------------------
    try:
        stop_event_type = "agent_stopped" if is_interrupted else "agent_complete"
        stop_detail = f"Agent {agent_type} {'stopped (appears interrupted)' if is_interrupted else 'completed'}"
        evt_id = events.emit(conn, type=stop_event_type, detail=stop_detail)
        result["events"].append({"type": stop_event_type, "id": evt_id})
    except Exception:
        pass  # Audit emission is best-effort; never block routing.

    # ---------------------------------------------------------------------------
    # Auto-dispatch decision (W-AD-1 — DEC-AD-001)
    #
    # True when the transition is clear, unblocked, and non-terminal:
    #   - next_role is resolved (not None/empty)
    #   - no PROCESS ERROR occurred
    #   - agent was not interrupted mid-task
    #
    # False for: interrupted agents, routing errors, terminal states
    # (cycle complete after guardian committed/merged), unknown agent types.
    # ---------------------------------------------------------------------------
    result["auto_dispatch"] = (
        result["next_role"] is not None
        and result["next_role"] != ""
        and result["error"] is None
        and not is_interrupted
    )

    # ---------------------------------------------------------------------------
    # Build suggestion for hookSpecificOutput additionalContext
    # ---------------------------------------------------------------------------
    if result["error"]:
        result["suggestion"] = result["error"]
    elif result["next_role"]:
        if result["auto_dispatch"]:
            # Machine-parseable prefix: orchestrator can auto-dispatch without
            # prompting the user (W-AD-1).
            suggestion = f"AUTO_DISPATCH: {result['next_role']}"
        else:
            # Interrupted or non-auto path: keep canonical human-readable form.
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

    # Append interruption warning to suggestion when check-* hooks flagged an
    # interrupted stop. Advisory only — does not change routing.
    try:
        if is_interrupted:
            warning = (
                f"\nWARNING: Agent appears interrupted mid-task"
                f"{': ' + _interrupt_reason if _interrupt_reason else ''}. "
                "Response lacks completion confirmation. Consider resuming via SendMessage."
            )
            result["suggestion"] = (result["suggestion"] or "") + warning
    except NameError:
        pass  # is_interrupted not set if emit block raised before assignment.

    return result


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _resolve_stop_assessment_wf_id(
    conn: sqlite3.Connection,
    project_root: str,
) -> str:
    """Resolve workflow_id for stop-assessment event matching.

    Uses the same lease-first, branch-fallback resolution as
    check-implementer.sh Check 7 (DEC-STOP-ASSESS-004), so both sides
    produce the same correlation key when an active lease exists.

    This is intentionally separate from _resolve_lease_context() so the
    stop-assessment lookup can be called without affecting lease routing,
    eval-state writes, or result["workflow_id"].

    Args:
        conn:         Open SQLite connection.
        project_root: Filesystem path to the project root.

    Returns:
        workflow_id string — from active lease if present, otherwise
        branch-derived via policy_utils.current_workflow_id(). Empty string
        if both sources fail.
    """
    # Lease first (WS1 invariant — mirrors lease_context() in context-lib.sh:449)
    try:
        lease = leases.get_current(conn, worktree_path=project_root)
        if lease and lease.get("status") == "active":
            wf_id = lease.get("workflow_id") or ""
            if wf_id:
                return wf_id
    except Exception:
        pass
    # Branch-derived fallback (mirrors current_workflow_id() in context-lib.sh:214)
    try:
        from runtime.core import policy_utils

        return policy_utils.current_workflow_id(project_root)
    except Exception:
        return ""


def _detect_interrupted(
    conn: sqlite3.Connection,
    agent_type: str,
    project_root: str,
) -> tuple[bool, str]:
    """Check if check-* hooks flagged this agent stop as interrupted.

    Queries recent stop_assessment events within a 30-second window and matches
    on both agent_type and workflow_id for concurrency safety — two implementer
    stops on different workflows in the same window must not collide.

    The workflow_id is resolved via _resolve_stop_assessment_wf_id() which uses
    the same lease-first, branch-fallback order as check-implementer.sh Check 7
    (DEC-STOP-ASSESS-004), ensuring the correlation keys match.

    Args:
        conn:         Open SQLite connection.
        agent_type:   Normalised role string (e.g. 'implementer').
        project_root: Filesystem path to the project root. Used to resolve the
                      workflow_id via lease-first, branch-derived fallback.

    Returns:
        (is_interrupted, reason) — is_interrupted is False when no matching
        assessment event is found or when any error occurs during lookup.
        Assessment lookup is advisory; never raises.
    """
    try:
        assess_wf_id = _resolve_stop_assessment_wf_id(conn, project_root)
        recent = events.query(
            conn,
            type="stop_assessment",
            since=int(time.time()) - 30,
            limit=5,
        )
        for assess in recent:
            detail = assess.get("detail") or ""
            # Match on both agent_type and workflow_id so concurrent stops on
            # different workflows do not collide (DEC-STOP-ASSESS-002).
            if detail.startswith(f"{agent_type}|{assess_wf_id}|appears_interrupted"):
                parts = detail.split("|", 3)
                reason = parts[3] if len(parts) > 3 else ""
                return True, reason
    except Exception:
        pass  # Assessment lookup is advisory; never block routing.
    return False, ""


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

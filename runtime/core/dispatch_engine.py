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

  Key invariant from DEC-COMPLETION-001: routing for reviewer and guardian is
  exclusively via completions.determine_next_role(). No case statement maps
  verdicts to roles in this module — that table lives only in completions.py.

  Phase 5 fallback (DEC-PHASE5-ROUTING-001): when no persisted implementer
  critic review exists, implementer still falls back to reviewer. With the
  critic loop active, implementer routing is owned by critic_reviews:
  READY_FOR_REVIEWER → reviewer, TRY_AGAIN → implementer, BLOCKED_BY_PLAN
  → planner, CRITIC_UNAVAILABLE → reviewer. The tester role is retired
  (Phase 8 Slice 11) — it is no longer a known runtime type and stop events
  that carry ``agent_type="tester"`` are handled by the generic unknown-type
  path (silent exit).

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
  only when no valid completion record exists. The contract still affects stop
  quality only. Implementer routing is owned separately by critic_reviews.

  Implementation: stop-event emission is deferred past the implementer role block
  so the contract lookup can override is_interrupted before the event is written.
  For all other roles the behaviour is unchanged (heuristic computed and emitted
  in the same pass as before).

@decision DEC-GUARD-WT-001
Title: Planner routes to guardian (not implementer) for worktree provisioning (W-GWT-1)
Status: accepted
Rationale: Guardian is the sole worktree lifecycle authority (INIT-GUARD-WT). The
  routing table previously mapped planner -> implementer directly, bypassing Guardian
  for worktree creation. W-GWT-1 changes the planner block to route to guardian with
  guardian_mode="provision". The completions routing table adds ("guardian",
  "provisioned") -> "implementer" so the chain planner -> guardian -> implementer is
  preserved end-to-end.

  dispatch_engine remains a pure routing engine — no git side effects, no lease
  writes (DEC-GUARD-WT-002). Worktree creation, Guardian lease issuance, and
  implementer lease issuance happen in the Guardian agent via the cc-policy worktree
  provision CLI (W-GWT-2), not here.

  workflow_id at planner stop is best-effort: active lease if present, branch-derived
  fallback otherwise, omitted from the suggestion if neither yields a value. The
  orchestrator already knows the workflow_id from the plan context (DEC-GUARD-WT-006
  R3), so the provision CLI receives it as a CLI argument, not from the planner lease.

  worktree_path flows end-to-end: Guardian emits WORKTREE_PATH in its response text,
  check-guardian.sh parses it into the completion record payload, _route_from_completion
  extracts it and sets result["worktree_path"], the suggestion builder encodes it in the
  AUTO_DISPATCH line, and cli.py serializes it in the passthrough dict (DEC-GUARD-WT-003).

  On rework cycles (reviewer needs_changes -> implementer), the worktree already exists.
  dispatch_engine reads worktree_path from workflow_bindings via workflows.get_binding()
  and encodes it in the needs_changes AUTO_DISPATCH suggestion so the orchestrator can
  pass it to the re-dispatched implementer (DEC-GUARD-WT-004).

@decision DEC-PHASE5-STOP-REVIEW-SEPARATION-001
Title: Regular Stop review/advice is non-authoritative for workflow dispatch
Status: accepted
Rationale: The Codex stop-review gate (W-AD-3 / DEC-AD-002) was originally wired
  into the auto_dispatch decision path to allow a Codex supervisor to halt the
  workflow chain for human review. Phase 5 separates this: workflow auto_dispatch
  is determined by runtime workflow facts only (next_role present, no PROCESS ERROR,
  not interrupted). Regular Stop is deterministic advice only
  (stop-advisor.sh); the deterministic SubagentStop Codex braid is the
  runtime-owned implementer critic review consumed below. _check_codex_gate has
  been deleted — no runtime consumer remains.

@decision DEC-IMPLEMENTER-CRITIC-LOOP-001
Title: Implementer inner-loop routing is owned by persisted critic reviews
Status: accepted
Rationale: The implementer previously routed straight to reviewer, forcing every
  tactical deficiency to be adjudicated in the outer loop. The new critic loop
  introduces a runtime-owned critic_reviews domain whose persisted verdicts drive
  implementer routing: READY_FOR_REVIEWER → reviewer, TRY_AGAIN → implementer,
  BLOCKED_BY_PLAN → planner, CRITIC_UNAVAILABLE → reviewer. Retry-limit and
  repeated-fingerprint escalation are computed from critic_reviews state, not from
  hook-local heuristics, so the routing authority stays in Python/runtime.
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Optional

from runtime.core import (
    completions,
    critic_reviews,
    critic_runs,
    dispatch_shadow,
    evaluation,
    events,
    leases,
    reviewer_convergence,
)

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
                      reviewer, guardian). Unknown types return silently.
        project_root: Filesystem path to the project root. Used to resolve the
                      active lease via worktree path when no explicit lease_id
                      is supplied. May be empty string when unavailable.

    Returns:
        dict with:
          next_role   str | None  — None means terminal planner verdict or unknown type.
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
        # W-GWT-1: guardian_mode distinguishes provision (planner→guardian) from
        # merge (reviewer→guardian). Populated by the planner block only.
        "guardian_mode": "",
        # W-GWT-1: worktree_path is extracted from the guardian completion record
        # payload (provisioned verdict) or from workflow_bindings (rework path).
        "worktree_path": "",
        # DEC-IMPLEMENTER-CRITIC-LOOP-001: implementer critic routing metadata.
        "critic_found": False,
        "critic_verdict": "",
        "critic_provider": "",
        "critic_summary": "",
        "critic_detail": "",
        "critic_next_steps": [],
        "critic_artifact_path": "",
        "critic_try_again_streak": 0,
        "critic_retry_limit": 0,
        "critic_repeated_fingerprint_streak": 0,
        "critic_escalated": False,
        "critic_escalation_reason": "",
        # Reviewer → evaluation_state convergence bridge. Reviewer completions
        # own readiness; evaluation_state remains the Guardian landing gate.
        "evaluation_status": "",
        "evaluation_head_sha": "",
        "reviewer_convergence_reason": "",
        "next_dispatch_id": None,
        "work_item_id": "",
        "landing_grant": None,
        "grant_signal": "",
    }

    # Normalise capitalisation variants (matches bash `Plan` alias).
    normalised = agent_type.lower() if agent_type else ""
    if normalised == "plan":
        normalised = "planner"

    # Exit silently for unknown types — hooks must not interfere with inputs
    # they do not own.
    _known_types = {"planner", "implementer", "guardian", "reviewer"}
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
    # Phase 6 Slice 4: planner verdict extracted for the suggestion builder.
    # Terminal verdicts (goal_complete, needs_user_decision, blocked_external)
    # route to None; the suggestion builder emits explicit signals so the
    # orchestrator knows the reason.
    _planner_verdict = ""

    if normalised == "planner":
        # Phase 6 Slice 4: planner routing consumes structured completion record
        # via _route_from_completion → determine_next_role("planner", PLAN_VERDICT)
        # → stage_registry. Replaces unconditional planner→guardian(provision).
        next_role, error = _route_from_completion(
            conn,
            role="planner",
            workflow_id=workflow_id,
            active_lease_id=active_lease_id,
        )
        result["next_role"] = next_role
        result["error"] = error
        # W-GWT-1: when planner routes to guardian (next_work_item verdict),
        # set guardian_mode=provision so guardian knows to provision a worktree.
        if next_role == "guardian" and not error:
            result["guardian_mode"] = "provision"
        # Extract planner verdict for terminal suggestion signals.
        if not error and active_lease_id:
            try:
                _pcomp = completions.latest(conn, lease_id=active_lease_id)
                if _pcomp and _pcomp.get("role") == "planner":
                    _planner_verdict = _pcomp.get("verdict", "")
            except Exception:
                pass

        # Phase 6 Slice 6: autonomy-budget enforcement for planner continuation.
        # When planner routes to guardian (next_work_item verdict), check the
        # goal contract's autonomy budget. If budget is exhausted, goal is
        # not active, or no goal contract exists, suppress auto-dispatch and
        # surface a user-boundary signal. Fail closed: if the budget check
        # raises, do NOT auto-dispatch guardian — surface an error instead.
        # goal_continuation is the sole budget authority — hooks must not
        # duplicate this logic.
        if next_role == "guardian" and not error and workflow_id:
            try:
                from runtime.core import goal_continuation as gc

                cont = gc.check_continuation_budget(conn, workflow_id=workflow_id)
                if not cont.allowed:
                    result["next_role"] = None
                    result["guardian_mode"] = ""
                    result["budget_exhausted"] = True
                    result["budget_signal"] = cont.signal
            except Exception as exc:
                # Fail closed: budget authority failure must not allow
                # ungatted auto-dispatch to guardian.
                result["next_role"] = None
                result["guardian_mode"] = ""
                result["budget_exhausted"] = True
                result["budget_signal"] = "BUDGET_CHECK_FAILED"
                result["error"] = (
                    f"PROCESS ERROR: BUDGET_CHECK_FAILED — "
                    f"Goal-continuation budget check failed: {exc}"
                )

        # Phase 6 Slice 6: update goal status for terminal planner verdicts.
        if _planner_verdict and not error and workflow_id:
            try:
                from runtime.core import goal_continuation as gc

                gc.update_goal_status_for_verdict(
                    conn, workflow_id=workflow_id, verdict=_planner_verdict
                )
            except Exception:
                pass  # Goal-status update is best-effort.

    elif normalised == "implementer":
        # Default fallback (legacy/no-critic path): implementer routes to reviewer.
        # DEC-IMPLEMENTER-CRITIC-LOOP-001 replaces this whenever a persisted
        # critic review exists for the workflow.
        result["next_role"] = "reviewer"

        # Populate worktree_path so the reviewer runs in the same worktree
        # as the implementer. Prefer the live worktree root, then refine from
        # workflow bindings when available.
        if project_root:
            result["worktree_path"] = project_root
        if workflow_id:
            try:
                from runtime.core import workflows

                binding = workflows.get_binding(conn, workflow_id)
                if binding and binding.get("worktree_path"):
                    result["worktree_path"] = binding.get("worktree_path") or ""
            except Exception:
                pass  # Advisory; routing is not gated on the binding lookup.

        # Check for structured completion contract (DEC-IMPL-CONTRACT-001).
        # When present and valid, trust IMPL_STATUS over the stop-assessment
        # heuristic. When absent or invalid, the heuristic from above still
        # applies. Routing (→ reviewer) is unchanged in all cases.
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

        critic_resolution = None
        if workflow_id:
            try:
                critic_resolution = critic_reviews.assess_latest(
                    conn,
                    workflow_id=workflow_id,
                    project_root=project_root,
                )
            except Exception:
                critic_resolution = None

        if critic_resolution and critic_resolution.found:
            result["critic_found"] = True
            result["critic_verdict"] = critic_resolution.verdict
            result["critic_provider"] = critic_resolution.provider
            result["critic_summary"] = critic_resolution.summary
            result["critic_detail"] = critic_resolution.detail
            result["critic_next_steps"] = critic_resolution.next_steps
            result["critic_artifact_path"] = critic_resolution.artifact_path
            result["critic_try_again_streak"] = critic_resolution.try_again_streak
            result["critic_retry_limit"] = critic_resolution.retry_limit
            result["critic_repeated_fingerprint_streak"] = (
                critic_resolution.repeated_fingerprint_streak
            )
            result["critic_escalated"] = critic_resolution.escalated
            result["critic_escalation_reason"] = critic_resolution.escalation_reason
            result["next_role"] = critic_resolution.next_role
            if critic_resolution.next_role == "planner":
                result["worktree_path"] = ""
            elif critic_resolution.next_role == "implementer" and not result["worktree_path"]:
                result["worktree_path"] = project_root or ""

        if result["next_role"] == "reviewer" and workflow_id:
            grant = _landing_grant_for_active_work_item(conn, workflow_id, active_lease_id)
            if grant:
                result["work_item_id"] = grant.get("work_item_id", "") or ""
                result["landing_grant"] = grant
                if not grant.get("can_request_review", True):
                    result["next_role"] = None
                    result["grant_signal"] = (
                        "USER_DECISION_REQUIRED: work-item landing grant disables "
                        f"reviewer handoff for {result['work_item_id'] or workflow_id}"
                    )
                    try:
                        evt_id = events.emit(
                            conn,
                            type="work_item_grant_blocked_review",
                            source="dispatch_engine",
                            detail=result["grant_signal"],
                        )
                        result["events"].append(
                            {"type": "work_item_grant_blocked_review", "id": evt_id}
                        )
                    except Exception:
                        pass

        if active_lease_id:
            _safe_release(conn, active_lease_id)

    elif normalised == "reviewer":
        next_role, error = _route_from_completion(
            conn,
            role="reviewer",
            workflow_id=workflow_id,
            active_lease_id=active_lease_id,
        )
        result["next_role"] = next_role
        result["error"] = error
        if workflow_id and active_lease_id and not error:
            sync = _sync_reviewer_evaluation_state(
                conn,
                workflow_id=workflow_id,
                active_lease_id=active_lease_id,
            )
            if sync:
                result["evaluation_status"] = sync.get("status", "")
                result["evaluation_head_sha"] = sync.get("head_sha", "")
                result["reviewer_convergence_reason"] = sync.get("reason", "")
                if next_role == "guardian" and sync.get("status") != "ready_for_guardian":
                    result["next_role"] = None
                    result["error"] = (
                        "PROCESS ERROR: Reviewer emitted ready_for_guardian but "
                        f"readiness did not converge ({sync.get('reason', 'unknown')})."
                    )
        # Rework path: when reviewer routes to implementer (needs_changes),
        # the worktree already exists. Read worktree_path from workflow
        # bindings so the orchestrator can pass it in the implementer
        # re-dispatch context. (The legacy tester needs_changes path that
        # originally sourced this pattern was retired in Phase 8 Slice 11;
        # reviewer needs_changes is now the sole producer of this
        # DEC-GUARD-WT-004 re-dispatch shape.)
        if next_role == "implementer" and workflow_id and not error:
            try:
                from runtime.core import workflows

                binding = workflows.get_binding(conn, workflow_id)
                if binding:
                    result["worktree_path"] = binding.get("worktree_path") or ""
            except Exception:
                pass  # Advisory; routing is already determined.
        if workflow_id and not error:
            try:
                critic_runs.mark_fallback_completed(
                    conn,
                    workflow_id=workflow_id,
                    fallback="reviewer",
                    summary="Reviewer fallback completed after critic unavailability.",
                )
            except Exception:
                pass  # Telemetry only; reviewer routing remains authoritative.

    elif normalised == "guardian":
        next_role, error, worktree_path = _route_from_guardian_completion(
            conn,
            workflow_id=workflow_id,
            active_lease_id=active_lease_id,
        )
        result["next_role"] = next_role
        result["error"] = error
        if worktree_path:
            result["worktree_path"] = worktree_path

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
    # False for: interrupted agents, routing errors, planner terminal states
    # (goal_complete / blocked_external), unknown agent types.
    # ---------------------------------------------------------------------------
    result["auto_dispatch"] = (
        result["next_role"] is not None
        and result["next_role"] != ""
        and result["error"] is None
        and (
            not is_interrupted
            or (normalised == "implementer" and bool(result.get("critic_found")))
        )
    )

    # ---------------------------------------------------------------------------
    # DEC-PHASE5-STOP-REVIEW-SEPARATION-001: Codex stop-review gate is NOT
    # consulted for workflow auto-dispatch decisions. auto_dispatch is
    # determined by runtime workflow facts only (next_role present, no error,
    # not interrupted). Regular Stop advice/review is not read here;
    # implementer critic reviews are the only Codex verdicts consumed here.
    # ---------------------------------------------------------------------------

    # ---------------------------------------------------------------------------
    # Build suggestion for hookSpecificOutput additionalContext
    #
    # W-GWT-1 (DEC-GUARD-WT-003, DEC-GUARD-WT-007): The suggestion text is the
    # ONLY carrier of worktree_path and guardian_mode to the orchestrator via
    # additionalContext. post-task.sh strips the cli.py result to hookSpecificOutput
    # only, so encoded fields in the suggestion line are the last-mile delivery.
    #
    # Encoding rules:
    #   planner -> guardian:     AUTO_DISPATCH: guardian (mode=provision, workflow_id=W)
    #   guardian -> implementer: AUTO_DISPATCH: implementer (worktree_path=X, workflow_id=W)
    #   reviewer needs_changes:  AUTO_DISPATCH: implementer (worktree_path=X, workflow_id=W)
    #   all other transitions:   AUTO_DISPATCH: <role> (workflow_id=W)
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

        # Build the structured parameter block (W-GWT-1).
        # planner -> guardian: encode mode=provision
        # guardian/reviewer -> implementer with worktree: encode worktree_path
        params: list[str] = []
        guardian_mode = result.get("guardian_mode", "")
        worktree_path = result.get("worktree_path", "")
        if guardian_mode:
            params.append(f"mode={guardian_mode}")
        if worktree_path:
            params.append(f"worktree_path={worktree_path}")
        if workflow_id:
            params.append(f"workflow_id={workflow_id}")
        if params:
            suggestion += f" ({', '.join(params)})"

        critic_suffix = _format_critic_context(result)
        if critic_suffix:
            suggestion += critic_suffix

        result["suggestion"] = suggestion
    elif normalised == "planner" and not result["error"]:
        # Planner terminal or budget-gated state: next_role=None.
        # Phase 6 Slice 6: budget_signal takes precedence over terminal signals
        # when the planner verdict was next_work_item but budget enforcement
        # suppressed auto-dispatch.
        budget_signal = result.get("budget_signal", "")
        if budget_signal:
            result["suggestion"] = budget_signal
        else:
            # Terminal planner verdicts emit explicit signals:
            #   goal_complete       → GOAL_COMPLETE (all work items done)
            #   needs_user_decision → USER_DECISION_REQUIRED (user input needed)
            #   blocked_external    → BLOCKED_EXTERNAL (external dependency)
            _PLANNER_TERMINAL_SIGNALS = {
                "goal_complete": "GOAL_COMPLETE",
                "needs_user_decision": "USER_DECISION_REQUIRED",
                "blocked_external": "BLOCKED_EXTERNAL",
            }
            signal = _PLANNER_TERMINAL_SIGNALS.get(_planner_verdict, "")
            if signal:
                result["suggestion"] = signal
        if _planner_verdict == "goal_complete":
            try:
                events.emit(
                    conn,
                    type="cycle_complete",
                    detail="Planner goal_complete — all work items done",
                )
            except Exception:
                pass
    elif result.get("grant_signal"):
        result["suggestion"] = result["grant_signal"]
    elif normalised == "guardian" and not result["error"] and not result["next_role"]:
        # Guardian terminal state (should not occur with stage_registry routing,
        # but retained as a safety net for unknown verdicts).
        result["suggestion"] = ""

    # DEC-PHASE5-STOP-REVIEW-SEPARATION-001: Codex block reason no longer
    # appended to workflow suggestion. Stop-review is a separate lane.

    # Append interruption warning to suggestion when check-* hooks flagged an
    # interrupted stop. Advisory only — does not change routing.
    try:
        if is_interrupted and not (
            normalised == "implementer" and bool(result.get("critic_found"))
        ):
            warning = (
                f"\nWARNING: Agent appears interrupted mid-task"
                f"{': ' + _interrupt_reason if _interrupt_reason else ''}. "
                "Response lacks completion confirmation. Consider resuming via SendMessage."
            )
            result["suggestion"] = (result["suggestion"] or "") + warning
    except NameError:
        pass  # is_interrupted not set if emit block raised before assignment.

    # ---------------------------------------------------------------------------
    # Shadow observer emission (DEC-CLAUDEX-DISPATCH-SHADOW-001)
    #
    # Best-effort side-channel that records what the target ClauDEX stage
    # registry would have decided for this same (role, verdict) pair. Zero
    # routing effect: wrapped in a broad try/except, never mutates ``result``,
    # never reads from anything except the completion record that the live
    # path already consulted. When the live path errored, skipped altogether
    # since there is no routing decision to compare against.
    # ---------------------------------------------------------------------------
    try:
        if result["error"] is None:
            _emit_shadow_stage_decision(
                conn,
                live_role=normalised,
                result=result,
                active_lease_id=active_lease_id,
                workflow_id=workflow_id,
            )
    except Exception:
        pass  # Shadow emission must never affect live routing (DEC-CLAUDEX-DISPATCH-SHADOW-001).

    if result.get("auto_dispatch") and result.get("next_role") and workflow_id:
        try:
            result["next_dispatch_id"] = _persist_next_dispatch_action(
                conn,
                workflow_id=workflow_id,
                source_role=normalised,
                next_role=str(result["next_role"]),
                worktree_path=str(result.get("worktree_path") or ""),
                guardian_mode=str(result.get("guardian_mode") or ""),
                reason=str(result.get("suggestion") or ""),
                payload={
                    "workflow_id": workflow_id,
                    "source_role": normalised,
                    "next_role": result.get("next_role"),
                    "worktree_path": result.get("worktree_path") or "",
                    "guardian_mode": result.get("guardian_mode") or "",
                    "auto_dispatch": result.get("auto_dispatch"),
                    "critic_verdict": result.get("critic_verdict") or "",
                },
            )
        except Exception:
            pass

    return result


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _persist_next_dispatch_action(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    source_role: str,
    next_role: str,
    worktree_path: str,
    guardian_mode: str,
    reason: str,
    payload: dict,
) -> int:
    """Persist the structured next dispatch action.

    The hook suggestion remains a human view. This table is the runtime-owned
    carrier for the next dispatch parameters.
    """
    now = int(time.time())
    with conn:
        cur = conn.execute(
            """
            INSERT INTO dispatch_next_actions (
                workflow_id, source_role, next_role, worktree_path,
                guardian_mode, reason, payload_json, status, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)
            """,
            (
                workflow_id,
                source_role,
                next_role,
                worktree_path,
                guardian_mode,
                reason,
                json.dumps(payload, sort_keys=True),
                now,
            ),
        )
    return int(cur.lastrowid)


def _landing_grant_for_active_work_item(
    conn: sqlite3.Connection,
    workflow_id: str,
    active_lease_id: str,
) -> Optional[dict]:
    """Return the effective work-item grant for the active dispatch, if known."""
    if not workflow_id:
        return None

    work_item_id = ""
    if active_lease_id:
        try:
            row = conn.execute(
                """
                SELECT work_item_id
                FROM dispatch_attempts
                WHERE lease_id = ? AND work_item_id IS NOT NULL AND work_item_id != ''
                ORDER BY created_at DESC, id DESC
                LIMIT 1
                """,
                (active_lease_id,),
            ).fetchone()
            if row:
                work_item_id = row["work_item_id"] or ""
        except sqlite3.OperationalError:
            work_item_id = ""

        if not work_item_id:
            try:
                lease = leases.get(conn, active_lease_id)
                metadata = json.loads(lease.get("metadata_json") or "{}") if lease else {}
                if isinstance(metadata, dict):
                    work_item_id = str(metadata.get("work_item_id") or "")
            except (TypeError, json.JSONDecodeError):
                work_item_id = ""

    if not work_item_id:
        try:
            rows = conn.execute(
                """
                SELECT work_item_id
                FROM work_items
                WHERE workflow_id = ?
                  AND status IN ('in_progress', 'in_review', 'ready_to_land')
                ORDER BY created_at ASC, work_item_id ASC
                """,
                (workflow_id,),
            ).fetchall()
            if len(rows) == 1:
                work_item_id = rows[0]["work_item_id"] or ""
        except sqlite3.OperationalError:
            work_item_id = ""

    if not work_item_id:
        return None

    try:
        from runtime.core import work_item_grants

        return work_item_grants.effective(
            conn,
            workflow_id=workflow_id,
            work_item_id=work_item_id,
        ).as_dict()
    except Exception:
        return None


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


def _sync_reviewer_evaluation_state(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    active_lease_id: str,
) -> dict:
    """Project reviewer completion into the Guardian landing readiness store.

    Reviewer completions and findings are the review authority. Guardian landing
    policies intentionally read ``evaluation_state`` as their fast gate, so the
    dispatch stop path is the single bridge between those domains.
    """
    try:
        comp = completions.latest(conn, lease_id=active_lease_id)
    except Exception:
        return {}

    if not comp or comp.get("role") != "reviewer":
        return {}
    if not (comp.get("valid") == 1 or comp.get("valid") is True):
        return {}

    verdict = comp.get("verdict") or ""
    payload = comp.get("payload_json") or {}
    head_sha = payload.get("REVIEW_HEAD_SHA") if isinstance(payload, dict) else ""
    head_sha = str(head_sha or "").strip()

    status = ""
    reason = verdict
    blockers = 0

    if verdict == "ready_for_guardian":
        try:
            readiness = reviewer_convergence.assess(
                conn,
                workflow_id=workflow_id,
                current_head_sha=head_sha,
            )
            reason = readiness.reason
            blockers = readiness.open_blocking_count
            status = "ready_for_guardian" if readiness.ready_for_guardian else "needs_changes"
        except Exception as exc:
            reason = f"reviewer_convergence_error:{exc}"
            status = "needs_changes"
    elif verdict in {"needs_changes", "blocked_by_plan"}:
        status = verdict
    else:
        return {}

    try:
        evaluation.set_status(
            conn,
            workflow_id,
            status,
            head_sha=head_sha or None,
            blockers=blockers,
        )
        events.emit(
            conn,
            type="reviewer_evaluation_state",
            detail=f"Reviewer verdict {verdict} projected to evaluation_state={status} for {workflow_id}",
        )
    except Exception:
        return {}

    return {"status": status, "head_sha": head_sha, "reason": reason}


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
        next_role may be None for planner terminal verdicts or unknown combos.
    """
    if not workflow_id:
        # No workflow_id resolvable at all — cannot route.
        error = (
            f"PROCESS ERROR: {role.capitalize()} completed but no workflow_id could be resolved. "
            "Cannot route."
        )
        return None, error

    if not active_lease_id:
        # No active lease — reviewer/guardian must run under a lease.
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


def _route_from_guardian_completion(
    conn: sqlite3.Connection,
    workflow_id: str,
    active_lease_id: str,
) -> tuple[Optional[str], Optional[str], str]:
    """Look up the guardian completion record, determine next_role, and extract worktree_path.

    W-GWT-1 (DEC-GUARD-WT-003): When verdict is "provisioned", the completion
    record payload includes WORKTREE_PATH set by check-guardian.sh. This function
    extracts it so the caller can encode it in the AUTO_DISPATCH suggestion line
    and in result["worktree_path"] for cli.py serialization.

    All other routing logic mirrors _route_from_completion(). The only differences
    are the role is always "guardian" and the return tuple carries worktree_path.

    Returns:
        (next_role, error, worktree_path) — next_role and error follow the same
        contract as _route_from_completion(). worktree_path is empty string when
        verdict is not "provisioned" or when the payload does not contain it.
    """
    if not workflow_id:
        error = (
            "PROCESS ERROR: Guardian completed but no workflow_id could be resolved. Cannot route."
        )
        return None, error, ""

    if not active_lease_id:
        error = (
            f"PROCESS ERROR: Guardian completed without an active lease for "
            f"workflow {workflow_id}. Cannot route."
        )
        return None, error, ""

    # Read the completion record BEFORE releasing the lease (DEC-ROUTING-002).
    try:
        comp = completions.latest(conn, lease_id=active_lease_id)
    except Exception as exc:
        error = (
            f"PROCESS ERROR: Failed to read completion record for guardian "
            f"lease {active_lease_id}: {exc}"
        )
        _safe_release(conn, active_lease_id)
        return None, error, ""

    if comp is None:
        try:
            events.emit(
                conn,
                type="completion_missing",
                detail=(
                    f"guardian lease {active_lease_id} has no completion record "
                    f"for workflow {workflow_id}"
                ),
            )
        except Exception:
            pass
        error = (
            f"PROCESS ERROR: Guardian completed with active lease "
            f"{active_lease_id} but no completion record. Contract not fulfilled."
        )
        _safe_release(conn, active_lease_id)
        return None, error, ""

    # Completion record found — check validity.
    comp_valid = comp.get("valid")
    is_valid = comp_valid == 1 or comp_valid is True

    if not is_valid:
        try:
            events.emit(
                conn,
                type="post_task_error",
                detail=f"guardian completion record invalid for workflow {workflow_id}",
            )
        except Exception:
            pass
        error = (
            f"PROCESS ERROR: Guardian completion record invalid for "
            f"workflow {workflow_id} lease {active_lease_id}. Contract not fulfilled."
        )
        _safe_release(conn, active_lease_id)
        return None, error, ""

    # Valid completion — route via determine_next_role() (DEC-COMPLETION-001).
    verdict = comp.get("verdict") or ""
    next_role = completions.determine_next_role("guardian", verdict)

    # Extract WORKTREE_PATH from payload when verdict is "provisioned" (W-GWT-1).
    # check-guardian.sh parses this from the guardian response text and stores it
    # in the completion record payload alongside LANDING_RESULT and OPERATION_CLASS.
    worktree_path = ""
    if verdict == "provisioned":
        try:
            payload = comp.get("payload_json") or {}
            if isinstance(payload, dict):
                worktree_path = payload.get("WORKTREE_PATH") or ""
        except Exception:
            pass  # Best-effort; routing is already determined.

    # Release lease AFTER routing is determined (DEC-ROUTING-002).
    _safe_release(conn, active_lease_id)

    return next_role, None, worktree_path


def _safe_release(conn: sqlite3.Connection, lease_id: str) -> None:
    """Release a lease without raising. Fire-and-forget."""
    try:
        leases.release(conn, lease_id)
    except Exception:
        pass


def _format_critic_context(result: dict) -> str:
    """Render implementer critic routing metadata for hook output."""
    if not result.get("critic_found"):
        return ""

    verdict = str(result.get("critic_verdict") or "")
    provider = str(result.get("critic_provider") or "")
    summary = str(result.get("critic_summary") or "")
    detail = str(result.get("critic_detail") or "")
    next_steps = result.get("critic_next_steps") or []
    retry_limit = int(result.get("critic_retry_limit") or 0)
    try_again_streak = int(result.get("critic_try_again_streak") or 0)
    repeated_fp_streak = int(result.get("critic_repeated_fingerprint_streak") or 0)
    escalated = bool(result.get("critic_escalated"))
    escalation_reason = str(result.get("critic_escalation_reason") or "")

    lines: list[str] = [
        f"CRITIC: provider={provider or 'unknown'}, verdict={verdict}"
    ]
    if verdict == "TRY_AGAIN":
        if escalated:
            lines.append(
                f"CRITIC_RETRY: reviewer_adjudication after {escalation_reason}"
            )
        else:
            lines.append(
                f"CRITIC_RETRY: try_again={try_again_streak}, retry_limit={retry_limit}"
            )
        if repeated_fp_streak >= 2:
            lines.append(
                f"CRITIC_CONVERGENCE: repeated_fingerprint_streak={repeated_fp_streak}"
            )
    if summary:
        lines.append(f"CRITIC_SUMMARY: {summary}")
    if detail:
        lines.append(f"CRITIC_DETAIL: {detail}")
    if next_steps:
        lines.append("CRITIC_NEXT_STEPS:")
        for step in next_steps[:8]:
            lines.append(f"- {step}")
    if verdict == "TRY_AGAIN":
        lines.append(
            "CRITIC_ACTION: Re-dispatch implementer with CRITIC_DETAIL and CRITIC_NEXT_STEPS verbatim."
        )
    elif verdict == "BLOCKED_BY_PLAN":
        lines.append(
            "CRITIC_ACTION: Re-dispatch planner with CRITIC_DETAIL and CRITIC_NEXT_STEPS verbatim."
        )
    elif verdict == "CRITIC_UNAVAILABLE":
        lines.append(
            "CRITIC_ACTION: Dispatch reviewer subagent fallback for read-only adjudication."
        )
    return "\n" + "\n".join(lines) if lines else ""


def _emit_shadow_stage_decision(
    conn: sqlite3.Connection,
    *,
    live_role: str,
    result: dict,
    active_lease_id: str,
    workflow_id: str,
) -> None:
    """Emit a ``shadow_stage_decision`` audit event for the current routing.

    DEC-CLAUDEX-DISPATCH-SHADOW-001: this is the Phase 1 shadow observer.
    It records what the target ClauDEX stage registry would have routed for
    the same (live_role, verdict) pair so later parity analysis can classify
    known divergences without affecting any live routing.

    Best-effort contract:
      * Never raises (caller is already wrapped in try/except).
      * Never mutates ``result`` or any runtime state outside the events
        table.
      * Reads only the completion record that the live path already
        consulted. Completion records persist after lease release, so this
        is a safe pure read.

    The event detail is JSON-encoded with a stable field set produced by
    ``dispatch_shadow.compute_shadow_decision``.
    """
    # Look up the live verdict from the completion record. All routing roles
    # now have structured completion records (planner added Phase 6 Slice 4).
    live_verdict = ""
    if live_role in ("planner", "implementer", "guardian", "reviewer") and active_lease_id:
        try:
            comp = completions.latest(conn, lease_id=active_lease_id)
            if comp and comp.get("role") == live_role:
                live_verdict = comp.get("verdict") or ""
        except Exception:
            pass  # Best-effort; absence just means no verdict to compare.

    # All routing roles require a verdict for meaningful shadow comparison.
    # Absence of a verdict means the live path did not finish routing
    # (contract missing / invalid); skip emission.
    if not live_verdict:
        return

    decision = dispatch_shadow.compute_shadow_decision(
        live_role=live_role,
        live_verdict=live_verdict,
        live_next_role=result.get("next_role"),
        guardian_mode=result.get("guardian_mode", "") or "",
    )

    # Augment with workflow identity so downstream analysis can scope by
    # workflow without re-joining tables.
    payload = dict(decision)
    payload["workflow_id"] = workflow_id or ""

    try:
        detail = json.dumps(payload, sort_keys=True)
    except (TypeError, ValueError):
        return  # Unserialisable payload — drop silently.

    source = f"workflow:{workflow_id}" if workflow_id else None
    evt_id = events.emit(
        conn,
        type="shadow_stage_decision",
        source=source,
        detail=detail,
    )
    # Expose the event id in result["events"] for tests / diagnostics, but
    # do NOT add it to any routing-affecting field. auto_dispatch and
    # next_role are already finalised above.
    try:
        result["events"].append({"type": "shadow_stage_decision", "id": evt_id})
    except Exception:
        pass

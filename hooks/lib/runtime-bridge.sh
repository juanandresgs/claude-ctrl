#!/usr/bin/env bash
# runtime-bridge.sh — shell adapter between hook scripts and the typed runtime.
#
# @decision DEC-BRIDGE-001
# @title Shell wrappers isolate hook scripts from cc_policy JSON parsing
# @status accepted
# @rationale Hook scripts (context-lib.sh, subagent-start.sh) need scalar
#   string values (a role name, a status word) not raw JSON blobs. Parsing
#   JSON with jq inline at every call site creates duplication and makes
#   fallback logic harder to read. These wrappers centralise parsing and
#   return plain strings so callers stay declarative. All wrappers suppress
#   errors and return empty string on failure; callers then apply flat-file
#   fallback. This makes every integration point resilient to runtime
#   unavailability without duplicating error handling.
#
# Sourced by context-lib.sh (and transitively by every hook that sources it).
# Never call this file directly.

# ---------------------------------------------------------------------------
# DB path resolver — single source of truth for all hook callers
# ---------------------------------------------------------------------------

# @decision DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001
# @title _resolve_policy_db delegates hook DB routing to the runtime resolver
# @status accepted
# @rationale pre-agent.sh L201-209 and subagent-start.sh L117-120 each had a
#   2-tier resolver (CLAUDE_POLICY_DB → CLAUDE_PROJECT_DIR) that silently skipped
#   the carrier write/consume when both env vars were absent in the harness launch
#   env (the real production path for guardian SubagentStart on the global-soak lane).
#   The result: _CARRIER_DB was empty, the guard evaluated false, and carrier
#   operations were silently skipped — causing _HAS_CONTRACT=no, A8 deny at
#   canonical_seat_no_carrier_contract, and no marker seating.  This function
#   Later linked-worktree dispatch exposed the remaining split: shell used
#   git rev-parse --show-toplevel while runtime/core/config.py used
#   --git-common-dir to collapse feature worktrees onto the shared repo DB.
#   This helper now delegates non-explicit resolution to runtime.core.config so
#   hooks, CLI, prompt-pack, marker, lease, and completion paths share the same
#   DB authority.
# @chain pre-agent.sh carrier-write → pending_agent_requests → subagent-start.sh
#   carrier-consume → _HAS_CONTRACT=yes → marker seating → lease claim → context role
_resolve_policy_db() {
    # Priority order mirrors runtime.core.config.resolve_db_path() for concrete
    # project contexts:
    #   1. $CLAUDE_POLICY_DB if already set and non-empty  (caller wins)
    #   2. Explicit project root hint from $CLAUDE_PROJECT_DIR, if valid
    #   3. CWD git repo/worktree discovery, passed as an explicit project root
    # Returns empty outside project/git contexts; hooks must not silently route
    # dispatch-significant state to the global home DB.
    # Also exports CLAUDE_POLICY_DB when resolution succeeded via tier 2 or 3.
    # Side-effect-free if CLAUDE_POLICY_DB is already set.
    local resolved=""
    if [[ -n "${CLAUDE_POLICY_DB:-}" ]]; then
        local explicit_name=""
        explicit_name="$(basename "$CLAUDE_POLICY_DB" 2>/dev/null || printf '%s' "$CLAUDE_POLICY_DB")"
        if [[ "$explicit_name" != "policy.db" ]]; then
            printf '%s\n' "$CLAUDE_POLICY_DB"
            return 0
        fi
        unset CLAUDE_POLICY_DB
    fi

    local bridge_dir repo_root python_bin project_root
    bridge_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$bridge_dir/../.." && pwd)"
    python_bin="$(command -v python3 2>/dev/null || printf '%s' python3)"
    project_root="${CLAUDE_PROJECT_DIR:-}"

    resolved="$("$python_bin" - "$repo_root" "$project_root" <<'PY' 2>/dev/null || true
import os
import subprocess
import sys
from pathlib import Path

repo_root = sys.argv[1]
project_root = sys.argv[2] or None
sys.path.insert(0, repo_root)

from runtime.core.config import resolve_db_path

if project_root and Path(project_root).is_dir():
    print(resolve_db_path(project_root=project_root))
    raise SystemExit(0)

try:
    result = subprocess.run(
        ["git", "-C", os.getcwd(), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True,
        timeout=5,
    )
except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
    result = None

if result is not None and result.returncode == 0 and result.stdout.strip() == "true":
    print(resolve_db_path(project_root=os.getcwd()))
PY
)"

    if [[ -n "$resolved" ]]; then
        export CLAUDE_POLICY_DB="$resolved"
        printf '%s\n' "$resolved"
    fi
}

# ---------------------------------------------------------------------------
# Core entry point
# ---------------------------------------------------------------------------

# _resolve_runtime_python
# Single authoritative Python resolver for shell → runtime calls.
#
# Priority:
#   1. CLAUDEX_PYTHON_BIN override
#   2. First executable python that can import yaml
#   3. Fallback to python3 on PATH
#
# The yaml import check matches the real runtime dependency surface used by
# prompt-pack compilation. Without it, hooks can silently select the system
# interpreter and collapse valid runtime-first paths into generic failures.
_CLAUDEX_RUNTIME_PYTHON=""
_resolve_runtime_python() {
    if [[ -n "${CLAUDEX_PYTHON_BIN:-}" ]]; then
        printf '%s\n' "${CLAUDEX_PYTHON_BIN}"
        return 0
    fi

    if [[ -n "${_CLAUDEX_RUNTIME_PYTHON:-}" ]]; then
        printf '%s\n' "${_CLAUDEX_RUNTIME_PYTHON}"
        return 0
    fi

    local candidate=""
    local resolved=""
    for candidate in python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
        resolved="$candidate"
        if [[ "$candidate" != */* ]]; then
            resolved="$(command -v "$candidate" 2>/dev/null || true)"
            [[ -z "$resolved" ]] && continue
        elif [[ ! -x "$candidate" ]]; then
            continue
        fi

        if "$resolved" -c 'import yaml' >/dev/null 2>&1; then
            _CLAUDEX_RUNTIME_PYTHON="$resolved"
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    resolved="$(command -v python3 2>/dev/null || echo "python3")"
    _CLAUDEX_RUNTIME_PYTHON="$resolved"
    printf '%s\n' "$resolved"
}

cc_policy() {
    local runtime_root="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
    # Delegate DB resolution to the single authoritative resolver so cc_policy
    # callers inherit the same 3-tier fallback without duplicating the logic.
    # (DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001)
    local _skip_db_resolution=false
    if [[ "${1:-}" == "hook" && ( "${2:-}" == "envelope" || "${2:-}" == "bash-pre-baseline" ) ]]; then
        _skip_db_resolution=true
    fi
    if [[ "$_skip_db_resolution" != "true" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
        _resolve_policy_db >/dev/null
    fi
    "$(_resolve_runtime_python)" "$runtime_root/cli.py" "$@"
}

# cc_policy_local_runtime <runtime_root> <args...>
# Uses the same Python and DB authority as cc_policy(), but lets callers bind
# the runtime root to the current worktree instead of the installed default.
cc_policy_local_runtime() {
    local runtime_root="$1"
    shift || true
    CLAUDE_RUNTIME_ROOT="$runtime_root" cc_policy "$@"
}

# ---------------------------------------------------------------------------
# Runtime notification transport
# ---------------------------------------------------------------------------

emit_runtime_notification() {
    local result_json="${1:-}"
    local hooks_dir="${2:-}"
    local notification_json=""
    local notify_hook=""

    notification_json=$(printf '%s' "$result_json" | jq -c '.runtimeNotification // empty' 2>/dev/null || echo "")
    [[ -z "$notification_json" || "$notification_json" == "null" ]] && return 0

    notify_hook="${hooks_dir}/notify.sh"
    [[ -f "$notify_hook" ]] || return 0

    printf '%s' "$notification_json" | bash "$notify_hook" >/dev/null 2>&1 || true
}

strip_runtime_notification() {
    local result_json="${1:-}"
    printf '%s' "$result_json" | jq -c 'del(.runtimeNotification)' 2>/dev/null || printf '%s\n' "$result_json"
}

export -f emit_runtime_notification strip_runtime_notification

# ---------------------------------------------------------------------------
# Schema bootstrap (lazy, idempotent)
# ---------------------------------------------------------------------------

# _rt_ensure_schema: create DB tables if the DB file does not yet exist.
# Called at the top of every wrapper so the first hook invocation in a new
# environment auto-provisions the schema without requiring a manual init step.
_rt_ensure_schema() {
    local db_path="${CLAUDE_POLICY_DB:-$HOME/.claude/state.db}"
    if [[ ! -f "$db_path" ]]; then
        cc_policy schema ensure >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Evaluation-state wrappers (TKT-024: sole readiness authority)
# ---------------------------------------------------------------------------

# rt_eval_get <workflow_id>
# Prints the evaluation status string ("idle", "pending", "needs_changes",
# "ready_for_guardian", "blocked_by_plan") or "idle" on failure.
rt_eval_get() {
    _rt_ensure_schema
    local result
    result=$(cc_policy evaluation get "$1" 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r '.status // "idle"'
}

# rt_eval_set <workflow_id> <status> [head_sha] [blockers] [major] [minor]
# Upserts evaluation state in SQLite. Suppresses output; callers check exit code.
rt_eval_set() {
    _rt_ensure_schema
    local wf_id="$1" status="$2"
    local head_sha="${3:-}" blockers="${4:-0}" major="${5:-0}" minor="${6:-0}"
    local args=("evaluation" "set" "$wf_id" "$status")
    [[ -n "$head_sha" ]] && args+=("--head-sha" "$head_sha")
    [[ "${blockers:-0}" -gt 0 ]] && args+=("--blockers" "$blockers")
    [[ "${major:-0}" -gt 0 ]]   && args+=("--major"    "$major")
    [[ "${minor:-0}" -gt 0 ]]   && args+=("--minor"    "$minor")
    cc_policy "${args[@]}" >/dev/null 2>&1
}

# rt_eval_list
# Prints raw JSON list of all evaluation_state rows, or nothing on failure.
rt_eval_list() {
    _rt_ensure_schema
    cc_policy evaluation list 2>/dev/null
}

# rt_eval_invalidate <workflow_id>
# Resets status from ready_for_guardian → pending if currently ready.
# Prints "true" when invalidated, "false" when no-op.
rt_eval_invalidate() {
    _rt_ensure_schema
    local result
    result=$(cc_policy evaluation invalidate "$1" 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r '.invalidated // false'
}

# ---------------------------------------------------------------------------
# Agent marker wrappers
# ---------------------------------------------------------------------------

# rt_marker_get_active [project_root] [workflow_id]
# Prints the active marker JSON, or {"found":false,...} when no active marker
# exists.
#
# ENFORCE-RCA-6-ext / #26: Accepts optional project_root and workflow_id
# so the caller can scope the lookup to its own project. Without scoping,
# a stale marker from an unrelated project can be returned and poison role
# detection — e.g. the orchestrator inherits an implementer role from a
# marker left behind by a different project and is silently authorised
# for source writes.
rt_marker_get_active() {
    _rt_ensure_schema
    local root="${1:-}"
    local wf="${2:-}"
    local args=()
    [[ -n "$root" ]] && args+=(--project-root "$root")
    [[ -n "$wf"   ]] && args+=(--workflow-id "$wf")
    cc_policy marker get-active "${args[@]}" 2>/dev/null
}

# rt_marker_get_active_role [project_root] [workflow_id]
# Prints the role string of the currently active marker, or nothing when
# no active marker exists.
rt_marker_get_active_role() {
    local result
    result=$(rt_marker_get_active "${1:-}" "${2:-}" 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r 'if .found then .role else empty end'
}

# rt_marker_set <agent_id> <role>
rt_marker_set() {
    _rt_ensure_schema
    cc_policy marker set "$1" "$2" >/dev/null 2>&1
}

# rt_marker_deactivate <agent_id>
rt_marker_deactivate() {
    _rt_ensure_schema
    cc_policy marker deactivate "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Event wrapper
# ---------------------------------------------------------------------------

# rt_event_emit <type> [detail]
rt_event_emit() {
    _rt_ensure_schema
    cc_policy event emit "$1" --detail "${2:-}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Statusline snapshot wrapper
# ---------------------------------------------------------------------------

# rt_statusline_snapshot
# Prints the full JSON snapshot dict to stdout, or nothing on failure.
# scripts/statusline.sh calls this instead of reading flat-file cache so
# all HUD state flows through the canonical runtime projection.
#
# Returns raw JSON (not a scalar) so the caller can jq-parse any field it needs:
#   active_agent, active_agent_id, worktree_count, worktrees[],
#   dispatch_status, dispatch_initiative, dispatch_cycle_id,
#   recent_event_count, recent_events[], snapshot_at
# Note: proof_status/proof_workflow were removed in W-CONV-4.
rt_statusline_snapshot() {
    _rt_ensure_schema
    cc_policy statusline snapshot 2>/dev/null
}

# ---------------------------------------------------------------------------
# Workflow binding wrappers
# ---------------------------------------------------------------------------

# rt_workflow_bind <workflow_id> <worktree_path> <branch> [ticket] [initiative]
# Registers the workflow→worktree→branch binding in SQLite.
# Silent on success; suppresses errors so hook callers are not disrupted.
rt_workflow_bind() {
    _rt_ensure_schema
    local wf_id="$1" wt_path="$2" branch="$3"
    local ticket="${4:-}" initiative="${5:-}"
    local args=("workflow" "bind" "$wf_id" "$wt_path" "$branch")
    [[ -n "$ticket" ]] && args+=("--ticket" "$ticket")
    [[ -n "$initiative" ]] && args+=("--initiative" "$initiative")
    cc_policy "${args[@]}" >/dev/null 2>&1
}

# rt_workflow_get <workflow_id>
# Prints the worktree_path string for the workflow, or empty string on failure.
# Used by get_workflow_binding() in context-lib.sh and guard.sh Check 12.
rt_workflow_get() {
    _rt_ensure_schema
    local result
    result=$(cc_policy workflow get "$1" 2>/dev/null) || return 0
    printf '%s\n' "$result" | jq -r 'if .found then .worktree_path else empty end' 2>/dev/null || true
}

# rt_workflow_scope_check <workflow_id> <changed_files_json>
# Returns the compliance JSON dict from cc-policy, or empty string on failure.
# Example: rt_workflow_scope_check "feature-foo" '["runtime/cli.py"]'
rt_workflow_scope_check() {
    _rt_ensure_schema
    local result
    result=$(cc_policy workflow scope-check "$1" --changed "$2" 2>/dev/null) || return 0
    printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# Bug pipeline wrapper
# ---------------------------------------------------------------------------

# rt_bug_file <bug_type> <title> [body] [scope] [source_component] [file_path] [evidence]
#
# Routes a discovered bug through the canonical filing pipeline:
#   cc-policy bug file '{"bug_type":...}'
#
# Returns the JSON result dict from cc-policy (includes "disposition", "fingerprint",
# "issue_url", "encounter_count"). On runtime unavailability returns a safe fallback
# JSON with disposition="failed_to_file" so callers can log and continue.
#
# All arguments after <title> are optional and default to empty / "global".
# Never blocks hook execution: errors are swallowed and reported via the fallback JSON.
#
# @decision DEC-BUGS-003
# @title rt_bug_file routes all enforcement-gap filings through the canonical pipeline
# @status accepted
# @rationale The prior direct `todo.sh add` call in file_enforcement_gap_backlog()
#   bypassed deduplication, audit-event emission, and SQLite persistence. Routing
#   through cc-policy bug file ensures: (1) fingerprint dedup prevents duplicate
#   GitHub issues across worktrees; (2) failed filings are retryable; (3) every
#   disposition emits an auditable event. The shell wrapper is intentionally thin —
#   no logic beyond JSON assembly and the cc-policy call lives here.
rt_bug_file() {
    _rt_ensure_schema
    local bug_type="$1"
    local title="$2"
    local body="${3:-}"
    local scope="${4:-global}"
    local source_component="${5:-}"
    local file_path="${6:-}"
    local evidence="${7:-}"

    # Build JSON payload using printf to avoid subshell quoting pitfalls.
    # Single-quotes inside values are not escaped here — callers must not pass
    # single-quote characters in these fields. For hook usage this is safe.
    local json
    json=$(printf '{"bug_type":"%s","title":"%s","body":"%s","scope":"%s","source_component":"%s","file_path":"%s","evidence":"%s","fixed_now":false}' \
        "$bug_type" "$title" "$body" "$scope" "$source_component" "$file_path" "$evidence")

    cc_policy bug file "$json" 2>/dev/null \
        || echo '{"disposition":"failed_to_file","error":"runtime unavailable","fingerprint":"","issue_url":null,"encounter_count":0}'
}

# ---------------------------------------------------------------------------
# Approval token wrappers (DEC-APPROVAL-001)
# ---------------------------------------------------------------------------

# rt_approval_grant <workflow_id> <op_type> [granted_by]
# Silently creates a one-shot approval token in SQLite.
# granted_by defaults to "user" when omitted.
rt_approval_grant() {
    _rt_ensure_schema
    local args=("approval" "grant" "$1" "$2")
    [[ -n "${3:-}" ]] && args+=("--granted-by" "$3")
    cc_policy "${args[@]}" >/dev/null 2>&1
}

# rt_approval_check <workflow_id> <op_type>
# Prints "true" if an unconsumed approval was found and consumed, "false" otherwise.
# Returns exit code 1 on runtime failure (caller treats as false).
rt_approval_check() {
    _rt_ensure_schema
    local result
    result=$(cc_policy approval check "$1" "$2" 2>/dev/null) || { echo "false"; return 1; }
    printf '%s\n' "$result" | jq -r '.approved // false'
}

# ---------------------------------------------------------------------------
# Dispatch lease wrappers (Phase 2: execution contracts)
# ---------------------------------------------------------------------------
#
# @decision DEC-LEASE-002
# @title Lease wrappers isolate hooks from cc_policy JSON parsing for contracts
# @status accepted
# @rationale Phase 1 leases.py and completions.py provide SQLite-backed
#   execution contracts. These shell wrappers follow the same pattern as the
#   proof/eval/marker wrappers above: all error paths return safe JSON
#   ({"found":false} or "{}") so callers never receive empty strings from
#   failed pipeline reads. Wrappers suppress stderr so runtime unavailability
#   does not interrupt hook output. The rt_lease_claim wrapper returns the
#   full JSON from cc_policy lease claim — callers extract lease_id and fields
#   with jq. rt_lease_validate_op returns the full validate-op JSON dict.
#   rt_lease_expire_stale is fire-and-forget (no output needed).

# rt_lease_validate_op <command> [worktree_path]
# Returns full validate-op JSON dict, or '{}' on failure.
rt_lease_validate_op() {
    _rt_ensure_schema
    local command="${1:-}" worktree_path="${2:-}"
    local args=("lease" "validate-op" "$command")
    [[ -n "$worktree_path" ]] && args+=("--worktree-path" "$worktree_path")
    cc_policy "${args[@]}" 2>/dev/null || echo '{}'
}

# rt_lease_current [worktree_path]
# Returns active lease JSON dict, or '{"found":false}' on failure.
rt_lease_current() {
    _rt_ensure_schema
    local worktree_path="${1:-}"
    local args=("lease" "current")
    [[ -n "$worktree_path" ]] && args+=("--worktree-path" "$worktree_path")
    cc_policy "${args[@]}" 2>/dev/null || echo '{"found":false}'
}

# rt_lease_claim <agent_id> [worktree_path] [expected_role]
# Claims an active lease for agent_id. Returns full claim JSON or '{"found":false}'.
# If expected_role is provided, the lease role must match or claim returns {"claimed":false}.
rt_lease_claim() {
    _rt_ensure_schema
    local agent_id="${1:-}" worktree_path="${2:-}" expected_role="${3:-}"
    local args=("lease" "claim" "$agent_id")
    [[ -n "$worktree_path" ]] && args+=("--worktree-path" "$worktree_path")
    [[ -n "$expected_role" ]] && args+=("--expected-role" "$expected_role")
    cc_policy "${args[@]}" 2>/dev/null || echo '{"found":false}'
}

# rt_lease_issue_for_dispatch <role> [worktree_path] [workflow_id] [branch] [requires_eval]
# Issues a dispatch lease. Returns full issue JSON or '{"issued":false}'.
# requires_eval defaults to true; pass "false", "0", or "no" to append --no-eval.
rt_lease_issue_for_dispatch() {
    _rt_ensure_schema
    local role="${1:-}" worktree_path="${2:-}" workflow_id="${3:-}" branch="${4:-}" requires_eval="${5:-true}"
    local args=("lease" "issue-for-dispatch" "$role")
    [[ -n "$worktree_path" ]] && args+=("--worktree-path" "$worktree_path")
    [[ -n "$workflow_id" ]] && args+=("--workflow-id" "$workflow_id")
    [[ -n "$branch" ]] && args+=("--branch" "$branch")
    case "$requires_eval" in
        false|False|FALSE|0|no|No|NO)
            args+=("--no-eval")
            ;;
    esac
    cc_policy "${args[@]}" 2>/dev/null || echo '{"issued":false}'
}

# rt_lease_release <lease_id>
# Transitions active → released. Fire-and-forget; never blocks hook execution.
# stdout suppressed: cc_policy outputs {"released":true} which would corrupt
# hook stdout when called from post-task.sh (DEC-ROUTING-002).
rt_lease_release() {
    _rt_ensure_schema
    local lease_id="${1:-}"
    [[ -n "$lease_id" ]] && cc_policy lease release "$lease_id" >/dev/null 2>&1 || true
}

# rt_lease_expire_stale
# Expires all active leases past their TTL. Fire-and-forget.
rt_lease_expire_stale() {
    _rt_ensure_schema
    cc_policy lease expire-stale >/dev/null 2>&1 || true
}

# rt_completion_submit <lease_id> <workflow_id> <role> <payload_json>
# Validates and records a completion. Returns submit result JSON or '{"valid":false}'.
rt_completion_submit() {
    _rt_ensure_schema
    local lease_id="${1:-}" workflow_id="${2:-}" role="${3:-}" payload="${4:-}"
    cc_policy completion submit \
        --lease-id "$lease_id" \
        --workflow-id "$workflow_id" \
        --role "$role" \
        --payload "$payload" \
        2>/dev/null || echo '{"valid":false}'
}

# rt_completion_latest [lease_id]
# Returns most recent completion record or '{"found":false}'.
rt_completion_latest() {
    _rt_ensure_schema
    local lease_id="${1:-}"
    local args=("completion" "latest")
    [[ -n "$lease_id" ]] && args+=("--lease-id" "$lease_id")
    cc_policy "${args[@]}" 2>/dev/null || echo '{"found":false}'
}

# rt_completion_route <role> <verdict>
# Calls determine_next_role(role, verdict) via cc-policy and returns the JSON
# result: {"next_role": "guardian"|"implementer"|"planner"|null, "status": "ok"}.
# next_role is null for cycle-complete terminal states.
# Returns '{"next_role":null}' on runtime failure so callers can detect terminal state.
#
# @decision DEC-ROUTING-001
# @title rt_completion_route is the sole routing call site in bash
# @status accepted
# @rationale post-task.sh previously duplicated the routing table as a bash case
#   statement, creating a dual-authority between bash and completions.py.
#   This wrapper centralises the call to determine_next_role() so the routing
#   table in completions.py is the single source of truth. Any future verdict
#   additions only require changing completions.py, not both files.
rt_completion_route() {
    _rt_ensure_schema
    local role="${1:-}" verdict="${2:-}"
    cc_policy completion route "$role" "$verdict" 2>/dev/null || echo '{"next_role":null}'
}

# ---------------------------------------------------------------------------
# Test-state wrappers (WS3: SQLite authority, replaces flat-file bridge)
# ---------------------------------------------------------------------------
#
# @decision DEC-WS3-002
# @title rt_test_state_* wrappers route all test-state I/O through cc-policy
# @status accepted
# @rationale guard.sh Checks 8/9, subagent-start.sh, and check-guardian.sh
#   previously called `python3 -m runtime.cli test-state get` which read the
#   .claude/.test-status flat-file. WS3 replaces the flat-file read with a
#   SQLite-backed test_state table. These wrappers follow the same pattern as
#   rt_eval_get/set: they call cc_policy, suppress stderr, and return safe
#   defaults on failure. Enforcement hooks call rt_test_state_get instead of
#   invoking python3 directly, making the call site uniform and the internal
#   storage swappable without touching hooks.

# rt_test_state_get [project_root]
# Returns the full JSON dict from cc-policy test-state get, or "" on failure.
# Callers parse .status and .found with jq.
rt_test_state_get() {
    _rt_ensure_schema
    local project_root="${1:-$(detect_project_root 2>/dev/null || echo "")}"
    local args=("test-state" "get")
    [[ -n "$project_root" ]] && args+=("--project-root" "$project_root")
    cc_policy "${args[@]}" 2>/dev/null || echo '{"found":false,"status":"unknown","fail_count":0}'
}

# rt_test_state_set <status> [project_root] [head_sha] [pass_count] [fail_count] [total]
# Upserts test state in SQLite. Fire-and-forget for hook callers; exit code
# propagated so callers can log failures if needed.
rt_test_state_set() {
    _rt_ensure_schema
    local status="$1"
    local project_root="${2:-$(detect_project_root 2>/dev/null || echo "")}"
    local head_sha="${3:-}"
    local pass_count="${4:-0}"
    local fail_count="${5:-0}"
    local total="${6:-0}"
    local args=("test-state" "set" "$status")
    [[ -n "$project_root" ]] && args+=("--project-root" "$project_root")
    [[ -n "$head_sha" ]] && args+=("--head-sha" "$head_sha")
    [[ "$pass_count" != "0" ]] && args+=("--passed" "$pass_count")
    [[ "$fail_count" != "0" ]] && args+=("--failed" "$fail_count")
    [[ "$total" != "0" ]] && args+=("--total" "$total")
    cc_policy "${args[@]}" >/dev/null 2>&1
}

# rt_test_state_check_pass [project_root]
# Returns exit code 0 (true) when status is pass or pass_complete, 1 otherwise.
# Convenience wrapper for guard conditions that want a boolean branch.
rt_test_state_check_pass() {
    _rt_ensure_schema
    local project_root="${1:-$(detect_project_root 2>/dev/null || echo "")}"
    local result
    result=$(rt_test_state_get "$project_root") || result=""
    local status
    status=$(printf '%s' "${result:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
    [[ "$status" == "pass" || "$status" == "pass_complete" ]]
}

# ---------------------------------------------------------------------------
# Observatory wrappers (W-OBS-1)
# ---------------------------------------------------------------------------

# rt_obs_metric <name> <value> [labels_json] [session_id] [role]
# Emit a single metric to obs_metrics. Silent on success; suppresses errors.
# Example: rt_obs_metric agent_duration_s 42.0 '{"phase":"impl"}' '' implementer
#
# @decision DEC-BRIDGE-002
# @title rt_obs_metric is the sole shell entry point for metric emission
# @status accepted
# @rationale Hook scripts must not build cc_policy obs emit calls inline.
#   All observatory metric writes go through this wrapper so error suppression,
#   arg handling, and future instrumentation changes stay in one place.
rt_obs_metric() {
    _rt_ensure_schema
    local name="$1" value="$2" labels="${3:-}" session_id="${4:-}" role="${5:-}"
    local args=("obs" "emit" "$name" "$value")
    [[ -n "$labels" ]] && args+=(--labels "$labels")
    [[ -n "$session_id" ]] && args+=(--session-id "$session_id")
    [[ -n "$role" ]] && args+=(--role "$role")
    cc_policy "${args[@]}" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Observatory batch accumulator (W-OBS-1)
# ---------------------------------------------------------------------------

# Internal accumulator array for batch metric emission.
# Use _obs_accum to queue metrics, then rt_obs_metric_batch to flush.
_OBS_BATCH=()

# _obs_accum <name> <value> [labels_json] [role]
# Append one metric to the pending batch.  Does not flush.
_obs_accum() {
    local lj="${3:-null}"
    local role="${4:-}"
    _OBS_BATCH+=("$(printf '{"name":"%s","value":%s,"labels":%s,"role":"%s"}' "$1" "$2" "$lj" "$role")")
}

# rt_obs_metric_batch
# Flush all accumulated metrics in a single cc_policy obs emit-batch call.
# Clears _OBS_BATCH after the flush.  No-op when the batch is empty.
rt_obs_metric_batch() {
    [[ ${#_OBS_BATCH[@]} -eq 0 ]] && return 0
    _rt_ensure_schema
    printf '[%s]' "$(IFS=,; echo "${_OBS_BATCH[*]}")" \
        | cc_policy obs emit-batch >/dev/null 2>&1 || true
    _OBS_BATCH=()
}

# ---------------------------------------------------------------------------
# Enforcement config wrappers (DEC-CONFIG-AUTHORITY-001)
# ---------------------------------------------------------------------------

# rt_config_get <key> [scope]
# Returns the config value for the given key, or the sentinel string
# "__FAIL_CLOSED__" when the CLI call fails (network error, missing table, etc.).
#
# IMPORTANT: Callers MUST distinguish:
#   ""               — key exists but is explicitly set to empty string
#   "__FAIL_CLOSED__" — lookup failed; treat as enforcement-on (fail-closed)
#   (absent / None)  — key not set; fall back to built-in default
#
# The fail-closed sentinel avoids silent fail-open behaviour when the policy
# engine is temporarily unavailable. Any caller that receives "__FAIL_CLOSED__"
# MUST default to the more-restrictive posture (i.e. treat the gate as enabled).
rt_config_get() {
    _rt_ensure_schema
    local key="${1:-}"
    [[ -z "$key" ]] && { printf '__FAIL_CLOSED__\n'; return 1; }
    local result
    if ! result=$(cc_policy config get "$key" 2>/dev/null); then
        printf '__FAIL_CLOSED__\n'
        return 1
    fi
    printf '%s\n' "$result" | jq -r '.value // empty' 2>/dev/null
}

# rt_config_set <key> <value> [scope]
# Writes an enforcement_config row via cc-policy config set.
# Caller must have CLAUDE_AGENT_ROLE=guardian in the environment or the
# Python layer will raise PermissionError and return non-zero exit.
# Returns nonzero on any error.
rt_config_set() {
    _rt_ensure_schema
    local key="${1:-}" value="${2:-}"
    local scope="${3:-global}"
    [[ -z "$key" || -z "$value" ]] && return 1
    cc_policy config set "$key" "$value" --scope "$scope" >/dev/null 2>&1
}

#!/usr/bin/env bash
# Hook library bootstrapper — sources log.sh and core-lib.sh.
#
# Usage: source "$(dirname "$0")/source-lib.sh"
#
# All 29 hooks source this file to get logging and context utilities.
# Direct sourcing from the hooks/ directory — simple and reliable.
#
# @decision DEC-SRCLIB-001
# @title Direct hook library sourcing (replaces session-scoped caching)
# @status accepted
# @rationale The previous caching mechanism (d6635ce) cached hook libraries
#   per session to prevent race conditions during concurrent git merges. However,
#   when cache population failed (permissions, disk full, missing session ID),
#   the source commands for log.sh and context-lib.sh were never reached. Since
#   all 29 hooks source this file, a single cache failure bricked the entire
#   hook system with no recovery path. Direct sourcing eliminates the failure
#   mode entirely. The theoretical git-merge race condition is mitigated by
#   session-init.sh's smoke test that validates library sourcing on startup.
#
# @decision DEC-SPLIT-002
# @title source-lib.sh provides require_*() lazy loaders for domain libraries
# @status accepted
# @rationale context-lib.sh was 2,221 lines loaded by every hook. Splitting
#   into domain libraries (git-lib, plan-lib, trace-lib, session-lib, doc-lib)
#   reduces parse overhead for hooks that only need 1-2 functions. require_*()
#   functions provide idempotent lazy loading — calling require_git() twice is
#   safe. All hooks and tests use require_*() for domain libraries directly.
#   context-lib.sh compatibility shim has been removed (issue #65).
#
# @decision DEC-PERF-001
# @title Hook timing instrumentation via EXIT trap
# @status accepted
# @rationale We need to measure real hook wall-clock time to validate the Phase 2
#   refactoring gains (claimed ~60ms per invocation vs. ~180-480ms before). The
#   EXIT trap approach adds <1ms overhead: two date calls + one printf append.
#   The trap fires on both clean exit and crash, so timing is always recorded.
#   nanosecond precision (date +%s%N) is used on Linux/macOS; the fallback to
#   second-level granularity on systems without %N support produces a "0ms"
#   reading rather than failing. The log file (.hook-timing.log) is append-only
#   with tab-separated fields: timestamp, hook_name, elapsed_ms, exit_code.
#   File lives in CLAUDE_DIR (default: ~/.claude) so it is co-located with
#   other state files and easy to rotate or grep. Writing errors are suppressed
#   (|| true) to prevent timing instrumentation from denying legitimate commands.

# Guard: prevent re-sourcing (test files that source multiple hooks would
# otherwise stack EXIT traps and crash bash's eval parser — exit code 139).
[[ -n "${_SOURCE_LIB_LOADED:-}" ]] && return 0
_SOURCE_LIB_LOADED=1
_SOURCE_LIB_VERSION=1

# --- Hook timing instrumentation — <5ms overhead ---
# Records wall-clock time for each hook invocation to .hook-timing.log
_HOOK_START_NS=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")
# Allow consolidated hooks to pre-set _HOOK_NAME before sourcing this file.
# Without this guard, BASH_SOURCE[1] in a consolidated hook resolves to the
# consolidated hook itself (correct) but the basename strips .sh — which works.
# However, when source-lib.sh is sourced from a function or subshell, BASH_SOURCE[1]
# may be empty or resolve to an intermediate file. Pre-setting _HOOK_NAME is the
# reliable fix; this guard makes the pre-set take precedence.
if [[ -z "${_HOOK_NAME:-}" ]]; then
    _HOOK_NAME="${BASH_SOURCE[1]:-unknown}"
    _HOOK_NAME="$(basename "$_HOOK_NAME" .sh)"
fi

_hook_log_timing() {
    local _exit_code=$?  # MUST be first line — capture before anything clobbers it
    local end_ns
    end_ns=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")
    local elapsed_ms=$(( (end_ns - _HOOK_START_NS) / 1000000 ))
    local claude_dir="${CLAUDE_DIR:-$HOME/.claude}"
    local timing_log="$claude_dir/.hook-timing.log"
    mkdir -p "$claude_dir" 2>/dev/null || true
    # Append: timestamp hook_name event_type elapsed_ms exit_code
    # _HOOK_EVENT_TYPE is set by consolidated hooks (pre-bash, pre-write, post-write, stop).
    # Old 4-field entries (without event_type) are still valid; hook-timing-report.sh handles both formats.
    printf '%s\t%s\t%s\t%d\t%d\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_HOOK_NAME" "${_HOOK_EVENT_TYPE:-}" "$elapsed_ms" "$_exit_code" >> "$timing_log" 2>/dev/null || true
    # Corpus capture: when HOOK_CORPUS_CAPTURE=1, dump raw input to timestamped file
    # Captures real-world hook input for corpus analysis (consumer script not yet built).
    if [[ "${HOOK_CORPUS_CAPTURE:-}" == "1" && -n "${HOOK_INPUT:-}" ]]; then
        local corpus_dir="${claude_dir}/tests/corpus/${_HOOK_EVENT_TYPE:-unknown}"
        mkdir -p "$corpus_dir" 2>/dev/null || true
        printf '%s\n' "$HOOK_INPUT" > "$corpus_dir/$(date +%Y%m%d-%H%M%S)-${_HOOK_NAME}.json" 2>/dev/null || true
    fi
}
# Preserve existing EXIT trap (e.g., crash trap from pre-bash.sh) so both fire on exit.
# Without this, trap '_hook_log_timing' EXIT would REPLACE the crash trap set by pre-bash.sh
# before sourcing source-lib.sh, meaning library-load failures would no longer deny.
_PREV_EXIT_TRAP=$(trap -p EXIT | sed "s/trap -- '\\(.*\\)' EXIT/\\1/" || echo "")
if [[ -n "$_PREV_EXIT_TRAP" ]]; then
    trap '_hook_log_timing; eval "$_PREV_EXIT_TRAP"' EXIT
else
    trap '_hook_log_timing' EXIT
fi

# CWD recovery: if the shell's CWD was deleted (e.g., worktree removal between
# hook invocations), recover before any hook logic runs. Without this, $PWD
# lookups fail with ENOENT and all subsequent detect_project_root() calls
# return garbage. This guard runs before sourcing log.sh so it is always active.
[[ ! -d "${PWD:-}" ]] && { cd "${HOME}" 2>/dev/null || cd /; }

_SRCLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @decision DEC-SRCLIB-FALLBACK-001
# @title Validate _SRCLIB_DIR contains expected sibling files; fallback to canonical hooks dir
# @status accepted
# @rationale When tests in worktrees source source-lib.sh with a path that doesn't
#   include the hooks/ directory segment (e.g., via a symlink or relative path that
#   resolves differently), BASH_SOURCE[0] resolves to a directory that doesn't contain
#   log.sh or core-lib.sh. The fallback to $HOME/.claude/hooks/ is always the canonical
#   location — this is defensive: it preserves the happy path (direct sourcing from the
#   hooks/ dir works unchanged) and only activates when the resolved directory is wrong.
if [[ ! -f "${_SRCLIB_DIR}/log.sh" ]]; then
    _SRCLIB_DIR="$HOME/.claude/hooks"
fi

source "${_SRCLIB_DIR}/log.sh"
source "${_SRCLIB_DIR}/core-lib.sh"

# --- Lazy domain library loaders ---
# These functions load domain libraries on demand. Each is idempotent:
# calling require_git() twice is safe (second call is a no-op).
#
# Usage in hooks that want to minimize load time:
#   require_session
#   append_session_event "write" "{}" "$PROJECT_ROOT"
#
# Hooks that need all domains (session-init.sh, compact-preserve.sh) call each
# require_*() explicitly — require_all() was removed in Phase 3 (dead code audit:
# it was defined but never called; all multi-domain hooks use explicit selectors).
#
# @decision DEC-PERF-002
# @title source-lib.sh loads core-lib.sh only; domain libs loaded on demand
# @status accepted
# @rationale Previously source-lib.sh sourced context-lib.sh which loaded ALL
#   domain libraries (3,175 lines total). Every hook paid the full parse cost.
#   Now source-lib.sh loads only log.sh (269 lines) + core-lib.sh (398 lines) =
#   667 lines. Domain libraries are loaded on demand via require_*() functions.
#   require_all() was removed (Phase 3 dead code audit) — no production hook called
#   it; session-init.sh and similar hooks enumerate their requires explicitly.
#   Tests now use source-lib.sh + require_*() directly (context-lib.sh removed).

require_git() {
    [[ -n "${_GIT_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/git-lib.sh"
}

require_plan() {
    [[ -n "${_PLAN_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/plan-lib.sh"
}

require_trace() {
    [[ -n "${_TRACE_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/trace-lib.sh"
}

require_session() {
    [[ -n "${_SESSION_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/session-lib.sh"
}

require_doc() {
    [[ -n "${_DOC_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/doc-lib.sh"
}

# read_trace_evidence TRACE_DIR [max_chars]
# Returns real evidence from trace artifacts, filtering auto-captured garbage.
# Priority: verification-output.txt > test-output.txt > commit-info.txt > summary.md
# Returns empty string if no real evidence found.
# Auto-captured files are detected by "# Auto-captured from" on the first line.
#
# @decision DEC-EVGATE-005
# @title read_trace_evidence() in source-lib.sh — shared across all hooks
# @status accepted
# @rationale All hooks source source-lib.sh unconditionally, making it the right
#   home for the evidence-reading helper. Placing it here avoids a new domain lib
#   and makes it available to stop.sh, check-tester.sh, and post-task.sh without
#   any require_*() call. Auto-capture filtering prevents garbage (captured env
#   dumps, hook timings) from being presented to users as "verification evidence".
read_trace_evidence() {
    local trace_dir="$1"
    local max_chars="${2:-2000}"
    local artifacts_dir="$trace_dir/artifacts"

    # Priority-ordered artifact list
    local -a artifact_names=("verification-output.txt" "test-output.txt" "commit-info.txt")

    for artifact in "${artifact_names[@]}"; do
        local artifact_path="$artifacts_dir/$artifact"
        [[ -f "$artifact_path" ]] || continue

        # Filter auto-captured garbage: skip if first line matches "# Auto-captured from"
        local first_line
        first_line=$(head -1 "$artifact_path" 2>/dev/null || echo "")
        if [[ "$first_line" == "# Auto-captured from"* ]]; then
            continue
        fi

        # Real artifact found — return its content (truncated)
        head -c "$max_chars" "$artifact_path" 2>/dev/null
        return 0
    done

    # Fallback: summary.md (labeled as agent summary, not raw output)
    local summary_path="$trace_dir/summary.md"
    if [[ -s "$summary_path" ]]; then
        local summary_size
        summary_size=$(wc -c < "$summary_path" 2>/dev/null || echo 0)
        if [[ "$summary_size" -ge 50 ]]; then
            local fallback_chars=$((max_chars > 1500 ? 1500 : max_chars))
            printf '[Agent summary — not raw terminal output]\n'
            head -c "$fallback_chars" "$summary_path" 2>/dev/null
            return 0
        fi
    fi

    # No real evidence found
    return 1
}

require_ci() {
    [[ -n "${_CI_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/ci-lib.sh"
}

# detect_workflow_id — determine the active workflow from a file path or env context.
#
# Returns a worktree identifier (the worktree directory name under .worktrees/) or "main".
# Used to scope proof-status to the specific workflow so parallel worktrees have
# independent proof state.
#
# Priority:
#   1. File path: if filepath contains /.worktrees/, extract the worktree name
#   2. WORKTREE_PATH env var: set by subagent-start.sh for agents running in worktrees
#   3. Default: "main" (main checkout or unknown context)
#
# Usage:
#   workflow_id=$(detect_workflow_id "$FILE_PATH")
#   workflow_id=$(detect_workflow_id "")  # reads WORKTREE_PATH
#
# @decision DEC-V3-FIX5-001
# @title detect_workflow_id() for per-worktree proof isolation
# @status accepted
# @rationale All agents share PROJECT_ROOT (the main checkout) so .proof-status-{phash}
#   is shared across worktrees. When implementer-B writes a file, it invalidates
#   the proof that tester-A verified for implementer-A. Scoping proof to the worktree
#   requires identifying which worktree a file belongs to. detect_workflow_id()
#   extracts the worktree name from file paths (/.worktrees/NAME/...) or from the
#   WORKTREE_PATH environment variable set by subagent-start.sh.
detect_workflow_id() {
    local filepath="${1:-}"

    # Priority 1: Extract worktree name from file path
    if [[ "$filepath" == */.worktrees/* ]]; then
        local after="${filepath#*/.worktrees/}"
        local wt_name="${after%%/*}"
        if [[ -n "$wt_name" ]]; then
            echo "$wt_name"
            return 0
        fi
    fi

    # Priority 2: WORKTREE_PATH env var (set by subagent-start.sh)
    if [[ -n "${WORKTREE_PATH:-}" ]]; then
        local wt_name="${WORKTREE_PATH##*/}"
        if [[ -n "$wt_name" ]]; then
            echo "$wt_name"
            return 0
        fi
    fi

    # Default: main checkout (no worktree)
    echo "main"
}

export -f detect_workflow_id

require_state() {
    [[ -n "${_STATE_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/state-lib.sh"
}
# require_state is intentionally not called from production hooks.
# state_update/state_read are used optionally via: type state_update &>/dev/null && ...
# (in log.sh and session-lib.sh). Tests call require_state directly.
# See test-proof-lifecycle.sh:T09 for the test coverage of this loader.

# verify_library_consistency
#   Checks that all loaded library versions match the expected version.
#   Returns 0 if all consistent, 1 if mismatches found.
#   Outputs warning messages for each mismatch.
#
# @decision DEC-RSM-SELFCHECK-001
# @title Version sentinel system for detecting library skew
# @status accepted
# @rationale Interrupted git pulls or partial file syncs can leave libraries
#   at different versions. Version sentinels enable runtime detection of such
#   skew at session start, with clear diagnostics for the user.
verify_library_consistency() {
    local expected_version="${1:-1}"
    local mismatches=0

    # Check core-lib.sh and log.sh (always loaded)
    if [[ -n "${_CORE_LIB_VERSION:-}" && "$_CORE_LIB_VERSION" != "$expected_version" ]]; then
        echo "WARNING: core-lib.sh version mismatch (loaded=$_CORE_LIB_VERSION expected=$expected_version)"
        mismatches=$((mismatches + 1))
    fi
    if [[ -n "${_LOG_LIB_VERSION:-}" && "$_LOG_LIB_VERSION" != "$expected_version" ]]; then
        echo "WARNING: log.sh version mismatch (loaded=$_LOG_LIB_VERSION expected=$expected_version)"
        mismatches=$((mismatches + 1))
    fi

    # Check optionally-loaded domain libraries (only if loaded).
    # Format: VAR:LIBNAME:EXPECTED (EXPECTED defaults to expected_version if omitted).
    # Per-library expected versions allow state-lib.sh to be at v2 while
    # other libraries remain at v1 (DEC-SQLITE-001 Wave 1 rewrite).
    local lib_vars=(
        "_STATE_LIB_VERSION:state-lib.sh:2"
        "_SESSION_LIB_VERSION:session-lib.sh"
        "_TRACE_LIB_VERSION:trace-lib.sh"
        "_PLAN_LIB_VERSION:plan-lib.sh"
        "_GIT_LIB_VERSION:git-lib.sh"
        "_DOC_LIB_VERSION:doc-lib.sh"
        "_CI_LIB_VERSION:ci-lib.sh"
    )

    for entry in "${lib_vars[@]}"; do
        local var="${entry%%:*}"
        local rest="${entry#*:}"
        local lib="${rest%%:*}"
        local lib_expected="${rest#*:}"
        # If no per-library expected version specified, use the global one
        [[ "$lib_expected" == "$lib" ]] && lib_expected="$expected_version"
        local val="${!var:-}"
        if [[ -n "$val" && "$val" != "$lib_expected" ]]; then
            echo "WARNING: $lib version mismatch (loaded=$val expected=$lib_expected)"
            mismatches=$((mismatches + 1))
        fi
    done

    return $mismatches
}

export -f verify_library_consistency

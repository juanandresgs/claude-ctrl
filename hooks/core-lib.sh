#!/usr/bin/env bash
# core-lib.sh — Universal utilities loaded by EVERY hook via source-lib.sh.
#
# This is the always-loaded base library. All functions here are safe to call
# anywhere. Domain libraries (git-lib, plan-lib, trace-lib, session-lib, doc-lib)
# may depend on functions defined here.
#
# @decision DEC-SPLIT-001
# @title context-lib.sh decomposed into focused domain libraries with lazy loading
# @status accepted
# @rationale context-lib.sh was 2,221 lines sourced by every hook. Every hook paid
#   the full parse cost even for hooks that only need 1-2 functions. The split
#   creates a small always-loaded core (~200 lines) and larger domain libraries
#   loaded on demand via require_*() functions in source-lib.sh. Backward
#   compatibility maintained via context-lib.sh compatibility shim that sources
#   all modules. No functional changes — pure file reorganization.
#
# @decision DEC-REMED-004
# @title emit_deny()/emit_advisory()/emit_flush() in core-lib.sh
# @status accepted
# @rationale Each hook previously defined its own deny() function with subtle
#   differences: some called _log_deny(), some used jq -Rs escaping, some used
#   jq --arg escaping. The unified emit_*() family provides a single correct
#   implementation that: (1) always calls _log_deny for audit trail, (2) always
#   uses jq -Rs for proper escaping, (3) sets _HOOK_COMPLETED=true to coordinate
#   with the fail-closed crash trap, (4) supports optional additionalContext param.
#   Hooks call enable_fail_closed() once to register their name; emit_deny() uses
#   _HOOK_NAME to tag log entries without requiring per-call repetition.
#
# @decision DEC-REMED-003
# @title declare_gate() replaces comment-based gate scanning
# @status accepted
# @rationale gate-inventory.sh previously used static grep patterns to discover
#   gates (# --- Check N:, # --- Gate N:). This was fragile: any formatting
#   change broke detection. declare_gate() embeds gate metadata directly in
#   executable code. When HOOK_GATE_SCAN=1, hooks run in scan-only mode and
#   emit GATE tab-separated lines before returning 0. gate-inventory.sh calls
#   each hook with HOOK_GATE_SCAN=1 < /dev/null to harvest the manifest.
#   No behavioral change in normal mode — declare_gate() is a no-op unless
#   HOOK_GATE_SCAN=1 is set.
#
# @decision DEC-REMED-005
# @title cache_project_context() for one-time detect_project_root/get_claude_dir
# @status accepted
# @rationale detect_project_root() and get_claude_dir() each spawn git subprocesses.
#   pre-write.sh called detect_project_root() 5 times and get_claude_dir() 3 times
#   in different gates. cache_project_context() calls each once and stores results
#   in _CACHED_PROJECT_ROOT and _CACHED_CLAUDE_DIR. Callers replace repeated calls
#   with $variable references. Measured savings: ~40-80ms per pre-write.sh invocation
#   (2-4 avoided git subprocesses at ~20ms each on the meta-repo).
#
# @decision DEC-REMED-006
# @title enable_fail_closed() opt-in crash trap with merge-deadlock prevention
# @status accepted
# @rationale The crash trap pattern was copy-pasted across pre-bash.sh, pre-write.sh,
#   and task-track.sh. Each copy had slightly different behavior — some had the
#   merge-deadlock prevention, some didn't. enable_fail_closed() provides a single
#   correct implementation: deny on crash unless ~/.claude is in a merge state,
#   in which case degrade to allow (prevents deadlock when hook source has conflicts).
#   Pre-bash.sh keeps an INLINE trap before source-lib.sh (to catch library-load
#   failures), then calls enable_fail_closed() after source-lib.sh succeeds to
#   replace it with the canonical implementation.
#
# Provides:
#   project_hash         - 8-char SHA-256 hash of path
#   is_source_file       - Check if file is a source file by extension
#   is_skippable_path    - Check if file should be skipped (test/config/vendor)
#   is_test_file         - Check if file is a test file by path/naming
#   is_claude_meta_repo  - Check if directory is the ~/.claude meta-repo
#   atomic_write         - Write via temp-file-then-mv (POSIX atomic)
#   validate_state_file  - Guard corrupt-file reads
#   read_test_status     - Read .test-status into globals
#   safe_cleanup         - Delete directory without CWD-deletion bug
#   append_audit         - Append to .audit-log
#   declare_gate         - Register a gate (scan-mode aware)
#   emit_deny            - Emit PreToolUse deny JSON and exit
#   emit_advisory        - Buffer an advisory message
#   emit_flush           - Emit all buffered advisories as a single JSON
#   enable_fail_closed   - Install deny-on-crash EXIT trap
#   cache_project_context - Cache project root and claude dir
#   _file_mtime          - Cross-platform file mtime (Linux-first stat order)
#   _with_timeout        - Portable timeout wrapper (Perl fallback on macOS)
#   Constants: SOURCE_EXTENSIONS, DECISION_LINE_THRESHOLD, etc.

_CORE_LIB_VERSION=1

# Portable SHA-256 command — initialize if not already set by log.sh.
# Guard prevents double-initialization when both core-lib.sh and log.sh are sourced.
# @decision DEC-SHA256-INIT-001
# @title _SHA256_CMD initialization in core-lib.sh
# @status accepted
# @rationale core-lib.sh can be sourced without log.sh (e.g. in tests and standalone
#   hooks). Without this block, $_SHA256_CMD is empty and project_hash() produces
#   .proof-status- (empty hash) instead of a valid 8-char hex hash. The guard
#   [[ -z "${_SHA256_CMD:-}" ]] prevents double-initialization when both libraries
#   are sourced — log.sh's definition takes precedence if it loaded first.
if [[ -z "${_SHA256_CMD:-}" ]]; then
    if command -v shasum >/dev/null 2>&1; then
        _SHA256_CMD="shasum -a 256"
    elif command -v sha256sum >/dev/null 2>&1; then
        _SHA256_CMD="sha256sum"
    else
        _SHA256_CMD="cat"  # last resort — won't hash but won't crash
    fi
fi

# project_hash — compute deterministic 8-char hash of a project root path.
# Duplicated from log.sh so core-lib.sh can be sourced independently.
# Both definitions are identical; double-sourcing is safe (last definition wins).
# @decision DEC-ISOLATION-001 (see log.sh for full rationale)
project_hash() {
    echo "${1:?project_hash requires a path argument}" | ${_SHA256_CMD:-shasum -a 256} | cut -c1-8
}

# --- Protected State Files Registry ---
# @decision DEC-STATE-REGISTRY-001
# @title _PROTECTED_STATE_FILES array for centralized write-guard enforcement
# @status accepted
# @rationale Gate 0 in pre-write.sh originally used inline pattern matching
#   (*proof-status* || *test-status*) to detect protected files. As the state
#   management system grew (adding .proof-epoch, .state.lock, .proof-status.lock),
#   this inline list would need to be updated in every gate that references it.
#   The registry pattern centralizes the list in core-lib.sh (always-loaded),
#   making is_protected_state_file() available to any hook without duplication.
#   New protected files need only be added here — all gates update automatically.
_PROTECTED_STATE_FILES=(
    ".proof-status"
    ".test-status"
    ".proof-epoch"
    ".state.lock"
    ".proof-status.lock"
    "proof-status"       # state/{phash}/proof-status (no dot prefix)
    "test-status"        # state/{phash}/test-status (no dot prefix)
    "proof-epoch"        # state/{phash}/proof-epoch (no dot prefix)
    "proof.lock"         # state/locks/proof.lock
    "state.lock"         # state/locks/state.lock (no dot prefix)
    ".orchestrator-sid"  # Dispatch enforcement: orchestrator session marker
)

# is_protected_state_file FILEPATH
#   Returns 0 if the file basename matches any protected state file pattern,
#   or if the filepath is under a state/ directory.
#   Dot-prefixed patterns use prefix-glob (catches .proof-status.lock,
#   .proof-status-<hash>, etc.). Non-dot patterns use exact match only —
#   they live in state/{phash}/ dirs and must not match files like
#   test-statusline.sh (false-positive from "test-status" prefix glob).
#   Usage: is_protected_state_file "/some/path/.proof-status" && emit_deny "..."
is_protected_state_file() {
    local filepath="$1"
    local basename="${filepath##*/}"
    # Match against registry
    for pattern in "${_PROTECTED_STATE_FILES[@]}"; do
        if [[ "$pattern" == .* ]]; then
            # Dot-prefixed: prefix-glob to catch .proof-status.lock, .proof-status-<hash>
            [[ "$basename" == $pattern* ]] && return 0
        else
            # No dot prefix: exact match only to avoid false positives
            [[ "$basename" == "$pattern" ]] && return 0
        fi
    done
    # Path-based match: anything under state/ directory is protected
    [[ "$filepath" == */state/* ]] && return 0
    return 1
}

# --- Constants ---
# Single source of truth for thresholds and patterns across all hooks.
# DECISION: Consolidated constants. Rationale: Magic numbers duplicated across
# hooks create drift risk when requirements change. Status: accepted.
DECISION_LINE_THRESHOLD=50
TEST_STALENESS_THRESHOLD=600    # 10 minutes in seconds
SESSION_STALENESS_THRESHOLD=1800 # 30 minutes in seconds

# @decision DEC-V3-FIX3-001
# @title GUARDIAN_ACTIVE_TTL constant for guardian marker freshness checks
# @status accepted
# @rationale The 600-second TTL for guardian marker validity was duplicated as
#   magic number 600 in both post-write.sh and pre-bash.sh. A single constant
#   in core-lib.sh ensures consistent behavior and documents the tiered approach:
#   - GUARDIAN_ACTIVE_TTL (600s): "is a guardian active right now?" decisions
#   - Init cleanup (30 min): clean markers from likely-crashed agents
#   - Session cleanup (60 min): belt-and-suspenders final cleanup
GUARDIAN_ACTIVE_TTL=600

# TTL rate limits for expensive stop.sh operations (seconds).
# @decision DEC-PERF-003
# @title TTL sentinel rate-limiting for stop.sh per-turn overhead
# @status accepted
# @rationale stop.sh fires on every agent response turn (~85 turns/implementer).
#   Three operations cost 2.3s+ per invocation: @decision scan, manifest backup,
#   and todo network fetch. TTL sentinel files (epoch timestamps) gate each operation
#   to a maximum frequency. Cost of check: ~1ms (one cat + arithmetic). Measured
#   savings: ~2.3s/turn × 85 turns ≈ 3-4 minutes per agent session eliminated.
STOP_SURFACE_TTL=300    # @decision scan: max once per 5 min
STOP_TODO_TTL=600       # todo network fetch: max once per 10 min
STOP_BACKUP_TTL=3600    # manifest backup: max once per hour

# --- Source file detection ---
# Single source of truth for source file extensions across all hooks.
# DECISION: Consolidated extension list. Rationale: Source file regex was
# copy-pasted in 8+ hooks creating drift risk. Status: accepted.
SOURCE_EXTENSIONS='ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh'

# Check if a file is a source file by extension
is_source_file() {
    local file="$1"
    [[ "$file" =~ \.($SOURCE_EXTENSIONS)$ ]]
}

# Check if a file should be skipped (test, config, generated, vendor)
is_skippable_path() {
    local file="$1"
    # Skip config files, test files, generated files
    [[ "$file" =~ (\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.) ]] && return 0
    # Skip vendor/build directories
    [[ "$file" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && return 0
    return 1
}

# Check if a file is a test file by path and naming convention
is_test_file() {
    local file="$1"
    [[ "$file" =~ \.test\. ]] && return 0
    [[ "$file" =~ \.spec\. ]] && return 0
    [[ "$file" =~ __tests__/ ]] && return 0
    [[ "$file" =~ _test\.go$ ]] && return 0
    [[ "$file" =~ _test\.py$ ]] && return 0
    [[ "$file" =~ test_[^/]*\.py$ ]] && return 0
    [[ "$file" =~ /tests/ ]] && return 0
    [[ "$file" =~ /test/ ]] && return 0
    return 1
}

# --- Meta-repo detection ---
# Check if a directory is the ~/.claude meta-infrastructure repo.
# Uses --git-common-dir so worktrees of ~/.claude are correctly recognized.
# Usage: is_claude_meta_repo "/path/to/dir"
# Returns: 0 if meta-repo, 1 otherwise
is_claude_meta_repo() {
    local dir="$1"
    local common_dir
    common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || echo "")
    # Resolve to absolute if relative
    if [[ -n "$common_dir" && "$common_dir" != /* ]]; then
        common_dir=$(cd "$dir" && cd "$common_dir" && pwd)
    fi
    # common_dir for ~/.claude is ~/.claude/.git (strip trailing /.git)
    [[ "${common_dir%/.git}" == */.claude ]]
}

# Read test-status and populate TEST_RESULT, TEST_FAILS, TEST_TIME, TEST_AGE globals.
# Checks state/{phash}/test-status first (new path), falls back to .test-status (legacy).
# Returns 0 on success, 1 if status file doesn't exist.
# Usage: read_test_status "$PROJECT_ROOT"
read_test_status() {
    local root="${1:-.}"
    local claude_dir
    claude_dir=$(PROJECT_ROOT="$root" get_claude_dir 2>/dev/null || echo "$root/.claude")
    local phash
    phash=$(project_hash "$root")
    # New path: state/{phash}/test-status
    local status_file="${claude_dir}/state/${phash}/test-status"
    # Migration fallback: legacy .test-status
    if [[ ! -f "$status_file" ]]; then
        status_file="${claude_dir}/.test-status"
    fi
    TEST_RESULT="" TEST_FAILS="" TEST_TIME="" TEST_AGE=""
    [[ -f "$status_file" ]] || return 1
    TEST_RESULT=$(cut -d'|' -f1 < "$status_file")
    TEST_FAILS=$(cut -d'|' -f2 < "$status_file")
    TEST_TIME=$(cut -d'|' -f3 < "$status_file")
    local now; now=$(date +%s)
    # Guard: non-numeric TEST_TIME causes set -u crash in arithmetic context
    [[ "$TEST_TIME" =~ ^[0-9]+$ ]] || TEST_TIME=0
    TEST_AGE=$(( now - TEST_TIME ))
    return 0
}

# --- State file validation ---
# @decision DEC-INTEGRITY-001
# @title validate_state_file guards corrupt-file reads in guard.sh
# @status accepted
# @rationale guard.sh reads .proof-status and .test-status via cut. A corrupt
#   or empty file causes cut to return an empty string, which then falls through
#   to unexpected code paths. Worse, a missing file guarded only by -f can still
#   fail if the inode is deleted between the check and the read. validate_state_file
#   validates existence, non-emptiness, and minimum field count before any caller
#   reads the file — preventing spurious ERR-trap fires that would otherwise cause
#   deny-on-crash to block legitimate commands.
# Validate a pipe-delimited state file has expected format.
# Usage: validate_state_file "/path/to/file" field_count
# Returns 0 if valid, 1 if invalid/missing/corrupt.
validate_state_file() {
    local file="$1"
    local expected_fields="${2:-1}"
    [[ ! -f "$file" ]] && return 1
    [[ ! -s "$file" ]] && return 1
    local content
    content=$(head -1 "$file" 2>/dev/null) || return 1
    [[ -z "$content" ]] && return 1
    # Count pipe-delimited fields
    local actual_fields
    actual_fields=$(echo "$content" | awk -F'|' '{print NF}')
    [[ "$actual_fields" -ge "$expected_fields" ]] || return 1
    return 0
}

# --- Atomic file writer ---
# @decision DEC-INTEGRITY-004
# @title Atomic write via temp-file-then-mv for state file safety
# @status accepted
# @rationale Writing state files directly (echo > file) can produce truncated or
# empty files if the process is killed mid-write (e.g., SIGKILL, power loss).
# temp-file-then-mv is atomic on POSIX filesystems: the destination either has
# the old content or the new content, never a partial write. The .tmp.$$ suffix
# makes temp files unique per-process so concurrent writers don't collide.
#
# Usage: atomic_write "/path/to/file" "content"
# Or:    echo "content" | atomic_write "/path/to/file"
atomic_write() {
    local target="$1"
    local content="${2:-}"
    local tmp="${target}.tmp.$$"
    mkdir -p "$(dirname "$target")"
    if [[ -n "$content" ]]; then
        printf '%s\n' "$content" > "$tmp"
    else
        cat > "$tmp"
    fi
    mv "$tmp" "$target"
}

# --- Safe directory cleanup ---
# Prevents CWD-deletion bug: if the shell's CWD is inside the target,
# posix_spawn fails with ENOENT for all subsequent commands (including
# Stop hooks). Always cd out before deleting.
# Usage: safe_cleanup "/path/to/delete" "$PROJECT_ROOT"
safe_cleanup() {
    local target="$1"
    local fallback="${2:-$HOME}"
    if [[ "$PWD" == "$target"* ]]; then
        cd "$fallback" || cd "$HOME" || cd /
    fi
    rm -rf "$target"
}

# --- Audit trail ---
append_audit() {
    local root="$1" event="$2" detail="$3"
    local audit_file="$root/.claude/.audit-log"
    mkdir -p "$root/.claude"
    echo "$(date -u +%Y-%m-%dT%H:%M:%S)|${event}|${detail}" >> "$audit_file"
}

# --- Deny logging ---
# @decision DEC-PERF-002
# @title _log_deny() appends deny events to .hook-deny.log for signal analysis
# @status accepted
# @rationale Deny events are high-signal: they indicate a hook blocked an
#   operation. Logging them to .hook-deny.log (separate from timing) enables
#   analysis of deny rates over time — a key metric for assessing whether
#   hooks are too aggressive or well-calibrated. The log format is tab-separated:
#   timestamp, hook_name, reason. Writing errors are suppressed (|| true) so
#   a full disk or permission problem never turns a deny into an allow.
#   Called by the deny() function in pre-bash.sh and pre-write.sh before
#   emitting the deny JSON, so the log entry always precedes the denial.
#
# Usage: _log_deny "hook_name" "reason"
_log_deny() {
    local hook="$1" reason="$2"
    local claude_dir="${CLAUDE_DIR:-$HOME/.claude}"
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook" "$reason" >> "$claude_dir/.hook-deny.log" 2>/dev/null || true
}

# =============================================================================
# Hook Convention Framework — Phase 3
# =============================================================================

# --- Gate Declaration Framework ---
# @decision DEC-REMED-003 (see file header for full rationale)
#
# State — module-level, initialized once per hook invocation.
# Hooks call enable_fail_closed() which sets _HOOK_NAME.
# declare_gate() uses _HOOK_NAME to tag each gate.
_HOOK_GATES=()

# declare_gate ID NAME [TYPE]
#   Register a gate with this hook. In normal mode: records gate metadata.
#   In scan mode (HOOK_GATE_SCAN=1): emits GATE line to stdout and returns 0
#   (hook exits cleanly after all declare_gate calls complete naturally).
#   TYPE: deny (default), advisory, or side-effect
#
# Usage (place before each gate's logic block):
#   declare_gate "nuclear-deny" "Nuclear command hard deny" "deny"
declare_gate() {
    local id="$1" name="$2" type="${3:-deny}"
    _HOOK_GATES+=("${id}|${name}|${type}")
    if [[ "${HOOK_GATE_SCAN:-}" == "1" ]]; then
        printf 'GATE\t%s\t%s\t%s\t%s\n' "${_HOOK_NAME:-unknown}" "$id" "$name" "$type"
    fi
}

# --- Unified Emit Functions ---
# @decision DEC-REMED-004 (see file header for full rationale)
#
# State — set by enable_fail_closed(), read by emit_deny().
_HOOK_COMPLETED=false
_HOOK_NAME="${_HOOK_NAME:-}"
_HOOK_ADVISORIES=()

# emit_deny REASON [CONTEXT]
#   Log the deny, emit PreToolUse deny JSON to stdout, and exit 0.
#   Sets _HOOK_COMPLETED=true so the crash trap knows to skip its fallback.
#   REASON: human-readable deny message (will be jq-escaped)
#   CONTEXT: optional additionalContext string (will be jq-escaped)
emit_deny() {
    local reason="$1"
    local context="${2:-}"
    _log_deny "${_HOOK_NAME:-unknown}" "$reason"
    local escaped_reason
    escaped_reason=$(printf '%s' "$reason" | jq -Rs .)
    if [[ -n "$context" ]]; then
        local escaped_context
        escaped_context=$(printf '%s' "$context" | jq -Rs .)
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s,"additionalContext":%s}}\n' \
            "$escaped_reason" "$escaped_context"
    else
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
            "$escaped_reason"
    fi
    _HOOK_COMPLETED=true
    exit 0
}

# emit_advisory MESSAGE
#   Buffer an advisory message for later emission via emit_flush().
#   Advisories are non-blocking (allow) and accumulated across all gates.
#   Call emit_flush() at the end of the hook to emit a single combined JSON.
emit_advisory() {
    local message="$1"
    _HOOK_ADVISORIES+=("$message")
}

# emit_flush
#   Emit all buffered advisory messages as a single PreToolUse JSON object.
#   If no advisories have been buffered, emits nothing (silent allow).
#   Sets _HOOK_COMPLETED=true so the crash trap knows checks completed.
emit_flush() {
    _HOOK_COMPLETED=true
    if [[ ${#_HOOK_ADVISORIES[@]} -gt 0 ]]; then
        local combined
        combined=$(printf '%s\n' "${_HOOK_ADVISORIES[@]}" | jq -Rs .)
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$combined"
    fi
}

# --- Fail-Closed Crash Trap ---
# @decision DEC-REMED-006 (see file header for full rationale)

# _hook_crash_deny — EXIT trap handler. Emits deny if hook exited without
# completing. Safe to call multiple times (guarded by _HOOK_COMPLETED).
# During a merge on ~/.claude, degrades to allow to prevent deadlock.
_hook_crash_deny() {
    [[ "$_HOOK_COMPLETED" == "true" ]] && return
    # During merge on ~/.claude, degrade to allow — prevents deadlock when
    # hook source has conflicts or runtime errors during merge resolution.
    local _mgd
    _mgd="$(git -C "$HOME/.claude" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
    if [[ -n "$_mgd" && -f "$_mgd/MERGE_HEAD" ]]; then return; fi
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"SAFETY: Hook crashed before completing checks. Command denied. Run: bash -n ~/.claude/hooks/<hook>.sh to diagnose."}}
EOF
}

# enable_fail_closed HOOK_NAME
#   Register the hook name for logging and install the deny-on-crash EXIT trap.
#   Call this AFTER source-lib.sh succeeds (for hooks that have a pre-source-lib
#   inline trap, enable_fail_closed replaces it with the canonical implementation).
#   HOOK_NAME: used in _log_deny() entries and crash messages (e.g. "pre-bash")
enable_fail_closed() {
    _HOOK_NAME="${1:?enable_fail_closed requires hook name}"
    trap '_hook_crash_deny' EXIT
}

# --- Per-gate Error Isolation ---
# @decision DEC-GATE-ISOLATE-001
# @title _run_gate() wraps advisory gates in subshells to contain crashes
# @status accepted
# @rationale When 5+ gates are consolidated into one hook file, a crash in one advisory
#   gate kills the entire hook — blocking all subsequent operations (e.g., doc-freshness
#   crashing blocks ALL git commits). enable_fail_closed() fail-closed behavior is correct
#   for safety-critical denials, but wrong for advisory gates where the denial is "gate
#   crashed, not a real violation."
#
#   _run_gate() wraps the gate function in a subshell with set -euo pipefail. If it exits
#   non-zero, the error is logged and execution continues — other gates are unaffected.
#   Subshell isolation means variables set inside don't propagate back; this is correct for
#   deny/advisory gates (they emit JSON to stdout and exit). For side-effect gates that set
#   parent-shell variables (e.g., track.sh setting PROJECT_ROOT), use set +e / set -e
#   sandwiching instead (see post-write.sh Step 1 pattern).
#
#   Safety-critical gates (nuclear deny, CWD guard, proof-status protection) MUST NOT use
#   _run_gate() — they must fail-closed. Only advisory and non-blocking gates use this.
#
# _run_gate GATE_NAME FUNCTION [ARGS...]
#   Run FUNCTION in an isolated subshell. If it crashes (exits non-zero), log and continue.
#   The caller's environment is NOT modified (subshell isolation).
#
# Usage:
#   _run_gate "doc-freshness" _do_doc_freshness_check
#   _run_gate "plan-validate" _do_plan_validate "$PLAN_FILE"
_run_gate() {
    local gate_name="$1"
    shift
    (
        set -euo pipefail
        "$@"
    ) || {
        local rc=$?
        log_info "$gate_name" "gate crashed (exit $rc) — isolated, continuing" 2>/dev/null || true
        return 0  # Don't propagate — other gates continue
    }
}

# _run_blocking_gate GATE_NAME FUNCTION [ARGS...]
#   Like _run_gate but preserves planned exit 2 (PostToolUse block signal).
#   Crashes (any non-zero exit other than 2) are isolated — logged and ignored.
#   Use this for PostToolUse gates that legitimately block with exit 2
#   (plan-validate, lint) but whose crashes should not block all writes.
#
# Exit 2 semantics: PostToolUse hooks use exit 2 to signal Claude Code to
#   block the write and show the reason. A crash that exits non-2 would also
#   block under set -euo pipefail; this function treats it as a non-fatal crash.
_run_blocking_gate() {
    local gate_name="$1"
    shift
    local _rc=0
    (
        set -euo pipefail
        "$@"
    ) || _rc=$?
    if [[ "$_rc" -eq 2 ]]; then
        exit 2  # Planned block — propagate to parent hook
    elif [[ "$_rc" -ne 0 ]]; then
        log_info "$gate_name" "gate crashed (exit $_rc) — isolated, continuing" 2>/dev/null || true
    fi
    # rc=0: gate passed normally — continue
}

# --- Cached Project Context ---
# @decision DEC-REMED-005 (see file header for full rationale)
_CACHED_PROJECT_ROOT=""
_CACHED_CLAUDE_DIR=""

# cache_project_context
#   Populate _CACHED_PROJECT_ROOT and _CACHED_CLAUDE_DIR once.
#   Call early in the hook (after input parse). Replace repeated calls to
#   detect_project_root() / get_claude_dir() with $variable references.
#   Safe to call multiple times — only computes on first call.
cache_project_context() {
    if [[ -z "$_CACHED_PROJECT_ROOT" ]]; then
        _CACHED_PROJECT_ROOT=$(detect_project_root)
    fi
    if [[ -z "$_CACHED_CLAUDE_DIR" ]]; then
        _CACHED_CLAUDE_DIR=$(get_claude_dir)
    fi
}

# --- Cross-platform file mtime ---
# @decision DEC-XPLAT-001
# @title _file_mtime() in core-lib.sh with Linux-first stat order
# @status accepted
# @rationale 25 inline stat patterns used macOS-first order: `stat -f %m ... || stat -c %Y`.
#   This is broken on Linux because `stat -f %m` succeeds on Linux but returns the filesystem
#   mount point (e.g., "/") instead of the modification time — so the `||` fallback to
#   `stat -c %Y` never triggers and callers receive garbage. Linux-first order is correct
#   because macOS `stat -c %Y` fails cleanly (unrecognized flag), while Linux `stat -f %m`
#   succeeds but produces wrong output. Single function in core-lib.sh (always-loaded)
#   replaces all 25 inline patterns with one correct implementation that prevents recurrence.
#   Alternatives rejected: per-file inline fix (25 maintenance sites), Python mtime (new dep),
#   uname detection at load time (see MASTER_PLAN.md DEC-XPLAT-001 for full trade-off).
#
# _file_mtime FILE
#   Print the modification time of FILE in seconds since epoch.
#   Prints "0" if the file does not exist or stat fails.
#   Usage: mtime=$(_file_mtime "$somefile")
_file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# --- Portable timeout wrapper ---
# @decision DEC-XPLAT-002
# @title _with_timeout() wrapper using Perl fallback
# @status accepted
# @rationale GNU coreutils `timeout` is not available on stock macOS (only via Homebrew).
#   ~10 occurrences across hooks and tests used bare `timeout`, which works locally on macOS
#   if Homebrew is installed but fails on CI runners (Ubuntu minimal images, macOS GitHub
#   Actions). Perl `alarm` + `exec` is available on every POSIX system (macOS ships Perl,
#   Linux distros include it). Zero new dependencies. Perl's alarm(0) cancels the timer
#   naturally when exec'd process exits. Exit code 124 is preserved for timeout expiry to
#   match GNU `timeout` semantics (pre-bash.sh checks for exit 124 explicitly).
#   Alternatives rejected: shell SIGALRM (not portable to all bash versions), Python subprocess
#   (slower startup), requiring coreutils in CI (adds setup step).
#
# _with_timeout SECONDS COMMAND [ARGS...]
#   Run COMMAND with a timeout of SECONDS. Exits with code 124 on timeout (GNU compat).
#   Usage: _with_timeout 120 make ci-local
_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm(shift @ARGV); exec @ARGV or exit 127' "$secs" "$@"
    fi
}

# --- Platform-native file descriptor locking ---
# @decision DEC-LOCK-NATIVE-001
# @title OS-native file locking via uname detection
# @status accepted
# @rationale macOS ships lockf(1), Linux ships flock(1). Platform detection via
#   uname -s eliminates homebrew dependency and cellar glob fragility. Same
#   FD+timeout semantics, zero external deps. In single-user Claude Code, the
#   atomic tmp+mv + lattice enforcement provide sufficient protection without
#   locking; the lock is defense-in-depth.
#
# _lock_fd TIMEOUT FD
#   Platform-native file descriptor locking.
#   Linux: flock -w TIMEOUT FD
#   macOS: lockf -s -t TIMEOUT FD
#   Neither: proceed unlocked (defense-in-depth: atomic tmp+mv + lattice)
#
# Usage (mirrors flock -w TIMEOUT FD):
#   ( _lock_fd 5 9 || { handle_failure; return 1; }
#     ... critical section ...
#   ) 9>"$lockfile"
_lock_fd() {
    local timeout="$1" fd="$2"
    if [[ -z "${_LOCK_CMD+set}" ]]; then
        case "$(uname -s)" in
            Darwin) _LOCK_CMD="lockf"  ;;
            Linux)  _LOCK_CMD="flock"  ;;
            *)      _LOCK_CMD="__none__" ;;
        esac
    fi
    case "$_LOCK_CMD" in
        lockf)  lockf -s -t "$timeout" "$fd" ;;
        flock)  flock -w "$timeout" "$fd" ;;
        *)      return 0 ;;
    esac
}

# Export core utilities for subshells
export SOURCE_EXTENSIONS DECISION_LINE_THRESHOLD TEST_STALENESS_THRESHOLD SESSION_STALENESS_THRESHOLD
export STOP_SURFACE_TTL STOP_TODO_TTL STOP_BACKUP_TTL
export _PROTECTED_STATE_FILES
export -f project_hash is_source_file is_skippable_path is_test_file is_claude_meta_repo
export -f read_test_status validate_state_file atomic_write safe_cleanup append_audit _log_deny
export -f declare_gate emit_deny emit_advisory emit_flush enable_fail_closed _hook_crash_deny
export -f cache_project_context _lock_fd is_protected_state_file _run_gate _run_blocking_gate
export -f _file_mtime _with_timeout

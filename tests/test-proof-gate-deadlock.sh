#!/usr/bin/env bash
# tests/test-proof-gate-deadlock.sh — proof gate deadlock fix test suite
#
# Validates all 5 components of the proof gate deadlock fix:
#   Component 1: post-task.sh emits advisory (not silent exit) when SUMMARY_TEXT empty
#   Component 2: task-track.sh writes tester-dispatch-session breadcrumb on tester dispatch
#   Component 3: prompt-submit.sh promotes proof when AUTOVERIFY: CLEAN in orchestrator prompt
#   Component 4: subagent-start.sh writes .last-tester-trace at trace creation time
#   Component 5: pre-bash.sh allows proof-status write when .autoverify-failed signal active
#
# Usage: ( cd /path/to/worktree && bash tests/test-proof-gate-deadlock.sh )
#
# Architecture note: hooks use detect_project_root() which checks CLAUDE_PROJECT_DIR first.
# We set CLAUDE_PROJECT_DIR to a synthetic test path so the hook uses a unique phash
# that doesn't collide with any real tester traces. The state dir and proof-status files
# land under ~/.claude/state/<test-phash>/.
# CLAUDE_SESSION_ID is read from hook input JSON (session_id field), not env var.
#
# @decision DEC-AV-LOUD-FAIL-001
# @title Test coverage for proof gate deadlock 5-component fix
# @status accepted
# @rationale The deadlock has 5 interdependent failure modes. Each must be tested
#   in isolation. Hooks resolve paths via detect_project_root() + _resolve_to_main_worktree(),
#   which always returns the main repo root (~/.claude) when cwd is a linked worktree.
#   Tests use the main project root's state dir and a unique session ID per test run
#   to avoid collision. Teardown cleans all test artifacts.

set -euo pipefail

# --- Test infrastructure ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_DIR}/hooks"

# Real ~/.claude directory (for TRACE_STORE — hooks write traces here)
REAL_CLAUDE_DIR="$HOME/.claude"
REAL_TRACE_STORE="${REAL_CLAUDE_DIR}/traces"

# TEST_PROJECT_PATH: synthetic project directory passed via CLAUDE_PROJECT_DIR.
# Hooks use detect_project_root() → CLAUDE_PROJECT_DIR, then get_claude_dir() →
# TEST_PROJECT_PATH/.claude (since TEST_PROJECT_PATH != ~/.claude).
# This isolates ALL hook state files from ~/.claude — they land in TEST_HOOK_CLAUDE_DIR.
TEST_PROJECT_PATH="${REAL_CLAUDE_DIR}/tmp/test-project-$$"
mkdir -p "$TEST_PROJECT_PATH"
# get_claude_dir() returns PROJECT_ROOT/.claude for non-~/.claude projects
TEST_HOOK_CLAUDE_DIR="${TEST_PROJECT_PATH}/.claude"
TEST_PHASH=$(echo "$TEST_PROJECT_PATH" | shasum -a 256 | cut -c1-8)
TEST_STATE_DIR="${TEST_HOOK_CLAUDE_DIR}/state/${TEST_PHASH}"

# Unique session ID for this test run — embedded in hook inputs as session_id
TEST_SESSION_ID="test-deadlock-$$-$(date +%s)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }

mkdir -p "${WORKTREE_DIR}/tmp" "${REAL_TRACE_STORE}"

# Run a hook, capturing stdout + stderr. Returns hook's exit code.
# Sets CLAUDE_PROJECT_DIR so detect_project_root() returns TEST_PROJECT_PATH
# regardless of the cwd or git topology, giving the test a clean isolated phash.
run_hook() {
    local hook="$1" input="$2"
    local _out_var="$3" _err_var="$4"
    local _f_in="${WORKTREE_DIR}/tmp/hook-in-$$.json"
    local _f_err="${WORKTREE_DIR}/tmp/hook-err-$$.txt"
    printf '%s' "$input" > "$_f_in"
    local _out="" _exit=0
    # Unset CLAUDE_SESSION_ID so init_hook reads it from the JSON session_id field.
    # If inherited from the parent Claude session, it would override TEST_SESSION_ID.
    _out=$(CLAUDE_PROJECT_DIR="$TEST_PROJECT_PATH" \
           env -u CLAUDE_SESSION_ID \
           bash "${HOOKS_DIR}/${hook}" < "$_f_in" 2>"$_f_err") || _exit=$?
    local _err="" ; _err=$(cat "$_f_err" 2>/dev/null || echo "")
    rm -f "$_f_in" "$_f_err"
    printf -v "$_out_var" '%s' "$_out"
    printf -v "$_err_var" '%s' "$_err"
    return $_exit
}

teardown() {
    # Remove test state from TEST_HOOK_CLAUDE_DIR (not REAL_CLAUDE_DIR).
    # Hooks write to TEST_PROJECT_PATH/.claude/ when CLAUDE_PROJECT_DIR = TEST_PROJECT_PATH.
    # TEST_PROJECT_PATH kept alive for CLAUDE_PROJECT_DIR -d check; removed in final_cleanup.
    rm -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed" 2>/dev/null || true
    rm -f "${TEST_HOOK_CLAUDE_DIR}/.agent-findings" 2>/dev/null || true
    rm -f "${TEST_HOOK_CLAUDE_DIR}/.last-tester-trace" 2>/dev/null || true
    rm -f "${TEST_STATE_DIR}/last-tester-trace" 2>/dev/null || true
    rm -f "${TEST_STATE_DIR}/tester-dispatch-session" 2>/dev/null || true
    rm -f "${TEST_STATE_DIR}/proof-status" 2>/dev/null || true
    rm -f "${TEST_HOOK_CLAUDE_DIR}/.proof-status-${TEST_PHASH}" 2>/dev/null || true
    rm -rf "${REAL_TRACE_STORE}/tester-test-deadlock-"* 2>/dev/null || true
}

final_cleanup() {
    teardown
    rm -rf "$TEST_PROJECT_PATH" 2>/dev/null || true
}

teardown  # clean any leftover from previous run
mkdir -p "$TEST_STATE_DIR"  # recreate after teardown

# ---
# COMPONENT 1: post-task.sh emits advisory when SUMMARY_TEXT empty
# ---
section "Component 1: post-task.sh loud failure when no summary.md found"

# Tester trace with NO summary.md so all detection tiers fail
_C1_TRACE_ID="tester-test-deadlock-c1-$(date +%s)"
_C1_TRACE_DIR="${REAL_TRACE_STORE}/${_C1_TRACE_ID}"
mkdir -p "${_C1_TRACE_DIR}/artifacts"
printf '{"version":"1","trace_id":"%s","agent_type":"tester","session_id":"%s","project":"%s","status":"active","created_at":%s}\n' \
    "$_C1_TRACE_ID" "$TEST_SESSION_ID" "$TEST_PROJECT_PATH" "$(date +%s)" \
    > "${_C1_TRACE_DIR}/manifest.json"
# No summary.md — intentional

printf 'needs-verification|%s\n' "$(date +%s)" > "${TEST_STATE_DIR}/proof-status"

# Hook input: session_id embedded so init_hook reads it correctly
_C1_INPUT=$(printf '{"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"run"},"cwd":"%s","session_id":"%s"}' \
    "$WORKTREE_DIR" "$TEST_SESSION_ID")

_C1_OUT="" _C1_ERR=""
run_hook "post-task.sh" "$_C1_INPUT" _C1_OUT _C1_ERR || true
rm -rf "$_C1_TRACE_DIR" 2>/dev/null || true

# Test 1.1: must emit non-empty output
if [[ -n "$_C1_OUT" ]]; then
    pass "1.1: post-task.sh emits output when summary.md missing (not silent exit)"
else
    fail "1.1: post-task.sh silently exited — no output when summary.md missing"
    echo "    STDERR: $(echo "$_C1_ERR" | tail -5)"
fi

# Test 1.2: output must contain additionalContext
if echo "$_C1_OUT" | grep -q '"additionalContext"'; then
    pass "1.2: output contains additionalContext JSON key"
else
    fail "1.2: output missing additionalContext — not a valid advisory"
    echo "    OUTPUT: $(echo "$_C1_OUT" | head -3)"
fi

# Test 1.3: advisory must mention autoverify/recovery
if echo "$_C1_OUT" | grep -qiE 'AUTOVERIFY|autoverify|RECOVERY|recovery|relay'; then
    pass "1.3: advisory mentions autoverify/recovery guidance"
else
    fail "1.3: advisory does not mention autoverify or recovery"
fi

# Test 1.4: .autoverify-failed must be written
if [[ -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed" ]]; then
    pass "1.4: .autoverify-failed signal file written by post-task.sh"
else
    fail "1.4: .autoverify-failed not written at ${REAL_CLAUDE_DIR}/.autoverify-failed"
    echo "    STDERR: $(echo "$_C1_ERR" | grep -i 'autoverify' | head -3)"
fi

# Test 1.5: .agent-findings must be written
if [[ -f "${TEST_HOOK_CLAUDE_DIR}/.agent-findings" ]]; then
    pass "1.5: .agent-findings written for next-prompt injection"
else
    fail "1.5: .agent-findings not written at ${REAL_CLAUDE_DIR}/.agent-findings"
fi

teardown
mkdir -p "$TEST_STATE_DIR"

# ---
# COMPONENT 2: task-track.sh writes tester-dispatch-session breadcrumb
# ---
section "Component 2: task-track.sh writes tester-dispatch-session breadcrumb"

printf 'needs-verification|%s\n' "$(date +%s)" > "${TEST_STATE_DIR}/proof-status"

_C2_INPUT=$(printf '{"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"run tester"},"cwd":"%s","session_id":"%s"}' \
    "$WORKTREE_DIR" "$TEST_SESSION_ID")

_C2_OUT="" _C2_ERR=""
run_hook "task-track.sh" "$_C2_INPUT" _C2_OUT _C2_ERR || true

_TDS_FILE="${TEST_STATE_DIR}/tester-dispatch-session"

# Test 2.1: breadcrumb file must exist
if [[ -f "$_TDS_FILE" ]]; then
    pass "2.1: tester-dispatch-session breadcrumb written"
else
    fail "2.1: tester-dispatch-session breadcrumb NOT written at ${_TDS_FILE}"
    echo "    STDERR: $(echo "$_C2_ERR" | grep -i 'breadcrumb\|tester' | head -3)"
fi

# Test 2.2: breadcrumb format must be session_id|epoch
if [[ -f "$_TDS_FILE" ]]; then
    _TDS_CONTENT=$(cat "$_TDS_FILE")
    if echo "$_TDS_CONTENT" | grep -qE '.+\|[0-9]+'; then
        pass "2.2: breadcrumb format is session_id|epoch: ${_TDS_CONTENT}"
    else
        fail "2.2: breadcrumb format invalid: '${_TDS_CONTENT}'"
    fi
fi

teardown
mkdir -p "$TEST_STATE_DIR"

# ---
# COMPONENT 3: prompt-submit.sh promotes proof on AUTOVERIFY: CLEAN relay
# ---
section "Component 3: prompt-submit.sh promotes proof on AUTOVERIFY: CLEAN relay"

printf 'needs-verification|%s\n' "$(date +%s)" > "${TEST_STATE_DIR}/proof-status"
printf 'needs-verification|%s\n' "$(date +%s)" > "${TEST_HOOK_CLAUDE_DIR}/.proof-status-${TEST_PHASH}"

_C3_PROMPT="The tester returned and reported AUTOVERIFY: CLEAN — all verification criteria met."
_C3_INPUT=$(printf '{"prompt":"%s","cwd":"%s","session_id":"%s"}' \
    "$_C3_PROMPT" "$WORKTREE_DIR" "$TEST_SESSION_ID")

_C3_OUT="" _C3_ERR=""
run_hook "prompt-submit.sh" "$_C3_INPUT" _C3_OUT _C3_ERR || true

# Test 3.1: must emit output
if [[ -n "$_C3_OUT" ]]; then
    pass "3.1: prompt-submit.sh emits output for AUTOVERIFY: CLEAN relay"
else
    fail "3.1: prompt-submit.sh emitted no output"
fi

# Test 3.2: output must mention AUTOVERIFY or Guardian
if echo "$_C3_OUT" | grep -qiE 'AUTOVERIFY|Guardian|GUARDIAN'; then
    pass "3.2: output mentions AUTOVERIFY or Guardian dispatch"
else
    fail "3.2: output does not mention AUTOVERIFY or Guardian"
    echo "    OUTPUT: $(echo "$_C3_OUT" | head -5)"
fi

# Test 3.3: proof-status must be promoted to verified
_PROOF_NEW=$(cut -d'|' -f1 "${TEST_STATE_DIR}/proof-status" 2>/dev/null || echo "unchanged")
_PROOF_OLD=$(cut -d'|' -f1 "${TEST_HOOK_CLAUDE_DIR}/.proof-status-${TEST_PHASH}" 2>/dev/null || echo "unchanged")
if [[ "$_PROOF_NEW" == "verified" || "$_PROOF_OLD" == "verified" ]]; then
    pass "3.3: proof-status promoted to verified on AUTOVERIFY: CLEAN relay"
else
    fail "3.3: proof-status unchanged (new=${_PROOF_NEW}, old=${_PROOF_OLD})"
fi

teardown
mkdir -p "$TEST_STATE_DIR"

# ---
# COMPONENT 4: subagent-start.sh writes .last-tester-trace at trace creation
# ---
section "Component 4: subagent-start.sh writes .last-tester-trace at trace creation"

_C4_INPUT=$(printf '{"agent_type":"tester","prompt":"verify","cwd":"%s","session_id":"%s"}' \
    "$WORKTREE_DIR" "$TEST_SESSION_ID")

_C4_OUT="" _C4_ERR=""
run_hook "subagent-start.sh" "$_C4_INPUT" _C4_OUT _C4_ERR || true

# Test 4.1: project-scoped breadcrumb
_LTT_SCOPED="${TEST_STATE_DIR}/last-tester-trace"
if [[ -f "$_LTT_SCOPED" ]]; then
    pass "4.1: project-scoped last-tester-trace written at trace creation"
else
    fail "4.1: project-scoped last-tester-trace NOT written at ${_LTT_SCOPED}"
    echo "    STDERR: $(echo "$_C4_ERR" | grep -i 'breadcrumb\|tester' | head -3)"
fi

# Test 4.2: legacy path breadcrumb
_LTT_LEGACY="${TEST_HOOK_CLAUDE_DIR}/.last-tester-trace"
if [[ -f "$_LTT_LEGACY" ]]; then
    pass "4.2: legacy .last-tester-trace also written (backward compat)"
else
    fail "4.2: legacy .last-tester-trace NOT written at ${_LTT_LEGACY}"
fi

# Test 4.3: breadcrumb is non-empty
if [[ -f "$_LTT_SCOPED" ]]; then
    _LTT_VAL=$(cat "$_LTT_SCOPED")
    if [[ -n "$_LTT_VAL" ]]; then
        pass "4.3: breadcrumb contains non-empty trace_id: ${_LTT_VAL}"
    else
        fail "4.3: breadcrumb is empty"
    fi
fi

teardown
mkdir -p "$TEST_STATE_DIR"

# ---
# COMPONENT 5: pre-bash.sh allows proof-status write when .autoverify-failed active
# ---
section "Component 5: pre-bash.sh emergency override with .autoverify-failed signal"

_PS_FILE="${TEST_HOOK_CLAUDE_DIR}/.proof-status-${TEST_PHASH}"
printf 'needs-verification|%s\n' "$(date +%s)" > "$_PS_FILE"

# Write fresh .autoverify-failed signal matching the test session
_AF_TS=$(date +%s)
printf 'failed|%s|%s\n' "$_AF_TS" "$TEST_SESSION_ID" > "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed"

# Command that Check 9 would block: write 'verified' to proof-status
_BLOCKED_CMD="echo 'verified|${_AF_TS}' > ${_PS_FILE}"
_C5_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s","session_id":"%s"}' \
    "$_BLOCKED_CMD" "$WORKTREE_DIR" "$TEST_SESSION_ID")

_C5_OUT="" _C5_ERR=""
run_hook "pre-bash.sh" "$_C5_INPUT" _C5_OUT _C5_ERR || true

# Test 5.1: must NOT emit deny when .autoverify-failed is active
if echo "$_C5_OUT" | grep -qi 'Cannot write approval'; then
    fail "5.1: pre-bash.sh denied write even with .autoverify-failed active"
    echo "    OUTPUT: $(echo "$_C5_OUT" | head -3)"
else
    pass "5.1: pre-bash.sh allows proof-status write when .autoverify-failed is active"
fi

# Test 5.2: .autoverify-failed cleaned up after override
if [[ ! -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed" ]]; then
    pass "5.2: .autoverify-failed cleaned up after emergency override"
else
    fail "5.2: .autoverify-failed not cleaned — will trigger again"
    rm -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed"
fi

# Test 5.3: Expired signal (>300s) must NOT grant override
printf 'needs-verification|%s\n' "$(date +%s)" > "$_PS_FILE"
_OLD_TS=$(( $(date +%s) - 600 ))
printf 'failed|%s|%s\n' "$_OLD_TS" "$TEST_SESSION_ID" > "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed"

_C5B_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s","session_id":"%s"}' \
    "$_BLOCKED_CMD" "$WORKTREE_DIR" "$TEST_SESSION_ID")
_C5B_OUT="" _C5B_ERR=""
run_hook "pre-bash.sh" "$_C5B_INPUT" _C5B_OUT _C5B_ERR || true

if echo "$_C5B_OUT" | grep -qi 'Cannot write approval'; then
    pass "5.3: expired .autoverify-failed (600s) correctly blocked — deny still fires"
else
    # Check 9 only blocks when command contains approval keywords — our test command has 'verified'
    # If the deny did NOT fire, it means the override was wrongly granted
    if [[ -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed" ]]; then
        # Signal still present = override not granted (correct)
        pass "5.3: expired .autoverify-failed not consumed — override not granted"
    else
        fail "5.3: expired .autoverify-failed was consumed — override incorrectly granted"
    fi
fi
rm -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed"

# Test 5.4: Wrong-session signal must NOT grant override
printf 'needs-verification|%s\n' "$(date +%s)" > "$_PS_FILE"
_FRESH_TS=$(date +%s)
printf 'failed|%s|%s\n' "$_FRESH_TS" "completely-different-session-xyz" > "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed"

_C5C_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s","session_id":"%s"}' \
    "$_BLOCKED_CMD" "$WORKTREE_DIR" "$TEST_SESSION_ID")
_C5C_OUT="" _C5C_ERR=""
run_hook "pre-bash.sh" "$_C5C_INPUT" _C5C_OUT _C5C_ERR || true

if echo "$_C5C_OUT" | grep -qi 'Cannot write approval'; then
    pass "5.4: wrong-session .autoverify-failed correctly blocked — deny still fires"
else
    if [[ -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed" ]]; then
        pass "5.4: wrong-session .autoverify-failed not consumed — override not granted"
    else
        fail "5.4: wrong-session .autoverify-failed was consumed — override incorrectly granted"
    fi
fi
rm -f "${TEST_HOOK_CLAUDE_DIR}/.autoverify-failed"

final_cleanup

# ---
# SUMMARY
# ---
echo
echo "================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "================================"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0

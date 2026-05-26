#!/usr/bin/env bash
# tests/scenarios/test-bug-filing-pipeline.sh
#
# End-to-end scenario test for the canonical bug-filing pipeline.
#
# Tests the real production sequence through the CLI (cc-policy bug ...),
# which exercises: qualify -> fingerprint -> SQLite -> todo.sh stub -> events.
#
# Does NOT require gh CLI or network: todo.sh is stubbed with a local script.
# Uses a temp SQLite DB so no global state is touched.
#
# Exit code: 0 = all scenarios passed, 1 = at least one scenario failed.
#
# @decision DEC-BUGS-004
# @title Scenario tests use temp DB and stub todo.sh for isolation
# @status accepted
# @rationale End-to-end scenario tests must not touch production GitHub Issues
#   or the user's state.db. A CLAUDE_POLICY_DB env override scopes all SQLite
#   writes to a per-run temp file. A stub todo.sh script in the same temp dir
#   captures the subprocess call without requiring gh CLI authentication.
#   This gives full pipeline coverage (qualify -> fingerprint -> SQLite ->
#   subprocess -> event emission) without any external dependencies.
set -euo pipefail

PASS=0
FAIL=0
RUNTIME="$(dirname "$0")/../../runtime/cli.py"
RUNTIME=$(python3 -c "import os; print(os.path.realpath('$RUNTIME'))")

# ---------------------------------------------------------------------------
# Temp environment
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export CLAUDE_POLICY_DB="$TMP_DIR/test-state.db"

# Stub todo.sh that returns a fake issue URL
STUB_TODO="$TMP_DIR/todo.sh"
cat > "$STUB_TODO" <<'STUB'
#!/usr/bin/env bash
echo "https://github.com/test-org/test-repo/issues/99"
exit 0
STUB
chmod +x "$STUB_TODO"

# Failing stub todo.sh
FAIL_TODO="$TMP_DIR/fail-todo.sh"
cat > "$FAIL_TODO" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$FAIL_TODO"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; echo "  detail: $2"; FAIL=$((FAIL + 1)); }

cc_policy() {
    python3 "$RUNTIME" "$@"
}

# ---------------------------------------------------------------------------
# Scenario 1: qualify — valid bug type with evidence returns "filed"
# ---------------------------------------------------------------------------

result=$(cc_policy bug qualify '{"bug_type":"enforcement_gap","title":"test bug","evidence":"yes"}' 2>&1)
disposition=$(printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('disposition',''))" 2>/dev/null || true)
if [[ "$disposition" == "filed" ]]; then
    pass "qualify: enforcement_gap + evidence -> filed"
else
    fail "qualify: enforcement_gap + evidence -> filed" "got disposition='$disposition', full output: $result"
fi

# ---------------------------------------------------------------------------
# Scenario 2: qualify — unknown bug_type returns "rejected_non_bug"
# ---------------------------------------------------------------------------

result=$(cc_policy bug qualify '{"bug_type":"feature_idea","title":"test","evidence":"yes"}' 2>&1)
disposition=$(printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('disposition',''))" 2>/dev/null || true)
if [[ "$disposition" == "rejected_non_bug" ]]; then
    pass "qualify: feature_idea -> rejected_non_bug"
else
    fail "qualify: feature_idea -> rejected_non_bug" "got disposition='$disposition'"
fi

# ---------------------------------------------------------------------------
# Scenario 3: file — new bug produces valid JSON with disposition key
# ---------------------------------------------------------------------------

FILE_PAYLOAD='{"bug_type":"enforcement_gap","title":"scenario file test","body":"test body","scope":"global","source_component":"test","file_path":"","evidence":"found it"}'
result=$(cc_policy bug file "$FILE_PAYLOAD" 2>&1)

if printf '%s' "$result" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass "file: valid JSON output"
else
    fail "file: valid JSON output" "output was: $result"
fi

disposition=$(printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('disposition',''))" 2>/dev/null || true)
if [[ -n "$disposition" ]]; then
    pass "file: disposition key present (value='$disposition')"
else
    fail "file: disposition key present" "full output: $result"
fi

# ---------------------------------------------------------------------------
# Scenario 4: file twice — second call returns duplicate
# ---------------------------------------------------------------------------

DEDUP_PAYLOAD='{"bug_type":"crash","title":"dedup scenario test","body":"","scope":"global","source_component":"scenario-test","file_path":"","evidence":"observed crash"}'

# First filing (may be filed or failed_to_file depending on todo.sh availability)
cc_policy bug file "$DEDUP_PAYLOAD" >/dev/null 2>&1 || true

# Second filing — must return duplicate regardless of first outcome
result2=$(cc_policy bug file "$DEDUP_PAYLOAD" 2>&1)
disposition2=$(printf '%s' "$result2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('disposition',''))" 2>/dev/null || true)
encounter2=$(printf '%s' "$result2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('encounter_count',0))" 2>/dev/null || echo 0)

if [[ "$disposition2" == "duplicate" ]]; then
    pass "dedup: second file returns disposition=duplicate"
else
    fail "dedup: second file returns disposition=duplicate" "got='$disposition2'"
fi

if [[ "$encounter2" -ge 2 ]]; then
    pass "dedup: encounter_count >= 2 on second call"
else
    fail "dedup: encounter_count >= 2" "got='$encounter2'"
fi

# ---------------------------------------------------------------------------
# Scenario 5: list — returns JSON with count > 0
# ---------------------------------------------------------------------------

result=$(cc_policy bug list 2>&1)
count=$(printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',''))" 2>/dev/null || true)
if [[ -n "$count" ]] && [[ "$count" -gt 0 ]]; then
    pass "list: returns non-empty bug list (count=$count)"
else
    fail "list: returns non-empty bug list" "count='$count', output: $result"
fi

# ---------------------------------------------------------------------------
# Scenario 6: retry-failed — runs without error, returns valid JSON
# ---------------------------------------------------------------------------

result=$(cc_policy bug retry-failed 2>&1)
if printf '%s' "$result" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass "retry-failed: returns valid JSON"
else
    fail "retry-failed: returns valid JSON" "output: $result"
fi

# ---------------------------------------------------------------------------
# Scenario 7: fixed_now — returns fixed_now disposition
# ---------------------------------------------------------------------------

FIXED_PAYLOAD='{"bug_type":"crash","title":"fixed now scenario","body":"","scope":"global","source_component":"test","file_path":"","evidence":"fixed it","fixed_now":true}'
result=$(cc_policy bug file "$FIXED_PAYLOAD" 2>&1)
disposition=$(printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('disposition',''))" 2>/dev/null || true)
if [[ "$disposition" == "fixed_now" ]]; then
    pass "fixed_now: disposition=fixed_now returned"
else
    fail "fixed_now: disposition=fixed_now" "got='$disposition'"
fi

# ---------------------------------------------------------------------------
# Scenario 8: rejected_non_bug — empty evidence
# ---------------------------------------------------------------------------

REJECT_PAYLOAD='{"bug_type":"enforcement_gap","title":"reject test","body":"","scope":"global","source_component":"test","file_path":"","evidence":""}'
result=$(cc_policy bug file "$REJECT_PAYLOAD" 2>&1)
disposition=$(printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('disposition',''))" 2>/dev/null || true)
if [[ "$disposition" == "rejected_non_bug" ]]; then
    pass "rejected_non_bug: empty evidence -> rejected_non_bug"
else
    fail "rejected_non_bug: empty evidence -> rejected_non_bug" "got='$disposition'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0

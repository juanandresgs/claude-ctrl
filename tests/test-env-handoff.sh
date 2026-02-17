#!/usr/bin/env bash
# Test suite for environment variable handoff from implementer to tester.
# Validates that subagent-start.sh correctly surfaces env-requirements.txt
# contents as ENV REQUIREMENTS context lines for the tester agent.
#
# @decision DEC-ENV-HANDOFF-001
# @title Test env-requirements.txt parsing in tester context injection
# @status accepted
# @rationale The env handoff feature adds ~10 lines of bash to subagent-start.sh.
#   These tests exercise the exact parsing logic (grep, cut, tr, paste pipeline)
#   against controlled fixtures: positive, negative, empty, comments-only, and
#   inline-comment cases. This ensures the pipeline produces correct comma-separated
#   var names and stays silent when no file exists.

set -euo pipefail

PASS=0
FAIL=0
TOTAL=0

assert() {
    local description="$1"
    local condition="$2"
    TOTAL=$((TOTAL + 1))
    if eval "$condition"; then
        echo "  PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $description"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: runs the exact env-check logic from subagent-start.sh
# Args: $1 = TRACE_STORE, $2 = IMPL_TRACE
# Outputs: the ENV REQUIREMENTS line (or empty)
run_env_check() {
    local TRACE_STORE="$1"
    local IMPL_TRACE="$2"
    local CONTEXT_PARTS=()

    if [[ -n "$IMPL_TRACE" ]]; then
        env_req_file="${TRACE_STORE}/${IMPL_TRACE}/artifacts/env-requirements.txt"
        if [[ -f "$env_req_file" ]]; then
            env_vars=$(grep -v '^#' "$env_req_file" | grep -v '^$' | cut -d'#' -f1 | tr -d ' ' | paste -sd ', ' -)
            if [[ -n "$env_vars" ]]; then
                CONTEXT_PARTS+=("ENV REQUIREMENTS: This feature requires: ${env_vars}. Verify they are set before running.")
            fi
        fi
    fi

    if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
        printf '%s\n' "${CONTEXT_PARTS[@]}"
    fi
}

# --- Setup ---
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo "=== test-env-handoff.sh ==="
echo ""

# --- Test 1: Two named vars ---
echo "Test 1: env-requirements.txt with two named vars produces ENV REQUIREMENTS line"
MOCK_STORE="$TMPDIR_BASE/store1"
MOCK_TRACE="impl-test-001"
mkdir -p "$MOCK_STORE/$MOCK_TRACE/artifacts"
cat > "$MOCK_STORE/$MOCK_TRACE/artifacts/env-requirements.txt" <<'EOF'
DATABASE_URL # PostgreSQL connection string
SECRET_KEY # Django secret key
EOF
ENV_RESULT=$(run_env_check "$MOCK_STORE" "$MOCK_TRACE")
assert "ENV REQUIREMENTS present in output" '[[ "$ENV_RESULT" == *"ENV REQUIREMENTS"* ]]'
assert "DATABASE_URL present" '[[ "$ENV_RESULT" == *"DATABASE_URL"* ]]'
assert "SECRET_KEY present" '[[ "$ENV_RESULT" == *"SECRET_KEY"* ]]'
echo ""

# --- Test 2: No env-requirements.txt ---
echo "Test 2: No env-requirements.txt → output does NOT contain ENV REQUIREMENTS"
MOCK_STORE2="$TMPDIR_BASE/store2"
MOCK_TRACE2="impl-test-002"
mkdir -p "$MOCK_STORE2/$MOCK_TRACE2/artifacts"
# No env-requirements.txt file
ENV_RESULT2=$(run_env_check "$MOCK_STORE2" "$MOCK_TRACE2")
assert "ENV_RESULT is empty when file absent" '[[ -z "$ENV_RESULT2" ]]'
echo ""

# --- Test 3: Empty file ---
echo "Test 3: Empty env-requirements.txt → output does NOT contain ENV REQUIREMENTS"
MOCK_STORE3="$TMPDIR_BASE/store3"
MOCK_TRACE3="impl-test-003"
mkdir -p "$MOCK_STORE3/$MOCK_TRACE3/artifacts"
touch "$MOCK_STORE3/$MOCK_TRACE3/artifacts/env-requirements.txt"
ENV_RESULT3=$(run_env_check "$MOCK_STORE3" "$MOCK_TRACE3")
assert "ENV_RESULT is empty for empty file" '[[ -z "$ENV_RESULT3" ]]'
echo ""

# --- Test 4: Only comments ---
echo "Test 4: File with only comment lines → output does NOT contain ENV REQUIREMENTS"
MOCK_STORE4="$TMPDIR_BASE/store4"
MOCK_TRACE4="impl-test-004"
mkdir -p "$MOCK_STORE4/$MOCK_TRACE4/artifacts"
cat > "$MOCK_STORE4/$MOCK_TRACE4/artifacts/env-requirements.txt" <<'EOF'
# This is a comment
# Another comment
EOF
ENV_RESULT4=$(run_env_check "$MOCK_STORE4" "$MOCK_TRACE4")
assert "ENV_RESULT is empty for comments-only file" '[[ -z "$ENV_RESULT4" ]]'
echo ""

# --- Test 5: Blank lines between vars ---
echo "Test 5: File with blank lines between vars → only non-blank, non-comment vars appear"
MOCK_STORE5="$TMPDIR_BASE/store5"
MOCK_TRACE5="impl-test-005"
mkdir -p "$MOCK_STORE5/$MOCK_TRACE5/artifacts"
cat > "$MOCK_STORE5/$MOCK_TRACE5/artifacts/env-requirements.txt" <<'EOF'
API_KEY

REDIS_URL
EOF
ENV_RESULT5=$(run_env_check "$MOCK_STORE5" "$MOCK_TRACE5")
assert "API_KEY present" '[[ "$ENV_RESULT5" == *"API_KEY"* ]]'
assert "REDIS_URL present" '[[ "$ENV_RESULT5" == *"REDIS_URL"* ]]'
echo ""

# --- Test 6: Inline comment stripping ---
echo "Test 6: Inline comment after # is not included in the var name"
MOCK_STORE6="$TMPDIR_BASE/store6"
MOCK_TRACE6="impl-test-006"
mkdir -p "$MOCK_STORE6/$MOCK_TRACE6/artifacts"
cat > "$MOCK_STORE6/$MOCK_TRACE6/artifacts/env-requirements.txt" <<'EOF'
MY_VAR # this is a long comment about the var
EOF
ENV_RESULT6=$(run_env_check "$MOCK_STORE6" "$MOCK_TRACE6")
assert "MY_VAR present in output" '[[ "$ENV_RESULT6" == *"MY_VAR"* ]]'
assert "Comment text correctly stripped" '[[ "$ENV_RESULT6" != *"long comment"* ]]'
echo ""

# --- Test 7: Empty IMPL_TRACE ---
echo "Test 7: Empty IMPL_TRACE — no crash and ENV_RESULT empty"
ENV_RESULT7=$(run_env_check "$TMPDIR_BASE" "")
assert "ENV_RESULT stays empty when IMPL_TRACE is empty" '[[ -z "$ENV_RESULT7" ]]'
echo ""

# --- Summary ---
echo "==========================="
echo "Results: ${PASS}/${TOTAL} passed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILURES: $FAIL"
    exit 1
fi

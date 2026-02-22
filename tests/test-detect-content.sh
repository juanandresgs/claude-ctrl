#!/usr/bin/env bash
# test-detect-content.sh — TAP-compatible test suite for detect_content.sh
#
# @decision DEC-ARCH-003
# @title Test real detect_content.sh without mocking
# @status accepted
# @rationale Each test creates isolated synthetic temp directories, runs the
# real detect_content.sh script, and validates JSON output. No mocking of
# internal functions — tests exercise the full detection pipeline. This follows
# Sacred Practice #5: real unit tests, not mocks.
#
# Usage: bash tests/test-detect-content.sh
# Output: TAP-compatible (TEST/PASS/FAIL lines) + summary

set -euo pipefail

# Use realpath to resolve paths without cd (guard.sh blocks cd into worktrees)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DETECT_SCRIPT="$PROJECT_ROOT/skills/architect/scripts/detect_content.sh"

# --- TAP helpers ---

TEST_NUMBER=0
PASSED=0
FAILED=0
TMPDIR_ROOT="$PROJECT_ROOT/tmp/test-detect-content-$$"

pass() {
    TEST_NUMBER=$((TEST_NUMBER + 1))
    PASSED=$((PASSED + 1))
    echo "PASS: $1"
}

fail() {
    TEST_NUMBER=$((TEST_NUMBER + 1))
    FAILED=$((FAILED + 1))
    echo "FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Detail: $2"
    fi
}

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local test_name="$4"

    if ! command -v jq > /dev/null 2>&1; then
        # Fallback: grep for the pattern
        if echo "$json" | grep -q "\"$field\":\"$expected\"" || \
           echo "$json" | grep -q "\"$field\": \"$expected\""; then
            pass "$test_name"
        else
            fail "$test_name" "field '$field' != '$expected' in: $json"
        fi
        return
    fi

    local actual
    actual=$(echo "$json" | jq -r ".$field // empty" 2>/dev/null || echo "")
    if [[ "$actual" == "$expected" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "field '$field': expected='$expected' actual='$actual'"
    fi
}

assert_json_field_nonzero() {
    local json="$1"
    local field="$2"
    local test_name="$3"

    if ! command -v jq > /dev/null 2>&1; then
        # Minimal grep check
        if echo "$json" | grep -q "\"$field\""; then
            pass "$test_name"
        else
            fail "$test_name" "field '$field' not found in: $json"
        fi
        return
    fi

    local actual
    actual=$(echo "$json" | jq -r ".$field" 2>/dev/null || echo "")
    if [[ "$actual" != "0" ]] && [[ -n "$actual" ]] && [[ "$actual" != "null" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "field '$field' is zero/null/empty: '$actual'"
    fi
}

assert_json_valid() {
    local json="$1"
    local test_name="$2"

    if ! command -v jq > /dev/null 2>&1; then
        # Basic: check it starts with { and ends with }
        json_stripped="${json#"${json%%[! ]*}"}"
        if [[ "$json_stripped" == \{* ]] && [[ "$json_stripped" == *\} ]]; then
            pass "$test_name"
        else
            fail "$test_name" "JSON does not look valid: $json"
        fi
        return
    fi

    if echo "$json" | jq . > /dev/null 2>&1; then
        pass "$test_name"
    else
        fail "$test_name" "Invalid JSON: $json"
    fi
}

assert_json_array_contains() {
    local json="$1"
    local field="$2"
    local expected_substring="$3"
    local test_name="$4"

    if echo "$json" | grep -q "$expected_substring"; then
        pass "$test_name"
    else
        fail "$test_name" "array field '$field' does not contain '$expected_substring' in: $json"
    fi
}

# --- Setup / Teardown ---

setup_tmp() {
    local name="$1"
    local dir="$TMPDIR_ROOT/$name"
    mkdir -p "$dir"
    echo "$dir"
}

cleanup_all() {
    rm -rf "$TMPDIR_ROOT"
}

# Ensure cleanup on exit
trap cleanup_all EXIT

mkdir -p "$TMPDIR_ROOT"

# --- Guard: script must exist and be executable ---

if [[ ! -f "$DETECT_SCRIPT" ]]; then
    echo "ERROR: detect_content.sh not found at $DETECT_SCRIPT"
    exit 1
fi
if [[ ! -x "$DETECT_SCRIPT" ]]; then
    echo "ERROR: detect_content.sh is not executable at $DETECT_SCRIPT"
    exit 1
fi

echo "TEST: detect_content.sh test suite"
echo "Script: $DETECT_SCRIPT"
echo ""

# =============================================================================
# Test 1: Codebase detection
# Directory with package.json and .js files → content_type: codebase
# =============================================================================

echo "TEST: 1 - Codebase detection (package.json + .js files)"

T1=$(setup_tmp "t1-codebase")
cat > "$T1/package.json" <<'EOF'
{"name": "test-codebase", "version": "1.0.0", "dependencies": {"express": "^4.0.0"}}
EOF
cat > "$T1/index.js" <<'EOF'
const express = require('express');
const app = express();
module.exports = app;
EOF
mkdir -p "$T1/src"
cat > "$T1/src/server.js" <<'EOF'
const app = require('../index');
app.listen(3000);
EOF

OUTPUT=$(bash "$DETECT_SCRIPT" "$T1" 2>&1)

assert_json_valid "$OUTPUT" "T1: output is valid JSON"
assert_json_field "$OUTPUT" "content_type" "codebase" "T1: content_type is codebase"
assert_json_array_contains "$OUTPUT" "framework_signals" "express" "T1: framework_signals includes express"
echo ""

# =============================================================================
# Test 2: Document set detection
# Directory with only .md files → content_type: documents
# =============================================================================

echo "TEST: 2 - Document set detection (only .md files)"

T2=$(setup_tmp "t2-docs")
cat > "$T2/README.md" <<'EOF'
# Project README
This is the main readme.
EOF
cat > "$T2/CONTRIBUTING.md" <<'EOF'
# Contributing Guide
How to contribute.
EOF
cat > "$T2/API.md" <<'EOF'
# API Reference
API documentation.
EOF
mkdir -p "$T2/guides"
cat > "$T2/guides/getting-started.md" <<'EOF'
# Getting Started
Step by step guide.
EOF

OUTPUT=$(bash "$DETECT_SCRIPT" "$T2" 2>&1)

assert_json_valid "$OUTPUT" "T2: output is valid JSON"
assert_json_field "$OUTPUT" "content_type" "documents" "T2: content_type is documents"
assert_json_array_contains "$OUTPUT" "doc_formats" ".md" "T2: doc_formats includes .md"
echo ""

# =============================================================================
# Test 3: Mixed detection
# Directory with both .py source and .md docs → content_type: mixed
# =============================================================================

echo "TEST: 3 - Mixed detection (.py source + .md docs)"

T3=$(setup_tmp "t3-mixed")
cat > "$T3/main.py" <<'EOF'
#!/usr/bin/env python3
def main():
    print("Hello, world")

if __name__ == "__main__":
    main()
EOF
cat > "$T3/utils.py" <<'EOF'
def helper():
    return True
EOF
mkdir -p "$T3/src"
cat > "$T3/src/app.py" <<'EOF'
from utils import helper
EOF
cat > "$T3/README.md" <<'EOF'
# My Python App
Documentation here.
EOF
cat > "$T3/ARCHITECTURE.md" <<'EOF'
# Architecture
Design decisions.
EOF

OUTPUT=$(bash "$DETECT_SCRIPT" "$T3" 2>&1)

assert_json_valid "$OUTPUT" "T3: output is valid JSON"
assert_json_field "$OUTPUT" "content_type" "mixed" "T3: content_type is mixed"
assert_json_array_contains "$OUTPUT" "languages" "python" "T3: languages includes python"
echo ""

# =============================================================================
# Test 4: Single file detection
# Path to a single .py file → content_type: single_file
# =============================================================================

echo "TEST: 4 - Single file detection (path to a single .py file)"

T4=$(setup_tmp "t4-single-file")
cat > "$T4/analyze.py" <<'EOF'
#!/usr/bin/env python3
"""Analysis script."""

def analyze(data):
    return {"result": data}

class Analyzer:
    def __init__(self):
        self.data = []
EOF

OUTPUT=$(bash "$DETECT_SCRIPT" "$T4/analyze.py" 2>&1)

assert_json_valid "$OUTPUT" "T4: output is valid JSON"
assert_json_field "$OUTPUT" "content_type" "single_file" "T4: content_type is single_file"
echo ""

# =============================================================================
# Test 5: Empty directory — handles gracefully without crashing
# =============================================================================

echo "TEST: 5 - Empty directory (graceful handling)"

T5=$(setup_tmp "t5-empty")
# Leave it empty

OUTPUT=$(bash "$DETECT_SCRIPT" "$T5" 2>&1)
EXIT_CODE=$?

assert_json_valid "$OUTPUT" "T5: empty directory produces valid JSON (no crash)"
if [[ "$EXIT_CODE" -eq 0 ]]; then
    pass "T5: exit code is 0 (no crash on empty dir)"
else
    fail "T5: exit code is 0 (no crash on empty dir)" "got exit code $EXIT_CODE"
fi
echo ""

# =============================================================================
# Test 6: Nested codebase / monorepo structure
# Top-level dirs each with own package.json → all detected as codebase
# =============================================================================

echo "TEST: 6 - Nested/monorepo codebase structure"

T6=$(setup_tmp "t6-monorepo")
# Root-level config (monorepo)
cat > "$T6/package.json" <<'EOF'
{"name": "monorepo-root", "workspaces": ["packages/*"]}
EOF
# Package 1
mkdir -p "$T6/packages/frontend/src"
cat > "$T6/packages/frontend/package.json" <<'EOF'
{"name": "frontend", "dependencies": {"react": "^18.0.0"}}
EOF
cat > "$T6/packages/frontend/src/App.tsx" <<'EOF'
import React from 'react';
export const App = () => <div>Hello</div>;
EOF
# Package 2
mkdir -p "$T6/packages/backend/src"
cat > "$T6/packages/backend/package.json" <<'EOF'
{"name": "backend", "dependencies": {"express": "^4.0.0"}}
EOF
cat > "$T6/packages/backend/src/server.ts" <<'EOF'
import express from 'express';
const app = express();
export default app;
EOF

OUTPUT=$(bash "$DETECT_SCRIPT" "$T6" 2>&1)

assert_json_valid "$OUTPUT" "T6: monorepo produces valid JSON"
assert_json_field "$OUTPUT" "content_type" "codebase" "T6: content_type is codebase"
assert_json_field_nonzero "$OUTPUT" "file_counts.source" "T6: source file count is non-zero"
echo ""

# =============================================================================
# Test 7: Syntax check — detect_content.sh passes bash -n
# =============================================================================

echo "TEST: 7 - Syntax check (bash -n)"

if bash -n "$DETECT_SCRIPT" 2>/dev/null; then
    pass "T7: detect_content.sh has no syntax errors"
else
    fail "T7: detect_content.sh has syntax errors" "$(bash -n "$DETECT_SCRIPT" 2>&1)"
fi
echo ""

# =============================================================================
# Test 8 (W1-6): Integration test — ~/.claude itself
# Should be mixed (bash scripts + markdown docs)
# =============================================================================

echo "TEST: 8 - Integration test against ~/.claude"

CLAUDE_DIR="$PROJECT_ROOT"

OUTPUT=$(bash "$DETECT_SCRIPT" "$CLAUDE_DIR" 2>&1)
EXIT_CODE=$?

assert_json_valid "$OUTPUT" "T8: ~/.claude produces valid JSON"
if [[ "$EXIT_CODE" -eq 0 ]]; then
    pass "T8: exit code is 0"
else
    fail "T8: exit code is 0" "got $EXIT_CODE"
fi

# content_type should be mixed (bash + markdown)
CONTENT_TYPE_ACTUAL=$(echo "$OUTPUT" | grep -o '"content_type":"[^"]*"' | head -1 | cut -d'"' -f4 || \
                      echo "$OUTPUT" | jq -r '.content_type' 2>/dev/null || echo "unknown")
if [[ "$CONTENT_TYPE_ACTUAL" == "mixed" ]] || [[ "$CONTENT_TYPE_ACTUAL" == "codebase" ]]; then
    pass "T8: content_type is mixed or codebase (expected for ~/.claude with bash+md)"
else
    fail "T8: content_type is mixed or codebase" "got: $CONTENT_TYPE_ACTUAL"
fi

# Languages should include shell/bash
if echo "$OUTPUT" | grep -qi '"shell"' || echo "$OUTPUT" | grep -qi '"bash"'; then
    pass "T8: languages includes shell/bash"
else
    fail "T8: languages includes shell/bash" "output: $OUTPUT"
fi

# file_counts total should be non-zero
assert_json_field_nonzero "$OUTPUT" "file_counts.total" "T8: file_counts.total is non-zero"
echo ""

# =============================================================================
# Summary
# =============================================================================

echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed out of $TEST_NUMBER assertions"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi

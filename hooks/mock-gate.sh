#!/usr/bin/env bash
set -euo pipefail

# Escalating mock-detection gate for test file writes.
# PreToolUse hook — matcher: Write|Edit
#
# @decision DEC-MOCK-001
# @title Escalating mock detection gate
# @status accepted
# @rationale Sacred Practice #5 says "Real unit tests, not mocks." arXiv 2602.00409
#   found agents mock 95% of test doubles vs humans at 91%. Prose instructions drift
#   (anthropics/claude-code#18660), so deterministic hooks are the only reliable
#   enforcement. Escalating strikes match the proven test-gate.sh pattern.
#
# Reads:  .claude/.mock-gate-strikes (format: "strike_count|last_strike_epoch")
# Writes: .claude/.mock-gate-strikes
#
# Logic:
#   - Non-test files → ALLOW (always)
#   - Test files with @mock-exempt annotation → ALLOW (always)
#   - Test files with external-boundary mocks only → ALLOW (always)
#   - Test files with internal mocks:
#       Strike 1 → ALLOW with advisory warning
#       Strike 2+ → DENY

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# --- Only inspect test files ---
is_test_file "$FILE_PATH" || exit 0

# --- Get file content from the tool input ---
# For Write: new_content is the full file. For Edit: check old_string + new_string.
FILE_CONTENT=""
WRITE_CONTENT=$(get_field '.tool_input.content' 2>/dev/null || echo "")
if [[ -n "$WRITE_CONTENT" ]]; then
    FILE_CONTENT="$WRITE_CONTENT"
else
    # Edit tool — check the new_string being written
    FILE_CONTENT=$(get_field '.tool_input.new_string' 2>/dev/null || echo "")
fi

# No content to inspect → allow
[[ -z "$FILE_CONTENT" ]] && exit 0

# --- Check for @mock-exempt annotation ---
if echo "$FILE_CONTENT" | grep -q '@mock-exempt'; then
    exit 0
fi

# --- Detect mock patterns ---
# Internal mock patterns (these indicate mocking internal code)
HAS_INTERNAL_MOCK=false

# Python internal mock patterns
if echo "$FILE_CONTENT" | grep -qE 'from\s+unittest\.mock\s+import|from\s+unittest\s+import\s+mock|MagicMock|@patch|mock\.patch|mocker\.patch'; then
    # Check if the mock target is an external boundary
    if echo "$FILE_CONTENT" | grep -qE '@patch|mock\.patch|mocker\.patch'; then
        # Extract mock targets — look for patterns like @patch('module.Class')
        MOCK_TARGETS=$(echo "$FILE_CONTENT" | grep -oE "(patch|mock\.patch|mocker\.patch)\(['\"]([^'\"]+)" || echo "")
        if [[ -n "$MOCK_TARGETS" ]]; then
            # Check if ALL mock targets are external boundaries
            ALL_EXTERNAL=true
            while IFS= read -r target; do
                # External boundary patterns: requests, httpx, redis, psycopg, sqlalchemy,
                # urllib, http.client, smtplib, socket, subprocess, os.environ, etc.
                if ! echo "$target" | grep -qiE 'requests\.|httpx\.|redis\.|psycopg|sqlalchemy\.|urllib\.|http\.client|smtplib\.|socket\.|subprocess\.|os\.environ|boto3\.|botocore\.|aiohttp\.|httplib2\.|pymongo\.|mysql\.|sqlite3\.|psutil\.|paramiko\.|ftplib\.'; then
                    ALL_EXTERNAL=false
                    break
                fi
            done <<< "$MOCK_TARGETS"
            if [[ "$ALL_EXTERNAL" == "false" ]]; then
                HAS_INTERNAL_MOCK=true
            fi
        else
            # Has mock imports but couldn't determine targets — flag it
            HAS_INTERNAL_MOCK=true
        fi
    else
        # MagicMock or bare mock import without @patch — likely internal mocking
        HAS_INTERNAL_MOCK=true
    fi
fi

# JS/TS internal mock patterns
if echo "$FILE_CONTENT" | grep -qE 'jest\.mock\(|vi\.mock\(|\.mockImplementation|\.mockReturnValue|\.mockResolvedValue|sinon\.stub|sinon\.mock'; then
    # Check if mock targets are external
    JEST_MOCK_TARGETS=$(echo "$FILE_CONTENT" | grep -oE "(jest|vi)\.mock\(['\"]([^'\"]+)" || echo "")
    if [[ -n "$JEST_MOCK_TARGETS" ]]; then
        ALL_EXTERNAL=true
        while IFS= read -r target; do
            # External: axios, fetch, node-fetch, http, https, fs, net, dns, child_process, etc.
            if ! echo "$target" | grep -qiE 'axios|node-fetch|cross-fetch|undici|http['\''"]|https['\''"]|fs['\''"]|net['\''"]|dns['\''"]|child_process|nodemailer|ioredis|pg['\''"]|mysql|mongodb|aws-sdk|@aws-sdk|googleapis|stripe|twilio'; then
                ALL_EXTERNAL=false
                break
            fi
        done <<< "$JEST_MOCK_TARGETS"
        if [[ "$ALL_EXTERNAL" == "false" ]]; then
            HAS_INTERNAL_MOCK=true
        fi
    fi
    # .mockImplementation/.mockReturnValue without jest.mock context → flag
    if echo "$FILE_CONTENT" | grep -qE '\.mockImplementation|\.mockReturnValue|\.mockResolvedValue'; then
        # These on their own strongly suggest internal mocking
        if [[ -z "$JEST_MOCK_TARGETS" ]]; then
            HAS_INTERNAL_MOCK=true
        fi
    fi
fi

# Go mock patterns
if echo "$FILE_CONTENT" | grep -qE 'gomock\.|mockgen|NewMockController|EXPECT\(\)\.'; then
    HAS_INTERNAL_MOCK=true
fi

# --- External-boundary test libraries that are always OK ---
# These replace real HTTP/DB connections, which is the correct use of test doubles
if echo "$FILE_CONTENT" | grep -qE 'pytest-httpx|httpretty|responses\.|respx\.|nock\(|msw|@mswjs|wiremock|testcontainers|dockertest'; then
    # If the ONLY mock-like patterns are external boundary libraries, allow
    if [[ "$HAS_INTERNAL_MOCK" == "false" ]]; then
        exit 0
    fi
fi

# No internal mocks detected → allow
[[ "$HAS_INTERNAL_MOCK" == "false" ]] && exit 0

# --- Escalating strike system ---
PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
STRIKES_FILE="${CLAUDE_DIR}/.mock-gate-strikes"

CURRENT_STRIKES=0
if [[ -f "$STRIKES_FILE" ]]; then
    CURRENT_STRIKES=$(cut -d'|' -f1 "$STRIKES_FILE" 2>/dev/null || echo "0")
fi

NOW=$(date +%s)
NEW_STRIKES=$(( CURRENT_STRIKES + 1 ))
mkdir -p "${PROJECT_ROOT}/.claude"
echo "${NEW_STRIKES}|${NOW}" > "$STRIKES_FILE"

if [[ "$NEW_STRIKES" -ge 2 ]]; then
    # Strike 2+: DENY
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Sacred Practice #5: Tests must use real implementations, not mocks. This test file uses mocks for internal code (strike $NEW_STRIKES). Refactor to use fixtures, factories, or in-memory implementations for internal code. Mocks are only permitted for external service boundaries (HTTP APIs, databases, third-party services). Add '# @mock-exempt: <reason>' if mocking is truly necessary here."
  }
}
EOF
    exit 0
fi

# Strike 1: ALLOW with advisory warning
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Sacred Practice #5: This test uses mocks for internal code. Prefer real implementations — use fixtures, factories, or in-memory implementations. Mocks are acceptable only for external boundaries (HTTP, DB, third-party APIs). Next mock-heavy test write will be blocked. Add '# @mock-exempt: <reason>' if mocking is truly necessary."
  }
}
EOF
exit 0

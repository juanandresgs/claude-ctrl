#!/usr/bin/env bash
# Consolidated PreToolUse:Write|Edit hook — replaces 6 individual hooks.
# Runs branch-guard, plan-check, test-gate, mock-gate, doc-gate, and checkpoint
# in a single process with ONE library source. Ordered fastest-deny-first.
#
# Replaces (in order of execution):
#   1. branch-guard.sh  — hard deny: source writes on main branch
#   2. plan-check.sh    — hard deny: writes without MASTER_PLAN.md
#   3. test-gate.sh     — escalating strikes: writes while tests fail
#   4. mock-gate.sh     — escalating strikes: test files with internal mocks
#   5. doc-gate.sh      — advisory/deny: missing doc headers + @decision
#   6. checkpoint.sh    — side-effect: git ref checkpoint (no deny)
#
# @decision DEC-CONSOLIDATE-001
# @title Merge 6 PreToolUse:Write|Edit hooks into pre-write.sh
# @status accepted
# @rationale Each hook invocation previously re-sourced source-lib.sh → log.sh →
#   context-lib.sh (2,220 lines) adding 60-160ms overhead. For Write/Edit, 6 hooks
#   executed sequentially — 360-960ms per write. Merging into a single process
#   with one library source reduces this to ~60ms and eliminates 5 subprocess spawns.
#   All safety logic is preserved unchanged; only the process boundary is removed.
#   Gate order: branch-guard first (fastest, structural deny), plan-check second
#   (stateless fs check), test-gate/mock-gate third (stateful strike counters),
#   doc-gate fourth (content inspection), checkpoint last (side-effect, no deny).
#
# @decision DEC-META-001
# @title Output buffering for multi-JSON prevention
# @status accepted
# @rationale Multiple gates can emit advisory JSON to stdout and continue.
#   Claude Code may only parse the first JSON object, causing later deny
#   decisions to be silently dropped. Buffering advisories in an array and
#   emitting a single combined JSON at exit guarantees exactly one JSON
#   object per hook invocation. Denies always exit immediately (no buffer needed).

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Advisory buffer — accumulated advisory messages from all gates.
# Emitted as a single combined JSON at the end. Denies always exit
# immediately and never touch this buffer.
_ADVISORIES=()

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')
TOOL_NAME=$(get_field '.tool_name')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# ============================================================
# Gate 1: Branch guard (fastest — structural repo check, hard deny)
# Source: branch-guard.sh
# ============================================================

# Skip MASTER_PLAN.md (plans are written on main by design)
if [[ "$(basename "$FILE_PATH")" != "MASTER_PLAN.md" ]]; then
    # Only check source files
    if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH"; then
        # Resolve the git repo for this file
        FILE_DIR=$(dirname "$FILE_PATH")
        if [[ ! -d "$FILE_DIR" ]]; then
            FILE_DIR=$(dirname "$FILE_DIR")
        fi

        REPO_ROOT=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$REPO_ROOT" ]]; then
            CURRENT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
                # Allow during merge conflict resolution
                GIT_DIR=$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo "")
                if [[ -z "$GIT_DIR" || ! -f "$GIT_DIR/MERGE_HEAD" ]]; then
                    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: Cannot write source code on $CURRENT_BRANCH branch. Sacred Practice #2: Main is sacred.\n\nAction: Invoke the Guardian agent to create an isolated worktree for this work."
  }
}
EOF
                    exit 0
                fi
            fi
        fi
    fi
fi

# ============================================================
# Gate 2: Plan check (hard deny for planless source writes)
# Source: plan-check.sh
# ============================================================

# Skip non-source files, test files, config, .claude directory itself
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH" && [[ ! "$FILE_PATH" =~ \.claude/ ]]; then
    # Edit tool is inherently scoped — skip plan check
    if [[ "$TOOL_NAME" != "Edit" ]]; then
        # Write tool: skip small files (<20 lines)
        if [[ "$TOOL_NAME" == "Write" ]]; then
            CONTENT_LINES=$(get_field '.tool_input.content' | wc -l | tr -d ' ')
            if [[ "$CONTENT_LINES" -lt 20 ]]; then
                _ADVISORIES+=("Fast-mode bypass: small file write ($CONTENT_LINES lines) skipped plan check. Surface audit will track this.")
                # Continue to next gates — don't exit
            else
                # Large write — check for plan
                PROJECT_ROOT=$(detect_project_root)
                if [[ -d "$PROJECT_ROOT/.git" ]]; then
                    if [[ ! -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
                        cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: No MASTER_PLAN.md in $PROJECT_ROOT. Sacred Practice #6: We NEVER run straight into implementing anything.\n\nAction: Invoke the Planner agent to create MASTER_PLAN.md before implementing."
  }
}
EOF
                        exit 0
                    fi

                    # Plan lifecycle check
                    get_plan_status "$PROJECT_ROOT"
                    if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
                        cat <<DORMANT_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: MASTER_PLAN.md is dormant — all initiatives are completed (or plan has no active initiatives).\\n\\nAction: Add a new initiative to MASTER_PLAN.md before writing code. Invoke the Planner agent with create-or-amend workflow."
  }
}
DORMANT_EOF
                        exit 0
                    fi

                    # Plan staleness check (composite: churn % + drift IDs)
                    get_drift_data "$PROJECT_ROOT"

                    CHURN_WARN_PCT="${PLAN_CHURN_WARN:-15}"
                    CHURN_DENY_PCT="${PLAN_CHURN_DENY:-35}"

                    CHURN_TIER="ok"
                    [[ "$PLAN_SOURCE_CHURN_PCT" -ge "$CHURN_DENY_PCT" ]] && CHURN_TIER="deny"
                    [[ "$CHURN_TIER" == "ok" && "$PLAN_SOURCE_CHURN_PCT" -ge "$CHURN_WARN_PCT" ]] && CHURN_TIER="warn"

                    DRIFT_TIER="ok"
                    TOTAL_DRIFT=0
                    if [[ "$DRIFT_LAST_AUDIT_EPOCH" -gt 0 ]]; then
                        TOTAL_DRIFT=$((DRIFT_UNPLANNED_COUNT + DRIFT_UNIMPLEMENTED_COUNT))
                        [[ "$TOTAL_DRIFT" -ge 5 ]] && DRIFT_TIER="deny"
                        [[ "$DRIFT_TIER" == "ok" && "$TOTAL_DRIFT" -ge 2 ]] && DRIFT_TIER="warn"
                    else
                        [[ "$PLAN_COMMITS_SINCE" -ge 100 ]] && DRIFT_TIER="deny"
                        [[ "$DRIFT_TIER" == "ok" && "$PLAN_COMMITS_SINCE" -ge 40 ]] && DRIFT_TIER="warn"
                    fi

                    STALENESS="ok"
                    [[ "$CHURN_TIER" == "deny" || "$DRIFT_TIER" == "deny" ]] && STALENESS="deny"
                    [[ "$STALENESS" == "ok" ]] && [[ "$CHURN_TIER" == "warn" || "$DRIFT_TIER" == "warn" ]] && STALENESS="warn"

                    DIAG_PARTS=()
                    [[ "$CHURN_TIER" != "ok" ]] && DIAG_PARTS+=("Source churn: ${PLAN_SOURCE_CHURN_PCT}% of files changed (threshold: ${CHURN_WARN_PCT}%/${CHURN_DENY_PCT}%).")
                    if [[ "$DRIFT_LAST_AUDIT_EPOCH" -gt 0 ]]; then
                        [[ "$DRIFT_TIER" != "ok" ]] && DIAG_PARTS+=("Decision drift: $TOTAL_DRIFT decisions out of sync (${DRIFT_UNPLANNED_COUNT} unplanned, ${DRIFT_UNIMPLEMENTED_COUNT} unimplemented).")
                    else
                        [[ "$DRIFT_TIER" != "ok" ]] && DIAG_PARTS+=("Commit count fallback: $PLAN_COMMITS_SINCE commits since plan update.")
                    fi
                    DIAGNOSTIC=""
                    [[ ${#DIAG_PARTS[@]} -gt 0 ]] && DIAGNOSTIC=$(printf '%s ' "${DIAG_PARTS[@]}")

                    if [[ "$STALENESS" == "deny" ]]; then
                        cat <<DENY_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "MASTER_PLAN.md is critically stale. ${DIAGNOSTIC}Read MASTER_PLAN.md, scan the codebase for @decision annotations, and update the plan's phase statuses before continuing."
  }
}
DENY_EOF
                        exit 0
                    elif [[ "$STALENESS" == "warn" ]]; then
                        _ADVISORIES+=("Plan staleness warning: ${DIAGNOSTIC}Consider reviewing MASTER_PLAN.md — it may not reflect the current codebase state.")
                        # Continue to next gates (warn is advisory)
                    fi
                fi
            fi
        fi
    fi
fi

# ============================================================
# Gate 3: Test gate (escalating strikes — source writes while tests fail)
# Source: test-gate.sh
# ============================================================

# Only inspect source files (not test files, not config, not .claude)
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH" && ! is_test_file "$FILE_PATH" && [[ ! "$FILE_PATH" =~ \.claude/ ]]; then
    _TEST_PROJECT_ROOT=$(detect_project_root)
    _TEST_CLAUDE_DIR=$(get_claude_dir)
    TEST_STATUS_FILE="${_TEST_CLAUDE_DIR}/.test-status"
    STRIKES_FILE="${_TEST_CLAUDE_DIR}/.test-gate-strikes"

    if [[ ! -f "$TEST_STATUS_FILE" ]]; then
        # No test status yet — cold start advisory
        HAS_TESTS=false
        [[ -f "$_TEST_PROJECT_ROOT/pyproject.toml" ]] && HAS_TESTS=true
        [[ -f "$_TEST_PROJECT_ROOT/vitest.config.ts" || -f "$_TEST_PROJECT_ROOT/vitest.config.js" ]] && HAS_TESTS=true
        [[ -f "$_TEST_PROJECT_ROOT/jest.config.ts" || -f "$_TEST_PROJECT_ROOT/jest.config.js" ]] && HAS_TESTS=true
        [[ -f "$_TEST_PROJECT_ROOT/Cargo.toml" ]] && HAS_TESTS=true
        [[ -f "$_TEST_PROJECT_ROOT/go.mod" ]] && HAS_TESTS=true
        if [[ "$HAS_TESTS" == "true" ]]; then
            COLD_FLAG="${_TEST_CLAUDE_DIR}/.test-gate-cold-warned"
            if [[ ! -f "$COLD_FLAG" ]]; then
                mkdir -p "${_TEST_PROJECT_ROOT}/.claude"
                touch "$COLD_FLAG"
                _ADVISORIES+=("No test results yet but test framework detected. Tests will run automatically after this write.")
            fi
        fi
    else
        read_test_status "$_TEST_PROJECT_ROOT"

        if [[ "$TEST_RESULT" == "pass" ]]; then
            rm -f "$STRIKES_FILE"
            # Tests passing — allow, continue to next gates
        elif [[ "$TEST_AGE" -gt "$TEST_STALENESS_THRESHOLD" ]]; then
            : # Stale test status — allow
        else
            # Tests failing and status is fresh — escalating strikes
            CURRENT_STRIKES=0
            if [[ -f "$STRIKES_FILE" ]]; then
                CURRENT_STRIKES=$(cut -d'|' -f1 "$STRIKES_FILE" 2>/dev/null || echo "0")
            fi
            NEW_STRIKES=$(( CURRENT_STRIKES + 1 ))
            mkdir -p "${_TEST_PROJECT_ROOT}/.claude"
            NOW=$(date +%s)
            echo "${NEW_STRIKES}|${NOW}" > "$STRIKES_FILE"

            if [[ "$NEW_STRIKES" -ge 2 ]]; then
                DENY_REASON="Tests are still failing ($TEST_FAILS failures, ${TEST_AGE}s ago). You've written source code ${NEW_STRIKES} times without fixing tests."

                EVENTS_FILE="${_TEST_CLAUDE_DIR}/.session-events.jsonl"
                if [[ -f "$EVENTS_FILE" ]]; then
                    detect_approach_pivots "$_TEST_PROJECT_ROOT"
                    if [[ "$PIVOT_COUNT" -gt 0 && -n "$PIVOT_FILES" ]]; then
                        TOP_FILE=$(echo "$PIVOT_FILES" | awk '{print $1}')
                        TOP_BASENAME=$(basename "$TOP_FILE")
                        FILE_WRITES=$(grep '"event":"write"' "$EVENTS_FILE" 2>/dev/null \
                            | jq -r --arg f "$TOP_FILE" 'select(.file == $f) | .file' 2>/dev/null \
                            | wc -l | tr -d ' ')
                        DENY_REASON="$DENY_REASON You've modified \`${TOP_BASENAME}\` ${FILE_WRITES} time(s) this session without resolving test failures."
                        if [[ -n "$PIVOT_ASSERTIONS" ]]; then
                            TOP_ASSERTION=$(echo "$PIVOT_ASSERTIONS" | tr ',' '\n' | grep -v '^$' | head -1)
                            if [[ -n "$TOP_ASSERTION" ]]; then
                                DENY_REASON="$DENY_REASON The assertion \`${TOP_ASSERTION}\` has been failing repeatedly. Consider reading the failing test to understand what it expects, or try a different approach."
                            fi
                        else
                            DENY_REASON="$DENY_REASON Consider stepping back to re-read the failing test or trying a different file."
                        fi
                    else
                        MOST_EDITED=$(grep '"event":"write"' "$EVENTS_FILE" 2>/dev/null \
                            | jq -r '.file // empty' 2>/dev/null \
                            | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
                        if [[ -n "$MOST_EDITED" ]]; then
                            MOST_EDITED_BASE=$(basename "$MOST_EDITED")
                            DENY_REASON="$DENY_REASON Most-edited file this session: \`${MOST_EDITED_BASE}\`. Consider reading the failing tests before writing more source code."
                        else
                            DENY_REASON="$DENY_REASON Fix the failing tests before continuing. Test files are exempt from this gate."
                        fi
                    fi
                else
                    DENY_REASON="$DENY_REASON Fix the failing tests before continuing. Test files are exempt from this gate."
                fi

                ESCAPED_REASON=$(echo "$DENY_REASON" | jq -Rs '.[0:-1]')
                cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $ESCAPED_REASON
  }
}
EOF
                exit 0
            fi

            # Strike 1: advisory only
            _ADVISORIES+=("Tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Consider fixing tests before writing more source code. Next source write without fixing tests will be blocked.")
            # Continue to next gates
        fi
    fi
fi

# ============================================================
# Gate 4: Mock gate (escalating strikes — test files with internal mocks)
# Source: mock-gate.sh
# ============================================================

if is_test_file "$FILE_PATH"; then
    # Get file content from tool input
    FILE_CONTENT=""
    WRITE_CONTENT=$(get_field '.tool_input.content' 2>/dev/null || echo "")
    if [[ -n "$WRITE_CONTENT" ]]; then
        FILE_CONTENT="$WRITE_CONTENT"
    else
        FILE_CONTENT=$(get_field '.tool_input.new_string' 2>/dev/null || echo "")
    fi

    if [[ -n "$FILE_CONTENT" ]]; then
        # Check for @mock-exempt annotation
        if ! echo "$FILE_CONTENT" | grep -q '@mock-exempt'; then
            HAS_INTERNAL_MOCK=false

            # Python internal mock patterns
            if echo "$FILE_CONTENT" | grep -qE 'from\s+unittest\.mock\s+import|from\s+unittest\s+import\s+mock|MagicMock|@patch|mock\.patch|mocker\.patch'; then
                if echo "$FILE_CONTENT" | grep -qE '@patch|mock\.patch|mocker\.patch'; then
                    MOCK_TARGETS=$(echo "$FILE_CONTENT" | grep -oE "(patch|mock\.patch|mocker\.patch)\(['\"]([^'\"]+)" || echo "")
                    if [[ -n "$MOCK_TARGETS" ]]; then
                        ALL_EXTERNAL=true
                        while IFS= read -r target; do
                            if ! echo "$target" | grep -qiE 'requests\.|httpx\.|redis\.|psycopg|sqlalchemy\.|urllib\.|http\.client|smtplib\.|socket\.|subprocess\.|os\.environ|boto3\.|botocore\.|aiohttp\.|httplib2\.|pymongo\.|mysql\.|sqlite3\.|psutil\.|paramiko\.|ftplib\.'; then
                                ALL_EXTERNAL=false
                                break
                            fi
                        done <<< "$MOCK_TARGETS"
                        [[ "$ALL_EXTERNAL" == "false" ]] && HAS_INTERNAL_MOCK=true
                    else
                        HAS_INTERNAL_MOCK=true
                    fi
                else
                    HAS_INTERNAL_MOCK=true
                fi
            fi

            # JS/TS internal mock patterns
            if echo "$FILE_CONTENT" | grep -qE 'jest\.mock\(|vi\.mock\(|\.mockImplementation|\.mockReturnValue|\.mockResolvedValue|sinon\.stub|sinon\.mock'; then
                JEST_MOCK_TARGETS=$(echo "$FILE_CONTENT" | grep -oE "(jest|vi)\.mock\(['\"]([^'\"]+)" || echo "")
                if [[ -n "$JEST_MOCK_TARGETS" ]]; then
                    ALL_EXTERNAL=true
                    while IFS= read -r target; do
                        if ! echo "$target" | grep -qiE 'axios|node-fetch|cross-fetch|undici|http['"'"'"]|https['"'"'"]|fs['"'"'"]|net['"'"'"]|dns['"'"'"]|child_process|nodemailer|ioredis|pg['"'"'"]|mysql|mongodb|aws-sdk|@aws-sdk|googleapis|stripe|twilio'; then
                            ALL_EXTERNAL=false
                            break
                        fi
                    done <<< "$JEST_MOCK_TARGETS"
                    [[ "$ALL_EXTERNAL" == "false" ]] && HAS_INTERNAL_MOCK=true
                fi
                if echo "$FILE_CONTENT" | grep -qE '\.mockImplementation|\.mockReturnValue|\.mockResolvedValue'; then
                    if [[ -z "$JEST_MOCK_TARGETS" ]]; then
                        HAS_INTERNAL_MOCK=true
                    fi
                fi
            fi

            # Go mock patterns
            if echo "$FILE_CONTENT" | grep -qE 'gomock\.|mockgen|NewMockController|EXPECT\(\)\.'; then
                HAS_INTERNAL_MOCK=true
            fi

            # External-boundary test libraries are OK
            if echo "$FILE_CONTENT" | grep -qE 'pytest-httpx|httpretty|responses\.|respx\.|nock\(|msw|@mswjs|wiremock|testcontainers|dockertest'; then
                [[ "$HAS_INTERNAL_MOCK" == "false" ]] && HAS_INTERNAL_MOCK=false  # no-op: already false
            fi

            if [[ "$HAS_INTERNAL_MOCK" == "true" ]]; then
                _MOCK_PROJECT_ROOT=$(detect_project_root)
                _MOCK_CLAUDE_DIR=$(get_claude_dir)
                MOCK_STRIKES_FILE="${_MOCK_CLAUDE_DIR}/.mock-gate-strikes"

                CURRENT_STRIKES=0
                if [[ -f "$MOCK_STRIKES_FILE" ]]; then
                    CURRENT_STRIKES=$(cut -d'|' -f1 "$MOCK_STRIKES_FILE" 2>/dev/null || echo "0")
                fi
                NOW=$(date +%s)
                NEW_STRIKES=$(( CURRENT_STRIKES + 1 ))
                mkdir -p "${_MOCK_PROJECT_ROOT}/.claude"
                echo "${NEW_STRIKES}|${NOW}" > "$MOCK_STRIKES_FILE"

                if [[ "$NEW_STRIKES" -ge 2 ]]; then
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

                # Strike 1: advisory
                _ADVISORIES+=("Sacred Practice #5: This test uses mocks for internal code. Prefer real implementations — use fixtures, factories, or in-memory implementations. Mocks are acceptable only for external boundaries (HTTP, DB, third-party APIs). Next mock-heavy test write will be blocked. Add '# @mock-exempt: <reason>' if mocking is truly necessary.")
            fi
        fi
    fi
fi

# ============================================================
# Gate 5: Doc gate (documentation header + @decision enforcement)
# Source: doc-gate.sh
# ============================================================

# --- Check: New markdown files in project root ---
if [[ "$TOOL_NAME" == "Write" && "$FILE_PATH" =~ \.md$ ]]; then
    _MD_FILE_DIR=$(dirname "$FILE_PATH")
    _MD_PROJECT_ROOT=$(detect_project_root)
    if [[ "$_MD_FILE_DIR" == "$_MD_PROJECT_ROOT" ]]; then
        _MD_FILE_NAME=$(basename "$FILE_PATH")
        case "$_MD_FILE_NAME" in
            CLAUDE.md|README.md|MASTER_PLAN.md|AGENTS.md|CHANGELOG.md|LICENSE.md|CONTRIBUTING.md)
                ;; # Operational docs — allowed
            *)
                if [[ ! -f "$FILE_PATH" ]]; then
                    _ADVISORIES+=("Creating new markdown file '$_MD_FILE_NAME' in project root. Sacred Practice #9: Track deferred work in GitHub issues, not standalone files. Consider: gh issue create --title '...' instead.")
                fi
                ;;
        esac
    fi
fi

# Only inspect source files (skip meta hooks dir itself)
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH" && [[ ! "$FILE_PATH" =~ \.claude/hooks/ ]]; then
    _DOC_EXT="${FILE_PATH##*.}"

    # Helper: check if content has a documentation header
    _has_doc_header() {
        local content="$1"
        local ext="$2"
        local first_meaningful
        first_meaningful=$(echo "$content" | grep -v '^\s*$' | grep -v '^#!' | head -1)
        case "$ext" in
            py) echo "$first_meaningful" | grep -qE '^\s*("""|'"'"''"'"''"'"'|#\s*\S)' ;;
            ts|tsx|js|jsx) echo "$first_meaningful" | grep -qE '^\s*(/\*\*|//\s*\S)' ;;
            go) echo "$first_meaningful" | grep -qE '^\s*//\s*\S' ;;
            rs) echo "$first_meaningful" | grep -qE '^\s*//(!\s*\S|/?\s*\S)' ;;
            sh|bash|zsh) echo "$first_meaningful" | grep -qE '^\s*#\s*\S' ;;
            c|cpp|h|hpp|cs) echo "$first_meaningful" | grep -qE '^\s*(/\*\*|//\s*\S)' ;;
            java|kt|swift) echo "$first_meaningful" | grep -qE '^\s*(/\*\*|//\s*\S)' ;;
            rb) echo "$first_meaningful" | grep -qE '^\s*#\s*\S' ;;
            php)
                local after_php
                after_php=$(echo "$content" | grep -v '^\s*$' | grep -v '^<?' | head -1)
                echo "$after_php" | grep -qE '^\s*(/\*\*|//\s*\S|#\s*\S)' ;;
            *) echo "$first_meaningful" | grep -qE '^\s*(/\*|//|#)\s*\S' ;;
        esac
    }

    _has_decision() {
        local content="$1"
        echo "$content" | grep -qE '@decision|# DECISION:|// DECISION:'
    }

    _doc_deny() {
        local reason="$1"
        local context="${2:-}"
        jq -n \
            --arg reason "$reason" \
            --arg context "$context" \
            '{
                hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    permissionDecision: "deny",
                    permissionDecisionReason: $reason,
                    additionalContext: $context
                }
            }'
        exit 0
    }

    _get_header_template() {
        local f="$1"
        case "$f" in
            *.py) echo '"""
[Module description: purpose and rationale]
"""' ;;
            *.ts|*.tsx|*.js|*.jsx) echo '/**
 * @file [filename]
 * @description [Purpose of this file]
 * @rationale [Why this approach was chosen]
 */' ;;
            *.go) echo '// Package [name] provides [description].
// [Rationale for approach]' ;;
            *.rs) echo '//! [Module description: purpose and rationale]' ;;
            *.sh|*.bash|*.zsh) echo '# [Script description: purpose and rationale]' ;;
            *.c|*.cpp|*.h|*.hpp) echo '/**
 * @file [filename]
 * @brief [Purpose]
 * @rationale [Why this approach]
 */' ;;
            *) echo '// [File description: purpose and rationale]' ;;
        esac
    }

    if [[ "$TOOL_NAME" == "Write" ]]; then
        _DOC_CONTENT=$(get_field '.tool_input.content')
        if [[ -n "$_DOC_CONTENT" ]]; then
            if ! _has_doc_header "$_DOC_CONTENT" "$_DOC_EXT"; then
                TEMPLATE=$(_get_header_template "$FILE_PATH")
                _doc_deny "File $FILE_PATH missing documentation header. Every source file must start with a documentation comment describing purpose and rationale." "Add a documentation header at the top of the file:\n$TEMPLATE"
            fi

            LINE_COUNT=$(echo "$_DOC_CONTENT" | wc -l | tr -d ' ')
            if [[ "$LINE_COUNT" -ge "$DECISION_LINE_THRESHOLD" ]]; then
                if ! _has_decision "$_DOC_CONTENT"; then
                    _doc_deny "File $FILE_PATH is $LINE_COUNT lines but has no @decision annotation. Significant files (${DECISION_LINE_THRESHOLD}+ lines) require a @decision annotation." "Add a @decision annotation to the file. See CLAUDE.md for format examples."
                fi
            fi
        fi
    elif [[ "$TOOL_NAME" == "Edit" ]]; then
        if [[ -f "$FILE_PATH" ]]; then
            FILE_CONTENT_ON_DISK=$(cat "$FILE_PATH" 2>/dev/null || echo "")
            if [[ -n "$FILE_CONTENT_ON_DISK" ]]; then
                if _has_doc_header "$FILE_CONTENT_ON_DISK" "$_DOC_EXT"; then
                    LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')
                    if [[ "$LINE_COUNT" -ge "$DECISION_LINE_THRESHOLD" ]]; then
                        if ! _has_decision "$FILE_CONTENT_ON_DISK"; then
                            _ADVISORIES+=("Note: $FILE_PATH is $LINE_COUNT lines but has no @decision annotation. Consider adding one.")
                        fi
                    fi
                else
                    _ADVISORIES+=("File $FILE_PATH lacks doc header. See CLAUDE.md for template.")
                fi
            fi
        fi
    fi
fi

# ============================================================
# Gate 6: Checkpoint (git ref-based snapshots — side-effect, no deny)
# Source: checkpoint.sh
# ============================================================

_CP_PROJECT_ROOT=$(detect_project_root)
_CP_CLAUDE_DIR=$(get_claude_dir)

# Only checkpoint git repos on feature branches (not main/master)
if git -C "$_CP_PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git -C "$_CP_PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
    if [[ "$BRANCH" != "main" && "$BRANCH" != "master" && -n "$BRANCH" ]]; then
        # Skip meta-repo checkpoints
        if ! is_claude_meta_repo "$_CP_PROJECT_ROOT" 2>/dev/null; then
            mkdir -p "$_CP_CLAUDE_DIR"

            COUNTER_FILE="${_CP_CLAUDE_DIR}/.checkpoint-counter"
            N=0
            if [[ -f "$COUNTER_FILE" ]]; then
                N=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
                [[ "$N" =~ ^[0-9]+$ ]] || N=0
            fi
            N=$((N + 1))
            echo "$N" > "$COUNTER_FILE"

            CREATE=false
            (( N % 5 == 0 )) && CREATE=true

            SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
            CHANGES_FILE="${_CP_CLAUDE_DIR}/.session-changes-${SESSION_ID}"
            if [[ -f "$CHANGES_FILE" ]]; then
                if ! grep -qF "$FILE_PATH" "$CHANGES_FILE" 2>/dev/null; then
                    CREATE=true
                fi
                grep -qF "$FILE_PATH" "$CHANGES_FILE" 2>/dev/null || echo "$FILE_PATH" >> "$CHANGES_FILE"
            else
                echo "$FILE_PATH" > "$CHANGES_FILE"
                CREATE=true
            fi

            if [[ "$CREATE" == "true" ]]; then
                GIT_DIR=$(git -C "$_CP_PROJECT_ROOT" rev-parse --git-dir 2>/dev/null) || true
                if [[ -n "$GIT_DIR" ]]; then
                    if [[ ! "${GIT_DIR}" = /* ]]; then
                        GIT_DIR="${_CP_PROJECT_ROOT}/${GIT_DIR}"
                    fi

                    TMPIDX=$(mktemp "${TMPDIR:-/tmp}/checkpoint-idx.XXXXXX")
                    # shellcheck disable=SC2064
                    trap "rm -f '$TMPIDX'" EXIT

                    if [[ -f "${GIT_DIR}/index" ]]; then
                        cp "${GIT_DIR}/index" "$TMPIDX" 2>/dev/null || true
                    fi

                    GIT_INDEX_FILE="$TMPIDX" git -C "$_CP_PROJECT_ROOT" add -A 2>/dev/null || true
                    TREE=$(GIT_INDEX_FILE="$TMPIDX" git -C "$_CP_PROJECT_ROOT" write-tree 2>/dev/null) || {
                        rm -f "$TMPIDX"
                        trap - EXIT
                        true
                    }

                    if [[ -n "${TREE:-}" ]]; then
                        rm -f "$TMPIDX"
                        trap - EXIT

                        PARENT=$(git -C "$_CP_PROJECT_ROOT" rev-parse HEAD 2>/dev/null) || true
                        if [[ -n "${PARENT:-}" ]]; then
                            BASENAME="${FILE_PATH##*/}"
                            MSG="checkpoint:$(date +%s):before:${BASENAME}"
                            SHA=$(git -C "$_CP_PROJECT_ROOT" commit-tree "$TREE" -p "$PARENT" -m "$MSG" 2>/dev/null) || true

                            if [[ -n "${SHA:-}" ]]; then
                                EXISTING=$(git -C "$_CP_PROJECT_ROOT" for-each-ref "refs/checkpoints/${BRANCH}/" --format='%(refname)' 2>/dev/null | wc -l | tr -d ' ')
                                CP_NUM=$((EXISTING + 1))
                                REF="refs/checkpoints/${BRANCH}/${CP_NUM}"
                                git -C "$_CP_PROJECT_ROOT" update-ref "$REF" "$SHA" 2>/dev/null || true

                                DETAIL=$(jq -cn --arg ref "$REF" --arg file "$BASENAME" --arg n "$N" \
                                    '{ref:$ref,file:$file,trigger:("n="+$n)}' 2>/dev/null) || DETAIL="{}"
                                append_session_event "checkpoint" "$DETAIL" "$_CP_PROJECT_ROOT" || true
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

# Emit combined advisory JSON if any gates produced advisory messages.
# This guarantees exactly one JSON object per hook invocation — denies
# exit immediately above, advisories are collected here and emitted once.
if [[ ${#_ADVISORIES[@]} -gt 0 ]]; then
    COMBINED=$(printf '%s\n' "${_ADVISORIES[@]}" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": $COMBINED
  }
}
EOF
fi

exit 0

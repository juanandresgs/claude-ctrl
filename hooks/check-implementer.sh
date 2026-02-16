#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:implementer — deterministic validation of implementer output.
# Checks worktree usage, @decision annotation coverage, and test status.
# Proof-of-work verification is handled by the tester agent, not the implementer.
#
# @decision DEC-IMPL-STOP-001
# @title Implementer SubagentStop without proof-of-work check
# @status accepted
# @rationale Proof-of-work verification moved to the tester agent to separate
#   builder from judge. The implementer exits after tests pass. The tester
#   handles live demos and user verification. This prevents the implementer
#   from being both builder and judge of its own work.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "implementer"

# --- Trace protocol: detect and prepare for finalization ---
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "implementer" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
fi

get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

ISSUES=()

# Check 1: Current branch is NOT main/master (worktree was used)
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    ISSUES+=("Implementation on $CURRENT_BRANCH branch — worktree should have been used")
fi

# Check 2: Scan session-changes for 50+ line source files missing @decision
SESSION_ID="${CLAUDE_SESSION_ID:-}"
CHANGES=""
if [[ -n "$SESSION_ID" && -f "${CLAUDE_DIR}/.session-changes-${SESSION_ID}" ]]; then
    CHANGES="${CLAUDE_DIR}/.session-changes-${SESSION_ID}"
elif [[ -f "${CLAUDE_DIR}/.session-changes" ]]; then
    CHANGES="${CLAUDE_DIR}/.session-changes"
fi

MISSING_COUNT=0
MISSING_FILES=""
DECISION_PATTERN='@decision|# DECISION:|// DECISION\('

if [[ -n "$CHANGES" && -f "$CHANGES" ]]; then
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        # Only check source files
        is_source_file "$file" || continue
        # Skip test/config
        is_skippable_path "$file" && continue

        # Check line count
        line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        if [[ "$line_count" -ge "$DECISION_LINE_THRESHOLD" ]]; then
            if ! grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
                ((MISSING_COUNT++)) || true
                MISSING_FILES+="  - $(basename "$file") ($line_count lines)\n"
            fi
        fi
    done < <(sort -u "$CHANGES")
fi

if [[ "$MISSING_COUNT" -gt 0 ]]; then
    ISSUES+=("$MISSING_COUNT source file(s) ≥50 lines missing @decision annotation")
fi

# Check 3: Approval-loop detection — agent should not end with unanswered question
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue)|ready to (test|review|commit)\?' || echo "")
    HAS_EXECUTION=$(echo "$RESPONSE_TEXT" | grep -iE 'tests pass|implementation complete|done|finished|all tests|ready for review' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_EXECUTION" ]]; then
        ISSUES+=("Agent ended with approval question but no completion confirmation — may need follow-up")
    fi
fi

# Check 4: Test status verification
if read_test_status "$PROJECT_ROOT"; then
    if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt 1800 ]]; then
        ISSUES+=("Tests failing ($TEST_FAILS failures, ${TEST_AGE}s ago) — implementation not complete")
    fi
else
    # No test results at all — warn (project may not have tests, so advisory)
    ISSUES+=("No test results found — verify tests were run before declaring done")
fi

# --- Trace protocol: finalize trace ---
if [[ -n "$TRACE_ID" ]]; then
    # Fallback: if agent didn't write summary.md, save response excerpt
    if [[ ! -f "$TRACE_DIR/summary.md" ]]; then
        echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
    fi
    # Validate expected artifacts
    for artifact in test-output.txt files-changed.txt; do
        if [[ ! -f "$TRACE_DIR/artifacts/$artifact" ]]; then
            ISSUES+=("Trace artifact missing: $artifact (TRACE_DIR=$TRACE_DIR)")
        fi
    done
    finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "implementer"
fi

# Response size advisory
if [[ -n "$RESPONSE_TEXT" ]]; then
    WORD_COUNT=$(echo "$RESPONSE_TEXT" | wc -w | tr -d ' ')
    if [[ "$WORD_COUNT" -gt 1200 ]]; then
        ISSUES+=("Agent response too large (~${WORD_COUNT} words). Use TRACE_DIR/artifacts/ for verbose output, return ≤1500 token summary.")
    fi
fi

# Build context message
CONTEXT=""
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Implementer validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
    if [[ -n "$MISSING_FILES" ]]; then
        CONTEXT+="\nFiles needing @decision:\n$MISSING_FILES"
    fi
else
    CONTEXT="Implementer validation: branch=$CURRENT_BRANCH, @decision coverage OK."
fi

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    FINDING="implementer|$(IFS=';'; echo "${ISSUES[*]}")"
    if ! grep -qxF "$FINDING" "$FINDINGS_FILE" 2>/dev/null; then
        echo "$FINDING" >> "$FINDINGS_FILE"
    fi
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_implementer" "$issue"
    done
fi

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0

#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:implementer — deterministic validation of implementer output.
# Replaces AI agent hook. Checks worktree usage and @decision annotation coverage.
# Exits 2 (feedback loop) when proof-of-work is missing — forces implementer resume.
# Exits 0 when proof-of-work is verified or when loop guard triggers escalation.
#
# DECISION: Blocking proof-of-work enforcement. Rationale: Advisory-only hook
# (exit 0 always) was routinely skipped — agents declared "done" without live demo.
# Exit 2 forces the orchestrator to resume the implementer, creating an unavoidable
# feedback loop. Loop guard (2+ resumes) escalates to user to prevent infinite loops.
# Status: accepted.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

PROJECT_ROOT=$(detect_project_root)

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "implementer"

ISSUES=()

# Check 1: Current branch is NOT main/master (worktree was used)
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    ISSUES+=("Implementation on $CURRENT_BRANCH branch — worktree should have been used")
fi

# Check 2: Scan session-changes for 50+ line source files missing @decision
SESSION_ID="${CLAUDE_SESSION_ID:-}"
CHANGES=""
if [[ -n "$SESSION_ID" && -f "$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}" ]]; then
    CHANGES="$PROJECT_ROOT/.claude/.session-changes-${SESSION_ID}"
elif [[ -f "$PROJECT_ROOT/.claude/.session-changes" ]]; then
    CHANGES="$PROJECT_ROOT/.claude/.session-changes"
fi

MISSING_COUNT=0
MISSING_FILES=""
DECISION_PATTERN='@decision|# DECISION:|// DECISION\('

if [[ -n "$CHANGES" && -f "$CHANGES" ]]; then
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        # Only check source files
        [[ ! "$file" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh)$ ]] && continue
        # Skip test/config
        [[ "$file" =~ (\.test\.|\.spec\.|__tests__|\.config\.|node_modules|vendor|dist|\.git|\.claude) ]] && continue

        # Check line count
        line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        if [[ "$line_count" -ge 50 ]]; then
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
TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
if [[ -f "$TEST_STATUS_FILE" ]]; then
    TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
    TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
    TEST_TIME=$(cut -d'|' -f3 "$TEST_STATUS_FILE")
    NOW=$(date +%s)
    AGE=$(( NOW - TEST_TIME ))
    if [[ "$TEST_RESULT" == "fail" && "$AGE" -lt 1800 ]]; then
        ISSUES+=("Tests failing ($TEST_FAILS failures, ${AGE}s ago) — implementation not complete")
    fi
else
    # No test results at all — warn (project may not have tests, so advisory)
    ISSUES+=("No test results found — verify tests were run before declaring done")
fi

# Check 5: Proof-of-work verification status (BLOCKING — exit 2 when missing)
PROOF_FILE="${PROJECT_ROOT}/.claude/.proof-status"
PROOF_MISSING=false
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
    if [[ "$PROOF_STATUS" == "verified" ]]; then
        : # OK — user has confirmed feature works
    elif [[ "$PROOF_STATUS" == "pending" ]]; then
        PROOF_MISSING=true
        ISSUES+=("Proof-of-work pending — verification checkpoint not completed by user")
    else
        PROOF_MISSING=true
        ISSUES+=("Proof-of-work status unknown ('$PROOF_STATUS') — run verification checkpoint")
    fi
else
    PROOF_MISSING=true
    ISSUES+=("No proof-of-work verification — user has not confirmed feature works (.proof-status missing)")
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
    FINDINGS_FILE="${PROJECT_ROOT}/.claude/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    echo "implementer|$(IFS=';'; echo "${ISSUES[*]}")" >> "$FINDINGS_FILE"
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_implementer" "$issue"
    done
fi

# If proof-of-work is missing, exit 2 (feedback loop) to block Guardian dispatch
if [[ "$PROOF_MISSING" == "true" ]]; then
    # Loop guard: count how many times implementer has been sent back for proof
    FINDINGS_FILE="${PROJECT_ROOT}/.claude/.agent-findings"
    RESUME_COUNT=0
    if [[ -f "$FINDINGS_FILE" ]]; then
        RESUME_COUNT=$(grep -c 'proof-of-work' "$FINDINGS_FILE" 2>/dev/null || echo "0")
    fi

    if [[ "$RESUME_COUNT" -ge 2 ]]; then
        # Escalate to user instead of looping
        DIRECTIVE="ESCALATION: The implementer has been sent back ${RESUME_COUNT} times for proof-of-work but has not completed it. Please intervene — either run the live demo yourself or waive the requirement for this task."
        ESCAPED=$(echo -e "$CONTEXT\n\n$DIRECTIVE" | jq -Rs .)
        cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
        exit 0  # Don't block forever — let the user see the escalation
    else
        DIRECTIVE="BLOCKED: Implementer returned without live proof-of-work.\nDO NOT dispatch Guardian. Resume the implementer to:\n1. Run the feature/system live (not just tests)\n2. Show actual output to the user\n3. Ask: \"Does this match your intent?\"\n4. Get user confirmation → write .proof-status\n\nThe SubagentStop hook enforces this gate. Proof-of-work is a BLOCKING requirement."
        ESCAPED=$(echo -e "$CONTEXT\n\n$DIRECTIVE" | jq -Rs .)
        cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
        exit 2  # Feedback loop — force implementer resume
    fi
fi

# Output as additionalContext (proof verified or no proof issues)
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0

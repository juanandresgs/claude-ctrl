#!/usr/bin/env bash
# SubagentStop:implementer — deterministic validation of implementer output.
# Checks worktree usage, @decision annotation coverage, and test status.
# Proof-of-work verification is handled by the tester agent, not the implementer.
#
# Ordering: trace finalization runs FIRST (immediately after PROJECT_ROOT detection)
# so it completes within the 5s timeout even when git/plan state checks are slow.
#
# @decision DEC-IMPL-STOP-001
# @title Implementer SubagentStop without proof-of-work check
# @status accepted
# @rationale Proof-of-work verification moved to the tester agent to separate
#   builder from judge. The implementer exits after tests pass. The tester
#   handles live demos and user verification. This prevents the implementer
#   from being both builder and judge of its own work.
#
# @decision DEC-IMPL-STOP-002
# @title Move finalize_trace before auto-capture blocks to beat timeout
# @status accepted
# @rationale The 5s hook timeout was causing finalize_trace to be skipped when
#   auto-capture git commands (files-changed, test-output) ran first and consumed
#   most of the budget. Moving finalize_trace immediately after the summary.md
#   fallback ensures the marker cleanup and trace sealing complete even when the
#   git auto-capture blocks time out. Auto-capture still runs after finalize_trace
#   for best-effort artifact collection without blocking marker removal.
#   See DEC-STALE-MARKER-001 for the root cause this ordering addresses.
#
# @decision DEC-STALE-MARKER-001
# @title Order finalize_trace before auto-capture to prevent stale .active-* markers
# @status accepted
# @rationale When a SubagentStop hook times out at 5s, any code after the timeout
#   point is silently skipped. If auto-capture git commands (3 git calls + sort)
#   consume the budget before finalize_trace runs, the .active-implementer-* marker
#   is never cleaned up. That stale marker causes Gate B in task-track.sh to
#   permanently block tester dispatch on the next session. Fix: finalize_trace runs
#   immediately after the summary.md fallback (which it depends on) and before any
#   git auto-capture. Auto-capture is best-effort; marker cleanup is mandatory.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

# Diagnostic: log SubagentStop payload keys for field-name investigation (Issue #TBD)
if [[ -n "$AGENT_RESPONSE" && "$AGENT_RESPONSE" != "{}" ]]; then
    PAYLOAD_KEYS=$(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo "unknown")
    PAYLOAD_SIZE=${#AGENT_RESPONSE}
    echo "check-implementer: SubagentStop payload keys=[$PAYLOAD_KEYS] size=${PAYLOAD_SIZE}" >&2
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "implementer"
append_session_event "agent_stop" "{\"type\":\"implementer\"}" "$PROJECT_ROOT"

# --- Trace protocol: finalize trace (RUNS FIRST to beat timeout) ---
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "implementer" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
fi

# Field name confirmed from Claude Code docs: SubagentStop payload uses `last_assistant_message`.
# `.response` kept as fallback for backward compatibility with any non-standard payloads.
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null || echo "")

if [[ -n "$TRACE_ID" ]]; then
    # Fallback: if agent didn't write summary.md or wrote a near-empty file (e.g. 1-byte \n),
    # save response excerpt or a diagnostic message.
    # Using a 10-byte minimum instead of -s (size>0) because stop hooks that receive an empty
    # RESPONSE_TEXT write "echo '' > summary.md" producing a 1-byte newline that -s considers
    # non-empty. A 10-byte threshold reliably catches both missing and trivially empty files.
    #
    # @decision DEC-IMPL-STOP-003
    # @title Use 10-byte minimum threshold for summary.md fallback check
    # @status accepted
    # @rationale The -s test (size > 0) was fooled by stop hooks writing a 1-byte newline from
    #   an empty RESPONSE_TEXT. The orchestrator then received an empty summary.md, lost all
    #   context, and went silent. A 10-byte threshold catches both missing and trivially empty
    #   files. When RESPONSE_TEXT itself is empty/whitespace, we write a diagnostic message
    #   with timestamp and likely cause so the orchestrator can surface it to the user.
    _sum_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
    if [[ ! -f "$TRACE_DIR/summary.md" ]] || [[ "$_sum_size" -lt 10 ]]; then
        if [[ -z "${RESPONSE_TEXT// /}" ]]; then
            {
                echo "# Agent returned empty response ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
                echo "Agent type: implementer"
                echo "Duration: ${SECONDS:-unknown}s"
                echo "Likely cause: max_turns exhausted or force-stopped"
            } > "$TRACE_DIR/summary.md" 2>/dev/null || true
        else
            echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
        fi
    fi

    # finalize_trace MUST run before auto-capture git commands to prevent stale markers.
    # See DEC-STALE-MARKER-001: if the hook times out during git commands, finalize_trace
    # (and its .active-* marker cleanup) would be silently skipped, permanently blocking
    # tester dispatch. summary.md fallback must precede this call — finalize_trace reads
    # it to determine crashed vs completed status.
    if ! finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "implementer"; then
        append_audit "$PROJECT_ROOT" "trace_orphan" "finalize_trace failed for implementer trace $TRACE_ID"
    fi

    # Auto-capture files-changed.txt if agent didn't write it (best-effort, runs after finalize).
    # Collects unstaged diffs, staged diffs, and recent commit file names so
    # refinalize_trace() can compute files_changed > 0 even when the agent omitted
    # the artifact. Uses || true on every git command — hook must not abort on
    # non-git paths or failed subcommands.
    if [[ -d "$TRACE_DIR/artifacts" && ! -f "$TRACE_DIR/artifacts/files-changed.txt" ]]; then
        git -C "$PROJECT_ROOT" diff --name-only 2>/dev/null > "$TRACE_DIR/artifacts/files-changed.txt" || true
        git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null >> "$TRACE_DIR/artifacts/files-changed.txt" || true
        git -C "$PROJECT_ROOT" log --name-only --format="" -5 2>/dev/null >> "$TRACE_DIR/artifacts/files-changed.txt" || true
        sort -u "$TRACE_DIR/artifacts/files-changed.txt" -o "$TRACE_DIR/artifacts/files-changed.txt" 2>/dev/null || true
    fi

    # Auto-capture test-output.txt from .test-status if agent didn't write it (best-effort).
    # .test-status format is "result|fail_count|timestamp". The capture adds a
    # human-readable prefix so report.sh can display it as evidence text.
    if [[ -d "$TRACE_DIR/artifacts" && ! -f "$TRACE_DIR/artifacts/test-output.txt" ]]; then
        TS_FILE=""
        [[ -f "${CLAUDE_DIR}/.test-status" ]] && TS_FILE="${CLAUDE_DIR}/.test-status"
        [[ -z "$TS_FILE" && -f "$PROJECT_ROOT/.test-status" ]] && TS_FILE="$PROJECT_ROOT/.test-status"
        [[ -z "$TS_FILE" && -f "$PROJECT_ROOT/.claude/.test-status" ]] && TS_FILE="$PROJECT_ROOT/.claude/.test-status"
        if [[ -n "$TS_FILE" ]]; then
            echo "# Auto-captured from .test-status at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TRACE_DIR/artifacts/test-output.txt"
            cat "$TS_FILE" >> "$TRACE_DIR/artifacts/test-output.txt" 2>/dev/null || true
            TS_RESULT=$(cut -d'|' -f1 "$TS_FILE" 2>/dev/null || echo "unknown")
            [[ "$TS_RESULT" == "pass" ]] && echo "Tests passed" >> "$TRACE_DIR/artifacts/test-output.txt"
            [[ "$TS_RESULT" == "fail" ]] && echo "Tests failed" >> "$TRACE_DIR/artifacts/test-output.txt"
        fi
    fi
fi

# --- Advisory checks (run after finalize to avoid timeout races) ---
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

# Check 5: Doc freshness — flag DENY-tier docs as issues
# Advisory docs (WARN tier) are noted but not flagged as blocking issues.
get_doc_freshness "$PROJECT_ROOT"
if [[ -n "$DOC_STALE_DENY" ]]; then
    ISSUES+=("Documentation stale (BLOCK tier): ${DOC_STALE_DENY} — update before merge to main")
fi
if [[ -n "$DOC_STALE_WARN" ]]; then
    ISSUES+=("Documentation stale (WARN tier): ${DOC_STALE_WARN} — review before merge")
fi

# Check 6: Validate expected trace artifacts (advisory, not blocking)
if [[ -n "$TRACE_ID" && -d "$TRACE_DIR" ]]; then
    for artifact in test-output.txt files-changed.txt; do
        if [[ ! -f "$TRACE_DIR/artifacts/$artifact" ]]; then
            ISSUES+=("Trace artifact missing: $artifact (TRACE_DIR=$TRACE_DIR)")
        fi
    done
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

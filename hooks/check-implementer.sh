#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:implementer — deterministic validation of implementer output.
# Replaces AI agent hook. Checks worktree usage and @decision annotation coverage.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# DECISION: Deterministic implementer validation. Rationale: AI agent hooks have
# non-deterministic runtime and cascade risk. Branch check is git rev-parse,
# @decision check is grep. Both complete in <1s. Status: accepted.

# shellcheck source=hooks/log.sh
source "$(dirname "$0")/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
AGENT_TYPE=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.agent_type // empty' 2>/dev/null || true)

PROJECT_ROOT=$(detect_project_root)

# Record hook start time for observatory duration metric.
_HOOK_START_AT=$(date +%s)

# ---------------------------------------------------------------------------
# Local runtime resolution — see post-task.sh DEC-BRIDGE-002 for rationale.
# ---------------------------------------------------------------------------
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"
_local_cc_policy() {
    if [[ -z "${CLAUDE_POLICY_DB:-}" ]]; then
        _resolve_policy_db >/dev/null
    fi
    cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" "$@"
}

# track_subagent_stop removed (TKT-008): .subagent-tracker no longer written.

# Deactivate runtime marker via lifecycle authority (DEC-LIFECYCLE-003).
# cc-policy lifecycle on-stop is the single authority for role-matched
# marker deactivation. It queries the active marker, matches its role to
# AGENT_TYPE, and deactivates — all in Python. No bash-side query needed.
# Pass project_root so the lifecycle authority only touches markers for this
# project; otherwise the globally newest active marker can be deactivated.
if [[ -n "$AGENT_TYPE" ]]; then
    _local_cc_policy lifecycle on-stop "$AGENT_TYPE" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true
fi

# Release the seat and abandon every active supervision_thread touching it.
# DEC-SUPERVISION-THREADS-DOMAIN-001 continuation. Best-effort — seat-release
# failures must never block the hook. release_session_seat() is idempotent
# (repeat calls return released=false, abandoned_count=0) so retries on
# unexpected interrupts are safe.
SESSION_ID=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.session_id // empty' 2>/dev/null || echo "")
if [[ -n "$SESSION_ID" && -n "$AGENT_TYPE" ]]; then
    _local_cc_policy dispatch seat-release \
        --session-id "$SESSION_ID" \
        --agent-type "$AGENT_TYPE" >/dev/null 2>&1 || true
fi

ISSUES=()

# Check 1: Current branch is NOT main/master (worktree was used)
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    ISSUES+=("Implementation on $CURRENT_BRANCH branch — worktree should have been used")
fi

# Check 2: Scan session-changes for 50+ line source files missing @decision
get_session_changes "$PROJECT_ROOT"
CHANGES="${SESSION_FILE:-}"

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
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .assistant_response // .response // .result // .output // empty' 2>/dev/null || echo "")
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue)|ready to (test|review|commit)\?' || echo "")
    HAS_EXECUTION=$(echo "$RESPONSE_TEXT" | grep -iE 'tests pass|implementation complete|done|finished|all tests|ready for review' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_EXECUTION" ]]; then
        ISSUES+=("Agent ended with approval question but no completion confirmation — may need follow-up")
    fi
fi

# Check 4: Test status verification (WS3: reads SQLite test_state, not flat file)
_CI_TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _CI_TS_JSON=""
_CI_TS_FOUND=$(printf '%s' "${_CI_TS_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$_CI_TS_FOUND" == "yes" ]]; then
    _CI_TS_STATUS=$(printf '%s' "$_CI_TS_JSON" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
    _CI_TS_FAILS=$(printf '%s' "$_CI_TS_JSON" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
    _CI_TS_UPDATED=$(printf '%s' "$_CI_TS_JSON" | jq -r '.updated_at // 0' 2>/dev/null || echo "0")
    _CI_NOW=$(date +%s)
    _CI_AGE=$(( _CI_NOW - _CI_TS_UPDATED ))
    if [[ "$_CI_TS_STATUS" == "fail" && "$_CI_AGE" -lt 1800 ]]; then
        ISSUES+=("Tests failing ($_CI_TS_FAILS failures, ${_CI_AGE}s ago) — implementation not complete")
    fi
else
    # No test results at all — warn (project may not have tests, so advisory)
    ISSUES+=("No test results found — verify tests were run before declaring done")
fi

# W-CONV-3: resolve workflow_id via lease-first before Check 5 and Check 6.
# Mirrors check-guardian.sh lines 69-80 pattern. _CI_WF_ID is used by both
# the evaluation state check (Check 5) and the scope compliance check (Check 6).
_CI_LEASE_CTX_EARLY=$(lease_context "$PROJECT_ROOT")
_CI_LEASE_FOUND_EARLY=$(printf '%s' "$_CI_LEASE_CTX_EARLY" | jq -r '.found' 2>/dev/null || echo "false")
_CI_WF_ID=""
if [[ "$_CI_LEASE_FOUND_EARLY" == "true" ]]; then
    _CI_WF_ID=$(printf '%s' "$_CI_LEASE_CTX_EARLY" | jq -r '.workflow_id // empty' 2>/dev/null || true)
fi
[[ -n "$_CI_WF_ID" ]] || _CI_WF_ID=$(current_workflow_id "$PROJECT_ROOT")

# Check 5: Evaluator-state handoff status (TKT-024)
# Reports evaluation_state language instead of proof-era language.
EVAL_STATUS=$(read_evaluation_status "$PROJECT_ROOT" "$_CI_WF_ID")
case "$EVAL_STATUS" in
    ready_for_guardian)
        VERIFICATION_NOTE="Evaluation state: ready_for_guardian — Guardian may proceed."
        ;;
    needs_changes)
        VERIFICATION_NOTE="Evaluation state: needs_changes — Reviewer found issues. Address them before re-dispatching Reviewer."
        ;;
    blocked_by_plan)
        VERIFICATION_NOTE="Evaluation state: blocked_by_plan — Reviewer flagged a plan gap. Dispatch Planner to resolve."
        ;;
    pending)
        VERIFICATION_NOTE="Evaluation state: pending — dispatch Reviewer to evaluate this implementation."
        ;;
    *)
        VERIFICATION_NOTE="Evaluation state: idle — dispatch Reviewer after implementation evidence is prepared."
        ;;
esac

# Check 6: Workflow scope compliance (advisory — guard.sh enforces the hard deny)
# Get changed files relative to base branch (uses workflow binding if available).
# WS1/W-CONV-3: _CI_WF_ID is already resolved via lease-first above (before Check 5).
# That single resolution serves both Check 5 and Check 6.
#
# @decision DEC-WS1-CI-001
# @title check-implementer.sh Check 6 uses lease-first identity for scope lookup
# @status accepted
# @rationale current_workflow_id() derives from the branch name. When a lease is
#   active with an explicit workflow_id (e.g. "wf-abc123") and the branch is named
#   differently (e.g. "feature/my-branch" → "feature-my-branch"), the scope binding
#   is stored under the lease workflow_id but the check queries the branch-derived id
#   — returning no binding and emitting a false "no workflow binding" warning. Lease-
#   first resolution (mirroring check-guardian.sh:69-80) fixes the mismatch.
#   W-CONV-3: resolution hoisted to before Check 5 so both checks share one call.
_WF_ID="$_CI_WF_ID"
_CHANGED_FILES_JSON="[]"
_BASE_BRANCH="main"

# Try to get base_branch from binding
_BINDING_JSON=$(cc_policy workflow get "$_WF_ID" 2>/dev/null) || _BINDING_JSON=""
if [[ -n "$_BINDING_JSON" ]]; then
    _FOUND=$(printf '%s' "$_BINDING_JSON" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
    if [[ "$_FOUND" == "yes" ]]; then
        _BASE_BRANCH=$(printf '%s' "$_BINDING_JSON" | jq -r '.base_branch // "main"' 2>/dev/null || echo "main")
    fi
fi

# Collect changed files vs base branch
_CHANGED_RAW=$(git -C "$PROJECT_ROOT" diff --name-only "$_BASE_BRANCH"...HEAD 2>/dev/null || echo "")
if [[ -n "$_CHANGED_RAW" ]]; then
    _CHANGED_FILES_JSON=$(printf '%s\n' "$_CHANGED_RAW" | jq -Rs 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]")
fi

# Check compliance (advisory only — exit 0 regardless)
_SCOPE_RESULT=$(rt_workflow_scope_check "$_WF_ID" "$_CHANGED_FILES_JSON") || _SCOPE_RESULT=""
if [[ -n "$_SCOPE_RESULT" ]]; then
    _COMPLIANT=$(printf '%s' "$_SCOPE_RESULT" | jq -r '.compliant // "true"' 2>/dev/null || echo "true")
    if [[ "$_COMPLIANT" == "false" ]]; then
        _VIOLATIONS=$(printf '%s' "$_SCOPE_RESULT" | jq -r '.violations[]? // empty' 2>/dev/null || echo "")
        ISSUES+=("Workflow scope violations detected (advisory — policy engine will enforce on commit):")
        while IFS= read -r viol; do
            [[ -n "$viol" ]] && ISSUES+=("  $viol")
        done <<< "$_VIOLATIONS"
    fi
    _NOTE=$(printf '%s' "$_SCOPE_RESULT" | jq -r '.note // empty' 2>/dev/null || echo "")
    if [[ -n "$_NOTE" ]]; then
        ISSUES+=("Scope note: $_NOTE")
    fi
elif [[ -z "$_BINDING_JSON" || "$_FOUND" != "yes" ]]; then
    ISSUES+=("No workflow binding found for '$_WF_ID' — policy engine will deny commit without binding.")
fi

# Check 7: Mid-task interruption detection (additive, advisory).
#
# Heuristic: if the last ~500 chars of the response contain future-tense action
# narration AND the full response lacks any test-completion evidence, the agent
# was likely interrupted mid-task rather than finishing cleanly.
#
# The correlation key must match the workflow_id that dispatch_engine resolves via
# _resolve_lease_context() (lease-first, branch-derived fallback).  Using only the
# branch-derived _WF_ID here caused a mismatch when an active lease carries a
# different workflow_id — dispatch_engine would query for "agent_type|lease-wf-id|"
# but the event was written with "agent_type|branch-wf-id|", so _detect_interrupted
# never returned True in production.  Fix: mirror the same resolution order here.
#
# @decision DEC-STOP-ASSESS-001
# Title: Heuristic mid-task detection via future-tense trailing signal
# Status: accepted
# Rationale: Claude Code's Agent tool always returns status=completed regardless
#   of whether the subagent finished its task. The only signal available at hook
#   time is the response text. Future-tense narration in the tail ("Let me", "I'll",
#   "I need to") without any test-completion evidence is the narrowest reliable
#   proxy for an interrupted stop. Cross-checking against test evidence avoids
#   false positives from agents that plan a next step before confirming tests pass.
#
# @decision DEC-STOP-ASSESS-004
# Title: _ASSESS_WF_ID uses lease-first resolution to match dispatch_engine
# Status: accepted
# Rationale: dispatch_engine._resolve_lease_context() returns the lease workflow_id
#   when an active lease exists, and falls back to branch-derived only when no lease
#   is found. check-implementer.sh must emit the stop_assessment event with the same
#   key so _detect_interrupted() matches. lease_context() (context-lib.sh:449) is the
#   canonical bash-side authority for this resolution — it calls rt_lease_current and
#   returns JSON with .found and .workflow_id. Branch-derived _WF_ID remains the
#   fallback when no lease is active, preserving backward compatibility.
# Resolve assessment workflow_id: lease first (WS1 invariant), branch-derived fallback.
# Must match dispatch_engine._resolve_stop_assessment_wf_id() resolution order.
_ASSESS_WF_ID=""
_ASSESS_LEASE_CTX=$(lease_context "$PROJECT_ROOT")
_ASSESS_LEASE_FOUND=$(printf '%s' "$_ASSESS_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
if [[ "$_ASSESS_LEASE_FOUND" == "true" ]]; then
    _ASSESS_WF_ID=$(printf '%s' "$_ASSESS_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
fi
[[ -z "$_ASSESS_WF_ID" ]] && _ASSESS_WF_ID=$(current_workflow_id "$PROJECT_ROOT")
_INTERRUPTED=false
_INTERRUPT_REASON=""
if [[ -n "$RESPONSE_TEXT" ]]; then
    # Extract last ~500 chars for the trailing-signal check.
    _TAIL=$(printf '%s' "$RESPONSE_TEXT" | tail -c 500 2>/dev/null || echo "")

    # Future-tense trailing patterns indicating planned-but-not-started actions.
    _FUTURE=$(printf '%s' "$_TAIL" \
        | grep -iE "Let me|I'll|I need to|Next I|Now I'll|I'm going to|checking if|About to" \
        || echo "")

    if [[ -n "$_FUTURE" ]]; then
        # Cross-check: look for test completion evidence anywhere in the full response.
        _TEST_EVIDENCE=$(printf '%s' "$RESPONSE_TEXT" \
            | grep -iE "PASS:|FAIL:|tests pass|all.*tests|test.*complete|exit code 0" \
            || echo "")
        if [[ -z "$_TEST_EVIDENCE" ]]; then
            _INTERRUPTED=true
            # Capture first matching phrase for the human-readable reason.
            _MATCHED=$(printf '%s' "$_FUTURE" | head -n 1 | sed 's/^[[:space:]]*//')
            _INTERRUPT_REASON="trailing future-tense signal without test evidence: $_MATCHED"
        fi
    fi
fi

if [[ "$_INTERRUPTED" == "true" ]]; then
    ISSUES+=("Agent appears interrupted mid-task — $_INTERRUPT_REASON")
    # Emit structured stop_assessment event for dispatch_engine to consume.
    # Format: <agent_type>|<workflow_id>|appears_interrupted|<human reason>
    rt_event_emit "stop_assessment" \
        "${AGENT_TYPE}|${_ASSESS_WF_ID}|appears_interrupted|${_INTERRUPT_REASON}" || true
fi

# Check 8: Implementer completion contract (DEC-IMPL-CONTRACT-001)
# Parse IMPL_STATUS and IMPL_HEAD_SHA trailers from the response text.
# When present, submit a structured completion record so dispatch_engine
# can prefer the contract over the heuristic for agent_complete vs agent_stopped.
# Missing trailers = backward-compatible heuristic fallback (NOT a hard failure).
# Malformed trailers = invalid contract evidence (NOT silently trusted).
#
# @decision DEC-IMPL-CONTRACT-002
# @title check-implementer.sh Check 8 parses and submits IMPL_STATUS/IMPL_HEAD_SHA
# @status accepted
# @rationale The completion contract (DEC-IMPL-CONTRACT-001) requires a structured
#   record in SQLite so dispatch_engine can read it in process_agent_stop(). This
#   check performs the bash-side parse using the same trailer-matching pattern
#   used by the other SubagentStop adapters (e.g. check-reviewer.sh, check-guardian.sh)
#   and submits via _local_cc_policy completion submit. Lease-first workflow identity
#   (reusing _ASSESS_LEASE_CTX from Check 7) ensures the record is filed under the
#   same workflow_id the dispatch engine resolves. When no active lease is found the
#   record cannot be submitted; the heuristic from Check 7 remains the fallback.
_IMPL_CONTRACT_NOTE=""
_IMPL_STATUS=""
_IMPL_HEAD_SHA=""
if [[ -n "$RESPONSE_TEXT" ]]; then
    _IMPL_STATUS=$(printf '%s' "$RESPONSE_TEXT" | grep -oE 'IMPL_STATUS:[[:space:]]*[^[:space:]]+' | tail -1 | sed 's/IMPL_STATUS:[[:space:]]*//' || echo "")
    _IMPL_HEAD_SHA=$(printf '%s' "$RESPONSE_TEXT" | grep -oE 'IMPL_HEAD_SHA:[[:space:]]*[^[:space:]]+' | tail -1 | sed 's/IMPL_HEAD_SHA:[[:space:]]*//' || echo "")
fi

if [[ -n "$_IMPL_STATUS" ]]; then
    # Build payload JSON
    _IMPL_PAYLOAD=$(jq -n \
        --arg status "$_IMPL_STATUS" \
        --arg sha "${_IMPL_HEAD_SHA:-}" \
        '{IMPL_STATUS: $status, IMPL_HEAD_SHA: $sha}')

    # Resolve lease_id and workflow_id for submission (lease-first, reuse existing)
    _IMPL_LEASE_ID=""
    _IMPL_WF_ID=""
    if [[ "$_ASSESS_LEASE_FOUND" == "true" ]]; then
        _IMPL_LEASE_ID=$(printf '%s' "$_ASSESS_LEASE_CTX" | jq -r '.lease_id // empty' 2>/dev/null || true)
        _IMPL_WF_ID="$_ASSESS_WF_ID"
    fi
    [[ -z "$_IMPL_WF_ID" ]] && _IMPL_WF_ID="$_WF_ID"

    if [[ -n "$_IMPL_LEASE_ID" && -n "$_IMPL_WF_ID" ]]; then
        _SUBMIT_OUT=$(_local_cc_policy completion submit \
            --lease-id "$_IMPL_LEASE_ID" \
            --workflow-id "$_IMPL_WF_ID" \
            --role "implementer" \
            --payload "$_IMPL_PAYLOAD" 2>/dev/null || echo '{"valid":false}')
        _SUBMIT_VALID=$(printf '%s' "$_SUBMIT_OUT" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
        if [[ "$_SUBMIT_VALID" == "true" ]]; then
            _IMPL_CONTRACT_NOTE="Implementer contract: IMPL_STATUS=$_IMPL_STATUS (valid, submitted)"
        else
            ISSUES+=("Implementer contract trailers present but invalid (IMPL_STATUS=$_IMPL_STATUS)")
        fi
    else
        # No lease — trailers present but cannot submit. Advisory only.
        _IMPL_CONTRACT_NOTE="Implementer contract: IMPL_STATUS=$_IMPL_STATUS (no active lease, not submitted)"
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
CONTEXT+="\n$VERIFICATION_NOTE"
if [[ -n "$_IMPL_CONTRACT_NOTE" ]]; then
    CONTEXT+="\n$_IMPL_CONTRACT_NOTE"
fi

# Emit findings to runtime event store (TKT-008: .agent-findings flat file removed).
# Events are queryable via cc-policy and surface through the runtime event log.
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for issue in "${ISSUES[@]}"; do
        rt_event_emit "agent_finding" "implementer|$issue" || true
        append_audit "$PROJECT_ROOT" "agent_implementer" "$issue"
    done
fi

# Observatory: emit agent duration metric (W-OBS-2).
# _HOOK_START_AT is set near the top of this hook after PROJECT_ROOT is resolved.
# _IMPL_STATUS is parsed from the IMPL_STATUS trailer (empty string when absent).
_obs_duration=$(( $(date +%s) - _HOOK_START_AT ))
rt_obs_metric agent_duration_s "$_obs_duration" \
    "{\"verdict\":\"${_IMPL_STATUS:-unknown}\"}" "" "implementer" || true

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0

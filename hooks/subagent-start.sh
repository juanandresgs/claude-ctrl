#!/usr/bin/env bash
set -euo pipefail

# Subagent context injection at spawn time.
# SubagentStart hook — matcher: (all agent types)
#
# Injects current project state into every subagent so Planner,
# Implementer, and Guardian agents always have fresh context:
#   - Current git branch and dirty state
#   - MASTER_PLAN.md existence and active phase
#   - Active worktrees
#   - Agent-type-specific guidance
#   - Tracks subagent spawn in .subagent-tracker for status bar
#   - Guardian: injects session event log summary for richer commit messages
#     (DEC-V2-005: structured session context in non-trivial commits)

source "$(dirname "$0")/source-lib.sh"

require_git
require_plan
require_session
require_trace

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(get_field '.agent_type')

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
CONTEXT_PARTS=()

# --- Git + Plan state (one line) ---
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"

# Track subagent spawn and refresh statusline cache
track_subagent_start "$PROJECT_ROOT" "${AGENT_TYPE:-unknown}"
write_statusline_cache "$PROJECT_ROOT"
append_session_event "agent_start" \
  "{\"type\":\"${AGENT_TYPE:-unknown}\"}" "$PROJECT_ROOT"

# --- Trace protocol: initialize trace directory ---
TRACE_ID=""
TRACE_DIR=""
case "$AGENT_TYPE" in
    Bash|Explore)
        # Lightweight agents — no trace
        ;;
    *)
        TRACE_ID=$(init_trace "$PROJECT_ROOT" "${AGENT_TYPE:-unknown}" 2>/dev/null || echo "")
        if [[ -n "$TRACE_ID" ]]; then
            TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
        fi
        ;;
esac

CTX_LINE="Context:"
[[ -n "$GIT_BRANCH" ]] && CTX_LINE="$CTX_LINE $GIT_BRANCH"
[[ "$GIT_DIRTY_COUNT" -gt 0 ]] && CTX_LINE="$CTX_LINE | $GIT_DIRTY_COUNT dirty"
[[ "$GIT_WT_COUNT" -gt 0 ]] && CTX_LINE="$CTX_LINE | $GIT_WT_COUNT worktrees"
if [[ "$PLAN_EXISTS" == "true" ]]; then
    [[ -n "$PLAN_PHASE" ]] && CTX_LINE="$CTX_LINE | Plan: $PLAN_PHASE" || CTX_LINE="$CTX_LINE | Plan: exists"
else
    CTX_LINE="$CTX_LINE | Plan: not found"
fi
CONTEXT_PARTS+=("$CTX_LINE")

# --- Inject project architecture from MASTER_PLAN.md ---
# Living-document format: extract ## Architecture section (top-level).
# Legacy format: extract ### Architecture subsection within preamble.
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    HAS_INITIATIVES=$(grep -cE '^\#\#\#\s+Initiative:' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$HAS_INITIATIVES" -gt 0 ]]; then
        # Living-document format: ## Architecture is a top-level section
        ARCH_SECTION=$(awk '/^## Architecture/{f=1; next} f && /^## /{exit} f{print}' \
            "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -15)
        # Also extract active initiative name for context line enrichment
        ACTIVE_INIT=$(awk '
            /^## Active Initiatives/{in_active=1; next}
            in_active && /^## /{in_active=0; next}
            in_active && /^\#\#\# Initiative:/ { name=substr($0, index($0,":")+2) }
            in_active && /^\*\*Status:\*\* active/ { print name; exit }
        ' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -1 || echo "")
        if [[ -n "$ACTIVE_INIT" ]]; then
            CTX_LINE="$CTX_LINE | Initiative: $ACTIVE_INIT"
        fi
    else
        # Legacy format: ### Architecture is nested within a preamble section
        ARCH_SECTION=$(awk '/^### Architecture/{found=1; next} /^###|^## |^---/{if(found) exit} found{print}' \
            "$PROJECT_ROOT/MASTER_PLAN.md" | head -15)
    fi
    if [[ -n "$ARCH_SECTION" ]]; then
        CONTEXT_PARTS+=("Project architecture:")
        CONTEXT_PARTS+=("$ARCH_SECTION")
    fi
fi

# --- Agent-type-specific context ---
case "$AGENT_TYPE" in
    planner|Plan)
        CONTEXT_PARTS+=("Role: Planner — create MASTER_PLAN.md before any code. Include rationale, architecture, git issues, worktree strategy.")
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            CONTEXT_PARTS+=("Research: $RESEARCH_ENTRY_COUNT entries ($RESEARCH_RECENT_TOPICS). Read .claude/research-log.md before researching — avoid duplicates.")
        else
            CONTEXT_PARTS+=("No prior research. /deep-research for tech comparisons and architecture decisions.")
        fi
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (analysis.md, decisions.json). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        # Diagnostic: log context size for planner spawn to aid silent-return diagnosis.
        # Large MASTER_PLAN.md + large planner.md can exhaust context before planning begins.
        # @decision DEC-PLAN-DIAG-001
        # @title Log planner spawn context size for silent-return diagnosis
        # @status accepted
        # @rationale Planner silent returns correlate with large context at spawn time.
        #   Logging plan file size and injected context byte count provides actionable
        #   signal when investigating "Agent returned no response" failures. Logs go to
        #   stderr (hook diagnostic stream) — not visible to the model, not polluting output.
        _plan_size=0
        if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
            _plan_size=$(wc -c < "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo 0)
        fi
        _agent_size=0
        _agent_file="$PROJECT_ROOT/agents/planner.md"
        if [[ -f "$_agent_file" ]]; then
            _agent_size=$(wc -c < "$_agent_file" 2>/dev/null || echo 0)
        fi
        echo "subagent-start[planner]: plan=${_plan_size}B agent=${_agent_size}B trace=${TRACE_DIR:-none}" >&2
        if [[ "$_plan_size" -gt 30000 ]]; then
            echo "subagent-start[planner]: WARNING plan file is large (${_plan_size}B > 30KB) — context exhaustion risk" >&2
        fi
        if [[ "$_agent_size" -gt 20000 ]]; then
            echo "subagent-start[planner]: WARNING agent file is large (${_agent_size}B > 20KB) — consider slimming agents/planner.md" >&2
        fi
        ;;
    implementer)
        # Check if any worktrees exist for this project
        if [[ "$GIT_WT_COUNT" -eq 0 ]]; then
            CONTEXT_PARTS+=("CRITICAL FIRST ACTION: No worktree detected. You MUST create a git worktree BEFORE writing any code. Run: git worktree add ../\<feature-name\> -b \<feature-name\> main — then cd into the worktree and work there. Do NOT write source code on main.")
        fi
        CONTEXT_PARTS+=("Role: Implementer — test-first development in isolated worktrees. Add @decision annotations to ${DECISION_LINE_THRESHOLD}+ line files. NEVER work on main. The branch-guard hook will DENY any source file writes on main.")
        # Inject test status
        TEST_STATUS_FILE="${CLAUDE_DIR}/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            if [[ "$TS_RESULT" == "fail" ]]; then
                CONTEXT_PARTS+=("WARNING: Tests currently FAILING ($TS_FAILS failures). Fix before proceeding.")
            fi
        fi
        get_research_status "$PROJECT_ROOT"
        if [[ "$RESEARCH_EXISTS" == "true" ]]; then
            CONTEXT_PARTS+=("Research log: $RESEARCH_ENTRY_COUNT entries. Check .claude/research-log.md before researching APIs or libraries.")
        fi
        # Surface CYCLE_MODE from dispatch prompt if present
        _IMPL_PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")
        if echo "$_IMPL_PROMPT" | grep -q 'CYCLE_MODE: auto-flow'; then
            CONTEXT_PARTS+=("CYCLE_MODE: auto-flow — After tests pass, proceed to Phase 3.5: dispatch tester sub-agent, then guardian if AUTOVERIFY: CLEAN. Return 'CYCLE COMPLETE' to orchestrator. See agents/implementer.md Phase 3.5.")
        elif echo "$_IMPL_PROMPT" | grep -q 'CYCLE_MODE: phase-boundary'; then
            CONTEXT_PARTS+=("CYCLE_MODE: phase-boundary — After tests pass, return to orchestrator. The tester agent handles live verification — you do NOT demo or write .proof-status.")
        else
            CONTEXT_PARTS+=("After tests pass, return to orchestrator. The tester agent handles live verification — you do NOT demo or write .proof-status.")
        fi
        # Inject current proof status with contextual guidance (W7-2: #42 residual, #134)
        # Use resolve_proof_file() for worktree-aware resolution (replaces inline project_hash).
        _PROOF_FILE=$(resolve_proof_file)
        [[ ! -f "$_PROOF_FILE" ]] && _PROOF_FILE=""
        if [[ -n "$_PROOF_FILE" && -f "$_PROOF_FILE" ]]; then
            if validate_state_file "$_PROOF_FILE" 2; then
                _PROOF_VAL=$(cut -d'|' -f1 "$_PROOF_FILE" 2>/dev/null || echo "")
            else
                _PROOF_VAL=""
            fi
            case "$_PROOF_VAL" in
                verified)
                    CONTEXT_PARTS+=("Proof: verified — user confirmed feature works.") ;;
                pending)
                    CONTEXT_PARTS+=("WARNING: Proof PENDING — source changed after last verification. Tester must re-verify before Guardian can commit.") ;;
                needs-verification)
                    CONTEXT_PARTS+=("WARNING: Proof PENDING — source changed after last verification. Tester must re-verify before Guardian can commit.") ;;
                *)
                    CONTEXT_PARTS+=("Proof: not started — Phase 4 verification is REQUIRED before commit.") ;;
            esac
        else
            CONTEXT_PARTS+=("Proof: not started — Phase 4 verification is REQUIRED before commit.")
        fi
        # Reset checkpoint counter for fresh session
        rm -f "${CLAUDE_DIR}/.checkpoint-counter"
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (test-output.txt, diff.patch, files-changed.txt, proof-evidence.txt). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
    tester)
        CONTEXT_PARTS+=("Role: Tester — run the feature end-to-end, show the user actual output, provide a Verification Assessment (methodology, coverage, confidence, gaps), write .proof-status = pending, then present the report and let the user respond naturally. Include AUTOVERIFY: CLEAN signal if all criteria are met. Do NOT modify source code. Do NOT write tests. Do NOT write 'verified' to .proof-status.")
        # Inject latest implementer trace path
        IMPL_TRACE=$(detect_active_trace "$PROJECT_ROOT" "implementer" 2>/dev/null || echo "")
        if [[ -z "$IMPL_TRACE" ]]; then
            # Try finding most recent completed implementer trace for THIS project only.
            # Critical fix: the original ls -t was unscoped — it returned the most recent
            # implementer trace globally, regardless of project. Now validates manifest.project.
            # @decision DEC-ISOLATION-007
            # @title subagent-start ls -t fallback validates manifest project field
            # @status accepted
            # @rationale Without project validation, tester agents on Project B would receive
            #   the implementer trace context from Project A (the most recently modified trace).
            #   This causes the tester to verify the wrong code. Fix: iterate manifests sorted
            #   by mtime, validate .project == PROJECT_ROOT, use the first match.
            # @decision DEC-ISOLATION-008
            # @title Use find+null-sort for mtime-ordered glob instead of ls -t
            # @status accepted
            # @rationale SC2045: iterating over ls output is fragile (spaces in filenames).
            #   We collect implementer manifest.json paths via glob (safe, no word-split),
            #   then sort by mtime using stat to produce the same ordering as ls -t.
            #   Glob produces an unsorted list; stat-based sort restores recency order.
            _impl_manifests=()
            for _g in "${TRACE_STORE}"/implementer-*/manifest.json; do
                [[ -f "$_g" ]] && _impl_manifests+=("$_g")
            done
            if [[ ${#_impl_manifests[@]} -gt 0 ]]; then
                # Sort by mtime descending using stat (cross-platform: Linux -c %Y first,
                # macOS -f %m as fallback). See DEC-STAT-COMPAT-001 in trace-lib.sh.
                while IFS= read -r _mf; do
                    [[ -f "$_mf" ]] || continue
                    _proj=$(jq -r '.project // empty' "$_mf" 2>/dev/null)
                    if [[ "$_proj" == "$PROJECT_ROOT" ]]; then
                        IMPL_TRACE=$(basename "$(dirname "$_mf")")
                        break
                    fi
                done < <(for _m in "${_impl_manifests[@]}"; do
                    _mt=$(stat -c "%Y" "$_m" 2>/dev/null || stat -f "%m" "$_m" 2>/dev/null || echo 0)
                    printf '%s\t%s\n' "$_mt" "$_m"
                done | sort -rn | cut -f2- | head -10)
            fi
        fi
        if [[ -n "$IMPL_TRACE" ]]; then
            CONTEXT_PARTS+=("Implementer trace: ${TRACE_STORE}/${IMPL_TRACE} — read summary.md and artifacts/ to understand what was built.")
        fi
        # Surface environment requirements from implementer trace
        if [[ -n "$IMPL_TRACE" ]]; then
            env_req_file="${TRACE_STORE}/${IMPL_TRACE}/artifacts/env-requirements.txt"
            if [[ -f "$env_req_file" ]]; then
                env_vars=$(grep -v '^#' "$env_req_file" | grep -v '^$' | cut -d'#' -f1 | tr -d ' ' | paste -sd ', ' -)
                if [[ -n "$env_vars" ]]; then
                    CONTEXT_PARTS+=("ENV REQUIREMENTS: This feature requires: ${env_vars}. Verify they are set before running.")
                fi
            fi
        fi
        # Inject worktree/branch context
        if [[ -n "$GIT_BRANCH" ]]; then
            CONTEXT_PARTS+=("Working on branch: $GIT_BRANCH — verify the feature on this branch, not main.")
        fi
        # Project type detection hints
        if [[ -f "$PROJECT_ROOT/package.json" ]]; then
            CONTEXT_PARTS+=("Project type hint: Node.js/web (package.json found). Try: npm run dev / npm start for dev server.")
        elif [[ -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/setup.py" ]]; then
            CONTEXT_PARTS+=("Project type hint: Python project. Look for CLI entrypoints or API servers.")
        elif [[ -f "$PROJECT_ROOT/Cargo.toml" ]]; then
            CONTEXT_PARTS+=("Project type hint: Rust project. Try: cargo run for CLI verification.")
        elif [[ -f "$PROJECT_ROOT/go.mod" ]]; then
            CONTEXT_PARTS+=("Project type hint: Go project. Try: go run . for CLI verification.")
        fi
        # Check for hook/script projects (like ~/.claude itself)
        if is_claude_meta_repo "$PROJECT_ROOT" 2>/dev/null; then
            CONTEXT_PARTS+=("Project type: Claude Code meta-infrastructure (hooks/scripts). Verify by running hooks with test input and checking output.")
        fi
        CONTEXT_PARTS+=("VERIFICATION PROTOCOL: 1. Run the feature live. 2. Paste actual output. 3. Produce Verification Assessment (methodology, coverage, confidence, gaps). 4. Write pending status via write_proof_status() (writes to canonical scoped .proof-status-{phash}). 5. If all auto-verify criteria met, include AUTOVERIFY: CLEAN signal. 6. Present the full report — let user approve naturally (or auto-verify handles it).")
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (verification-output.txt, verification-strategy.txt). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
    guardian)
        CONTEXT_PARTS+=("Role: Guardian — Update MASTER_PLAN.md ONLY at phase boundaries: when a merge completes a phase, update status to completed, populate Decision Log, present diff to user. For non-phase-completing merges, do NOT update the plan — close the relevant GitHub issues instead. Always: verify @decision annotations, check for staged secrets, require explicit approval.")
        # Save HEAD SHA for commit detection in check-guardian.sh (W3-1: commit event emission)
        # check-guardian.sh compares current HEAD against this SHA after Guardian runs
        # to detect whether a commit occurred and emit a `commit` session event.
        _PHASH_GSS=$(project_hash "$PROJECT_ROOT")
        mkdir -p "${CLAUDE_DIR}/state/${_PHASH_GSS}" 2>/dev/null || true
        git -C "$PROJECT_ROOT" rev-parse HEAD > "${CLAUDE_DIR}/state/${_PHASH_GSS}/guardian-start-sha" 2>/dev/null || true
        git -C "$PROJECT_ROOT" rev-parse HEAD > "${CLAUDE_DIR}/.guardian-start-sha" 2>/dev/null || true  # legacy
        # Inject test status
        TEST_STATUS_FILE="${CLAUDE_DIR}/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            if [[ "$TS_RESULT" == "fail" ]]; then
                CONTEXT_PARTS+=("CRITICAL: Tests FAILING ($TS_FAILS failures). Do NOT commit/merge until tests pass.")
            fi
        fi
        # Inject session summary for richer commit messages
        SESSION_SUMMARY=$(get_session_summary_context "$PROJECT_ROOT" 2>/dev/null || echo "")
        if [[ -n "$SESSION_SUMMARY" ]]; then
            CONTEXT_PARTS+=("Session event log summary for commit context: $SESSION_SUMMARY")
        fi
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/ (merge-analysis.md). Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
    Bash)
        # Truly lightweight — no context
        ;;
    Explore)
        CONTEXT_PARTS+=("OUTPUT LIMIT: If your findings exceed ~1000 words, write the full report to tmp/explore-findings.md in the project root, then return a ≤1500 token summary with key findings and 'Full report: tmp/explore-findings.md'. The orchestrator can read the file for details.")
        ;;
    *)
        CONTEXT_PARTS+=("Agent type: ${AGENT_TYPE:-unknown}")
        if [[ -n "$TRACE_DIR" ]]; then
            CONTEXT_PARTS+=("TRACE_DIR=$TRACE_DIR — Write verbose output to TRACE_DIR/artifacts/. Write TRACE_DIR/summary.md before returning. Keep return message under 1500 tokens.")
        fi
        ;;
esac

# --- Output ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0

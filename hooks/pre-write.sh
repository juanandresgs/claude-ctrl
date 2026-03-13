#!/usr/bin/env bash
# Consolidated PreToolUse:Write|Edit hook — replaces 6 individual hooks + defprog gate.
# Runs branch-guard, plan-check, test-gate, mock-gate, defprog-gate, doc-gate, and checkpoint
# in a single process with ONE library source. Ordered fastest-deny-first.
#
# Replaces (in order of execution):
#   1. branch-guard.sh  — hard deny: source writes on main branch
#   2. plan-check.sh    — hard deny: writes without MASTER_PLAN.md
#   3. test-gate.sh     — escalating strikes: writes while tests fail
#   4. mock-gate.sh     — escalating strikes: test files with internal mocks
#   4.5 defprog-gate    — escalating strikes: silent exception swallowing
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
#   Framework: emit_advisory() buffers; emit_flush() emits the combined JSON.

set -euo pipefail

# Pre-set hook identity before source-lib.sh auto-detection.
_HOOK_NAME="pre-write"
_HOOK_EVENT_TYPE="PreToolUse:Write"

source "$(dirname "$0")/source-lib.sh"

enable_fail_closed "pre-write"

# Lazy-load domain libraries needed by pre-write.sh gates.
# require_plan: get_plan_status, get_drift_data (Gate 2: plan-check)
# require_session: read_test_status, append_session_event, detect_approach_pivots
#   (Gate 3: test-gate, Gate 6: checkpoint session tracking)
# require_state: state_read (Gate 1.5: orchestrator_sid SQLite read, DEC-STATE-KV-001)
require_plan
require_session
require_state

# In scan mode: emit all gate declarations and exit cleanly BEFORE reading stdin.
# Hooks are invoked with < /dev/null in scan mode, so stdin is empty.
# This block MUST be before read_input() to avoid early-exit on empty FILE_PATH.
if [[ "${HOOK_GATE_SCAN:-}" == "1" ]]; then
    declare_gate "proof-status-content" "Direct Write/Edit to protected state files (.proof-status, .test-status, lock files)" "deny"
    declare_gate "branch-guard-write" "Source writes on main branch" "deny"
    declare_gate "orchestrator-source-guard" "Source writes from orchestrator context (must use implementer)" "deny"
    declare_gate "plan-check" "Writes without MASTER_PLAN.md" "deny"
    declare_gate "test-gate-write" "Source writes while tests fail" "deny"
    declare_gate "mock-gate" "Test files with internal mocks" "deny"
    declare_gate "defprog-gate" "Silent error swallowing" "deny"
    declare_gate "doc-gate" "Missing doc headers + @decision annotation" "deny"
    declare_gate "checkpoint" "Git ref checkpoint before write" "side-effect"
    emit_flush
    exit 0
fi

init_hook
FILE_PATH=$(get_field '.tool_input.file_path')
TOOL_NAME=$(get_field '.tool_name')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && { _HOOK_COMPLETED=true; exit 0; }

# Cache project context once — replaces 5 detect_project_root() + 3 get_claude_dir() calls
cache_project_context

# Cache file content for Write tool — replaces 3 get_field '.tool_input.content' calls
_CACHED_WRITE_CONTENT=""
if [[ "$TOOL_NAME" == "Write" ]]; then
    _CACHED_WRITE_CONTENT=$(get_field '.tool_input.content')
fi

# Worktree detection: skip low-value gates when writing inside a worktree.
# plan-check is advisory-at-best in worktrees (plan lives on main).
# doc-gate @decision enforcement is noisy during rapid iteration.
# @decision DEC-PERF-003
# @title Skip plan-check and lighten doc-gate in worktrees
# @status accepted
# @rationale plan-check fires on every source write and calls get_plan_status() +
#   get_drift_data(), each spawning git subprocesses. In worktrees this is wasted
#   effort — the plan lives on main and worktree writes don't need plan validation.
#   Similarly, doc-gate's @decision enforcement is advisory noise during rapid
#   iteration. Branch-guard, test-gate, and mock-gate still fire (safety-critical).
_IN_WORKTREE=false
if [[ "${_FORCE_WORKTREE_CHECK:-}" != "0" && ( "$FILE_PATH" == *"/.worktrees/"* || "$FILE_PATH" == *"/.claude/worktrees/"* ) ]]; then
    _IN_WORKTREE=true
fi

# ============================================================
# Gate 0: Proof-status write guard (fastest deny — content-based hard deny)
# Closes the Write-tool loophole: agents can use Write/Edit to directly write
# "verified" to .proof-status, bypassing the monotonic lattice in write_proof_status().
# This gate runs before branch-guard to deny as fast as possible.
#
# @decision DEC-PROOF-GUARD-001
# @title Gate 0: Block Write/Edit tool access to .proof-status and .test-status files
# @status accepted
# @rationale An LLM can directly invoke the Write or Edit tool on .proof-status,
#   bypassing the monotonic lattice enforced by write_proof_status() in log.sh.
#   The existing guard in pre-bash.sh (Check 9) only blocks shell commands (echo,
#   tee), not Write/Edit tool calls. Gate 0 closes this loophole by denying any
#   Write or Edit targeting a file whose path matches *proof-status* or *test-status*.
#   All legitimate status transitions go through write_proof_status() called from
#   hooks — agents never need to write these files directly.
# ============================================================
declare_gate "proof-status-content" "Direct Write/Edit to protected state files (.proof-status, .test-status, lock files)" "deny"

if is_protected_state_file "$FILE_PATH"; then
    emit_deny "Direct writes to .proof-status, .test-status, or lock files are not allowed. Status transitions go through write_proof_status() in hooks only. Use the verification flow: run tests, get tester confirmation, user approval triggers prompt-submit.sh."
fi

# ============================================================
# Gate 1: Branch guard (fastest — structural repo check, hard deny)
# Source: branch-guard.sh
# ============================================================
declare_gate "branch-guard-write" "Source writes on main branch" "deny"

# Skip MASTER_PLAN.md only for bootstrap (not yet tracked in git).
# If it is already tracked, fall through to the normal branch guard —
# amendments travel in a worktree and merge to main with the implementation.
_SKIP_FOR_MASTER_PLAN=false
if [[ "$(basename "$FILE_PATH")" == "MASTER_PLAN.md" ]]; then
    FILE_DIR_TMP=$(dirname "$FILE_PATH")
    REPO_ROOT_TMP=$(git -C "$FILE_DIR_TMP" rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$REPO_ROOT_TMP" ]] && ! git -C "$REPO_ROOT_TMP" ls-files --error-unmatch MASTER_PLAN.md &>/dev/null; then
        _SKIP_FOR_MASTER_PLAN=true  # not tracked yet = bootstrap, bypass branch guard
    fi
fi

if [[ "$_SKIP_FOR_MASTER_PLAN" == "true" ]]; then
    : # Bootstrap: allow write on main (MASTER_PLAN.md not yet tracked)
else
    # For MASTER_PLAN.md that is already tracked, treat it like any source file
    # (falls through to branch-guard checks below). For all other files, apply
    # the is_source_file guard first.
    _DO_BRANCH_CHECK=false
    if [[ "$(basename "$FILE_PATH")" == "MASTER_PLAN.md" ]]; then
        _DO_BRANCH_CHECK=true  # already-tracked MASTER_PLAN.md: enforce branch guard
    elif is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH"; then
        _DO_BRANCH_CHECK=true
    # Governance-critical markdown files are as critical as source code.
    # agents/*.md, docs/*.md, CLAUDE.md, and ARCHITECTURE.md define agent behavior
    # and system governance — changes propagate immediately to all future dispatches.
    # Two features (b4f2b6c, f5f45a1) bypassed governance by modifying these files
    # on main without worktrees. Protecting them like source closes this gap.
    #
    # @decision DEC-RECK-011
    # @title Extend branch guard to governance-critical markdown
    # @status accepted
    # @rationale agents/*.md, docs/*.md, CLAUDE.md define agent behavior and system
    #   governance. Changes propagate immediately to all future agent dispatches.
    #   Two features (b4f2b6c, f5f45a1) bypassed governance by modifying these files
    #   on main without worktrees. Protecting them like source closes this gap.
    #   MASTER_PLAN.md is handled separately above (bootstrap exception).
    #   The check is scoped to main/master — worktree branches are always allowed.
    elif [[ "$FILE_PATH" =~ /agents/[^/]+\.md$ || \
            "$FILE_PATH" =~ /docs/[^/]+\.md$ || \
            "$(basename "$FILE_PATH")" == "CLAUDE.md" || \
            "$(basename "$FILE_PATH")" == "ARCHITECTURE.md" ]]; then
        _DO_BRANCH_CHECK=true
    fi

    if [[ "$_DO_BRANCH_CHECK" == "true" ]]; then
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
                    if [[ "$(basename "$FILE_PATH")" == "MASTER_PLAN.md" ]]; then
                        emit_deny "BLOCKED: MASTER_PLAN.md is already tracked. Amend it in a worktree, not on main. Create a worktree: git worktree add .worktrees/feature-name -b feature/name"
                    elif [[ "$FILE_PATH" =~ /agents/[^/]+\.md$ || \
                            "$FILE_PATH" =~ /docs/[^/]+\.md$ || \
                            "$(basename "$FILE_PATH")" == "CLAUDE.md" || \
                            "$(basename "$FILE_PATH")" == "ARCHITECTURE.md" ]]; then
                        emit_deny "BLOCKED: Cannot write governance-critical markdown (agents/*.md, docs/*.md, CLAUDE.md, ARCHITECTURE.md) on $CURRENT_BRANCH branch. These files define agent behavior and propagate to all future dispatches — changes require the same worktree isolation as source code (DEC-RECK-011).\n\nAction: git worktree add .worktrees/feature-name -b feature/name, then dispatch Implementer."
                    else
                        emit_deny "BLOCKED: Cannot write source code on $CURRENT_BRANCH branch. Sacred Practice #2: Main is sacred.\n\nAction: Invoke the Guardian agent to create an isolated worktree for this work."
                    fi
                fi
            elif [[ -n "$CURRENT_BRANCH" && "$CURRENT_BRANCH" != "HEAD" ]]; then
                # @decision DEC-BRANCH-GUARD-FEATURE-001
                # @title Extend branch-guard to feature branches outside .worktrees/
                # @status accepted
                # @rationale The legacy branch-guard only blocked writes on main/master.
                #   The orchestrator demonstrated it could write source on feature branches
                #   in the main working tree without creating a worktree — bypassing Sacred
                #   Practice #2. This elif denies any source write on a feature branch when
                #   the file path does NOT contain /.worktrees/. The .worktrees/ check ensures
                #   implementers working in proper isolated worktrees are unaffected.
                #   "HEAD" is excluded: unborn branches (no commits yet) report "HEAD" and
                #   should not be blocked during initial project setup.
                if [[ "$FILE_PATH" != *"/.worktrees/"* && "$FILE_PATH" != *"/.claude/worktrees/"* ]]; then
                    GIT_DIR=$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo "")
                    if [[ -z "$GIT_DIR" || ! -f "$GIT_DIR/MERGE_HEAD" ]]; then
                        emit_deny "BLOCKED: Cannot write source on '$CURRENT_BRANCH' outside a worktree. Sacred Practice #2: All implementation work must happen in isolated worktrees.\n\nAction: git worktree add .worktrees/<name> -b feature/<name>, then dispatch Implementer to the worktree."
                    fi
                fi
            fi
        fi
    fi
fi

# ============================================================
# Gate 1.5: Orchestrator source write guard
# Detects and blocks source writes from orchestrator context.
# The orchestrator must dispatch implementer for all source code work.
# Uses CLAUDE_SESSION_ID comparison: session-init.sh writes the
# orchestrator's SID at startup; subagents get different SIDs.
#
# @decision DEC-DISPATCH-003
# @title Gate 1.5: Block source writes from orchestrator context
# @status accepted
# @rationale The dispatch routing table says "Orchestrator May? No — MUST invoke
#   implementer" for implementation work. Previously this was instruction-only with
#   zero mechanical enforcement. Guardian dispatch was enforced (pre-bash.sh blocks
#   git commit/merge unless Guardian marker exists) but implementer dispatch was not.
#   Gate 1.5 closes this gap by comparing CLAUDE_SESSION_ID against .orchestrator-sid
#   written by session-init.sh. If they match, the caller is the orchestrator, not a
#   subagent — deny the source write. Backward compatible: missing .orchestrator-sid
#   or unset CLAUDE_SESSION_ID falls through to allow.
# ============================================================
declare_gate "orchestrator-source-guard" "Source writes from orchestrator context (must use implementer)" "deny"

if [[ "$_IN_WORKTREE" == "true" ]] && is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH"; then
    if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
        _ORCH_SID=""
        # Primary: read orchestrator_sid from SQLite (DEC-STATE-KV-001).
        # Use explicit workflow_id = {phash}_main: session-init.sh always runs in the
        # main checkout (no WORKTREE_PATH), so it writes with wt_id="main". When
        # pre-write.sh runs inside an implementer subagent, WORKTREE_PATH may be set,
        # which would make workflow_id() return {phash}_kv-feature-name instead of
        # {phash}_main. Explicit _main suffix avoids that mismatch.
        _orch_main_wf="$(project_hash "$(detect_project_root 2>/dev/null || echo "$HOME/.claude")")_main"
        _ORCH_SID=$(state_read "orchestrator_sid" "$_orch_main_wf" 2>/dev/null || echo "")
        # Fallback: flat-file read for backward compat during migration (DEC-STATE-UNIFY-004).
        # Retained until SQLite write is confirmed stable across all deployments.
        if [[ -z "$_ORCH_SID" ]]; then
            _ORCH_SID_FILE="${_CACHED_CLAUDE_DIR}/.orchestrator-sid"
            [[ -f "$_ORCH_SID_FILE" ]] && _ORCH_SID=$(cat "$_ORCH_SID_FILE" 2>/dev/null || echo "")
        fi
        if [[ -n "$_ORCH_SID" && "$CLAUDE_SESSION_ID" == "$_ORCH_SID" ]]; then
            emit_deny "BLOCKED: Source writes from orchestrator context. The orchestrator must dispatch an implementer subagent for all source code work (Sacred Practice #2 + Dispatch Rules). Use: Agent tool with subagent_type=implementer, prompt describing the task, working in this worktree."
        fi
    fi
fi

# ============================================================
# Gate 2: Plan check (hard deny for planless source writes)
# Source: plan-check.sh
# Skipped in worktrees: plan lives on main; worktree writes don't need plan validation.
# ============================================================
declare_gate "plan-check" "Writes without MASTER_PLAN.md" "deny"

if [[ "$_IN_WORKTREE" == "false" ]]; then
    # Skip non-source files, test files, config, .claude directory itself
    if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH" && [[ ! "$FILE_PATH" =~ \.claude/ ]]; then
        # Edit tool is inherently scoped — skip plan check
        if [[ "$TOOL_NAME" != "Edit" ]]; then
            # Write tool: skip small files (<20 lines)
            if [[ "$TOOL_NAME" == "Write" ]]; then
                CONTENT_LINES=$(echo "$_CACHED_WRITE_CONTENT" | wc -l | tr -d ' ')
                if [[ "$CONTENT_LINES" -lt 20 ]]; then
                    emit_advisory "Fast-mode bypass: small file write ($CONTENT_LINES lines) skipped plan check. Surface audit will track this."
                    # Continue to next gates — don't exit
                else
                    # Large write — check for plan
                    if [[ -d "$_CACHED_PROJECT_ROOT/.git" ]]; then
                        if [[ ! -f "$_CACHED_PROJECT_ROOT/MASTER_PLAN.md" ]]; then
                            emit_deny "BLOCKED: No MASTER_PLAN.md in $_CACHED_PROJECT_ROOT. Sacred Practice #6: We NEVER run straight into implementing anything.\n\nAction: Invoke the Planner agent to create MASTER_PLAN.md before implementing."
                        fi

                        # Plan lifecycle check
                        get_plan_status "$_CACHED_PROJECT_ROOT"
                        if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
                            emit_deny "BLOCKED: MASTER_PLAN.md is dormant — all initiatives are completed (or plan has no active initiatives).\n\nAction: Add a new initiative to MASTER_PLAN.md before writing code. Invoke the Planner agent with create-or-amend workflow."
                        fi

                        # Plan staleness check (composite: churn % + drift IDs)
                        get_drift_data "$_CACHED_PROJECT_ROOT"

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
                            emit_deny "MASTER_PLAN.md is critically stale. ${DIAGNOSTIC}Read MASTER_PLAN.md, scan the codebase for @decision annotations, and update the plan's phase statuses before continuing."
                        elif [[ "$STALENESS" == "warn" ]]; then
                            emit_advisory "Plan staleness warning: ${DIAGNOSTIC}Consider reviewing MASTER_PLAN.md — it may not reflect the current codebase state."
                            # Continue to next gates (warn is advisory)
                        fi
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
declare_gate "test-gate-write" "Source writes while tests fail" "deny"

# Only inspect source files (not test files, not config, not .claude)
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH" && ! is_test_file "$FILE_PATH" && [[ ! "$FILE_PATH" =~ \.claude/ ]]; then
    TEST_STATUS_FILE="${_CACHED_CLAUDE_DIR}/.test-status"
    STRIKES_FILE="${_CACHED_CLAUDE_DIR}/.test-gate-strikes"

    if [[ ! -f "$TEST_STATUS_FILE" ]]; then
        # No test status yet — cold start advisory
        HAS_TESTS=false
        [[ -f "$_CACHED_PROJECT_ROOT/pyproject.toml" ]] && HAS_TESTS=true
        [[ -f "$_CACHED_PROJECT_ROOT/vitest.config.ts" || -f "$_CACHED_PROJECT_ROOT/vitest.config.js" ]] && HAS_TESTS=true
        [[ -f "$_CACHED_PROJECT_ROOT/jest.config.ts" || -f "$_CACHED_PROJECT_ROOT/jest.config.js" ]] && HAS_TESTS=true
        [[ -f "$_CACHED_PROJECT_ROOT/Cargo.toml" ]] && HAS_TESTS=true
        [[ -f "$_CACHED_PROJECT_ROOT/go.mod" ]] && HAS_TESTS=true
        if [[ "$HAS_TESTS" == "true" ]]; then
            COLD_FLAG="${_CACHED_CLAUDE_DIR}/.test-gate-cold-warned"
            if [[ ! -f "$COLD_FLAG" ]]; then
                mkdir -p "${_CACHED_PROJECT_ROOT}/.claude"
                touch "$COLD_FLAG"
                emit_advisory "No test results yet but test framework detected. Tests will run automatically after this write."
            fi
        fi
    else
        read_test_status "$_CACHED_PROJECT_ROOT"

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
            mkdir -p "${_CACHED_PROJECT_ROOT}/.claude"
            NOW=$(date +%s)
            echo "${NEW_STRIKES}|${NOW}" > "$STRIKES_FILE"

            if [[ "$NEW_STRIKES" -ge 2 ]]; then
                DENY_REASON="Tests are still failing ($TEST_FAILS failures, ${TEST_AGE}s ago). You've written source code ${NEW_STRIKES} times without fixing tests."

                EVENTS_FILE="${_CACHED_CLAUDE_DIR}/.session-events.jsonl"
                if [[ -f "$EVENTS_FILE" ]]; then
                    detect_approach_pivots "$_CACHED_PROJECT_ROOT"
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

                emit_deny "$DENY_REASON"
            fi

            # Strike 1: advisory only
            emit_advisory "Tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Consider fixing tests before writing more source code. Next source write without fixing tests will be blocked."
            # Continue to next gates
        fi
    fi
fi

# ============================================================
# Gate 4: Mock gate (escalating strikes — test files with internal mocks)
# Source: mock-gate.sh
# ============================================================
declare_gate "mock-gate" "Test files with internal mocks" "deny"

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

            # External-boundary test libraries (pytest-httpx, responses, nock, msw, wiremock, testcontainers, etc.)
            # do not constitute internal mocks — HAS_INTERNAL_MOCK remains as set above.
            # No override needed: the Python/JS/Go checks above already classify boundary-only mocks as external.

            if [[ "$HAS_INTERNAL_MOCK" == "true" ]]; then
                MOCK_STRIKES_FILE="${_CACHED_CLAUDE_DIR}/.mock-gate-strikes"

                CURRENT_STRIKES=0
                if [[ -f "$MOCK_STRIKES_FILE" ]]; then
                    CURRENT_STRIKES=$(cut -d'|' -f1 "$MOCK_STRIKES_FILE" 2>/dev/null || echo "0")
                fi
                NOW=$(date +%s)
                NEW_STRIKES=$(( CURRENT_STRIKES + 1 ))
                mkdir -p "${_CACHED_PROJECT_ROOT}/.claude"
                echo "${NEW_STRIKES}|${NOW}" > "$MOCK_STRIKES_FILE"

                if [[ "$NEW_STRIKES" -ge 2 ]]; then
                    emit_deny "Sacred Practice #5: Tests must use real implementations, not mocks. This test file uses mocks for internal code (strike $NEW_STRIKES). Refactor to use fixtures, factories, or in-memory implementations for internal code. Mocks are only permitted for external service boundaries (HTTP APIs, databases, third-party services). Add '# @mock-exempt: <reason>' if mocking is truly necessary here."
                fi

                # Strike 1: advisory
                emit_advisory "Sacred Practice #5: This test uses mocks for internal code. Prefer real implementations — use fixtures, factories, or in-memory implementations. Mocks are acceptable only for external boundaries (HTTP, DB, third-party APIs). Next mock-heavy test write will be blocked. Add '# @mock-exempt: <reason>' if mocking is truly necessary."
            fi
        fi
    fi
fi

# ============================================================
# Gate 4.5: Defensive programming gate (escalating strikes)
# Detects silent exception swallowing patterns across languages.
# Python: except:pass, bare except, broad except without handling
# JS/TS: empty catch blocks
# Exemption: @defprog-exempt annotation in file content
# ============================================================
declare_gate "defprog-gate" "Silent error swallowing" "deny"

# Inspect all source files (not .claude/hooks/ or .claude/.worktrees/*/hooks/ — meta-infrastructure uses bash)
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH" && [[ ! "$FILE_PATH" =~ \.claude(/\.worktrees/[^/]+)?/hooks/ ]]; then
    # Extract content to inspect
    _DEFPROG_CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
        _DEFPROG_CONTENT="$_CACHED_WRITE_CONTENT"
    elif [[ "$TOOL_NAME" == "Edit" ]]; then
        _DEFPROG_CONTENT=$(get_field '.tool_input.new_string' 2>/dev/null || echo "")
    fi

    if [[ -n "$_DEFPROG_CONTENT" ]]; then
        # Check for exemption annotation
        if ! echo "$_DEFPROG_CONTENT" | grep -q '@defprog-exempt'; then
            _DEFPROG_VIOLATION=false
            _DEFPROG_EXT="${FILE_PATH##*.}"

            case "$_DEFPROG_EXT" in
                py)
                    # Rule 1: except with pass or ellipsis — one-liner or two-liner.
                    # Uses awk with POSIX [ \t] (macOS awk lacks \s support).
                    _HAS_SILENT_EXCEPT=$(echo "$_DEFPROG_CONTENT" | awk '
                        /^[ \t]*except[^:]*:[ \t]*(pass|\.\.\.)[ \t]*$/ { print "SILENT"; exit }
                        /^[ \t]*except/ { was_except=1; next }
                        was_except { if (/^[ \t]*(pass|\.\.\.)[ \t]*$/) { print "SILENT"; exit }; was_except=0 }
                    ')
                    [[ "$_HAS_SILENT_EXCEPT" == "SILENT" ]] && _DEFPROG_VIOLATION=true
                    # Rule 2: bare except (no exception type specified)
                    if echo "$_DEFPROG_CONTENT" | grep -qE '^\s*except\s*:\s*$'; then
                        _DEFPROG_VIOLATION=true
                    fi
                    # Rule 3: broad except without handling (except Exception: with no
                    # log/raise/return within the next 3 lines). Uses awk for multi-line check.
                    # Uses POSIX [ \t] instead of \s (macOS awk compatibility).
                    if echo "$_DEFPROG_CONTENT" | grep -qE '^\s*except\s+(Exception|BaseException)\s*(as\s+\w+)?\s*:'; then
                        _HAS_UNHANDLED_BROAD=$(echo "$_DEFPROG_CONTENT" | awk '
                            /^[ \t]*except[ \t]+(Exception|BaseException)/ {
                                found=1; count=0; has_handler=0; next
                            }
                            found && count < 3 {
                                count++
                                if (/log|logger|logging|raise|return|warn|print|sys[.]exit/) has_handler=1
                            }
                            found && count >= 3 {
                                if (!has_handler) { print "UNHANDLED"; exit }
                                found=0
                            }
                            END { if (found && !has_handler) print "UNHANDLED" }
                        ')
                        [[ "$_HAS_UNHANDLED_BROAD" == "UNHANDLED" ]] && _DEFPROG_VIOLATION=true
                    fi
                    ;;
                js|jsx|ts|tsx)
                    # Rule 1: empty catch blocks — catch(e) { } or catch { }
                    if echo "$_DEFPROG_CONTENT" | grep -qE 'catch\s*(\([^)]*\))?\s*\{\s*\}'; then
                        _DEFPROG_VIOLATION=true
                    fi
                    ;;
            esac

            if [[ "$_DEFPROG_VIOLATION" == "true" ]]; then
                DEFPROG_STRIKES_FILE="${_CACHED_CLAUDE_DIR}/.defprog-gate-strikes"

                CURRENT_STRIKES=0
                if [[ -f "$DEFPROG_STRIKES_FILE" ]]; then
                    CURRENT_STRIKES=$(cut -d'|' -f1 "$DEFPROG_STRIKES_FILE" 2>/dev/null || echo "0")
                fi
                NOW=$(date +%s)
                NEW_STRIKES=$(( CURRENT_STRIKES + 1 ))
                mkdir -p "${_CACHED_PROJECT_ROOT}/.claude"
                echo "${NEW_STRIKES}|${NOW}" > "$DEFPROG_STRIKES_FILE"

                if [[ "$NEW_STRIKES" -ge 2 ]]; then
                    emit_deny "BLOCKED: This code silently swallows errors (strike $NEW_STRIKES). Exception handlers must log, re-raise, or return a sentinel value. Silent error swallowing causes cascading failures that are extremely difficult to debug.\n\nRemediation:\n- Python: Replace 'except: pass' with 'except SpecificError as e: logger.error(e)' or 'raise'\n- JS/TS: Replace empty 'catch {}' with 'catch (e) { console.error(e); }' or re-throw\n\nAdd '@defprog-exempt: <reason>' if silent swallowing is intentional here."
                fi

                # Strike 1: advisory
                emit_advisory "This code silently swallows errors. Exception handlers must log, re-raise, or return a sentinel. Next violation will be blocked. Add '@defprog-exempt: <reason>' if this is intentional."
            fi
        fi
    fi
fi

# ============================================================
# Gate 5: Doc gate (documentation header + @decision enforcement)
# Source: doc-gate.sh
# ============================================================
declare_gate "doc-gate" "Missing doc headers + @decision annotation" "deny"

# --- Check: New markdown files in project root ---
if [[ "$TOOL_NAME" == "Write" && "$FILE_PATH" =~ \.md$ ]]; then
    _MD_FILE_DIR=$(dirname "$FILE_PATH")
    if [[ "$_MD_FILE_DIR" == "$_CACHED_PROJECT_ROOT" ]]; then
        _MD_FILE_NAME=$(basename "$FILE_PATH")
        case "$_MD_FILE_NAME" in
            CLAUDE.md|README.md|MASTER_PLAN.md|AGENTS.md|CHANGELOG.md|LICENSE.md|CONTRIBUTING.md)
                ;; # Operational docs — allowed
            *)
                if [[ ! -f "$FILE_PATH" ]]; then
                    emit_advisory "Creating new markdown file '$_MD_FILE_NAME' in project root. Sacred Practice #9: Track deferred work in GitHub issues, not standalone files. Consider: gh issue create --title '...' instead."
                fi
                ;;
        esac
    fi
fi

# Only inspect source files (skip meta hooks dir — main and worktrees)
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH" && [[ ! "$FILE_PATH" =~ \.claude(/\.worktrees/[^/]+)?/hooks/ ]]; then
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
        _DOC_CONTENT="$_CACHED_WRITE_CONTENT"
        if [[ -n "$_DOC_CONTENT" ]]; then
            if ! _has_doc_header "$_DOC_CONTENT" "$_DOC_EXT"; then
                TEMPLATE=$(_get_header_template "$FILE_PATH")
                emit_deny "File $FILE_PATH missing documentation header. Every source file must start with a documentation comment describing purpose and rationale." "Add a documentation header at the top of the file:\n$TEMPLATE"
            fi

            LINE_COUNT=$(echo "$_DOC_CONTENT" | wc -l | tr -d ' ')
            if [[ "$LINE_COUNT" -ge "$DECISION_LINE_THRESHOLD" ]]; then
                if ! _has_decision "$_DOC_CONTENT"; then
                    emit_deny "File $FILE_PATH is $LINE_COUNT lines but has no @decision annotation. Significant files (${DECISION_LINE_THRESHOLD}+ lines) require a @decision annotation." "Add a @decision annotation to the file. See CLAUDE.md for format examples."
                fi
            fi
        fi
    elif [[ "$TOOL_NAME" == "Edit" ]]; then
        if [[ -f "$FILE_PATH" ]]; then
            FILE_CONTENT_ON_DISK=$(cat "$FILE_PATH" 2>/dev/null || echo "")
            if [[ -n "$FILE_CONTENT_ON_DISK" ]]; then
                if _has_doc_header "$FILE_CONTENT_ON_DISK" "$_DOC_EXT"; then
                    # Skip @decision advisory in worktrees — advisory noise during rapid iteration.
                    if [[ "$_IN_WORKTREE" == "false" ]]; then
                        LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')
                        if [[ "$LINE_COUNT" -ge "$DECISION_LINE_THRESHOLD" ]]; then
                            if ! _has_decision "$FILE_CONTENT_ON_DISK"; then
                                emit_advisory "Note: $FILE_PATH is $LINE_COUNT lines but has no @decision annotation. Consider adding one."
                            fi
                        fi
                    fi
                else
                    emit_advisory "File $FILE_PATH lacks doc header. See CLAUDE.md for template."
                fi
            fi
        fi
    fi
fi

# ============================================================
# Gate 6: Checkpoint (git ref-based snapshots — side-effect, no deny)
# Source: checkpoint.sh
# ============================================================
declare_gate "checkpoint" "Git ref checkpoint before write" "side-effect"

# Only checkpoint git repos on feature branches (not main/master)
if git -C "$_CACHED_PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git -C "$_CACHED_PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
    if [[ "$BRANCH" != "main" && "$BRANCH" != "master" && -n "$BRANCH" ]]; then
        # Skip meta-repo checkpoints
        if ! is_claude_meta_repo "$_CACHED_PROJECT_ROOT" 2>/dev/null; then
            mkdir -p "$_CACHED_CLAUDE_DIR"

            COUNTER_FILE="${_CACHED_CLAUDE_DIR}/.checkpoint-counter"
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
            CHANGES_FILE="${_CACHED_CLAUDE_DIR}/.session-changes-${SESSION_ID}"
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
                GIT_DIR=$(git -C "$_CACHED_PROJECT_ROOT" rev-parse --git-dir 2>/dev/null) || true
                if [[ -n "$GIT_DIR" ]]; then
                    if [[ ! "${GIT_DIR}" = /* ]]; then
                        GIT_DIR="${_CACHED_PROJECT_ROOT}/${GIT_DIR}"
                    fi

                    TMPIDX=$(mktemp "${TMPDIR:-/tmp}/checkpoint-idx.XXXXXX")
                    # shellcheck disable=SC2064
                    trap "rm -f '$TMPIDX'" EXIT

                    if [[ -f "${GIT_DIR}/index" ]]; then
                        cp "${GIT_DIR}/index" "$TMPIDX" 2>/dev/null || true
                    fi

                    GIT_INDEX_FILE="$TMPIDX" git -C "$_CACHED_PROJECT_ROOT" add -A 2>/dev/null || true
                    TREE=$(GIT_INDEX_FILE="$TMPIDX" git -C "$_CACHED_PROJECT_ROOT" write-tree 2>/dev/null) || {
                        rm -f "$TMPIDX"
                        trap - EXIT
                        true
                    }

                    if [[ -n "${TREE:-}" ]]; then
                        rm -f "$TMPIDX"
                        trap - EXIT

                        PARENT=$(git -C "$_CACHED_PROJECT_ROOT" rev-parse HEAD 2>/dev/null) || true
                        if [[ -n "${PARENT:-}" ]]; then
                            BASENAME="${FILE_PATH##*/}"
                            MSG="checkpoint:$(date +%s):before:${BASENAME}"
                            SHA=$(git -C "$_CACHED_PROJECT_ROOT" commit-tree "$TREE" -p "$PARENT" -m "$MSG" 2>/dev/null) || true

                            if [[ -n "${SHA:-}" ]]; then
                                EXISTING=$(git -C "$_CACHED_PROJECT_ROOT" for-each-ref "refs/checkpoints/${BRANCH}/" --format='%(refname)' 2>/dev/null | wc -l | tr -d ' ')
                                CP_NUM=$((EXISTING + 1))
                                REF="refs/checkpoints/${BRANCH}/${CP_NUM}"
                                git -C "$_CACHED_PROJECT_ROOT" update-ref "$REF" "$SHA" 2>/dev/null || true

                                DETAIL=$(jq -cn --arg ref "$REF" --arg file "$BASENAME" --arg n "$N" \
                                    '{ref:$ref,file:$file,trigger:("n="+$n)}' 2>/dev/null) || DETAIL="{}"
                                append_session_event "checkpoint" "$DETAIL" "$_CACHED_PROJECT_ROOT" || true
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

# Emit combined advisory JSON if any gates produced advisory messages.
# Framework: emit_flush() emits a single combined JSON or nothing if no advisories.
emit_flush

exit 0

#!/usr/bin/env bash
# diagnose.sh — Hook and state health check for ~/.claude infrastructure.
# Run via /diagnose skill to validate system integrity.
#
# Sources context-lib.sh for shared utilities (project root, state file
# readers, constants) to avoid reimplementing logic that hooks already provide.
# Sources log.sh for detect_project_root and get_claude_dir helpers.
#
# Usage: bash ~/.claude/skills/diagnose/scripts/diagnose.sh [--quick]
#
# Options:
#   --quick   Run only fast, read-only preflight checks (<250ms):
#             library syntax, state file format, hook registration.
#             Excludes: MASTER_PLAN.md analysis, git health, settings
#             consistency (duplicate detection). Skips decorative headers.
#             Suitable for session startup injection via session-init.sh.
#
# Output: [PASS], [WARN], [FAIL] prefixed lines. Summary counts at end.
# Exit 0 if no FAILs; exit 1 if any FAILs detected.
#
# @decision DEC-DIAG-001
# @title Hook and state health check script
# @status accepted
# @rationale Provides a single command to validate the entire hook/state system,
# catching misconfigurations before they cause silent failures. Sources shared
# libraries rather than reimplementing their logic. Uses set -uo pipefail
# (not set -e) so individual check failures don't abort the whole diagnostic.
# The --quick flag enables <250ms preflight mode for session-init.sh integration,
# running only syntax checks, state file format validation, and hook registration
# verification — no git operations or jq iteration.

set -uo pipefail

# Parse --quick flag before any other work
QUICK_MODE=false
if [[ "${1:-}" == "--quick" ]]; then
    QUICK_MODE=true
fi

CLAUDE_HOME="${HOME}/.claude"
HOOKS_DIR="${CLAUDE_HOME}/hooks"

# Source shared libraries from hooks directory
if [[ ! -f "${HOOKS_DIR}/log.sh" ]]; then
    echo "[FAIL] Cannot source log.sh — not found at ${HOOKS_DIR}/log.sh"
    exit 1
fi
if [[ ! -f "${HOOKS_DIR}/context-lib.sh" ]]; then
    echo "[FAIL] Cannot source context-lib.sh — not found at ${HOOKS_DIR}/context-lib.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "${HOOKS_DIR}/log.sh"
# shellcheck source=/dev/null
source "${HOOKS_DIR}/context-lib.sh"

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn() { echo "[WARN] $1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if [[ "$QUICK_MODE" != "true" ]]; then
    echo "=== diagnose.sh — ~/.claude health check ==="
    echo "Running from: ${CLAUDE_HOME}"
    echo ""
fi

# ---------------------------------------------------------------------------
# Check 1: Hook File Integrity (Quick: existence + executable check only)
# Parse settings.json for all hook commands; verify each exists & is executable.
# ---------------------------------------------------------------------------
if [[ "$QUICK_MODE" != "true" ]]; then
    echo "--- 1. Hook File Integrity ---"
fi

SETTINGS_FILE="${CLAUDE_HOME}/settings.json"
if [[ ! -f "$SETTINGS_FILE" ]]; then
    fail "settings.json not found at ${SETTINGS_FILE}"
else
    if ! jq empty < "$SETTINGS_FILE" 2>/dev/null; then
        fail "settings.json is not valid JSON"
    else
        pass "settings.json is valid JSON"

        # Extract hook commands (hooks section) — structure: hooks.Event[].hooks[].command
        hook_commands=()
        while IFS= read -r cmd; do
            hook_commands+=("$cmd")
        done < <(jq -r '
            .hooks // {} |
            to_entries[] |
            .value[] |
            .hooks[]? |
            .command // empty
        ' "$SETTINGS_FILE" 2>/dev/null)

        # Also extract statusLine command if present
        statusline_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null)
        if [[ -n "$statusline_cmd" ]]; then
            hook_commands+=("$statusline_cmd")
        fi

        if [[ ${#hook_commands[@]} -eq 0 ]]; then
            warn "No hook commands found in settings.json (expected hooks section)"
        else
            missing_count=0
            nonexec_count=0
            for cmd in "${hook_commands[@]}"; do
                # Extract the script path (first word of the command, may contain bash/sh prefix)
                script_path=$(echo "$cmd" | grep -oE '[^ ]+\.sh' | head -1)
                if [[ -z "$script_path" ]]; then
                    continue
                fi
                # Expand $HOME or ~ in path
                script_path="${script_path/\$HOME/$HOME}"
                script_path="${script_path/\~/$HOME}"
                if [[ ! -f "$script_path" ]]; then
                    fail "Hook script missing: ${script_path}"
                    missing_count=$((missing_count + 1))
                elif [[ ! -x "$script_path" ]]; then
                    fail "Hook script not executable: ${script_path}"
                    nonexec_count=$((nonexec_count + 1))
                fi
            done
            if [[ "$missing_count" -eq 0 && "$nonexec_count" -eq 0 ]]; then
                pass "All hook scripts exist and are executable (${#hook_commands[@]} checked)"
            fi
        fi
    fi
fi
if [[ "$QUICK_MODE" != "true" ]]; then echo ""; fi

# ---------------------------------------------------------------------------
# Check 2: Shared Library Health (included in --quick mode)
# Verify log.sh and context-lib.sh pass bash -n syntax check.
# ---------------------------------------------------------------------------
if [[ "$QUICK_MODE" != "true" ]]; then
    echo "--- 2. Shared Library Health ---"
fi

for lib in log.sh context-lib.sh; do
    lib_path="${HOOKS_DIR}/${lib}"
    if [[ ! -f "$lib_path" ]]; then
        fail "${lib} not found at ${lib_path}"
    elif ! bash -n "$lib_path" 2>/dev/null; then
        fail "${lib} has syntax errors (bash -n failed)"
    else
        pass "${lib} passes syntax check"
    fi
done
if [[ "$QUICK_MODE" != "true" ]]; then echo ""; fi

# ---------------------------------------------------------------------------
# Check 3: State File Validation (included in --quick mode)
# Check .proof-status and .test-status in quick mode; .plan-drift and
# .agent-findings only in full mode.
# ---------------------------------------------------------------------------
if [[ "$QUICK_MODE" != "true" ]]; then
    echo "--- 3. State File Validation ---"
fi

# Detect project root using shared library function
PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# .plan-drift (full mode only — skip in --quick mode)
if [[ "$QUICK_MODE" != "true" ]]; then
    drift_file="${CLAUDE_DIR}/.plan-drift"
    if [[ ! -f "$drift_file" ]]; then
        warn ".plan-drift not found at ${drift_file} — drift tracking inactive (run a session to populate)"
    else
        # Expected fields: unplanned_count, unimplemented_count, missing_decisions, audit_epoch
        expected_fields=(unplanned_count unimplemented_count missing_decisions audit_epoch)
        missing_fields=()
        for field in "${expected_fields[@]}"; do
            if ! grep -q "^${field}=" "$drift_file" 2>/dev/null; then
                missing_fields+=("$field")
            fi
        done
        if [[ ${#missing_fields[@]} -gt 0 ]]; then
            fail ".plan-drift missing fields: ${missing_fields[*]}"
        else
            pass ".plan-drift has all expected fields"
        fi
    fi
fi

# .proof-status
proof_file="${CLAUDE_DIR}/.proof-status"
if [[ ! -f "$proof_file" ]]; then
    warn ".proof-status not found — no active verification gate (bootstrap state is OK)"
else
    proof_content=$(cat "$proof_file" 2>/dev/null || echo "")
    # Valid formats: "verified|EPOCH", "needs-verification", "pending"
    if echo "$proof_content" | grep -qE '^verified\|[0-9]+$'; then
        pass ".proof-status: verified"
    elif echo "$proof_content" | grep -qE '^needs-verification$'; then
        pass ".proof-status: needs-verification"
    elif echo "$proof_content" | grep -qE '^pending$'; then
        pass ".proof-status: pending"
    else
        fail ".proof-status has unexpected format: '${proof_content}' (expected: verified|EPOCH, needs-verification, or pending)"
    fi
fi

# .test-status — use read_test_status from context-lib.sh
test_status_file="${CLAUDE_DIR}/.test-status"
if [[ ! -f "$test_status_file" ]]; then
    warn ".test-status not found — test results not tracked yet"
else
    if read_test_status "$PROJECT_ROOT" 2>/dev/null; then
        # read_test_status populated TEST_RESULT, TEST_FAILS, TEST_TIME, TEST_AGE
        if [[ -z "$TEST_RESULT" ]]; then
            fail ".test-status is unreadable or malformed"
        else
            pass ".test-status readable: result=${TEST_RESULT}, failures=${TEST_FAILS:-0}"
            # Check staleness
            if [[ -n "$TEST_AGE" && "$TEST_AGE" -gt "$TEST_STALENESS_THRESHOLD" ]]; then
                age_min=$(( TEST_AGE / 60 ))
                warn ".test-status is stale (${age_min}m old, threshold: $((TEST_STALENESS_THRESHOLD / 60))m) — run tests to refresh"
            fi
        fi
    else
        fail ".test-status found but read_test_status returned error"
    fi
fi

# .agent-findings (full mode only — not critical for preflight)
if [[ "$QUICK_MODE" != "true" ]]; then
    findings_file="${CLAUDE_DIR}/.agent-findings"
    if [[ -f "$findings_file" ]]; then
        if [[ ! -s "$findings_file" ]]; then
            warn ".agent-findings exists but is empty — may indicate a failed tester run"
        else
            pass ".agent-findings exists and is non-empty"
        fi
    fi
fi
if [[ "$QUICK_MODE" != "true" ]]; then echo ""; fi

# ---------------------------------------------------------------------------
# Check 4: Settings Consistency (full mode only — jq iteration is slow)
# Validate JSON, check for duplicate hook registrations per event.
# ---------------------------------------------------------------------------
if [[ "$QUICK_MODE" != "true" ]]; then
    echo "--- 4. Settings Consistency ---"

    if [[ -f "$SETTINGS_FILE" ]] && jq empty < "$SETTINGS_FILE" 2>/dev/null; then
        # Check for duplicate hook registrations within each event
        # Extract all (event, command) pairs and look for duplicates
        duplicate_count=0
        while IFS= read -r event; do
            # Get all commands for this event
            cmds=$(jq -r --arg evt "$event" '.hooks[$evt][]? | if type == "object" then .command // empty else empty end' "$SETTINGS_FILE" 2>/dev/null)
            dup_cmds=$(echo "$cmds" | sort | uniq -d)
            if [[ -n "$dup_cmds" ]]; then
                fail "Duplicate hook registration in event '${event}': ${dup_cmds}"
                duplicate_count=$((duplicate_count + 1))
            fi
        done < <(jq -r '.hooks // {} | keys[]' "$SETTINGS_FILE" 2>/dev/null)

        if [[ "$duplicate_count" -eq 0 ]]; then
            pass "No duplicate hook registrations found"
        fi

        # Count total registered hooks
        total_hooks=$(jq '[.hooks // {} | to_entries[] | .value | length] | add // 0' "$SETTINGS_FILE" 2>/dev/null || echo "0")
        pass "Total hook registrations: ${total_hooks}"
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Check 5: MASTER_PLAN.md Status (full mode only — source churn calculation slow)
# Use get_plan_status from context-lib.sh.
# ---------------------------------------------------------------------------
if [[ "$QUICK_MODE" != "true" ]]; then
    echo "--- 5. MASTER_PLAN.md Status ---"

    get_plan_status "$PROJECT_ROOT"

    if [[ "$PLAN_EXISTS" != "true" ]]; then
        warn "No MASTER_PLAN.md found at ${PROJECT_ROOT}/MASTER_PLAN.md — no active plan"
    else
        pass "MASTER_PLAN.md found"
        pass "Phases: ${PLAN_COMPLETED_PHASES}/${PLAN_TOTAL_PHASES} completed (in-progress: ${PLAN_IN_PROGRESS_PHASES:-0})"
        pass "Requirements: ${PLAN_REQ_COUNT} total, ${PLAN_P0_COUNT} P0, ${PLAN_NOGO_COUNT} non-goals"
        pass "Lifecycle: ${PLAN_LIFECYCLE}"

        # Check staleness: source churn >= 10% is a WARN
        if [[ "${PLAN_SOURCE_CHURN_PCT:-0}" -ge 10 ]]; then
            warn "Plan staleness: ${PLAN_SOURCE_CHURN_PCT}% of source files changed since plan update (${PLAN_CHANGED_SOURCE_FILES}/${PLAN_TOTAL_SOURCE_FILES} files) — consider reviewing plan alignment"
        else
            pass "Plan staleness: ${PLAN_SOURCE_CHURN_PCT}% source churn (within threshold)"
        fi

        # Check DEC-ID format in plan
        plan_file="${PROJECT_ROOT}/MASTER_PLAN.md"
        dec_count=$(grep -cE 'DEC-[A-Z0-9]+-[0-9]+' "$plan_file" 2>/dev/null || true)
        if [[ "${dec_count:-0}" -eq 0 ]]; then
            warn "No DEC-IDs found in MASTER_PLAN.md — decisions may be undocumented"
        else
            pass "DEC-IDs present: ${dec_count} references"
        fi
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Check 6: Git Health (full mode only — git commands are slow/network-touching)
# Use get_git_state from context-lib.sh. Report branch, dirty count, worktrees.
# Check for orphaned worktrees. Warn if on main with dirty changes.
# ---------------------------------------------------------------------------
if [[ "$QUICK_MODE" != "true" ]]; then
    echo "--- 6. Git Health ---"

    get_git_state "$PROJECT_ROOT"

    if [[ -z "$GIT_BRANCH" ]]; then
        warn "Not a git repository at ${PROJECT_ROOT}"
    else
        pass "Git branch: ${GIT_BRANCH}"

        if [[ "$GIT_DIRTY_COUNT" -gt 0 ]]; then
            if [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]]; then
                warn "On ${GIT_BRANCH} with ${GIT_DIRTY_COUNT} dirty files — main should stay clean (Sacred Practice #2)"
            else
                pass "Dirty files: ${GIT_DIRTY_COUNT} (on feature branch ${GIT_BRANCH}, this is expected)"
            fi
        else
            pass "Working tree is clean"
        fi

        pass "Worktrees: ${GIT_WT_COUNT} active"

        # Check for orphaned worktrees (listed by git but directory missing)
        if [[ "$GIT_WT_COUNT" -gt 0 ]]; then
            orphan_count=0
            while IFS= read -r wt_line; do
                wt_path=$(echo "$wt_line" | awk '{print $1}')
                if [[ -n "$wt_path" && ! -d "$wt_path" ]]; then
                    fail "Orphaned worktree (directory missing): ${wt_path} — run: git worktree prune"
                    orphan_count=$((orphan_count + 1))
                fi
            done < <(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2 || true)

            if [[ "$orphan_count" -eq 0 ]]; then
                pass "No orphaned worktrees"
            fi
        fi
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$QUICK_MODE" != "true" ]]; then
    echo "=== Summary ==="
fi
echo "PASS: ${PASS_COUNT}  WARN: ${WARN_COUNT}  FAIL: ${FAIL_COUNT}"
if [[ "$QUICK_MODE" != "true" ]]; then echo ""; fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    if [[ "$QUICK_MODE" != "true" ]]; then
        echo "System has ${FAIL_COUNT} critical issue(s). See [FAIL] lines above for remediation."
    fi
    exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    if [[ "$QUICK_MODE" != "true" ]]; then
        echo "System is functional with ${WARN_COUNT} non-critical warning(s). See [WARN] lines above."
    fi
    exit 0
else
    if [[ "$QUICK_MODE" != "true" ]]; then
        echo "System is healthy. All checks passed."
    fi
    exit 0
fi

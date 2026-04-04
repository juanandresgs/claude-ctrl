#!/usr/bin/env bash
# pre-bash.sh — Thin adapter that delegates all Bash pre-execution policy to
# the Python policy engine (cc-policy evaluate). Replaces the former guard.sh
# delegation now that all 13 guard checks live in runtime/core/policies/.
#
# @decision DEC-HOOK-004
# @title Consolidated Bash entrypoint — now a thin cc-policy evaluate adapter
# @status accepted (updated PE-W3-fix)
# @rationale guard.sh's 13 inline checks have been migrated to Python policy
#   modules registered in runtime/core/policies/. This hook now normalises the
#   Claude hook JSON into a policy engine request and forwards the decision.
#   guard.sh and hooks/lib/bash-policy.sh are deleted — this file is the sole
#   authority for Bash pre-execution policy.
#
# Fail-closed contract (DEC-HOOK-004-FC):
#   If cc_policy evaluate fails, times out, or returns empty output this hook
#   emits a deny decision and exits 0 with the deny JSON rather than silently
#   allowing. "Fail open" is not acceptable for an enforcement hook.
#
# Target-aware context (DEC-PE-W3-CTX-001):
#   Commands like ``git -C /other-repo commit`` target a different repo than
#   the session cwd. We extract the git target directory from the command and
#   pass it as ``target_cwd`` in the evaluate payload so the policy engine
#   resolves lease/scope/eval_state/test_state from the command target, not
#   the session repo. Patterns matched (same as policy_utils.extract_git_target_dir):
#     Pattern A: cd /path && git ...
#     Pattern B: git -C /path ...
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hooks/log.sh
source "$HOOKS_DIR/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$HOOKS_DIR/context-lib.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')
[[ -z "$COMMAND" ]] && exit 0

# Resolve actor context for the policy engine.
ACTOR_ROLE=$(current_active_agent_role "$(detect_project_root)" 2>/dev/null || echo "")

# --- Target-aware context: extract git target directory from command ---
# Pattern A: cd /path (unquoted, single-quoted, or double-quoted)
# Pattern B: git -C /path
# Fallback: empty string (engine will use session cwd)
TARGET_CWD=""
if echo "$COMMAND" | grep -qE 'cd\s+("([^"]+)"|'"'"'([^'"'"']+)'"'"'|([^\s&;]+))'; then
    _candidate=$(echo "$COMMAND" | sed -E 's/.*cd[[:space:]]+"([^"]+)".*/\1/;t end
s/.*cd[[:space:]]+'"'"'([^'"'"']+)'"'"'.*/\1/;t end
s/.*cd[[:space:]]+([^[:space:]&;]+).*/\1/;t end
d
:end' 2>/dev/null || echo "")
    if [[ -n "$_candidate" && -d "$_candidate" ]]; then
        TARGET_CWD="$_candidate"
    fi
fi
if [[ -z "$TARGET_CWD" ]] && echo "$COMMAND" | grep -qE 'git\s+-C\s+'; then
    _candidate=$(echo "$COMMAND" | sed -E 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/;t end
s/.*git[[:space:]]+-C[[:space:]]+'"'"'([^'"'"']+)'"'"'.*/\1/;t end
s/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/;t end
d
:end' 2>/dev/null || echo "")
    if [[ -n "$_candidate" && -d "$_candidate" ]]; then
        TARGET_CWD="$_candidate"
    fi
fi

# Build evaluate payload — merge actor_role, target_cwd, and hook fields.
EVAL_INPUT=$(printf '%s' "$HOOK_INPUT" | jq \
    --arg role "$ACTOR_ROLE" \
    --arg target_cwd "$TARGET_CWD" \
    '. + {event_type: "PreToolUse", tool_name: "Bash", actor_role: $role, actor_id: "",
          target_cwd: (if $target_cwd != "" then $target_cwd else null end)}
     | if .target_cwd == null then del(.target_cwd) else . end')

# Call policy engine — single authority for all Bash decisions.
# Fail-closed: if the engine errors or returns empty output, emit a deny
# rather than silently allowing. The `|| true` anti-pattern is intentionally
# absent here.
RESULT=$(printf '%s' "$EVAL_INPUT" | cc_policy evaluate 2>/tmp/pre-bash-eval-err$$) \
    || RESULT=""

# Validate result: must be non-empty and contain an "action" field.
if [[ -z "$RESULT" ]] || ! printf '%s' "$RESULT" | jq -e '.action' >/dev/null 2>&1; then
    # Engine failed or returned invalid output — emit deny (fail-closed).
    _ERR=$(cat /tmp/pre-bash-eval-err$$ 2>/dev/null || echo "cc_policy evaluate returned empty or invalid output")
    rm -f /tmp/pre-bash-eval-err$$
    printf '%s\n' "$(jq -n \
        --arg reason "Policy engine unavailable or returned invalid output. Denying as fail-safe. Detail: $_ERR" \
        '{permissionDecision: "deny", permissionDecisionReason: $reason, blockingHook: "pre-bash-fail-closed"}')"
    exit 0
fi

rm -f /tmp/pre-bash-eval-err$$

# Extract the hookSpecificOutput block if present; fall back to full result.
_HSO=$(printf '%s' "$RESULT" | jq '.hookSpecificOutput // empty' 2>/dev/null || echo "")
if [[ -n "$_HSO" ]]; then
    printf '%s\n' "$_HSO"
else
    printf '%s\n' "$RESULT"
fi

exit 0

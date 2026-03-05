#!/usr/bin/env bash
# tests/test-replay.sh — Single-path JSONL replay runner.
#
# Replays recorded hook interactions from JSONL files and compares each
# event's actual hook decision against the expected_decision in _meta.
# Uses a single CLAUDE_DIR sandbox. No old-hook comparison.
#
# Usage: bash tests/test-replay.sh <JSONL_FILE> [--verbose]
#   JSONL_FILE: path to replay JSONL (each line is a JSON event)
#   --verbose: print detailed output per event
#
# @decision DEC-REPLAY-001
# @title Single-path replay runner for hook behavioral verification
# @status accepted
# @rationale The comparative replay harness from the metanoia archive required
#   two hook configurations (old vs new) to compare decisions. This project
#   uses a single hook config, so the old-hook path is removed. The runner
#   simply feeds each JSONL event to its corresponding hook and checks whether
#   the actual decision matches expected_decision in _meta:
#     "allow"        — no deny decision in output
#     "deny"         — deny decision present in output
#     "allow_or_deny" — either is acceptable (uncertain/context-dependent)
#   Bash events on feature branches inject a temp git repo CWD so branch
#   detection works correctly. Requires: jq, bash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# HOOKS_DIR is set by test-helpers.sh sourcing
REPLAY_FILE=""

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT
VERBOSE=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --help|-h)
            echo "Usage: bash tests/test-replay.sh <JSONL_FILE> [--verbose]"
            exit 0
            ;;
        *)
            if [[ -z "$REPLAY_FILE" ]]; then
                REPLAY_FILE="$1"
            else
                echo "ERROR: unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$REPLAY_FILE" ]]; then
    echo "ERROR: no JSONL file specified" >&2
    echo "Usage: bash tests/test-replay.sh <JSONL_FILE> [--verbose]" >&2
    exit 1
fi

if [[ ! -f "$REPLAY_FILE" ]]; then
    echo "ERROR: file not found: $REPLAY_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Sandbox setup — single CLAUDE_DIR for the run
# ---------------------------------------------------------------------------
SANDBOX_DIR=$(make_temp)
_CLEANUP_DIRS+=("${SANDBOX_DIR}")
export CLAUDE_PROJECT_DIR="$SANDBOX_DIR"
export CLAUDE_SESSION_ID="replay-test-$$"

# Create a minimal git repo on main for Bash events with branch context
SANDBOX_MAIN_REPO=$(make_temp)
_CLEANUP_DIRS+=("${SANDBOX_MAIN_REPO}")
git init "$SANDBOX_MAIN_REPO" >/dev/null 2>&1
(
    cd "$SANDBOX_MAIN_REPO"
    git checkout -b main >/dev/null 2>&1 || true
    git commit -m "init" --allow-empty >/dev/null 2>&1
)

# Create a feature repo for feature-branch events
SANDBOX_FEATURE_REPO=$(make_temp)
_CLEANUP_DIRS+=("${SANDBOX_FEATURE_REPO}")
git init "$SANDBOX_FEATURE_REPO" >/dev/null 2>&1
(
    cd "$SANDBOX_FEATURE_REPO"
    git checkout -b "feature/replay-test" >/dev/null 2>&1 || true
    git commit -m "init" --allow-empty >/dev/null 2>&1
)

# ---------------------------------------------------------------------------
# Hook routing — determine which hook to run based on event type
# ---------------------------------------------------------------------------

# route_event EVENT_JSON → prints hook path
route_event() {
    local event="$1"
    local tool_name
    tool_name=$(echo "$event" | jq -r '.tool_name // empty' 2>/dev/null)

    case "$tool_name" in
        Bash)
            echo "$HOOKS_DIR/pre-bash.sh"
            ;;
        Write|Edit)
            echo "$HOOKS_DIR/pre-write.sh"
            ;;
        Task)
            echo "$HOOKS_DIR/task-track.sh"
            ;;
        "")
            # No tool_name: check for stop_reason (stop hook) or prompt (prompt-submit)
            local stop_reason prompt_val
            stop_reason=$(echo "$event" | jq -r '.stop_reason // empty' 2>/dev/null)
            prompt_val=$(echo "$event" | jq -r '.prompt // empty' 2>/dev/null)
            if [[ -n "$stop_reason" ]]; then
                echo "$HOOKS_DIR/stop.sh"
            elif [[ -n "$prompt_val" ]]; then
                echo "$HOOKS_DIR/prompt-submit.sh"
            else
                echo ""
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# inject_cwd EVENT_JSON BRANCH → add cwd field pointing to a temp git repo
# Returns modified event JSON with cwd injected into tool_input if it's a Bash event.
inject_cwd_for_bash() {
    local event="$1"
    local branch="$2"
    local tool_name
    tool_name=$(echo "$event" | jq -r '.tool_name // empty' 2>/dev/null)
    if [[ "$tool_name" != "Bash" ]]; then
        echo "$event"
        return
    fi

    # Pick repo based on branch
    local repo_path
    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
        repo_path="$SANDBOX_MAIN_REPO"
    else
        repo_path="$SANDBOX_FEATURE_REPO"
    fi

    # Inject cwd into tool_input
    echo "$event" | jq --arg cwd "$repo_path" '.tool_input.cwd = $cwd' 2>/dev/null || echo "$event"
}

# get_actual_decision HOOK_OUTPUT → "deny" or "allow"
get_actual_decision() {
    local output="$1"
    if [[ -z "$output" ]]; then
        echo "allow"
        return
    fi
    local decision
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        echo "deny"
    else
        echo "allow"
    fi
}

# ---------------------------------------------------------------------------
# Replay loop
# ---------------------------------------------------------------------------
echo "=== Replay: $(basename "$REPLAY_FILE") ==="
echo ""

event_num=0
while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue

    event_num=$((event_num + 1))

    # Parse event fields
    tool_name=$(echo "$line" | jq -r '.tool_name // empty' 2>/dev/null)
    description=$(echo "$line" | jq -r '._meta.description // "event '"$event_num"'"' 2>/dev/null)
    branch=$(echo "$line" | jq -r '._meta.branch // "unknown"' 2>/dev/null)
    expected=$(echo "$line" | jq -r '._meta.expected_decision // "allow_or_deny"' 2>/dev/null)

    # Determine hook
    hook=$(route_event "$line")
    if [[ -z "$hook" ]]; then
        skip "event $event_num: $description" "no hook for tool_name='${tool_name:-none}'"
        continue
    fi
    if [[ ! -f "$hook" ]]; then
        skip "event $event_num: $description" "hook not found: $hook"
        continue
    fi

    # Inject CWD for Bash events so branch detection works
    event_with_cwd=$(inject_cwd_for_bash "$line" "$branch")

    # Run the hook
    hook_output=$(echo "$event_with_cwd" | bash "$hook" 2>/dev/null || true)
    actual=$(get_actual_decision "$hook_output")

    label="event $event_num ($tool_name): $description"

    if [[ "$VERBOSE" == "true" ]]; then
        echo "  branch=$branch expected=$expected actual=$actual"
        if [[ -n "$hook_output" ]]; then
            echo "  output: ${hook_output:0:120}"
        fi
    fi

    # Compare
    case "$expected" in
        allow)
            if [[ "$actual" == "allow" ]]; then
                pass "$label"
            else
                fail "$label" "expected allow, got deny"
            fi
            ;;
        deny)
            if [[ "$actual" == "deny" ]]; then
                pass "$label"
            else
                fail "$label" "expected deny, got allow (hook may need real git repo context)"
            fi
            ;;
        allow_or_deny)
            pass "$label (allow_or_deny: got $actual)"
            ;;
        *)
            skip "$label" "unrecognized expected_decision: $expected"
            ;;
    esac

done < "$REPLAY_FILE"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$SANDBOX_DIR" "$SANDBOX_MAIN_REPO" "$SANDBOX_FEATURE_REPO" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
summary

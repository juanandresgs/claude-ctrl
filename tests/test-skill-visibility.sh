#!/usr/bin/env bash
# test-skill-visibility.sh — Tests for skill call visibility + /approve removal
#
# Purpose: Validates three security hardening changes:
#   1. commands/approve.md is deleted (removes agent-accessible attack surface)
#   2. /approve is removed from CLAUDE.md documentation
#   3. skill-result.sh logs skill_invoked events to .session-events.jsonl
#      with skill name, agent type, and args fields
#
# @decision DEC-SKILL-VIS-001
# @title Test suite for skill call visibility and /approve command removal
# @status accepted
# @rationale Security hardening: /approve was an attack surface agents could
#   attempt to invoke via the Skill tool. skill-result.sh logging provides a
#   forensic trail for Skill invocations from subagents. Tests verify both
#   the removal and the new logging behavior, including the no-active-agent
#   default of "orchestrator".
#
# Test isolation: hooks are invoked with CLAUDE_PROJECT_DIR set to a temp dir,
# which overrides detect_project_root() so events land in temp dirs, not the
# real project's .session-events.jsonl.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
COMMANDS_DIR="$PROJECT_ROOT/commands"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $1"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

# ============================================================================
# Test 1: commands/approve.md no longer exists
# ============================================================================

test_approve_command_deleted() {
    run_test "commands/approve.md is deleted"
    local approve_file="$COMMANDS_DIR/approve.md"
    if [[ ! -f "$approve_file" ]]; then
        pass_test
    else
        fail_test "File still exists: $approve_file"
    fi
}

# ============================================================================
# Test 2: /approve not referenced in CLAUDE.md
# ============================================================================

test_approve_not_in_claude_md() {
    run_test "/approve not referenced in CLAUDE.md"
    local claude_md="$PROJECT_ROOT/CLAUDE.md"
    if [[ ! -f "$claude_md" ]]; then
        fail_test "CLAUDE.md not found at $claude_md"
        return
    fi
    if grep -q '/approve' "$claude_md"; then
        fail_test "/approve still appears in CLAUDE.md"
    else
        pass_test
    fi
}

# ============================================================================
# Helpers for hook invocation tests
# Runs skill-result.sh with CLAUDE_PROJECT_DIR pointing to a temp dir so that
# detect_project_root() returns the temp dir and events land there, not in the
# real project root.
# ============================================================================

invoke_hook() {
    local hook_input="$1"
    local tmp_dir="$2"
    local session_id="$3"

    # CLAUDE_PROJECT_DIR overrides detect_project_root() (see log.sh line ~71)
    CLAUDE_PROJECT_DIR="$tmp_dir" \
    CLAUDE_SESSION_ID="$session_id" \
    bash "$HOOKS_DIR/skill-result.sh" <<< "$hook_input" 2>/dev/null || true
}

# ============================================================================
# Test 3: skill-result.sh logs skill_invoked event — happy path
# ============================================================================

test_skill_invoked_event_logged() {
    run_test "skill-result.sh logs skill_invoked event to .session-events.jsonl"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Set up a fake project root with .claude dir and subagent tracker
    mkdir -p "$tmp_dir/.claude"
    local fake_session="test-$$"
    echo "ACTIVE|implementer|$(date +%s)" \
        > "$tmp_dir/.claude/.subagent-tracker-${fake_session}"

    local hook_input
    hook_input=$(jq -n '{
        tool_name: "Skill",
        tool_input: {skill: "deep-research", args: "some query"}
    }')

    invoke_hook "$hook_input" "$tmp_dir" "$fake_session"

    local events_file="$tmp_dir/.claude/.session-events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        fail_test "No .session-events.jsonl written at $events_file"
        return
    fi

    local last_event
    last_event=$(tail -1 "$events_file")

    if echo "$last_event" | jq -e '.event == "skill_invoked"' > /dev/null 2>&1; then
        pass_test
    else
        fail_test "Last event is not skill_invoked: $last_event"
    fi
}

# ============================================================================
# Test 4: Logged event contains skill, agent_type, and args fields with correct values
# ============================================================================

test_skill_invoked_event_fields() {
    run_test "skill_invoked event contains skill, agent_type, and args fields"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    mkdir -p "$tmp_dir/.claude"
    local fake_session="test-fields-$$"
    echo "ACTIVE|tester|$(date +%s)" \
        > "$tmp_dir/.claude/.subagent-tracker-${fake_session}"

    local hook_input
    hook_input=$(jq -n '{
        tool_name: "Skill",
        tool_input: {skill: "observatory", args: "analyze traces"}
    }')

    invoke_hook "$hook_input" "$tmp_dir" "$fake_session"

    local events_file="$tmp_dir/.claude/.session-events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        fail_test "No .session-events.jsonl written"
        return
    fi

    local last_event
    last_event=$(tail -1 "$events_file")

    local skill_val agent_type_val has_args
    skill_val=$(echo "$last_event" | jq -r '.skill // empty' 2>/dev/null)
    agent_type_val=$(echo "$last_event" | jq -r '.agent_type // empty' 2>/dev/null)
    has_args=$(echo "$last_event" | jq -r 'has("args")' 2>/dev/null || echo "false")

    if [[ "$skill_val" == "observatory" && "$agent_type_val" == "tester" && "$has_args" == "true" ]]; then
        pass_test
    else
        fail_test "Field values wrong: skill='$skill_val' agent_type='$agent_type_val' has_args=$has_args — event: $last_event"
    fi
}

# ============================================================================
# Test 5: No active subagent → agent_type defaults to "orchestrator"
# ============================================================================

test_no_active_subagent_defaults_to_orchestrator() {
    run_test "agent_type defaults to orchestrator when no subagent active"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    mkdir -p "$tmp_dir/.claude"
    # No tracker file — simulates orchestrator invoking skill directly
    local fake_session="test-noagent-$$"

    local hook_input
    hook_input=$(jq -n '{
        tool_name: "Skill",
        tool_input: {skill: "diagnose", args: ""}
    }')

    invoke_hook "$hook_input" "$tmp_dir" "$fake_session"

    local events_file="$tmp_dir/.claude/.session-events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        fail_test "No .session-events.jsonl written"
        return
    fi

    local last_event
    last_event=$(tail -1 "$events_file")

    local agent_type_val
    agent_type_val=$(echo "$last_event" | jq -r '.agent_type // empty' 2>/dev/null)

    if [[ "$agent_type_val" == "orchestrator" ]]; then
        pass_test
    else
        fail_test "Expected agent_type=orchestrator, got: '$agent_type_val' — event: $last_event"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running skill-visibility test suite..."
echo ""

test_approve_command_deleted
test_approve_not_in_claude_md
test_skill_invoked_event_logged
test_skill_invoked_event_fields
test_no_active_subagent_defaults_to_orchestrator

echo ""
echo "========================================="
echo "Test Results:"
echo "  Total:  $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
else
    echo "  Failed: 0"
fi
echo "========================================="

# ============================================================================
# Frontmatter Visibility Tests (Part 2)
# Verifies that all skills and agents have the correct visibility declarations.
# ============================================================================

echo ""
echo "--- Frontmatter visibility checks ---"

# Helper: extract visibility from a SKILL.md or agent .md frontmatter
get_frontmatter_visibility() {
    local file="$1"
    local in_frontmatter=0
    local fm_count=0
    local visibility=""

    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            fm_count=$((fm_count + 1))
            if [[ $fm_count -eq 1 ]]; then
                in_frontmatter=1
                continue
            elif [[ $fm_count -ge 2 ]]; then
                break
            fi
        fi
        if [[ $in_frontmatter -eq 1 && "$line" =~ ^visibility:[[:space:]]*(.*) ]]; then
            visibility="${BASH_REMATCH[1]}"
            break
        fi
    done < "$file"

    echo "$visibility"
}

test_public_skills_have_correct_frontmatter() {
    run_test "Public skills have visibility: public in frontmatter"
    local expected_public=(
        "consume-content"
        "context-preservation"
        "decide"
        "deep-research"
        "diagnose"
        "prd"
        "rewind"
        "last30days"
    )
    local all_pass=1
    for skill in "${expected_public[@]}"; do
        local skill_file="$PROJECT_ROOT/skills/$skill/SKILL.md"
        if [[ ! -f "$skill_file" ]]; then
            echo "    WARN: $skill_file not found — skipping"
            continue
        fi
        local vis
        vis="$(get_frontmatter_visibility "$skill_file")"
        if [[ "$vis" != "public" ]]; then
            fail_test "skills/$skill: expected visibility=public, got '${vis:-<empty>}'"
            all_pass=0
        fi
    done
    if [[ $all_pass -eq 1 ]]; then
        pass_test
    fi
}

test_private_skills_have_correct_frontmatter() {
    run_test "Private skills have visibility: private in frontmatter"
    local expected_private=(
        "architect"
        "bazaar"
        "observatory"
        "uplevel"
        "generate-paper-snapshot"
    )
    local all_pass=1
    for skill in "${expected_private[@]}"; do
        local skill_file="$PROJECT_ROOT/skills/$skill/SKILL.md"
        if [[ ! -f "$skill_file" ]]; then
            echo "    WARN: $skill_file not found — skipping"
            continue
        fi
        local vis
        vis="$(get_frontmatter_visibility "$skill_file")"
        if [[ "$vis" != "private" && -n "$vis" ]]; then
            fail_test "skills/$skill: expected visibility=private or empty, got '$vis'"
            all_pass=0
        fi
    done
    if [[ $all_pass -eq 1 ]]; then
        pass_test
    fi
}

test_agents_have_public_frontmatter() {
    run_test "All agents have visibility: public in frontmatter"
    local expected_agents=("planner" "implementer" "tester" "guardian")
    local all_pass=1
    for agent in "${expected_agents[@]}"; do
        local agent_file="$PROJECT_ROOT/agents/$agent.md"
        if [[ ! -f "$agent_file" ]]; then
            fail_test "agents/$agent.md not found"
            all_pass=0
            continue
        fi
        local vis
        vis="$(get_frontmatter_visibility "$agent_file")"
        if [[ "$vis" != "public" ]]; then
            fail_test "agents/$agent.md: expected visibility=public, got '${vis:-<empty>}'"
            all_pass=0
        fi
    done
    if [[ $all_pass -eq 1 ]]; then
        pass_test
    fi
}

test_visibility_yaml_exists_and_valid() {
    run_test "VISIBILITY.yaml exists and has required structure"
    local vis_file="$PROJECT_ROOT/VISIBILITY.yaml"

    if [[ ! -f "$vis_file" ]]; then
        fail_test "VISIBILITY.yaml not found at $vis_file"
        return
    fi

    if ! grep -q "^public:" "$vis_file"; then
        fail_test "VISIBILITY.yaml missing top-level 'public:' key"
        return
    fi

    pass_test
}

test_visibility_yaml_categories() {
    run_test "VISIBILITY.yaml contains required category sections"
    local vis_file="$PROJECT_ROOT/VISIBILITY.yaml"
    [[ ! -f "$vis_file" ]] && { fail_test "VISIBILITY.yaml not found"; return; }

    local all_pass=1
    for cat in hooks tests agents config commands; do
        if ! grep -q "^  ${cat}:" "$vis_file"; then
            fail_test "VISIBILITY.yaml missing '$cat:' category"
            all_pass=0
        fi
    done
    if [[ $all_pass -eq 1 ]]; then
        pass_test
    fi
}

test_visibility_yaml_no_private_leaks() {
    run_test "VISIBILITY.yaml does not list known-private items in public section"
    local vis_file="$PROJECT_ROOT/VISIBILITY.yaml"
    [[ ! -f "$vis_file" ]] && { fail_test "VISIBILITY.yaml not found"; return; }

    local all_pass=1
    local private_items=("todo.sh" "community-check.sh" "MASTER_PLAN.md")
    for item in "${private_items[@]}"; do
        if grep -q "^    - ${item}" "$vis_file"; then
            fail_test "$item should be private but appears in public list"
            all_pass=0
        fi
    done
    if [[ $all_pass -eq 1 ]]; then
        pass_test
    fi
}

test_public_skills_have_correct_frontmatter
test_private_skills_have_correct_frontmatter
test_agents_have_public_frontmatter
test_visibility_yaml_exists_and_valid
test_visibility_yaml_categories
test_visibility_yaml_no_private_leaks

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi

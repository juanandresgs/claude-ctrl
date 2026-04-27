# Payload Contract

This document specifies the expected JSON schema for each Claude runtime hook
event, derived from reading the hook source code in `hooks/`. Fields listed
here are those the hooks actually parse — not a complete runtime spec.

Status: **derived from hook source** (TKT-001). Fields marked `[unconfirmed]`
have not yet been verified against a live capture session. The Tester for
TKT-001 must run a live capture and update status markers.

## How to Read This Document

- **Required**: hook will break or produce wrong output if field absent
- **Optional**: hook uses `// empty` fallback, missing field is safe
- **Unconfirmed**: field inferred from hook code, not yet live-captured

---

## SessionStart

**Hook:** `hooks/session-init.sh`
**Trigger:** Claude startup, `/clear`, `/compact`, session resume

The session-init hook does not read any fields from the payload. It derives
all context from the filesystem (git state, MASTER_PLAN.md, proof files).

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| *(none parsed)* | — | — | Hook ignores payload content |

**Output schema** (hook produces `additionalContext`):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<multiline string with git/plan/proof state>"
  }
}
```

---

## UserPromptSubmit

**Hook:** `hooks/prompt-submit.sh`
**Trigger:** Every user prompt submission

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.prompt` | string | Optional | The user's prompt text. Hook exits silently if absent. `jq -r '.prompt // empty'` |

**Output schema:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "<contextual injection string, may be empty>"
  }
}
```

---

## SubagentStart

**Hook:** `hooks/subagent-start.sh`
**Trigger:** Every subagent spawn (Task tool, Bash agent, etc.)

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.agent_type` | string | Optional | Agent type identifier. `jq -r '.agent_type // empty'`. Known values below. |

**Known `.agent_type` values** (from hook case statement):
- `planner` — Planner agent
- `Plan` — Planner agent (alternate casing used by runtime)
- `implementer` — Implementer agent
- `reviewer` — Reviewer agent (read-only evaluator; live after Phase 8 Slice 11)
- `guardian` — Guardian agent
- `Bash` — Bash subagent (lightweight)
- `Explore` — Explore subagent (lightweight)
- *(any other value)* — falls through to default case, emits agent_type string

Phase 8 Slice 11 retired the legacy `tester` agent role; it is no longer a
live runtime payload value and must not appear in new captures
(DEC-PHASE8-SLICE11-001).

**[unconfirmed]**: Whether runtime uses `planner` or `Plan` in practice.
Whether `Bash` and `Explore` are actual runtime values or placeholders.

**Output schema:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": "<role-specific context string>"
  }
}
```

The hook outputs nothing (exits 0 silently) for `Bash` and `Explore` types.

---

## SubagentStop

**Hooks:** `hooks/check-planner.sh`, `hooks/check-implementer.sh`,
`hooks/check-reviewer.sh`, `hooks/check-guardian.sh`
**Trigger:** Subagent completion, matched by agent type

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.agent_type` | string | Optional | Used by settings.json matcher to route to the correct check hook |
| `.response` | string | **[unconfirmed]** | May contain the agent's final output. Presence and structure unverified. |

**[unconfirmed]**: The SubagentStop payload schema has not been live-captured.
Field `.response` is presumed present based on runtime documentation but must
be verified. The check-*.sh hooks need to be read to determine what they
actually parse.

---

## PreToolUse — Write

**Hooks:** `hooks/test-gate.sh`, `hooks/mock-gate.sh`, `hooks/branch-guard.sh`,
`hooks/doc-gate.sh`, `hooks/plan-check.sh`
**Trigger:** Before any Write tool call

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.tool_name` | string | Required | Value: `"Write"`. Used to distinguish Write vs Edit in hooks. |
| `.tool_input.file_path` | string | Required | Absolute path to the file being written. |
| `.tool_input.content` | string | Required | Full content of the file to be written. |
| `.cwd` | string | Optional | Current working directory. Used by guard.sh for git target resolution. |

**Deny output schema** (hook blocks the write):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "<human-readable explanation>"
  }
}
```

**Allow output** (hook passes through): exit 0 with no stdout, or `{}`.

---

## PreToolUse — Edit

**Hooks:** `hooks/test-gate.sh`, `hooks/mock-gate.sh`, `hooks/branch-guard.sh`,
`hooks/doc-gate.sh`, `hooks/plan-check.sh`
**Trigger:** Before any Edit tool call

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.tool_name` | string | Required | Value: `"Edit"`. |
| `.tool_input.file_path` | string | Required | Absolute path to the file being edited. |
| `.tool_input.old_string` | string | Required | The exact text being replaced. |
| `.tool_input.new_string` | string | Required | The replacement text. |
| `.cwd` | string | Optional | Current working directory. |

Note: `plan-check.sh` skips all Edit calls (`exit 0` immediately for Edit).
`branch-guard.sh` applies the same logic to both Write and Edit.

---

## PreToolUse — Bash

**Hook:** `hooks/guard.sh`, `hooks/auto-review.sh`
**Trigger:** Before any Bash tool call

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.tool_name` | string | Required | Value: `"Bash"`. |
| `.tool_input.command` | string | Required | The full shell command string. `jq -r '.tool_input.command'`. Hook exits silently if absent. |
| `.cwd` | string | Optional | Current working directory. Used for git target directory resolution. `jq -r '.cwd // empty'`. |

**Deny output schema:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "<explanation>"
  }
}
```

---

## PostToolUse — Write/Edit

**Hooks:** `hooks/lint.sh`, `hooks/track.sh`, `hooks/code-review.sh`,
`hooks/plan-validate.sh`, `hooks/test-runner.sh`
**Trigger:** After a Write or Edit tool call completes

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.tool_name` | string | Optional | `"Write"` or `"Edit"` |
| `.tool_input.file_path` | string | Optional | Path of the file that was written/edited |
| `.tool_response` | object | **[unconfirmed]** | Runtime response data, structure unverified |

**[unconfirmed]**: PostToolUse payload structure not yet live-captured.

---

## Stop

**Hooks:** `hooks/surface.sh`, `hooks/session-summary.sh`, `hooks/stop-advisor.sh`
**Trigger:** Claude finishes responding

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `.last_assistant_message` | string | Optional | Used by `stop-advisor.sh` when present |

**[unconfirmed]**: Whether Stop payload contains session metadata, turn count,
or other fields.

---

## Verification Status

This contract was derived from hook source analysis on 2026-03-23.

To upgrade `[unconfirmed]` fields to confirmed:
1. Run `tests/scenarios/capture/install-capture.sh`
2. Activate capture settings
3. Exercise each event type in a live Claude session
4. Inspect `payloads/` files and update this document

Fields confirmed from source analysis (hooks parse them with exact jq paths):
- `SubagentStart.agent_type` — confirmed path `.agent_type // empty`
- `UserPromptSubmit.prompt` — confirmed path `.prompt // empty`
- `PreToolUse.tool_name` — confirmed path `.tool_name`
- `PreToolUse(Write/Edit).tool_input.file_path` — confirmed path `.tool_input.file_path`
- `PreToolUse(Write).tool_input.content` — confirmed path `.tool_input.content`
- `PreToolUse(Bash).tool_input.command` — confirmed path `.tool_input.command`
- `PreToolUse(Bash).cwd` — confirmed path `.cwd`

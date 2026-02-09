---
name: Hook Idea
about: Propose a new hook with its stdin/stdout contract
title: "[Hook] "
labels: hook-idea
assignees: ''
---

## Hook Name

`hooks/my-hook.sh`

## Event & Matcher

- **Event**: (e.g., PreToolUse, PostToolUse)
- **Matcher**: (e.g., `Bash`, `Write|Edit`, or omit for all tools)

## Sacred Practice

Which sacred practice does this enforce? (or is it a new practice?)

## Stdin Contract

What JSON does the hook receive?

```json
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/example/path.ts"
  }
}
```

## Decision Logic

Pseudocode or description of when to deny/allow/advise:

```
IF condition THEN deny("reason")
ELSE IF condition THEN advisory("warning")
ELSE allow
```

## Stdout Contract

Example deny response:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Explanation"
  }
}
```

## Chain Position

Where should this hook run relative to existing hooks? (e.g., "after test-gate.sh but before branch-guard.sh")

## State Files

Does this hook need persistent state across invocations? (e.g., strike counters like mock-gate.sh)

## Shared Library Usage

Which functions from `log.sh` / `context-lib.sh` will it use?

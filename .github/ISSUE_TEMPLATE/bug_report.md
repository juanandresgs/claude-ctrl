---
name: Bug Report
about: A hook isn't behaving as expected
title: "[Bug] "
labels: bug
assignees: ''
---

## Hook

Which hook is affected? (e.g., `guard.sh`, `test-gate.sh`, `auto-review.sh`)

## Environment

- **OS**: (e.g., macOS 15.x, Ubuntu 24.04)
- **Claude Code version**: (`claude --version`)
- **Shell**: (e.g., bash 5.2, zsh 5.9)
- **jq version**: (`jq --version`)

## Expected Behavior

What should the hook do?

## Actual Behavior

What does the hook do instead?

## Reproduction

JSON input that triggers the bug:

```json
{
  "tool_name": "...",
  "tool_input": { "command": "..." }
}
```

Command to reproduce:

```bash
echo '<json above>' | bash hooks/<hook>.sh
```

## Stdout Output

```
(paste hook stdout here)
```

## Stderr Output

```
(paste hook stderr here — this is where log messages go)
```

## Additional Context

Any other details: settings.json modifications, local overrides, related hooks in the chain.

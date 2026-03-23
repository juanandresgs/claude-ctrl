#!/usr/bin/env bash
set -euo pipefail

# Bootstrap bridge to the future typed runtime.

cc_policy() {
    local runtime_root="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
    python3 "$runtime_root/cli.py" "$@"
}

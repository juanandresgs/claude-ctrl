#!/usr/bin/env bash
# install.sh — one-time portable setup for cc-policy on a new machine.
#
# Usage:
#   bash ~/.claude/bin/install.sh
#
# What it does:
#   1. Verifies ~/.claude symlink resolves to a valid config repo
#   2. If ~/.local/bin is on PATH, creates a symlink there (preferred — no rc edit)
#   3. Otherwise, prints the one-line PATH export to add to your shell rc
#
# Idempotent: safe to re-run.

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
WRAPPER="${CLAUDE_DIR}/bin/cc-policy"

if [[ ! -f "$WRAPPER" ]]; then
    echo "ERROR: $WRAPPER not found." >&2
    echo "       Is ~/.claude symlinked to the config repo?" >&2
    exit 1
fi

# Verify the wrapper actually works
if ! "$WRAPPER" obs status >/dev/null 2>&1; then
    echo "WARNING: $WRAPPER exists but failed a smoke test." >&2
    echo "         Check that runtime/cli.py is reachable from the wrapper." >&2
fi

# Try ~/.local/bin first (XDG standard, on PATH for most users)
LOCAL_BIN="${HOME}/.local/bin"
if [[ ":$PATH:" == *":${LOCAL_BIN}:"* ]]; then
    mkdir -p "$LOCAL_BIN"
    ln -sf "$WRAPPER" "${LOCAL_BIN}/cc-policy"
    echo "OK: Symlinked $WRAPPER -> ${LOCAL_BIN}/cc-policy"
    echo "    cc-policy is now on your PATH via ~/.local/bin"
    exit 0
fi

# Fall back to instructions
echo "cc-policy wrapper exists at: $WRAPPER"
echo ""
# shellcheck disable=SC2088
echo "~/.local/bin is not on your PATH. To enable cc-policy globally, add"
echo "one of these to your shell rc (~/.zshrc or ~/.bashrc):"
echo ""
echo "    export PATH=\"\$HOME/.claude/bin:\$PATH\""
echo ""
echo "Or, if you prefer ~/.local/bin:"
echo ""
echo "    mkdir -p ~/.local/bin"
echo "    ln -sf $WRAPPER ~/.local/bin/cc-policy"
echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "Then reload: source ~/.zshrc"

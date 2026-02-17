#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook for Playwright MCP tools.
# Matcher: mcp__playwright__browser_snapshot
#
# After content is captured via browser_snapshot, injects guidance
# to call browser_close when done browsing. This ensures Playwright
# only keeps the browser open while actively needed — not for the
# rest of the session.
#
# Uses browser_close (MCP tool) which surgically closes only the
# Playwright-managed page/context, never the user's real browser.
#
# @decision DEC-FETCH-005
# @title Surgical Playwright cleanup via PostToolUse nudge
# @status accepted
# @rationale pkill would risk killing the user's real browser.
#   browser_close is surgical — only closes what Playwright opened.
#   PostToolUse on browser_snapshot is the right trigger because
#   snapshot is the typical "content captured" signal.

source "$(dirname "$0")/source-lib.sh"

INPUT=$(read_input)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Only act on browser_snapshot — the "I captured the content" signal
if [[ "$TOOL_NAME" == "mcp__playwright__browser_snapshot" ]]; then
    cat <<'EOF'
{
  "hookSpecificOutput": {
    "additionalContext": "Browser content captured. When you are done with the browser (no more navigation or interaction needed), call mcp__playwright__browser_close to close the Playwright-managed page. This only closes what Playwright opened — not the user's real browser."
  }
}
EOF
    log_info "PLAYWRIGHT-CLEANUP" "Injected browser_close reminder after snapshot"
fi

#!/usr/bin/env bash
# webfetch-fallback.sh — PostToolUse hook for WebFetch failures
#
# Purpose: Detects WebFetch failures (blocked domains, cascade errors) and automatically
# suggests resilient alternatives (mcp__fetch__fetch for single URLs, batch-fetch.py for
# multiple URLs). This preserves Claude's existing WebFetch patterns while providing a
# deterministic recovery path when failures occur.
#
# Rationale: WebFetch has a domain blocklist and causes cascade failures in parallel batches.
# Rather than prohibiting its use via CLAUDE.md directives, we detect failures at tool
# execution time and suggest alternatives. This approach is more reliable than instructions
# and catches cases where Claude defaults to WebFetch.
#
# Hook type: PostToolUse
# Trigger: WebFetch tool calls
# Input: JSON on stdin with tool_name, tool_input, tool_output
# Output: JSON with additionalContext on failure, nothing on success
#
# @decision DEC-FETCH-003
# @title Automatic WebFetch fallback via PostToolUse hook
# @status accepted
# @rationale WebFetch has domain blocklist and causes cascade failures in parallel batches.
#            Rather than prohibit its use, we detect failures and suggest alternatives
#            automatically. This preserves Claude's existing WebFetch patterns while
#            providing a deterministic recovery path.

set -euo pipefail

# Read tool result JSON from stdin
INPUT=$(cat)

# Extract tool_output field (the result of the WebFetch call)
TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // ""')

# Detect failure indicators in the output
if echo "$TOOL_OUTPUT" | grep -qiE '(error:|failed|blocked|denied|refused|timeout|unable|cannot fetch|sibling tool call errored)'; then
    # WebFetch failed — output retry guidance
    cat <<'EOF'
{
  "hookSpecificOutput": {
    "additionalContext": "WebFetch failed. Retry using:\n- Single URL: mcp__fetch__fetch (MCP tool)\n- Multiple URLs (3+): python3 ~/.claude/scripts/batch-fetch.py \"<URL1>\" \"<URL2>\" ...\n- JS-rendered sites: Playwright MCP (browser_navigate → browser_snapshot)\n\nDo NOT retry with WebFetch for the same URL."
  }
}
EOF
    exit 0
fi

# Check for empty/null output (another failure indicator)
if [ -z "$TOOL_OUTPUT" ] || [ "$TOOL_OUTPUT" = "null" ]; then
    cat <<'EOF'
{
  "hookSpecificOutput": {
    "additionalContext": "WebFetch returned empty output. Retry using:\n- Single URL: mcp__fetch__fetch (MCP tool)\n- Multiple URLs (3+): python3 ~/.claude/scripts/batch-fetch.py \"<URL1>\" \"<URL2>\" ...\n- JS-rendered sites: Playwright MCP (browser_navigate → browser_snapshot)"
  }
}
EOF
    exit 0
fi

# Success — output nothing (no interference)
exit 0

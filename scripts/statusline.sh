#!/usr/bin/env bash
# statusline.sh — Renders the Claude Code statusline HUD.
#
# Produces a compact single-line HUD of key:value pairs for the terminal.
# Primary data source: runtime snapshot via cc-policy statusline snapshot.
# Fallback: basic git branch/dirty state when the runtime is unavailable.
#
# Input: none (standalone; does not read stdin)
# Output: single-line HUD string, no trailing newline
#
# @decision DEC-SL-001
# @title Runtime-backed statusline renderer
# @status accepted
# @rationale The statusline must be a read model over canonical runtime state,
#   not a second authority. All data comes from cc-policy statusline snapshot
#   via rt_statusline_snapshot() in runtime-bridge.sh. Flat-file reading has
#   been removed; the bridge wrapper already handles schema bootstrap, error
#   suppression, and scoping CLAUDE_POLICY_DB. Flat-file fallback (git branch
#   + dirty count) exists for graceful degradation only — when the runtime CLI
#   is unreachable or returns a non-ok status. This design eliminates the
#   .statusline-cache file as a data authority and makes the HUD a direct
#   projection of the canonical SQLite-backed runtime state.
#   Replaces the previous stdin-driven, .statusline-cache-reading version.
#   See TKT-012 and DEC-RT-011 (statusline snapshot canonical projection).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the runtime bridge — this provides rt_statusline_snapshot().
# The bridge sources safely and suppresses its own errors; we tolerate
# a missing file here with || true so the fallback path still runs.
# shellcheck source=../hooks/lib/runtime-bridge.sh
source "$SCRIPT_DIR/../hooks/lib/runtime-bridge.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Attempt: call rt_statusline_snapshot() and validate the response.
# rt_statusline_snapshot() returns raw JSON or empty string on failure.
# We require .status == "ok" before trusting any field.
# ---------------------------------------------------------------------------
SNAPSHOT=""
if declare -f rt_statusline_snapshot >/dev/null 2>&1; then
    SNAPSHOT=$(rt_statusline_snapshot 2>/dev/null) || SNAPSHOT=""
fi

if [[ -n "$SNAPSHOT" ]] && printf '%s' "$SNAPSHOT" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    # -----------------------------------------------------------------------
    # Runtime path: parse snapshot fields and build HUD from them.
    # All fields default safely via jq // operator so missing keys never
    # cause the script to crash.
    # -----------------------------------------------------------------------
    PROOF=$(printf '%s' "$SNAPSHOT"      | jq -r '.proof_status // "idle"')
    AGENT=$(printf '%s' "$SNAPSHOT"      | jq -r '.active_agent // "null"')
    WT_COUNT=$(printf '%s' "$SNAPSHOT"   | jq -r '.worktree_count // 0')
    DISPATCH=$(printf '%s' "$SNAPSHOT"   | jq -r '.dispatch_status // "null"')
    INITIATIVE=$(printf '%s' "$SNAPSHOT" | jq -r '.dispatch_initiative // "null"')

    # Build HUD as array of key:value parts then join with spaces.
    PARTS=()
    PARTS+=("proof:$PROOF")

    # Agent — omit when null/none (no active agent is the common case; keep HUD lean)
    if [[ "$AGENT" != "none" && "$AGENT" != "null" && -n "$AGENT" ]]; then
        PARTS+=("agent:$AGENT")
    fi

    # Worktree count — omit when 0
    if [[ "$WT_COUNT" -gt 0 ]]; then
        PARTS+=("wt:$WT_COUNT")
    fi

    # Dispatch next role — omit when queue is empty
    if [[ -n "$DISPATCH" && "$DISPATCH" != "null" ]]; then
        PARTS+=("next:$DISPATCH")
    fi

    # Dispatch initiative — omit when no active cycle
    if [[ -n "$INITIATIVE" && "$INITIATIVE" != "null" ]]; then
        PARTS+=("init:$INITIATIVE")
    fi

    printf '%s' "${PARTS[*]}"
else
    # -----------------------------------------------------------------------
    # Fallback path: runtime is unavailable.
    # Render a minimal HUD from git state so the statusline is never blank.
    # The "(no runtime)" marker lets the user know this is degraded output.
    # -----------------------------------------------------------------------
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    printf '%s' "branch:$BRANCH dirty:$DIRTY (no runtime)"
fi

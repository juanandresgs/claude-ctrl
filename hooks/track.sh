#!/usr/bin/env bash
# Project-aware file change tracking.
# PostToolUse hook — matcher: Write|Edit
#
# Tracks file changes per-session in the PROJECT's .claude directory.
# Uses CLAUDE_PROJECT_DIR when available, falls back to git root detection.
# Session-scoped to avoid collisions with concurrent sessions.
# Also invalidates .proof-status when verified source files change post-verification.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Exit silently if parent directory doesn't exist
[[ ! -e "$(dirname "$FILE_PATH")" ]] && exit 0

# Detect project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Session-scoped tracking file (tracks file changes, not decisions)
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
TRACKING_DIR="$PROJECT_ROOT/.claude"
TRACKING_FILE="$TRACKING_DIR/.session-changes-${SESSION_ID}"

# Create tracking directory if needed
mkdir -p "$TRACKING_DIR"

# Atomic append: write to temp then append (safer than direct >>)
TMPFILE=$(mktemp "${TRACKING_DIR}/.track.XXXXXX")
echo "$FILE_PATH" > "$TMPFILE"
cat "$TMPFILE" >> "$TRACKING_FILE"
rm -f "$TMPFILE"

# --- Log write event to session event log (skip trace artifacts — meta-infrastructure noise) ---
if [[ ! "$FILE_PATH" =~ /\.claude/traces/ ]]; then
    append_session_event "write" "{\"file\":\"$FILE_PATH\"}" "$PROJECT_ROOT"
fi

# --- Invalidate doc freshness cache when a .md file is written ---
# The cache key includes doc modification times. A direct write to a tracked .md
# file changes its mtime, which the next get_doc_freshness() call detects as a
# cache miss. Removing the cache here ensures recomputation within the same session.
if [[ "$FILE_PATH" == *.md ]]; then
    _DOC_CACHE="${TRACKING_DIR}/.doc-freshness-cache"
    rm -f "$_DOC_CACHE"
fi

# --- Invalidate proof-status when non-test source files change ---
# If user verified the feature and then source code changes, proof is stale.
# @decision DEC-PROOF-PATH-003
# @title Use get_claude_dir() for proof-status path in track.sh and guard.sh
# @status accepted
# @rationale For the meta-repo (PROJECT_ROOT = ~/.claude), TRACKING_DIR is
#   set to "$PROJECT_ROOT/.claude" = "~/.claude/.claude" which produces a
#   double-nested path. PROOF_FILE then becomes "~/.claude/.claude/.proof-status"
#   — a path that never exists — so the invalidation guard silently does nothing.
#   get_claude_dir() (from log.sh) already handles this: it returns PROJECT_ROOT
#   as-is when PROJECT_ROOT == ~/.claude, and PROJECT_ROOT/.claude otherwise.
#   Using it here ensures the proof-status path is consistent with where
#   resolve_proof_file(), prompt-submit.sh, and check-tester.sh write the file.
#   Same fix applied to guard.sh Check 8 (DEC-PROOF-PATH-003). Fixes meta-repo
#   proof invalidation and guard.sh's double-nested proof read on git commit.
_PROOF_PHASH=$(project_hash "$PROJECT_ROOT")
_PROOF_SCOPED="$(get_claude_dir)/.proof-status-${_PROOF_PHASH}"
_PROOF_LEGACY="$(get_claude_dir)/.proof-status"
# Check scoped file first; fall back to legacy for backward compat
if [[ -f "$_PROOF_SCOPED" ]]; then
    PROOF_FILE="$_PROOF_SCOPED"
elif [[ -f "$_PROOF_LEGACY" ]]; then
    PROOF_FILE="$_PROOF_LEGACY"
else
    PROOF_FILE="$_PROOF_SCOPED"
fi
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
    if [[ "$PROOF_STATUS" == "verified" ]]; then
        # @decision DEC-TRACK-GUARDIAN-001
        # @title Skip proof invalidation when Guardian agent is active
        # @status accepted
        # @rationale Guardian's commit/merge workflow can trigger Write/Edit events
        #   (e.g., merge conflict resolution, hook-generated file updates). Without
        #   this guard, track.sh fires on those writes and resets .proof-status from
        #   verified→pending mid-workflow. Guard.sh Check 8 then blocks the commit
        #   because the proof is no longer verified — a deadlock where Guardian's own
        #   actions prevent it from completing. The fix: if a Guardian agent is active
        #   (marker file exists in TRACE_STORE), skip the invalidation entirely.
        #   The proof was already verified by the user before Guardian dispatched; a
        #   write during Guardian's merge cycle does NOT represent new unverified work.
        #   Pattern mirrors guard.sh's is_guardian_active() check at lines 133-141.
        #   Inlined here (not extracted to context-lib.sh) to keep the fix minimal and
        #   avoid changing the shared library surface for a single call site. Fixes #49.
        _guardian_active=false
        for _gm in "${TRACE_STORE}/.active-guardian-"*; do
            [[ -f "$_gm" ]] && { _guardian_active=true; break; }
        done

        if [[ "$_guardian_active" == "false" ]]; then
            # Only invalidate for source file changes (not tests, config, docs).
            # Use RELATIVE_PATH (relative to project root) for exclusion checks so that
            # ancestor directories containing ".claude" (e.g. ~/.claude/tmp/test-XXXX/main.sh)
            # do not false-positive the exclusion. The extension check stays on the full
            # FILE_PATH since extensions are at the tail and unaffected by directory depth.
            # @decision DEC-TRACK-001
            # @title Use relative path for proof invalidation exclusions in track.sh
            # @status accepted
            # @rationale Using the absolute FILE_PATH for exclusion matching caused all
            #   source files in the meta-repo (~/.claude) to be excluded because their
            #   absolute paths contain ".claude". Changing to relative path (FILE_PATH
            #   stripped of PROJECT_ROOT prefix) restricts the exclusion to the filename
            #   and path within the project, not the project's ancestor directories.
            #   Also fixes the same issue for projects whose absolute paths contain
            #   any of the exclusion keywords (node_modules, .git, vendor, etc. in the
            #   path above the project root are now ignored). Fixes #135/#43.
            RELATIVE_PATH="${FILE_PATH#${PROJECT_ROOT}/}"
            if [[ "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]] \
               && [[ ! "$RELATIVE_PATH" =~ (\.test\.|\.spec\.|__tests__|\.config\.|node_modules|vendor|dist|\.git|\.claude) ]]; then
                echo "pending|$(date +%s)" > "$PROOF_FILE"
            fi
        fi
    fi
fi

exit 0

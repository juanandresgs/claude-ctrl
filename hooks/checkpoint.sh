#!/usr/bin/env bash
# Checkpoint creation for mid-session recovery.
# PreToolUse hook — matcher: Write|Edit
#
# Creates git refs at refs/checkpoints/<branch>/<N> that snapshot the
# working directory state before file writes. Refs are created:
#   1. Every 5 writes (threshold-based)
#   2. On the first modification of a file not yet seen this session
#
# Checkpoints do not affect the working copy or the git index — they use
# a temporary index to stage all files and write-tree, then create a
# commit object via git plumbing. The ref update is the only visible change.
#
# @decision DEC-V2-002
# @title Git ref-based checkpoints via plumbing commands
# @status accepted
# @rationale Git refs are first-class, survive garbage collection when referenced,
# and support random access without branch switching or stash pollution.
# Alternative (git stash) modifies working copy and creates visible stash entries.
# Alternative (temp files) are not version-controlled and don't survive gc.
# Git refs with commit-tree are the minimal-footprint, recoverable approach.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path in input
[[ -z "$FILE_PATH" ]] && exit 0

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Skip if not a git repo
git -C "$PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1 || exit 0

# Skip on main/master (checkpoints are for feature branches)
BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
[[ "$BRANCH" == "main" || "$BRANCH" == "master" || -z "$BRANCH" ]] && exit 0

# Skip if meta-repo (~/.claude infrastructure changes don't need checkpoints)
is_claude_meta_repo "$PROJECT_ROOT" 2>/dev/null && exit 0

# Ensure .claude directory exists for state files
mkdir -p "$CLAUDE_DIR"

# Read and increment the write counter
COUNTER_FILE="${CLAUDE_DIR}/.checkpoint-counter"
N=0
if [[ -f "$COUNTER_FILE" ]]; then
    N=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    # Guard against non-numeric content
    [[ "$N" =~ ^[0-9]+$ ]] || N=0
fi
N=$((N + 1))
echo "$N" > "$COUNTER_FILE"

# Determine whether to create a checkpoint
CREATE=false

# Condition 1: Every 5 writes (threshold)
if (( N % 5 == 0 )); then
    CREATE=true
fi

# Condition 2: First time this session we're modifying this file
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
CHANGES_FILE="${CLAUDE_DIR}/.session-changes-${SESSION_ID}"
if [[ -f "$CHANGES_FILE" ]]; then
    if ! grep -qF "$FILE_PATH" "$CHANGES_FILE" 2>/dev/null; then
        CREATE=true  # First modification of this file in this session
    fi
    # Record this file as seen (append if not already present)
    grep -qF "$FILE_PATH" "$CHANGES_FILE" 2>/dev/null || echo "$FILE_PATH" >> "$CHANGES_FILE"
else
    # First write of the session — create the file and trigger a checkpoint
    echo "$FILE_PATH" > "$CHANGES_FILE"
    CREATE=true
fi

# Create checkpoint if conditions met
if [[ "$CREATE" == "true" ]]; then
    # Use a temporary index to snapshot working directory without touching the real index.
    # This avoids modifying staging area or working copy.
    GIT_DIR=$(git -C "$PROJECT_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
    if [[ ! "${GIT_DIR}" = /* ]]; then
        GIT_DIR="${PROJECT_ROOT}/${GIT_DIR}"
    fi

    TMPIDX=$(mktemp "${TMPDIR:-/tmp}/checkpoint-idx.XXXXXX")
    trap "rm -f '$TMPIDX'" EXIT

    # Copy the current real index as the base, then add all working directory files
    if [[ -f "${GIT_DIR}/index" ]]; then
        cp "${GIT_DIR}/index" "$TMPIDX" 2>/dev/null || true
    fi

    # Stage everything into the temp index and write the tree
    GIT_INDEX_FILE="$TMPIDX" git -C "$PROJECT_ROOT" add -A 2>/dev/null || true
    TREE=$(GIT_INDEX_FILE="$TMPIDX" git -C "$PROJECT_ROOT" write-tree 2>/dev/null) || {
        rm -f "$TMPIDX"
        exit 0
    }
    rm -f "$TMPIDX"
    trap - EXIT

    # Get current HEAD as parent
    PARENT=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null) || exit 0

    # Create a commit object (not a real commit — just an object in the object store)
    BASENAME="${FILE_PATH##*/}"
    MSG="checkpoint:$(date +%s):before:${BASENAME}"
    SHA=$(git -C "$PROJECT_ROOT" commit-tree "$TREE" -p "$PARENT" -m "$MSG" 2>/dev/null) || exit 0

    # Determine checkpoint number (sequential per branch)
    EXISTING=$(git -C "$PROJECT_ROOT" for-each-ref "refs/checkpoints/${BRANCH}/" --format='%(refname)' 2>/dev/null | wc -l | tr -d ' ')
    CP_NUM=$((EXISTING + 1))
    REF="refs/checkpoints/${BRANCH}/${CP_NUM}"

    # Atomically update the ref
    git -C "$PROJECT_ROOT" update-ref "$REF" "$SHA" 2>/dev/null || exit 0

    # Log the checkpoint event for session trajectory tracking
    # Use jq to build valid JSON — avoids shell escaping issues with $REF, $BASENAME, $N
    DETAIL=$(jq -cn --arg ref "$REF" --arg file "$BASENAME" --arg n "$N" \
        '{ref:$ref,file:$file,trigger:("n="+$n)}' 2>/dev/null) || DETAIL="{}"
    append_session_event "checkpoint" "$DETAIL" "$PROJECT_ROOT" || true
fi

exit 0

#!/usr/bin/env bash
# Community contribution checker
# SessionStart hook — runs on session startup
#
# @decision DEC-COMMUNITY-001
# @title GitHub community contribution notifications — fresh every session
# @status accepted
# @rationale Surface inbound PRs and issues from other users to keep maintainers
#   aware of community engagement. Checks fresh every session (no cache TTL) —
#   user prefers always-current data over saving 2-3 seconds of startup time.
#   Filters out self-authored items and claude-todo issues (those are the todo
#   system, not contributions). Silent exit on missing gh CLI or network failure
#   to avoid startup noise.
#
# Flow:
#   0. Check disable toggle (.disable-community-check)
#   1. Verify gh CLI is available and authenticated
#   2. Determine GitHub username
#   3. List all public repos
#   4. Query open PRs and issues for each repo
#   5. Filter out self-authored items and claude-todo labels
#   6. Write .community-status JSON for session-init.sh consumption
#
# Status file format (JSON):
# {
#   "status": "active|none|error",
#   "checked_at": EPOCH,
#   "total_prs": N,
#   "total_issues": N,
#   "items": [
#     {"type":"pr|issue","repo":"name","number":N,"title":"...","author":"..."},
#     ...
#   ]
# }

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
STATUS_FILE="$CLAUDE_DIR/.community-status"
LOCK_FILE="$CLAUDE_DIR/.community-check.lock"
DISABLE_FILE="$CLAUDE_DIR/.disable-community-check"

# Always clean up lock file on exit
cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

write_status() {
    local status="$1"
    local total_prs="${2:-0}"
    local total_issues="${3:-0}"
    local items_json="${4:-[]}"

    cat > "$STATUS_FILE" << EOF
{
  "status": "$status",
  "checked_at": $(date +%s),
  "total_prs": $total_prs,
  "total_issues": $total_issues,
  "items": $items_json
}
EOF
}

# --- Step 0: Disable toggle ---
if [[ -f "$DISABLE_FILE" ]]; then
    exit 0
fi

# --- Step 1: Lock file (prevent concurrent checks) ---
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        # Another check is running
        exit 0
    fi
    # Stale lock — clean up
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# --- Step 2: Verify gh CLI ---
if ! command -v gh >/dev/null 2>&1; then
    exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
    exit 0
fi

# --- Step 3: Get GitHub username ---
USERNAME=$(gh api user --jq .login 2>/dev/null || echo "")
if [[ -z "$USERNAME" ]]; then
    write_status "error"
    exit 0
fi

# --- Step 4: List public repos ---
REPOS=$(gh repo list "$USERNAME" --public --json name --limit 100 2>/dev/null || echo "[]")
if [[ "$REPOS" == "[]" ]]; then
    write_status "none"
    exit 0
fi

# --- Step 5: Query PRs and issues for each repo ---
# Use temp files for parallel processing
TMP_DIR=$(mktemp -d)
trap "rm -rf '$TMP_DIR'; cleanup" EXIT

ALL_ITEMS="[]"
TOTAL_PRS=0
TOTAL_ISSUES=0

# Process repos sequentially (parallel would be complex with temp files)
while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue

    REPO_FULL="${USERNAME}/${repo_name}"

    # Fetch PRs
    PRS=$(gh pr list --repo "$REPO_FULL" --state open --json number,title,author,createdAt 2>/dev/null || echo "[]")

    # Filter out self-authored PRs and convert to our format
    FILTERED_PRS=$(echo "$PRS" | jq --arg username "$USERNAME" --arg repo "$repo_name" '
        map(select(.author.login != $username)) |
        map({
            type: "pr",
            repo: $repo,
            number: .number,
            title: .title,
            author: .author.login
        })
    ' 2>/dev/null || echo "[]")

    # Fetch issues
    ISSUES=$(gh issue list --repo "$REPO_FULL" --state open --json number,title,author,labels,createdAt 2>/dev/null || echo "[]")

    # Filter out self-authored issues and claude-todo labels
    FILTERED_ISSUES=$(echo "$ISSUES" | jq --arg username "$USERNAME" --arg repo "$repo_name" '
        map(select(.author.login != $username)) |
        map(select([.labels[].name] | any(. == "claude-todo") | not)) |
        map({
            type: "issue",
            repo: $repo,
            number: .number,
            title: .title,
            author: .author.login
        })
    ' 2>/dev/null || echo "[]")

    # Merge into ALL_ITEMS
    ALL_ITEMS=$(echo "$ALL_ITEMS" | jq --argjson prs "$FILTERED_PRS" --argjson issues "$FILTERED_ISSUES" \
        '. + $prs + $issues' 2>/dev/null || echo "[]")

done < <(echo "$REPOS" | jq -r '.[].name' 2>/dev/null)

# --- Step 6: Count and write status ---
TOTAL_PRS=$(echo "$ALL_ITEMS" | jq '[.[] | select(.type == "pr")] | length' 2>/dev/null || echo "0")
TOTAL_ISSUES=$(echo "$ALL_ITEMS" | jq '[.[] | select(.type == "issue")] | length' 2>/dev/null || echo "0")

if [[ "$TOTAL_PRS" -eq 0 && "$TOTAL_ISSUES" -eq 0 ]]; then
    write_status "none"
else
    # Compact JSON output (no pretty printing)
    ITEMS_JSON=$(echo "$ALL_ITEMS" | jq -c '.' 2>/dev/null || echo "[]")
    write_status "active" "$TOTAL_PRS" "$TOTAL_ISSUES" "$ITEMS_JSON"
fi

exit 0

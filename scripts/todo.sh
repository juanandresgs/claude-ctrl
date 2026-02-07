#!/usr/bin/env bash
# todo.sh — Claude Code persistent idea capture backend.
#
# Purpose: Wraps the GitHub CLI (gh) to provide durable, visible todo/idea
# storage as GitHub Issues. Called by /todo and /todos slash commands and
# queried by hooks (session-init, session-summary) for automatic surfacing.
#
# @decision GitHub Issues over flat files — provides durability, visibility
# outside Claude Code (web/mobile/notifications), team access, search,
# and timestamps for staleness detection. gh CLI already in allowed perms.
# Flat files are invisible, easy to lose, and lack timestamps. Status: accepted.
#
# Commands:
#   add "title" [--global] [--priority=high|medium|low] [--body="details"]
#   list [--project|--global|--all] [--json]
#   done <issue-number> [--global|--repo=owner/repo]
#   stale [--days=14]
#   count [--project|--global|--all]
#   claim <issue-number> [--global] [--auto]
#   unclaim [--session=ID]
#   active [--json]
#
# Requires: gh CLI authenticated (gh auth login)
set -euo pipefail

LABEL="claude-todo"
STALE_DAYS=14
CONFIG_DIR="$HOME/.config/cc-todos"
CONFIG_FILE="$CONFIG_DIR/config"
CLAIMS_FILE="$CONFIG_DIR/active-claims.tsv"

# --- Bootstrap ---

require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not found. Install it:" >&2
        echo "  brew install gh   (macOS)" >&2
        echo "  https://cli.github.com  (other)" >&2
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: gh CLI not authenticated. Run:" >&2
        echo "  gh auth login" >&2
        exit 1
    fi
}

resolve_global_repo() {
    # Fast path: cached value
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        if [[ -n "${GLOBAL_REPO:-}" ]]; then
            return 0
        fi
    fi

    # Slow path: auto-detect from GitHub
    local username
    username=$(gh api user --jq '.login' 2>/dev/null) || {
        echo "ERROR: Could not detect GitHub username. Set manually:" >&2
        echo "  mkdir -p $CONFIG_DIR && echo 'GLOBAL_REPO=youruser/cc-todos' > $CONFIG_FILE" >&2
        exit 1
    }

    GLOBAL_REPO="${username}/cc-todos"

    # Cache for next time
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<-CONF
GITHUB_USER=$username
GLOBAL_REPO=$GLOBAL_REPO
CONF

    echo "Auto-detected GitHub user: $username" >&2
    echo "Cached global repo: $GLOBAL_REPO → $CONFIG_FILE" >&2
}

# --- Helpers ---

is_git_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

get_repo_name() {
    if is_git_repo; then
        gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo ""
    fi
}

ensure_label() {
    local repo="${1:-}"
    local repo_flag=""
    [[ -n "$repo" ]] && repo_flag="--repo $repo"

    # Create label if it doesn't exist (silently ignore if it does)
    gh label create "$LABEL" \
        --description "Captured via Claude Code /todo" \
        --color "1d76db" \
        $repo_flag 2>/dev/null || true
}

ensure_priority_label() {
    local priority="$1"
    local repo="${2:-}"
    local repo_flag=""
    [[ -n "$repo" ]] && repo_flag="--repo $repo"

    local color="ededed"
    case "$priority" in
        high)   color="d73a4a" ;;
        medium) color="fbca04" ;;
        low)    color="0e8a16" ;;
    esac

    gh label create "priority:$priority" \
        --description "Priority: $priority" \
        --color "$color" \
        $repo_flag 2>/dev/null || true
}

ensure_global_repo() {
    # Check if global repo exists; if not, create it
    if ! gh repo view "$GLOBAL_REPO" >/dev/null 2>&1; then
        echo "Creating global todo repo: $GLOBAL_REPO..."
        gh repo create "$GLOBAL_REPO" \
            --private \
            --description "Global Claude Code todo backlog" 2>/dev/null || {
            echo "ERROR: Could not create $GLOBAL_REPO. Create it manually on GitHub." >&2
            exit 1
        }
    fi
}

# --- Commands ---

cmd_add() {
    local title=""
    local scope="project"
    local priority=""
    local body="Captured via Claude Code /todo"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global)
                scope="global"
                shift ;;
            --priority=*)
                priority="${1#--priority=}"
                shift ;;
            --body=*)
                body="${1#--body=}"
                shift ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                else
                    title="$title $1"
                fi
                shift ;;
        esac
    done

    if [[ -z "$title" ]]; then
        echo "ERROR: No todo title provided." >&2
        echo "Usage: todo.sh add \"title\" [--global] [--priority=high|medium|low]" >&2
        exit 1
    fi

    # Determine target repo
    local target_repo=""
    local repo_flag=""

    if [[ "$scope" == "global" ]]; then
        ensure_global_repo
        target_repo="$GLOBAL_REPO"
        repo_flag="--repo $GLOBAL_REPO"
        body="$body (global)"
    elif is_git_repo; then
        target_repo=$(get_repo_name)
        if [[ -z "$target_repo" ]]; then
            echo "WARNING: In a git repo but no GitHub remote. Falling back to global." >&2
            ensure_global_repo
            target_repo="$GLOBAL_REPO"
            repo_flag="--repo $GLOBAL_REPO"
            body="$body (global - no remote)"
        fi
    else
        ensure_global_repo
        target_repo="$GLOBAL_REPO"
        repo_flag="--repo $GLOBAL_REPO"
        body="$body (global - not in git repo)"
    fi

    # Ensure labels exist
    ensure_label "$target_repo"

    # Build label list
    local labels="$LABEL"
    if [[ -n "$priority" ]]; then
        ensure_priority_label "$priority" "$target_repo"
        labels="$labels,priority:$priority"
    fi

    # Add context to body
    local cwd
    cwd=$(pwd)
    local branch=""
    is_git_repo && branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    body="$body

---
**Context:**
- Directory: \`$cwd\`"
    [[ -n "$branch" ]] && body="$body
- Branch: \`$branch\`"
    body="$body
- Captured: $(date '+%Y-%m-%d %H:%M')"

    # Create the issue
    local result
    result=$(gh issue create \
        --title "$title" \
        --body "$body" \
        --label "$labels" \
        $repo_flag 2>&1)

    echo "$result"
}

cmd_list() {
    local scope="all"
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) scope="project"; shift ;;
            --global)  scope="global"; shift ;;
            --all)     scope="all"; shift ;;
            --json)    json_output=true; shift ;;
            *) shift ;;
        esac
    done

    local has_output=false

    # Project todos
    if [[ "$scope" == "project" || "$scope" == "all" ]]; then
        if is_git_repo; then
            local repo_name
            repo_name=$(get_repo_name)
            if [[ -n "$repo_name" ]]; then
                local project_issues
                project_issues=$(gh issue list \
                    --label "$LABEL" \
                    --state open \
                    --limit 10 \
                    --json number,title,createdAt,labels \
                    2>/dev/null || echo "[]")

                local count
                count=$(echo "$project_issues" | jq 'length')

                if [[ "$count" -gt 0 ]]; then
                    has_output=true
                    if $json_output; then
                        echo "$project_issues" | jq --arg repo "$repo_name" '{repo: $repo, scope: "project", issues: .}'
                    else
                        echo "PROJECT [$repo_name] ($count open):"
                        echo "$project_issues" | jq -r '.[] | "  #\(.number) \(.title) (\(.createdAt | split("T")[0]))"'
                    fi
                fi
            fi
        fi
    fi

    # Global todos
    if [[ "$scope" == "global" || "$scope" == "all" ]]; then
        if gh repo view "$GLOBAL_REPO" >/dev/null 2>&1; then
            local global_issues
            global_issues=$(gh issue list \
                --repo "$GLOBAL_REPO" \
                --label "$LABEL" \
                --state open \
                --limit 10 \
                --json number,title,createdAt,labels \
                2>/dev/null || echo "[]")

            local count
            count=$(echo "$global_issues" | jq 'length')

            if [[ "$count" -gt 0 ]]; then
                has_output=true
                if $json_output; then
                    echo "$global_issues" | jq --arg repo "$GLOBAL_REPO" '{repo: $repo, scope: "global", issues: .}'
                else
                    echo "GLOBAL [$GLOBAL_REPO] ($count open):"
                    echo "$global_issues" | jq -r '.[] | "  #\(.number) \(.title) (\(.createdAt | split("T")[0]))"'
                fi
            fi
        fi
    fi

    if ! $has_output; then
        echo "No pending todos."
    fi
}

cmd_done() {
    local issue_number="$1"
    shift || true

    local repo_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo=*) repo_flag="--repo ${1#--repo=}"; shift ;;
            --global) repo_flag="--repo $GLOBAL_REPO"; shift ;;
            *) shift ;;
        esac
    done

    gh issue close "$issue_number" \
        --comment "Closed via Claude Code /todos done" \
        $repo_flag 2>&1
}

cmd_stale() {
    local days=$STALE_DAYS

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days=*) days="${1#--days=}"; shift ;;
            *) shift ;;
        esac
    done

    local cutoff_date
    cutoff_date=$(date -v-${days}d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
                  date -d "${days} days ago" '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
                  echo "")

    [[ -z "$cutoff_date" ]] && { echo "Could not compute cutoff date"; exit 1; }

    echo "Todos older than ${days} days:"

    # Project stale
    if is_git_repo; then
        local repo_name
        repo_name=$(get_repo_name)
        if [[ -n "$repo_name" ]]; then
            local stale
            stale=$(gh issue list \
                --label "$LABEL" \
                --state open \
                --json number,title,createdAt \
                2>/dev/null || echo "[]")

            echo "$stale" | jq -r --arg cutoff "$cutoff_date" \
                '.[] | select(.createdAt < $cutoff) | "  #\(.number) \(.title) (\(.createdAt | split("T")[0])) [PROJECT]"'
        fi
    fi

    # Global stale
    if gh repo view "$GLOBAL_REPO" >/dev/null 2>&1; then
        local stale
        stale=$(gh issue list \
            --repo "$GLOBAL_REPO" \
            --label "$LABEL" \
            --state open \
            --json number,title,createdAt \
            2>/dev/null || echo "[]")

        echo "$stale" | jq -r --arg cutoff "$cutoff_date" \
            '.[] | select(.createdAt < $cutoff) | "  #\(.number) \(.title) (\(.createdAt | split("T")[0])) [GLOBAL]"'
    fi
}

cmd_count() {
    local scope="all"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) scope="project"; shift ;;
            --global)  scope="global"; shift ;;
            --all)     scope="all"; shift ;;
            *) shift ;;
        esac
    done

    local project_count=0
    local global_count=0
    local stale_count=0

    local cutoff_date
    cutoff_date=$(date -v-${STALE_DAYS}d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
                  date -d "${STALE_DAYS} days ago" '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
                  echo "")

    # Project count
    if [[ "$scope" == "project" || "$scope" == "all" ]]; then
        if is_git_repo; then
            local repo_name
            repo_name=$(get_repo_name)
            if [[ -n "$repo_name" ]]; then
                local issues
                issues=$(gh issue list \
                    --label "$LABEL" \
                    --state open \
                    --json number,createdAt \
                    --limit 100 \
                    2>/dev/null || echo "[]")
                project_count=$(echo "$issues" | jq 'length')

                if [[ -n "$cutoff_date" ]]; then
                    stale_count=$(echo "$issues" | jq --arg cutoff "$cutoff_date" \
                        '[.[] | select(.createdAt < $cutoff)] | length')
                fi
            fi
        fi
    fi

    # Global count
    if [[ "$scope" == "global" || "$scope" == "all" ]]; then
        if gh repo view "$GLOBAL_REPO" >/dev/null 2>&1; then
            local issues
            issues=$(gh issue list \
                --repo "$GLOBAL_REPO" \
                --label "$LABEL" \
                --state open \
                --json number,createdAt \
                --limit 100 \
                2>/dev/null || echo "[]")
            global_count=$(echo "$issues" | jq 'length')

            if [[ -n "$cutoff_date" ]]; then
                local gs
                gs=$(echo "$issues" | jq --arg cutoff "$cutoff_date" \
                    '[.[] | select(.createdAt < $cutoff)] | length')
                stale_count=$((stale_count + gs))
            fi
        fi
    fi

    # Output as pipe-delimited for easy parsing by hooks
    echo "${project_count}|${global_count}|${stale_count}"
}

# --- HUD (formatted listing for hook injection) ---

cmd_hud() {
    local max=5

    # Try project todos first, fall back to global
    local scope=""
    local issues=""
    local count=0

    if is_git_repo; then
        local repo_name
        repo_name=$(get_repo_name)
        if [[ -n "$repo_name" ]]; then
            local pj
            pj=$(gh issue list --label "$LABEL" --state open --limit 10 \
                --json number,title 2>/dev/null || echo "[]")
            count=$(echo "$pj" | jq 'length')
            if [[ "$count" -gt 0 ]]; then
                scope="PROJECT"
                issues="$pj"
            fi
        fi
    fi

    if [[ -z "$scope" ]]; then
        if gh repo view "$GLOBAL_REPO" >/dev/null 2>&1; then
            local gj
            gj=$(gh issue list --repo "$GLOBAL_REPO" --label "$LABEL" --state open \
                --limit 10 --json number,title 2>/dev/null || echo "[]")
            count=$(echo "$gj" | jq 'length')
            if [[ "$count" -gt 0 ]]; then
                scope="GLOBAL"
                issues="$gj"
            fi
        fi
    fi

    [[ -z "$scope" ]] && return 0

    # Get active claims for annotation
    local active_issues=""
    if [[ -f "$CLAIMS_FILE" ]]; then
        active_issues=$(cmd_active --json 2>/dev/null | jq -r '.[].issue' 2>/dev/null | tr '\n' ',' || echo "")
    fi

    echo "Todos (${scope} - ${count} open):"
    local shown=0
    while IFS= read -r line; do
        local num title entry
        num=$(echo "$line" | jq -r '.number')
        title=$(echo "$line" | jq -r '.title')
        entry="  #${num} ${title}"

        if echo ",$active_issues," | grep -q ",${num},"; then
            entry="${entry} ← active session"
        fi

        echo "$entry"
        shown=$((shown + 1))
        [[ "$shown" -ge "$max" ]] && break
    done < <(echo "$issues" | jq -c '.[]')

    local remaining=$((count - shown))
    if [[ "$remaining" -gt 0 ]]; then
        echo "  ... and ${remaining} more. Use /todos to review."
    else
        echo "  Use /todos to review."
    fi
}

# --- Active session tracking ---

cmd_claim() {
    local issue_number=""
    local scope="project"
    local source="manual"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) scope="global"; shift ;;
            --auto)   source="auto"; shift ;;
            *)
                if [[ -z "$issue_number" ]]; then
                    issue_number="$1"
                fi
                shift ;;
        esac
    done

    if [[ -z "$issue_number" ]]; then
        echo "ERROR: No issue number provided." >&2
        echo "Usage: todo.sh claim <number> [--global] [--auto]" >&2
        exit 1
    fi

    local repo=""
    if [[ "$scope" == "global" ]]; then
        repo="$GLOBAL_REPO"
    elif is_git_repo; then
        repo=$(get_repo_name)
    fi
    [[ -z "$repo" ]] && repo="$GLOBAL_REPO"

    local session_id="${CLAUDE_SESSION_ID:-$$}"
    local pid="${PPID:-$$}"
    local cwd="$PWD"
    local timestamp
    timestamp=$(date '+%s')

    mkdir -p "$CONFIG_DIR"

    # Remove existing claim for same session+issue (idempotent)
    if [[ -f "$CLAIMS_FILE" ]]; then
        local tmp="${CLAIMS_FILE}.tmp"
        grep -v "^${session_id}	.*	${issue_number}	${repo}	" "$CLAIMS_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$CLAIMS_FILE"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$session_id" "$pid" "$issue_number" "$repo" "$cwd" "$timestamp" "$source" \
        >> "$CLAIMS_FILE"

    echo "Claimed #${issue_number} (${repo}) [${source}]"
}

cmd_unclaim() {
    local session_id="${CLAUDE_SESSION_ID:-$$}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session=*) session_id="${1#--session=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ ! -f "$CLAIMS_FILE" ]]; then
        return 0
    fi

    local tmp="${CLAIMS_FILE}.tmp"
    grep -v "^${session_id}	" "$CLAIMS_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$CLAIMS_FILE"

    # Remove empty file
    [[ ! -s "$CLAIMS_FILE" ]] && rm -f "$CLAIMS_FILE"
}

cmd_active() {
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_output=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ ! -f "$CLAIMS_FILE" ]]; then
        $json_output && echo "[]"
        return 0
    fi

    local now
    now=$(date '+%s')
    local auto_ttl=$((8 * 3600))   # 8 hours
    local manual_ttl=$((24 * 3600)) # 24 hours
    local kept_lines=()

    while IFS=$'\t' read -r sid pid inum repo cwd ts src; do
        [[ -z "$sid" ]] && continue

        # Prune: PID dead
        if ! kill -0 "$pid" 2>/dev/null; then
            continue
        fi

        # Prune: TTL expired
        local age=$((now - ts))
        if [[ "$src" == "auto" && "$age" -gt "$auto_ttl" ]]; then
            continue
        fi
        if [[ "$src" == "manual" && "$age" -gt "$manual_ttl" ]]; then
            continue
        fi

        kept_lines+=("${sid}	${pid}	${inum}	${repo}	${cwd}	${ts}	${src}")
    done < "$CLAIMS_FILE"

    # Rewrite pruned file
    if [[ ${#kept_lines[@]} -gt 0 ]]; then
        printf '%s\n' "${kept_lines[@]}" > "$CLAIMS_FILE"
    else
        rm -f "$CLAIMS_FILE"
    fi

    # Output
    if $json_output; then
        if [[ ${#kept_lines[@]} -eq 0 ]]; then
            echo "[]"
            return 0
        fi
        local json="["
        local first=true
        for line in "${kept_lines[@]}"; do
            IFS=$'\t' read -r sid pid inum repo cwd ts src <<< "$line"
            $first || json+=","
            first=false
            json+="{\"session\":\"${sid}\",\"pid\":${pid},\"issue\":${inum},\"repo\":\"${repo}\",\"cwd\":\"${cwd}\",\"timestamp\":${ts},\"source\":\"${src}\"}"
        done
        json+="]"
        echo "$json"
    else
        if [[ ${#kept_lines[@]} -eq 0 ]]; then
            echo "No active claims."
            return 0
        fi
        for line in "${kept_lines[@]}"; do
            IFS=$'\t' read -r sid pid inum repo cwd ts src <<< "$line"
            echo "  #${inum} (${repo}) — session ${sid:0:8}… [${src}]"
        done
    fi
}

# --- Bootstrap (validate gh + resolve repo) ---

require_gh
resolve_global_repo

# --- Main dispatch ---

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    add)     cmd_add "$@" ;;
    list)    cmd_list "$@" ;;
    done)    cmd_done "$@" ;;
    stale)   cmd_stale "$@" ;;
    count)   cmd_count "$@" ;;
    claim)   cmd_claim "$@" ;;
    unclaim) cmd_unclaim "$@" ;;
    active)  cmd_active "$@" ;;
    hud)     cmd_hud "$@" ;;
    help|*)
        echo "Claude Code Todo System"
        echo ""
        echo "Usage:"
        echo "  todo.sh add \"title\" [--global] [--priority=high|medium|low] [--body=\"details\"]"
        echo "  todo.sh list [--project|--global|--all] [--json]"
        echo "  todo.sh done <issue-number> [--global|--repo=owner/repo]"
        echo "  todo.sh stale [--days=14]"
        echo "  todo.sh count [--project|--global|--all]"
        echo "  todo.sh claim <number> [--global] [--auto]"
        echo "  todo.sh unclaim [--session=ID]"
        echo "  todo.sh active [--json]"
        echo "  todo.sh hud"
        echo ""
        echo "Persistence: GitHub Issues labeled '$LABEL'"
        echo "Global repo: $GLOBAL_REPO"
        ;;
esac

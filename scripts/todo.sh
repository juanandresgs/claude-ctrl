#!/usr/bin/env bash
# todo.sh — Claude Code persistent idea capture backend.
#
# Purpose: Wraps the GitHub CLI (gh) to provide durable, visible todo/idea
# storage as GitHub Issues. Called by /backlog slash command and
# queried by hooks (session-init, session-summary) for automatic surfacing.
#
# @decision GitHub Issues over flat files — provides durability, visibility
# outside Claude Code (web/mobile/notifications), team access, search,
# and timestamps for staleness detection. gh CLI already in allowed perms.
# Flat files are invisible, easy to lose, and lack timestamps. Status: accepted.
#
# Commands:
#   add "title" [--global|--config] [--priority=high|medium|low] [--body="details"]
#   list [--project|--global|--config|--all] [--json] [--grouped]
#   done <issue-number> [--global|--config|--repo=owner/repo]
#   stale [--days=14]
#   count [--project|--global|--config|--all]
#   group <component> <issue-numbers...> [--global|--config]
#   ungroup <component> <issue-numbers...> [--global|--config]
#   attach <issue-number> <image-path> [--global|--config] [--gist]
#   images <issue-number> [--global|--config]
#   claim <issue-number> [--global|--config] [--auto]
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
TODO_IMAGES_DIR="$HOME/.claude/todo-images"

# --- Bootstrap ---

# @decision CONFIG_REPO derived from ~/.claude git remote rather than hardcoded.
# Rationale: follows the same dynamic-detection pattern as GLOBAL_REPO. If the user
# forks or moves the harness repo, it auto-adapts. Status: accepted.

# Verify gh CLI is installed and authenticated, exit with instructions if not.
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

# Resolve the global todo repository (user/cc-todos) via GitHub API, caching result.
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

# Derive config repo (owner/claude-ctrl) from ~/.claude git remote, caching result.
resolve_config_repo() {
    # Fast path: cached value
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        if [[ -n "${CONFIG_REPO:-}" ]]; then
            return 0
        fi
    fi

    # Slow path: derive from ~/.claude git remote
    local remote_url
    remote_url=$(git -C "$HOME/.claude" remote get-url origin 2>/dev/null) || {
        echo "WARNING: ~/.claude has no git remote. Cannot resolve config repo." >&2
        CONFIG_REPO=""
        return 1
    }

    # Parse owner/repo from SSH or HTTPS URL
    CONFIG_REPO=$(echo "$remote_url" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')

    # Append to existing config file
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "CONFIG_REPO=$CONFIG_REPO" >> "$CONFIG_FILE"
    else
        mkdir -p "$CONFIG_DIR"
        echo "CONFIG_REPO=$CONFIG_REPO" >> "$CONFIG_FILE"
    fi

    echo "Auto-detected config repo: $CONFIG_REPO → $CONFIG_FILE" >&2
}

# --- Cache ---

TODO_CACHE="$HOME/.claude/.todo-count"

# Write todo count to cache file for status bar enrichment.
update_todo_cache() {
    local count="${1:-0}"
    echo "$count" > "$TODO_CACHE"
}

# --- Helpers ---

# Check if current directory is inside a git repository.
is_git_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Get owner/repo slug for current repository via gh CLI.
get_repo_name() {
    if is_git_repo; then
        gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo ""
    fi
}

# Create claude-todo label in target repository if it doesn't exist.
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

# Create priority:high|medium|low label in target repository if it doesn't exist.
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

# Create component:<name> label in target repository if it doesn't exist.
ensure_component_label() {
    local component="$1"
    local repo="${2:-}"
    local repo_flag=""
    [[ -n "$repo" ]] && repo_flag="--repo $repo"

    gh label create "component:$component" \
        --description "Component: $component" \
        --color "5319e7" \
        $repo_flag 2>/dev/null || true
}

# --- Image helpers ---

# Save image to local cache directory with metadata for later upload.
save_image() {
    local image_path="$1"
    local repo_slug="$2"
    local issue_number="$3"

    if [[ ! -f "$image_path" ]]; then
        echo "ERROR: Image not found: $image_path" >&2
        return 1
    fi

    local dest_dir="$TODO_IMAGES_DIR/${repo_slug}/${issue_number}"
    mkdir -p "$dest_dir"

    local filename
    filename="$(date '+%s')-$(basename "$image_path")"
    cp "$image_path" "$dest_dir/$filename"

    echo "$dest_dir/$filename"
}

# Upload image to GitHub Gist, returning raw URL for markdown embedding.
upload_image_gist() {
    local image_path="$1"
    local description="${2:-Todo image attachment}"

    local gist_url
    gist_url=$(gh gist create "$image_path" --desc "$description" 2>/dev/null) || {
        echo "WARNING: Gist upload failed. Image saved locally only." >&2
        return 1
    }

    # Convert gist URL to raw URL for markdown embedding
    # gh gist create returns: https://gist.github.com/<user>/<id>
    local gist_id
    gist_id=$(basename "$gist_url")
    local filename
    filename=$(basename "$image_path")
    local raw_url="https://gist.githubusercontent.com/raw/${gist_id}/${filename}"

    echo "$raw_url"
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
    local body=""
    local image_path=""
    local use_gist=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global)
                scope="global"
                shift ;;
            --config)
                scope="config"
                shift ;;
            --priority=*)
                priority="${1#--priority=}"
                shift ;;
            --body=*)
                body="${1#--body=}"
                shift ;;
            --image=*)
                image_path="${1#--image=}"
                shift ;;
            --gist)
                use_gist=true
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
        echo "Usage: todo.sh add \"title\" [--global|--config] [--priority=high|medium|low]" >&2
        exit 1
    fi

    # Determine target repo
    local target_repo=""
    local repo_flag=""

    if [[ "$scope" == "config" ]]; then
        if [[ -z "${CONFIG_REPO:-}" ]]; then
            echo "ERROR: Config repo not resolved. Ensure ~/.claude has a git remote." >&2
            exit 1
        fi
        target_repo="$CONFIG_REPO"
        repo_flag="--repo $CONFIG_REPO"
    elif [[ "$scope" == "global" ]]; then
        ensure_global_repo
        target_repo="$GLOBAL_REPO"
        repo_flag="--repo $GLOBAL_REPO"
    elif is_git_repo; then
        target_repo=$(get_repo_name)
        if [[ -z "$target_repo" ]]; then
            echo "WARNING: In a git repo but no GitHub remote. Falling back to global." >&2
            ensure_global_repo
            target_repo="$GLOBAL_REPO"
            repo_flag="--repo $GLOBAL_REPO"
        fi
    else
        ensure_global_repo
        target_repo="$GLOBAL_REPO"
        repo_flag="--repo $GLOBAL_REPO"
    fi

    # Ensure labels exist
    ensure_label "$target_repo"

    # Build label list
    local labels="$LABEL"
    if [[ -n "$priority" ]]; then
        ensure_priority_label "$priority" "$target_repo"
        labels="$labels,priority:$priority"
    fi

    # Build structured body (use user-provided body or default template)
    local cwd
    cwd=$(pwd)
    local branch=""
    is_git_repo && branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [[ -z "$body" ]]; then
        body="## Problem
${title}

## Acceptance Criteria
- [ ] TBD

---
Captured via Claude Code /backlog

**Context:**
- Directory: \`$cwd\`"
        [[ -n "$branch" ]] && body="$body
- Branch: \`$branch\`"
        body="$body
- Captured: $(date '+%Y-%m-%d %H:%M')"
    else
        # User provided --body, append context
        body="$body

---
**Context:**
- Directory: \`$cwd\`"
        [[ -n "$branch" ]] && body="$body
- Branch: \`$branch\`"
        body="$body
- Captured: $(date '+%Y-%m-%d %H:%M')"
    fi

    # Create the issue
    local result
    result=$(gh issue create \
        --title "$title" \
        --body "$body" \
        --label "$labels" \
        $repo_flag 2>&1)

    echo "$result"

    # Handle image attachment if provided
    if [[ -n "$image_path" ]]; then
        # Extract issue number from result URL (format: https://github.com/owner/repo/issues/N)
        local new_issue_num
        new_issue_num=$(echo "$result" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' | tail -1)
        if [[ -n "$new_issue_num" ]]; then
            local repo_slug="${target_repo//\//-}"
            local saved
            saved=$(save_image "$image_path" "$repo_slug" "$new_issue_num") || true
            if [[ -n "${saved:-}" ]]; then
                echo "Image saved: $saved"
                local img_comment="**Attachment:** \`$(basename "$image_path")\`\nLocal: \`$saved\`"
                if $use_gist; then
                    local raw_url
                    raw_url=$(upload_image_gist "$image_path" "Attachment for #${new_issue_num} in ${target_repo}") || true
                    if [[ -n "${raw_url:-}" ]]; then
                        img_comment="![attachment](${raw_url})\n\n${img_comment}\nGist: ${raw_url}"
                        echo "Image uploaded: $raw_url"
                    fi
                fi
                gh issue comment "$new_issue_num" --body "$(echo -e "$img_comment")" $repo_flag 2>/dev/null || true
            fi
        fi
    fi

    # Increment cached todo count
    local cached=0
    [[ -f "$TODO_CACHE" ]] && cached=$(cat "$TODO_CACHE" 2>/dev/null || echo 0)
    update_todo_cache $((cached + 1))
}

cmd_list() {
    local scope="all"
    local json_output=false
    local grouped=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)  scope="project"; shift ;;
            --global)   scope="global"; shift ;;
            --config)   scope="config"; shift ;;
            --all)      scope="all"; shift ;;
            --json)     json_output=true; shift ;;
            --grouped)  grouped=true; shift ;;
            *) shift ;;
        esac
    done

    local has_output=false
    local all_issues="[]"

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
                    if $grouped; then
                        all_issues=$(echo "$all_issues" "$project_issues" | jq -s --arg repo "$repo_name" \
                            '.[0] + [.[1][] | . + {_scope: "project", _repo: $repo}]')
                    elif $json_output; then
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
                if $grouped; then
                    all_issues=$(echo "$all_issues" "$global_issues" | jq -s --arg repo "$GLOBAL_REPO" \
                        '.[0] + [.[1][] | . + {_scope: "global", _repo: $repo}]')
                elif $json_output; then
                    echo "$global_issues" | jq --arg repo "$GLOBAL_REPO" '{repo: $repo, scope: "global", issues: .}'
                else
                    echo "GLOBAL [$GLOBAL_REPO] ($count open):"
                    echo "$global_issues" | jq -r '.[] | "  #\(.number) \(.title) (\(.createdAt | split("T")[0]))"'
                fi
            fi
        fi
    fi

    # Config todos
    if [[ "$scope" == "config" || "$scope" == "all" ]]; then
        if [[ -n "${CONFIG_REPO:-}" ]] && gh repo view "$CONFIG_REPO" >/dev/null 2>&1; then
            local config_issues
            config_issues=$(gh issue list \
                --repo "$CONFIG_REPO" \
                --label "$LABEL" \
                --state open \
                --limit 10 \
                --json number,title,createdAt,labels \
                2>/dev/null || echo "[]")

            local count
            count=$(echo "$config_issues" | jq 'length')

            if [[ "$count" -gt 0 ]]; then
                has_output=true
                if $grouped; then
                    all_issues=$(echo "$all_issues" "$config_issues" | jq -s --arg repo "$CONFIG_REPO" \
                        '.[0] + [.[1][] | . + {_scope: "config", _repo: $repo}]')
                elif $json_output; then
                    echo "$config_issues" | jq --arg repo "$CONFIG_REPO" '{repo: $repo, scope: "config", issues: .}'
                else
                    echo "CONFIG [$CONFIG_REPO] ($count open):"
                    echo "$config_issues" | jq -r '.[] | "  #\(.number) \(.title) (\(.createdAt | split("T")[0]))"'
                fi
            fi
        fi
    fi

    # --- COMMUNITY section (not shown in --json or --grouped mode) ---
    if ! $json_output && ! $grouped; then
        COMMUNITY_STATUS_FILE="$HOME/.claude/.community-status"
        if [[ -f "$COMMUNITY_STATUS_FILE" ]]; then
            local comm_status
            comm_status=$(jq -r '.status // "none"' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "none")
            if [[ "$comm_status" == "active" ]]; then
                local comm_items
                comm_items=$(jq -r '.items // []' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "[]")
                local comm_count
                comm_count=$(echo "$comm_items" | jq 'length' 2>/dev/null || echo "0")

                if [[ "$comm_count" -gt 0 ]]; then
                    has_output=true
                    echo ""
                    echo "COMMUNITY ($comm_count items across your repos):"
                    echo "$comm_items" | jq -r '.[] |
                        if .type == "pr" then
                            "  PR #\(.number) on \(.repo) — \(.title) (by \(.author))"
                        else
                            "  Issue #\(.number) on \(.repo) — \(.title) (by \(.author))"
                        end' 2>/dev/null
                fi
            fi
        fi
    fi

    # Grouped output: display issues grouped by component:* label
    if $grouped && $has_output; then
        echo "$all_issues" | jq -r '
            [.[] | . + {
                _component: (
                    [.labels[].name | select(startswith("component:"))] | first // "ungrouped"
                    | sub("^component:"; "")
                )
            }]
            | group_by(._component)
            | sort_by(.[0]._component)
            | .[] | (
                "[\(.[0]._component | ascii_upcase)] (\(length) issues):",
                (.[] | "  #\(.number) \(.title) (\(.createdAt | split("T")[0])) [\(._scope)]")
            )'
        return
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
            --config) repo_flag="--repo $CONFIG_REPO"; shift ;;
            *) shift ;;
        esac
    done

    gh issue close "$issue_number" \
        --comment "Closed via Claude Code /backlog done" \
        $repo_flag 2>&1

    # Decrement cached todo count
    local cached=0
    [[ -f "$TODO_CACHE" ]] && cached=$(cat "$TODO_CACHE" 2>/dev/null || echo 0)
    [[ "$cached" -gt 0 ]] && cached=$((cached - 1))
    update_todo_cache "$cached"
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

    # Config stale
    if [[ -n "${CONFIG_REPO:-}" ]] && gh repo view "$CONFIG_REPO" >/dev/null 2>&1; then
        local stale
        stale=$(gh issue list \
            --repo "$CONFIG_REPO" \
            --label "$LABEL" \
            --state open \
            --json number,title,createdAt \
            2>/dev/null || echo "[]")

        echo "$stale" | jq -r --arg cutoff "$cutoff_date" \
            '.[] | select(.createdAt < $cutoff) | "  #\(.number) \(.title) (\(.createdAt | split("T")[0])) [CONFIG]"'
    fi
}

cmd_count() {
    local scope="all"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) scope="project"; shift ;;
            --global)  scope="global"; shift ;;
            --config)  scope="config"; shift ;;
            --all)     scope="all"; shift ;;
            *) shift ;;
        esac
    done

    local project_count=0
    local global_count=0
    local config_count=0
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

    # Config count
    if [[ "$scope" == "config" || "$scope" == "all" ]]; then
        if [[ -n "${CONFIG_REPO:-}" ]] && gh repo view "$CONFIG_REPO" >/dev/null 2>&1; then
            local issues
            issues=$(gh issue list \
                --repo "$CONFIG_REPO" \
                --label "$LABEL" \
                --state open \
                --json number,createdAt \
                --limit 100 \
                2>/dev/null || echo "[]")
            config_count=$(echo "$issues" | jq 'length')

            if [[ -n "$cutoff_date" ]]; then
                local cs
                cs=$(echo "$issues" | jq --arg cutoff "$cutoff_date" \
                    '[.[] | select(.createdAt < $cutoff)] | length')
                stale_count=$((stale_count + cs))
            fi
        fi
    fi

    # Output as pipe-delimited for easy parsing by hooks
    echo "${project_count}|${global_count}|${config_count}|${stale_count}"
}

# --- HUD (formatted listing for hook injection) ---

cmd_hud() {
    local max=5

    # @decision DEC-HUD-PARALLEL-001
    # @title Parallel todo HUD queries via background subshells + temp files
    # @status accepted
    # @rationale The original implementation tried project → global → config
    # sequentially, short-circuiting on the first non-empty result. Each gh
    # issue list call costs ~0.3-0.5s; in the worst case (no project todos) two
    # API calls ran serially. The fix: launch all three queries in parallel
    # background subshells, each writing to a temp file in a mktemp directory.
    # wait for all three, then pick the first non-empty result in project →
    # global → config priority order. Network-down / auth-fail paths produce
    # empty "[]" results, preserving original fallback behavior. Temp dir is
    # cleaned up in all exit paths via trap.

    local scope=""
    local issues=""
    local count=0

    # Create temp dir for parallel query results
    local _hud_tmpdir
    _hud_tmpdir=$(mktemp -d 2>/dev/null) || _hud_tmpdir=""
    if [[ -z "$_hud_tmpdir" ]]; then
        # mktemp failed — fall back to sequential behavior (best-effort)
        _hud_tmpdir=""
    fi

    # Cleanup on all exit paths
    _hud_cleanup() { [[ -n "${_hud_tmpdir:-}" ]] && rm -rf "$_hud_tmpdir"; }
    trap _hud_cleanup RETURN

    if [[ -n "$_hud_tmpdir" ]]; then
        local _pj_file="$_hud_tmpdir/project.json"
        local _gj_file="$_hud_tmpdir/global.json"
        local _cj_file="$_hud_tmpdir/config.json"

        # Launch parallel background queries
        # Project scope: only when inside a git repo
        if is_git_repo && [[ -n "$(get_repo_name 2>/dev/null)" ]]; then
            (gh issue list --label "$LABEL" --state open --limit 10 \
                --json number,title 2>/dev/null || echo "[]") > "$_pj_file" &
        else
            echo "[]" > "$_pj_file"
        fi

        # Global scope
        (gh issue list --repo "$GLOBAL_REPO" --label "$LABEL" --state open \
            --limit 10 --json number,title 2>/dev/null || echo "[]") > "$_gj_file" &

        # Config scope: only when CONFIG_REPO is set
        if [[ -n "${CONFIG_REPO:-}" ]]; then
            (gh issue list --repo "$CONFIG_REPO" --label "$LABEL" --state open \
                --limit 10 --json number,title 2>/dev/null || echo "[]") > "$_cj_file" &
        else
            echo "[]" > "$_cj_file"
        fi

        # Wait for all background queries to finish
        wait

        # Pick first non-empty result in priority order: project → global → config
        local _pj _gj _cj _pj_count _gj_count _cj_count
        _pj=$(cat "$_pj_file" 2>/dev/null || echo "[]")
        _gj=$(cat "$_gj_file" 2>/dev/null || echo "[]")
        _cj=$(cat "$_cj_file" 2>/dev/null || echo "[]")
        _pj_count=$(echo "$_pj" | jq 'length' 2>/dev/null || echo "0")
        _gj_count=$(echo "$_gj" | jq 'length' 2>/dev/null || echo "0")
        _cj_count=$(echo "$_cj" | jq 'length' 2>/dev/null || echo "0")

        if [[ "$_pj_count" -gt 0 ]]; then
            scope="PROJECT"; issues="$_pj"; count="$_pj_count"
        elif [[ "$_gj_count" -gt 0 ]]; then
            scope="GLOBAL";  issues="$_gj"; count="$_gj_count"
        elif [[ "$_cj_count" -gt 0 ]]; then
            scope="CONFIG";  issues="$_cj"; count="$_cj_count"
        fi
    else
        # Fallback: sequential queries (original behavior, no temp dir)
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

        if [[ -z "$scope" ]]; then
            if [[ -n "${CONFIG_REPO:-}" ]] && gh repo view "$CONFIG_REPO" >/dev/null 2>&1; then
                local cj
                cj=$(gh issue list --repo "$CONFIG_REPO" --label "$LABEL" --state open \
                    --limit 10 --json number,title 2>/dev/null || echo "[]")
                count=$(echo "$cj" | jq 'length')
                if [[ "$count" -gt 0 ]]; then
                    scope="CONFIG"
                    issues="$cj"
                fi
            fi
        fi
    fi

    if [[ -z "$scope" ]]; then
        update_todo_cache 0
        return 0
    fi

    # Authoritative cache sync — real count from API
    update_todo_cache "$count"

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
        echo "  ... and ${remaining} more. Use /backlog to review."
    else
        echo "  Use /backlog to review."
    fi

    # Add community one-liner if items exist
    COMMUNITY_STATUS_FILE="$HOME/.claude/.community-status"
    if [[ -f "$COMMUNITY_STATUS_FILE" ]]; then
        local comm_status
        comm_status=$(jq -r '.status // "none"' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "none")
        if [[ "$comm_status" == "active" ]]; then
            local comm_prs comm_issues
            comm_prs=$(jq -r '.total_prs // 0' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "0")
            comm_issues=$(jq -r '.total_issues // 0' "$COMMUNITY_STATUS_FILE" 2>/dev/null || echo "0")

            if [[ "$comm_prs" -gt 0 || "$comm_issues" -gt 0 ]]; then
                echo ""
                local comm_text=""
                if [[ "$comm_prs" -gt 0 && "$comm_issues" -gt 0 ]]; then
                    local pr_s=""; [[ "$comm_prs" -ne 1 ]] && pr_s="s"
                    local issue_s=""; [[ "$comm_issues" -ne 1 ]] && issue_s="s"
                    comm_text="${comm_prs} PR${pr_s} + ${comm_issues} issue${issue_s}"
                elif [[ "$comm_prs" -gt 0 ]]; then
                    local pr_s=""; [[ "$comm_prs" -ne 1 ]] && pr_s="s"
                    comm_text="${comm_prs} PR${pr_s}"
                else
                    local issue_s=""; [[ "$comm_issues" -ne 1 ]] && issue_s="s"
                    comm_text="${comm_issues} issue${issue_s}"
                fi
                echo "Community: ${comm_text} across your repos (use /backlog to see details)"
            fi
        fi
    fi
}

# --- Component grouping ---

cmd_group() {
    local component=""
    local scope="project"
    local issues=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) scope="global"; shift ;;
            --config) scope="config"; shift ;;
            *)
                if [[ -z "$component" ]]; then
                    component="$1"
                else
                    issues+=("${1#\#}")  # Strip leading # if present
                fi
                shift ;;
        esac
    done

    if [[ -z "$component" || ${#issues[@]} -eq 0 ]]; then
        echo "ERROR: Usage: todo.sh group <component> <issue-numbers...> [--global|--config]" >&2
        exit 1
    fi

    local repo="" repo_flag=""
    if [[ "$scope" == "config" ]]; then
        repo="$CONFIG_REPO"; repo_flag="--repo $CONFIG_REPO"
    elif [[ "$scope" == "global" ]]; then
        repo="$GLOBAL_REPO"; repo_flag="--repo $GLOBAL_REPO"
    elif is_git_repo; then
        repo=$(get_repo_name)
    fi
    [[ -z "$repo" ]] && repo="$GLOBAL_REPO" && repo_flag="--repo $GLOBAL_REPO"

    ensure_component_label "$component" "$repo"

    for num in "${issues[@]}"; do
        if gh issue edit "$num" --add-label "component:$component" $repo_flag >/dev/null 2>&1; then
            echo "#${num} <- component:${component}"
        else
            echo "ERROR: Failed to label #${num}" >&2
        fi
    done
}

cmd_ungroup() {
    local component=""
    local scope="project"
    local issues=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) scope="global"; shift ;;
            --config) scope="config"; shift ;;
            *)
                if [[ -z "$component" ]]; then
                    component="$1"
                else
                    issues+=("${1#\#}")
                fi
                shift ;;
        esac
    done

    if [[ -z "$component" || ${#issues[@]} -eq 0 ]]; then
        echo "ERROR: Usage: todo.sh ungroup <component> <issue-numbers...> [--global|--config]" >&2
        exit 1
    fi

    local repo_flag=""
    if [[ "$scope" == "config" ]]; then
        repo_flag="--repo $CONFIG_REPO"
    elif [[ "$scope" == "global" ]]; then
        repo_flag="--repo $GLOBAL_REPO"
    elif is_git_repo; then
        : # no flag needed for current repo
    else
        repo_flag="--repo $GLOBAL_REPO"
    fi

    for num in "${issues[@]}"; do
        if gh issue edit "$num" --remove-label "component:$component" $repo_flag >/dev/null 2>&1; then
            echo "#${num} -x- component:${component}"
        else
            echo "ERROR: Failed to unlabel #${num}" >&2
        fi
    done
}

# --- Image attachments ---

cmd_attach() {
    local issue_number=""
    local image_path=""
    local scope="project"
    local use_gist=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) scope="global"; shift ;;
            --config) scope="config"; shift ;;
            --gist)   use_gist=true; shift ;;
            *)
                if [[ -z "$issue_number" ]]; then
                    issue_number="${1#\#}"
                elif [[ -z "$image_path" ]]; then
                    image_path="$1"
                fi
                shift ;;
        esac
    done

    if [[ -z "$issue_number" || -z "$image_path" ]]; then
        echo "ERROR: Usage: todo.sh attach <issue-number> <image-path> [--global|--config] [--gist]" >&2
        exit 1
    fi

    local repo="" repo_flag=""
    if [[ "$scope" == "config" ]]; then
        repo="$CONFIG_REPO"; repo_flag="--repo $CONFIG_REPO"
    elif [[ "$scope" == "global" ]]; then
        repo="$GLOBAL_REPO"; repo_flag="--repo $GLOBAL_REPO"
    elif is_git_repo; then
        repo=$(get_repo_name)
    fi
    [[ -z "$repo" ]] && repo="$GLOBAL_REPO" && repo_flag="--repo $GLOBAL_REPO"

    # Normalize repo slug for filesystem (owner/repo → owner-repo)
    local repo_slug="${repo//\//-}"

    # Save locally
    local saved_path
    saved_path=$(save_image "$image_path" "$repo_slug" "$issue_number") || exit 1
    echo "Saved: $saved_path"

    # Optionally upload to gist
    local comment_body="**Attachment:** \`$(basename "$image_path")\`\nLocal: \`$saved_path\`"
    if $use_gist; then
        local raw_url
        raw_url=$(upload_image_gist "$image_path" "Attachment for #${issue_number} in ${repo}") || true
        if [[ -n "${raw_url:-}" ]]; then
            comment_body="![attachment](${raw_url})\n\n${comment_body}\nGist: ${raw_url}"
            echo "Uploaded: $raw_url"
        fi
    fi

    # Add comment to issue with image reference
    gh issue comment "$issue_number" --body "$(echo -e "$comment_body")" $repo_flag 2>&1
}

cmd_images() {
    local issue_number=""
    local scope="project"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) scope="global"; shift ;;
            --config) scope="config"; shift ;;
            *)
                if [[ -z "$issue_number" ]]; then
                    issue_number="${1#\#}"
                fi
                shift ;;
        esac
    done

    if [[ -z "$issue_number" ]]; then
        echo "ERROR: Usage: todo.sh images <issue-number> [--global|--config]" >&2
        exit 1
    fi

    local repo=""
    if [[ "$scope" == "config" ]]; then
        repo="$CONFIG_REPO"
    elif [[ "$scope" == "global" ]]; then
        repo="$GLOBAL_REPO"
    elif is_git_repo; then
        repo=$(get_repo_name)
    fi
    [[ -z "$repo" ]] && repo="$GLOBAL_REPO"

    local repo_slug="${repo//\//-}"
    local img_dir="$TODO_IMAGES_DIR/${repo_slug}/${issue_number}"

    if [[ ! -d "$img_dir" ]]; then
        echo "No images for #${issue_number}."
        return 0
    fi

    local count=0
    echo "Images for #${issue_number} (${repo}):"
    for f in "$img_dir"/*; do
        [[ -f "$f" ]] || continue
        echo "  $(basename "$f") — $f"
        count=$((count + 1))
    done

    if [[ "$count" -eq 0 ]]; then
        echo "  (none)"
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
            --config) scope="config"; shift ;;
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
        echo "Usage: todo.sh claim <number> [--global|--config] [--auto]" >&2
        exit 1
    fi

    local repo=""
    if [[ "$scope" == "config" ]]; then
        repo="$CONFIG_REPO"
    elif [[ "$scope" == "global" ]]; then
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

    # Surface any attached images
    local repo_slug="${repo//\//-}"
    local img_dir="$TODO_IMAGES_DIR/${repo_slug}/${issue_number}"
    if [[ -d "$img_dir" ]]; then
        local img_count=0
        for f in "$img_dir"/*; do
            [[ -f "$f" ]] && img_count=$((img_count + 1))
        done
        if [[ "$img_count" -gt 0 ]]; then
            echo "  $img_count image(s) attached. Use 'todo.sh images $issue_number' to view."
        fi
    fi
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
resolve_config_repo || true  # Non-fatal if ~/.claude has no remote

# --- Main dispatch ---

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    add)      cmd_add "$@" ;;
    list)     cmd_list "$@" ;;
    done)     cmd_done "$@" ;;
    stale)    cmd_stale "$@" ;;
    count)    cmd_count "$@" ;;
    group)    cmd_group "$@" ;;
    ungroup)  cmd_ungroup "$@" ;;
    attach)   cmd_attach "$@" ;;
    images)   cmd_images "$@" ;;
    claim)    cmd_claim "$@" ;;
    unclaim)  cmd_unclaim "$@" ;;
    active)   cmd_active "$@" ;;
    hud)      cmd_hud "$@" ;;
    help|*)
        echo "Claude Code Todo System"
        echo ""
        echo "Usage:"
        echo "  todo.sh add \"title\" [--global|--config] [--priority=high|medium|low] [--body=\"details\"] [--image=path] [--gist]"
        echo "  todo.sh list [--project|--global|--config|--all] [--json] [--grouped]"
        echo "  todo.sh done <issue-number> [--global|--config|--repo=owner/repo]"
        echo "  todo.sh stale [--days=14]"
        echo "  todo.sh count [--project|--global|--config|--all]"
        echo "  todo.sh group <component> <issue-numbers...> [--global|--config]"
        echo "  todo.sh ungroup <component> <issue-numbers...> [--global|--config]"
        echo "  todo.sh attach <issue-number> <image-path> [--global|--config] [--gist]"
        echo "  todo.sh images <issue-number> [--global|--config]"
        echo "  todo.sh claim <number> [--global|--config] [--auto]"
        echo "  todo.sh unclaim [--session=ID]"
        echo "  todo.sh active [--json]"
        echo "  todo.sh hud"
        echo ""
        echo "Scopes:"
        echo "  --project  Current repo (default when in a git repo)"
        echo "  --global   Global backlog ($GLOBAL_REPO)"
        echo "  --config   Harness config repo (${CONFIG_REPO:-not configured})"
        echo ""
        echo "Persistence: GitHub Issues labeled '$LABEL'"
        ;;
esac

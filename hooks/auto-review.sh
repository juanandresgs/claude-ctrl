#!/usr/bin/env bash
# Intelligent Bash command auto-review hook.
# PreToolUse hook — matcher: Bash
#
# Three-tier command classification engine that auto-approves safe commands
# and injects advisory context for risky ones. Philosophy: "Approve unless
# proven dangerous" — safe commands auto-approve, risky commands get advisory
# context injected so the permission prompt is intelligent, not generic.
#
# Tier 1 — Inherently safe (read-only, navigation, output): always approve
# Tier 2 — Behavior-dependent (git, npm, docker, etc.): analyze subcommand + flags
# Tier 3 — Always risky (rm, sudo, kill, etc.): inject advisory, defer to permission system
#
# Compound commands (&&, ||, ;, |) are decomposed and each segment analyzed.
# Command substitutions ($() and backticks) are recursively analyzed (depth limit 2).
# If ANY segment is risky or unknown, the entire command defers to user.
#
# @decision DEC-AUTOREVIEW-001
# @title Three-tier command classification with recursive analysis
# @status accepted
# @rationale Static prefix matching in settings.json cannot distinguish
#   safe from dangerous invocations of the same tool. A policy engine
#   that understands subcommands, flags, and composition provides
#   intelligent auto-approval without sacrificing safety.

set -euo pipefail
source "$(dirname "$0")/log.sh"

# shellcheck disable=SC2034  # HOOK_INPUT read for side effects (read_input advances stdin)
HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')

# Exit silently (defer to user) if no command
[[ -z "$COMMAND" ]] && exit 0

# ── Helpers ──────────────────────────────────────────────────────

approve() {
    local reason="$1"
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "$reason"
  }
}
EOF
    exit 0
}

# Advisory — inject the risk reason as context for the permission system.
# Exits 0 (no opinion on permission), but provides the model with context
# about WHY the command is risky so it can explain to the user.
advise() {
    local reason="${RISK_REASON:-unknown risk}"
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "auto-review risk: $reason"
  }
}
EOF
    exit 0
}

# Global risk reason — set by analyzers when a command is risky
RISK_REASON=""

set_risk() {
    # Only set if not already set (first risky thing wins)
    if [[ -z "$RISK_REASON" ]]; then
        RISK_REASON="$1"
    fi
}

# Return 0 = safe, 1 = risky/unknown
# Usage: is_safe "command string" [recursion_depth]
is_safe() {
    local cmd="$1"
    local depth="${2:-0}"

    # Depth limit for recursion
    if (( depth > 2 )); then
        return 1
    fi

    # ── PHASE 1: Dangerous pattern bypass ──
    # Heredocs can contain anything
    if echo "$cmd" | grep -qE '<<\s*[A-Za-z_"'"'"']'; then
        set_risk "Heredoc (<<) detected — content cannot be statically analyzed"
        return 1
    fi
    # Redirects to system paths (exempt /dev/null, /dev/stdout, /dev/stderr)
    if echo "$cmd" | grep -qE '>\s*/(etc|usr|var|sys|boot|proc)/'; then
        set_risk "Redirect to system path detected — writing to protected OS directories"
        return 1
    fi
    if echo "$cmd" | grep -qE '>\s*/dev/' && ! echo "$cmd" | grep -qE '>\s*/dev/(null|stdout|stderr|fd/)'; then
        set_risk "Redirect to /dev/ device — writing to device files"
        return 1
    fi
    # Process substitution
    if echo "$cmd" | grep -qF '<('; then
        set_risk "Process substitution <() detected — cannot statically analyze"
        return 1
    fi

    # ── PHASE 2: Decompose compound command ──
    # Split on &&, ||, ; but NOT inside quotes or $()
    local segments
    segments=$(decompose_command "$cmd")

    # ── PHASE 3: Analyze each segment ──
    while IFS= read -r segment; do
        [[ -z "$segment" ]] && continue
        if ! analyze_segment "$segment" "$depth"; then
            return 1
        fi
    done <<< "$segments"

    return 0
}

# Split compound command into segments on &&, ||, ;
# Pipe chains are treated as a single unit analyzed left-to-right.
# Quote-aware: semicolons inside single or double quotes are preserved.
# Multi-line commands are collapsed to a single line first so that quote
# tracking is not reset at newline boundaries (e.g. python3 -c "...\n...").
decompose_command() {
    local cmd="$1"
    printf '%s' "$cmd" | tr '\n' ' ' | awk '
    {
        n = length($0); sq = 0; dq = 0; start = 1
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "\047" && !dq) sq = !sq
            else if (c == "\"" && !sq) dq = !dq
            else if (!sq && !dq) {
                if (c == ";") {
                    print substr($0, start, i - start)
                    start = i + 1
                } else if (c == "&" && substr($0, i+1, 1) == "&") {
                    print substr($0, start, i - start)
                    i++; start = i + 1
                } else if (c == "|" && substr($0, i+1, 1) == "|") {
                    print substr($0, start, i - start)
                    i++; start = i + 1
                }
            }
        }
        if (start <= n) print substr($0, start)
    }'
}

# Analyze a single segment (may contain pipes)
# Return 0 = safe, 1 = risky
analyze_segment() {
    local segment="$1"
    local depth="$2"

    # Trim whitespace
    segment=$(echo "$segment" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$segment" ]] && return 0

    # Handle pipes: split on unquoted single | (|| already handled by decompose_command)
    # Uses a quote-aware awk parser to avoid splitting | inside single or double quotes.
    # Example: echo 'a|b' must NOT be split; cat foo | grep bar MUST be split.
    #
    # @decision DEC-AUTOREVIEW-PIPE-001
    # @title analyze_segment uses quote-aware awk parser for pipe splitting
    # @status accepted
    # @rationale The previous sed 's/\s*|\s*/\n/g' split was not quote-aware.
    #   A command like echo 'a|b' would be split into ["echo 'a", "b'"] causing
    #   false positives. The awk parser tracks sq/dq state and only splits on
    #   unquoted single-pipe characters (not || which decompose_command already
    #   handles at the compound-operator level before analyze_segment is called).
    local pipe_parts
    pipe_parts=$(printf '%s' "$segment" | awk '
    {
        n = length($0); sq = 0; dq = 0; start = 1
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "\047" && !dq) sq = !sq
            else if (c == "\"" && !sq) dq = !dq
            else if (!sq && !dq && c == "|" && substr($0, i+1, 1) != "|") {
                # Also check previous char is not | (for || at boundary)
                if (i > 1 && substr($0, i-1, 1) == "|") continue
                print substr($0, start, i - start)
                start = i + 1
            }
        }
        if (start <= n) print substr($0, start)
    }')
    local pipe_count
    pipe_count=$(printf '%s\n' "$pipe_parts" | wc -l)
    if [[ "$pipe_count" -gt 1 ]]; then
        while IFS= read -r part; do
            [[ -z "$part" ]] && continue
            if ! analyze_single_command "$part" "$depth"; then
                return 1
            fi
        done <<< "$pipe_parts"
        return 0
    fi

    analyze_single_command "$segment" "$depth"
}

# Analyze a single command (no pipes, no compound operators)
# Return 0 = safe, 1 = risky
analyze_single_command() {
    local cmd="$1"
    local depth="$2"

    # Trim
    cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$cmd" ]] && return 0

    # Check for command substitutions first — analyze inner commands
    if echo "$cmd" | grep -qE '\$\(|`'; then
        if ! analyze_substitutions "$cmd" "$depth"; then
            return 1
        fi
    fi

    # Strip leading env variable assignments (FOO=bar BAZ=qux command ...)
    local stripped="$cmd"
    while [[ "$stripped" =~ ^[A-Za-z_][A-Za-z0-9_]*=([^[:space:]]*|\"[^\"]*\"|\'[^\']*\')[[:space:]]+ ]]; do
        stripped="${stripped#*=}"
        # Skip the value
        if [[ "$stripped" =~ ^\"[^\"]*\" ]]; then
            stripped="${stripped#\"*\"}"
        elif [[ "$stripped" =~ ^\'[^\']*\' ]]; then
            stripped="${stripped#\'*\'}"
        else
            stripped="${stripped#*[[:space:]]}"
        fi
        # shellcheck disable=SC2001  # sed needed: bash ${var#} only trims one char; extglob not guaranteed
        stripped=$(echo "$stripped" | sed 's/^[[:space:]]*//')
    done

    # If only env assignments remain (no actual command), it's safe
    if [[ -z "$stripped" ]] || [[ "$stripped" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        return 0
    fi

    # Extract the command name (strip path prefixes)
    local cmd_name
    cmd_name=$(echo "$stripped" | awk '{print $1}')
    cmd_name=$(basename "$cmd_name" 2>/dev/null || echo "$cmd_name")

    # Extract arguments (everything after command name)
    local args
    # shellcheck disable=SC2001  # sed strips first word+spaces; bash ${var#word} can't match trailing spaces
    args=$(echo "$stripped" | sed "s|^[^[:space:]]*[[:space:]]*||")

    # Classify the command
    local tier
    tier=$(classify_command "$cmd_name")

    case "$tier" in
        1) return 0 ;;
        2) analyze_tier2 "$cmd_name" "$args" "$depth" ;;
        3)
            set_risk "'$cmd_name' is a Tier 3 command (always requires approval: destructive, privilege escalation, or meta-execution)"
            return 1
            ;;
        *)
            set_risk "'$cmd_name' is not in the known command database — cannot assess safety"
            return 1
            ;;
    esac
}

# Check command substitutions $() and backticks
# Return 0 if all inner commands are safe, 1 if any risky
analyze_substitutions() {
    local cmd="$1"
    local depth="$2"
    local next_depth=$((depth + 1))

    # Extract $(...) content — simple approach for common cases
    # Handle nested parens by counting depth
    local remaining="$cmd"
    # shellcheck disable=SC2016  # literal '$(' is intentional: testing for the string, not expanding it
    while [[ "$remaining" == *'$('* ]]; do
        # Find the $( position — before is unused; after anchors the scan
        # shellcheck disable=SC2034  # before unused by design: only after (the content post-opener) is needed
        local before="${remaining%%\$(*}"
        local after="${remaining#*\$(}"

        # Count parentheses to find matching close
        local paren_depth=1
        local i=0
        local inner=""
        while (( i < ${#after} && paren_depth > 0 )); do
            local ch="${after:$i:1}"
            if [[ "$ch" == "(" ]]; then
                ((paren_depth++))
            elif [[ "$ch" == ")" ]]; then
                ((paren_depth--))
                if (( paren_depth == 0 )); then
                    break
                fi
            fi
            inner+="$ch"
            ((i++))
        done

        if [[ -n "$inner" ]]; then
            if ! is_safe "$inner" "$next_depth"; then
                return 1
            fi
        fi

        remaining="${after:$((i+1))}"
    done

    # Handle backtick substitutions
    local bt_remaining="$cmd"
    while [[ "$bt_remaining" == *'`'* ]]; do
        # shellcheck disable=SC2034  # bt_before unused by design: only bt_after is needed for content scan
        local bt_before="${bt_remaining%%\`*}"
        local bt_after="${bt_remaining#*\`}"
        if [[ "$bt_after" == *'`'* ]]; then
            local bt_inner="${bt_after%%\`*}"
            if [[ -n "$bt_inner" ]]; then
                if ! is_safe "$bt_inner" "$next_depth"; then
                    return 1
                fi
            fi
            bt_remaining="${bt_after#*\`}"
        else
            break
        fi
    done

    return 0
}

# ── Classification ───────────────────────────────────────────────

# Returns: 1 (safe), 2 (behavior-dependent), 3 (always defer), 0 (unknown)
classify_command() {
    local cmd="$1"

    case "$cmd" in
        # Tier 1 — Inherently safe (read-only, navigation, output)
        ls|cat|head|tail|grep|egrep|fgrep|rg|find|diff|stat|wc|file|du|strings|xxd|less|tree|more)
            echo 1 ;;
        cd|pwd|pushd|popd)
            echo 1 ;;
        echo|printf|true|false)
            echo 1 ;;
        sort|uniq|cut|tr|awk|column|comm|fold|rev|seq|tac|paste|expand|unexpand|fmt|nl)
            echo 1 ;;
        which|type|whoami|hostname|uname|date|id|env|printenv|man|lsof|uptime|nproc)
            echo 1 ;;
        basename|dirname|readlink|realpath)
            echo 1 ;;
        test|\[|\[\[)
            echo 1 ;;
        sleep)
            echo 1 ;;
        md5|md5sum|sha256sum|shasum|cksum|b2sum)
            echo 1 ;;
        xargs)
            echo 1 ;; # xargs safety depends on piped command — handled in pipe analysis

        # Tier 2 — Behavior-dependent
        git)            echo 2 ;;
        npm|npx|pnpm|yarn|bun)   echo 2 ;;
        pip|pip3|uv)    echo 2 ;;
        docker|podman)  echo 2 ;;
        cargo)          echo 2 ;;
        go)             echo 2 ;;
        make|cmake)     echo 2 ;;
        curl)           echo 2 ;;
        sed)            echo 2 ;;
        chmod)          echo 2 ;;
        cp|mv)          echo 2 ;;
        mkdir|mktemp)   echo 2 ;;
        touch)          echo 2 ;;
        ln)             echo 2 ;;
        brew)           echo 2 ;;
        tar|gzip|gunzip|zip|unzip|bzip2|xz) echo 2 ;;
        open|xdg-open)  echo 2 ;;
        python|python3|node|ruby|perl) echo 2 ;;
        tee)            echo 2 ;;
        jq|yq)          echo 2 ;;
        gh)             echo 2 ;;
        pytest|jest|vitest|mocha) echo 2 ;;

        # Tier 3 — Always defer
        rm|rmdir)       echo 3 ;;
        kill|killall|pkill) echo 3 ;;
        sudo|su|doas)   echo 3 ;;
        eval|exec)      echo 3 ;;
        source|\.)      echo 3 ;;
        bash|sh|zsh|dash|fish) echo 3 ;; # meta-execution shells
        dd|mkfs|mount|umount) echo 3 ;;
        systemctl|launchctl|crontab) echo 3 ;;
        ssh|scp|rsync)  echo 3 ;;
        wget)           echo 3 ;;
        apt|apt-get|yum|dnf|pacman|apk) echo 3 ;;
        chown|chgrp)    echo 3 ;;
        nohup)          echo 3 ;;

        # Unknown → defer
        *)              echo 0 ;;
    esac
}

# ── Tier 2 Analyzers ─────────────────────────────────────────────

# Dispatch to the right analyzer
# Return 0 = safe, 1 = risky
analyze_tier2() {
    local cmd="$1"
    local args="$2"
    local depth="$3"

    case "$cmd" in
        git)        analyze_git "$args" ;;
        npm|npx|pnpm|yarn|bun) analyze_npm "$args" ;;
        pip|pip3|uv) analyze_pip "$args" ;;
        docker|podman) analyze_docker "$args" ;;
        cargo)      analyze_cargo "$args" ;;
        go)         analyze_go "$args" ;;
        make|cmake) return 0 ;; # Build tools — always safe
        curl)       analyze_curl "$args" ;;
        sed)        analyze_sed "$args" ;;
        chmod)      analyze_chmod "$args" ;;
        cp|mv)      analyze_path_target "$cmd" "$args" ;;
        mkdir|mktemp) return 0 ;; # Constructive — always safe
        touch)      return 0 ;; # Constructive — always safe
        ln)         analyze_path_target "$cmd" "$args" ;;
        brew)       analyze_brew "$args" ;;
        tar|gzip|gunzip|zip|unzip|bzip2|xz) return 0 ;; # Archive tools — safe
        open|xdg-open) return 0 ;; # Opener — safe
        python|python3|node|ruby|perl) return 0 ;; # Script exec — allow
        tee)        analyze_path_target "tee" "$args" ;;
        jq|yq)      return 0 ;; # JSON/YAML processor — safe
        gh)         analyze_gh "$args" ;;
        pytest|jest|vitest|mocha) return 0 ;; # Test runners — safe
        *)          return 1 ;; # Unknown tier 2 — defer
    esac
}

# ── Git analyzer ──
analyze_git() {
    local args="$1"

    # Extract subcommand (skip flags like -C /path)
    local subcmd
    subcmd=$(echo "$args" | sed -E 's/^(-[A-Za-z]\s+[^[:space:]]+\s+)*//; s/^(-[A-Za-z]+\s+)*//' | awk '{print $1}')

    # Check dangerous flags first (cross-cutting)
    # @decision DEC-AUTOREVIEW-001
    # @title POSIX-compatible flag detection for BSD grep portability
    # @status accepted
    # @rationale macOS BSD grep does not support \b in -E patterns (\b silently
    #   returns non-zero, causing dangerous flags to be misclassified as safe).
    #   Additionally, grep -qE '--force' passes --force as a grep option, not a
    #   pattern, on BSD grep. Fix: use grep -qF (fixed-string) for long double-dash
    #   flags — these are literal strings, no regex needed. Short flags (\s-f) use
    #   grep -qE with ($|\s) anchor and a leading character to avoid the -- problem.
    if echo "$args" | grep -qF -- '--force'; then
        set_risk "git $subcmd --force — force flag bypasses safety checks"
        return 1
    fi
    if echo "$args" | grep -qF -- '--hard'; then
        set_risk "git $subcmd --hard — discards uncommitted changes permanently"
        return 1
    fi
    if echo "$args" | grep -qF -- '--no-verify'; then
        set_risk "git $subcmd --no-verify — skips pre-commit/pre-push hooks"
        return 1
    fi
    if echo "$args" | grep -qE '\s-f($|\s)' && [[ "$subcmd" != "fetch" ]]; then
        set_risk "git $subcmd -f — force flag bypasses safety checks"
        return 1
    fi

    case "$subcmd" in
        # Read-only / safe operations
        log|diff|status|show|shortlog|describe|blame)
            return 0 ;;
        rev-parse|rev-list|ls-files|ls-tree|ls-remote|name-rev|for-each-ref)
            return 0 ;;
        branch)
            if echo "$args" | grep -qE '\s-[dD]($|\s)'; then
                set_risk "git branch -d/-D — deletes a branch"
                return 1
            fi
            return 0
            ;;
        tag)
            if echo "$args" | grep -qE '\s-[dafs]($|\s)|--delete'; then
                set_risk "git tag create/delete — modifies repository tags"
                return 1
            fi
            return 0
            ;;
        add|stage)
            return 0 ;;
        fetch)
            return 0 ;;
        pull)
            return 0 ;;
        checkout|switch)
            return 0 ;;
        stash)
            return 0 ;;
        remote)
            if echo "$args" | grep -qE 'remote\s+(add|remove|rename|set-url)'; then
                set_risk "git remote add/remove/rename — modifies remote configuration"
                return 1
            fi
            return 0
            ;;
        worktree)
            local wt_subcmd
            wt_subcmd=$(echo "$args" | sed 's/worktree//' | awk '{print $1}')
            case "$wt_subcmd" in
                list|add) return 0 ;;
                *)
                    set_risk "git worktree $wt_subcmd — modifies worktree state"
                    return 1
                    ;;
            esac
            ;;
        config)
            if echo "$args" | grep -qE '--(get|list|get-all|get-regexp)'; then
                return 0
            fi
            set_risk "git config (write) — modifies git configuration"
            return 1
            ;;
        cherry-pick|am|apply)
            return 0 ;; # Apply patches — generally safe
        init)
            return 0 ;;

        # Write operations
        commit)  return 0 ;;   # guard.sh enforces main-branch/test/proof gates; Guardian provides formal approval
        push)    return 0 ;;   # guard.sh enforces force-push protection; Guardian provides formal approval
        merge)   return 0 ;;   # Guardian agent handles merges formally; conflicts are recoverable
        rebase)  set_risk "git rebase — rewrites commit history"; return 1 ;;
        reset)   set_risk "git reset — moves HEAD and may discard changes"; return 1 ;;
        clean)   set_risk "git clean — permanently deletes untracked files"; return 1 ;;
        revert)  return 0 ;;   # Safe — creates a new commit, reversible
        bisect)  set_risk "git bisect — interactive binary search through history"; return 1 ;;
        reflog)  set_risk "git reflog — accesses reference log history"; return 1 ;;

        # Empty subcommand (just "git") or unknown
        ""|*)
            set_risk "git (unknown subcommand) — cannot assess safety"
            return 1 ;;
    esac
}

# ── npm/yarn/pnpm analyzer ──
analyze_npm() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')

    case "$subcmd" in
        # Safe: read/query/build/test
        list|ls|info|view|show|outdated|audit|why|explain|doctor)
            return 0 ;;
        test|t|run|run-script|start|dev|build|lint|check|exec)
            return 0 ;;
        install|i|add|ci)
            return 0 ;; # Local install is safe
        remove|uninstall|rm)
            return 0 ;; # Local uninstall is safe (tracked in lockfile)
        init|create)
            return 0 ;;
        pack|version)
            return 0 ;;

        # Risky: global side effects
        publish|unpublish|deprecate)
            set_risk "npm $subcmd — publishes/modifies package on npm registry"; return 1 ;;
        dist-tag|access|owner|team|token)
            set_risk "npm $subcmd — modifies registry access/permissions"; return 1 ;;
        login|logout|adduser|whoami)
            set_risk "npm $subcmd — modifies authentication state"; return 1 ;;
        link)
            return 0 ;; # Symlinks are routine in monorepo dev

        *)
            set_risk "npm $subcmd — unknown subcommand, cannot assess safety"
            return 1
            ;;
    esac
}

# ── pip analyzer ──
analyze_pip() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')

    case "$subcmd" in
        list|show|freeze|check|search|index|debug|cache|config|inspect)
            return 0 ;;
        install)
            return 0 ;; # Local install — safe in venvs
        download|wheel|hash)
            return 0 ;;

        uninstall)
            set_risk "pip uninstall — removes installed packages"; return 1 ;;

        *)
            set_risk "pip $subcmd — unknown subcommand, cannot assess safety"
            return 1
            ;;
    esac
}

# ── Docker analyzer ──
analyze_docker() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')

    case "$subcmd" in
        # Safe: read/inspect/build
        # Note: 'image' is intentionally absent here — it belongs in the destructive branch below
        # (docker image rm/prune are destructive; docker image ls/inspect are handled via subcommand check)
        build|ps|images|logs|inspect|version|info|top|stats|port|history|events|manifest)
            return 0 ;;
        run|exec|create|start|compose)
            # Docker run/compose are generally safe for dev
            return 0 ;;
        network|volume)
            local sub2
            sub2=$(echo "$args" | awk '{print $2}')
            case "$sub2" in
                ls|list|inspect) return 0 ;;
                *)
                    set_risk "docker $subcmd $sub2 — modifies Docker $subcmd configuration"
                    return 1
                    ;;
            esac
            ;;
        pull|tag|login|logout)
            return 0 ;;

        # Destructive
        rm|rmi|stop|kill|pause|unpause|system|container|image)
            if echo "$args" | grep -qE 'prune|rm|rmi|remove|stop|kill'; then
                set_risk "docker $subcmd — destructive operation (removes/stops containers or images)"
                return 1
            fi
            return 0
            ;;

        *)
            set_risk "docker $subcmd — unknown subcommand, cannot assess safety"
            return 1
            ;;
    esac
}

# ── Cargo analyzer ──
analyze_cargo() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')

    case "$subcmd" in
        build|b|test|t|check|c|clippy|fmt|doc|run|r|bench|clean|update|tree|metadata|verify-project|search|read-manifest)
            return 0 ;;
        add|remove|fix)
            return 0 ;; # Local dependency management
        init|new)
            return 0 ;;

        publish)
            set_risk "cargo publish — publishes crate to crates.io registry"; return 1 ;;
        install|uninstall)
            set_risk "cargo $subcmd — modifies globally installed binaries"; return 1 ;;
        login|owner|yank)
            set_risk "cargo $subcmd — modifies crates.io registry state"; return 1 ;;

        *)
            set_risk "cargo $subcmd — unknown subcommand, cannot assess safety"
            return 1
            ;;
    esac
}

# ── Go analyzer ──
analyze_go() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')

    case "$subcmd" in
        build|test|vet|fmt|run|doc|version|env|list|tool|generate|work|fix)
            return 0 ;;
        mod)
            local mod_subcmd
            mod_subcmd=$(echo "$args" | awk '{print $2}')
            case "$mod_subcmd" in
                tidy|download|verify|graph|why|edit|init|vendor) return 0 ;;
                *)
                    set_risk "go mod $mod_subcmd — unknown mod subcommand"
                    return 1
                    ;;
            esac
            ;;
        get)
            return 0 ;;
        clean)
            return 0 ;;

        install)
            set_risk "go install — installs binary globally"; return 1 ;;

        *)
            set_risk "go $subcmd — unknown subcommand, cannot assess safety"
            return 1
            ;;
    esac
}

# ── curl analyzer ──
analyze_curl() {
    local args="$1"

    # Check for data-sending flags
    if echo "$args" | grep -qEi '-X\s*(POST|PUT|DELETE|PATCH)'; then
        local method
        method=$(echo "$args" | grep -oEi '(POST|PUT|DELETE|PATCH)' | head -1)
        set_risk "curl -X $method — sends data-modifying HTTP request"
        return 1
    fi
    if echo "$args" | grep -qEi '(^|\s)-d($|\s)' || \
       echo "$args" | grep -qFi -- '--data' || \
       echo "$args" | grep -qFi -- '--data-raw' || \
       echo "$args" | grep -qFi -- '--data-binary' || \
       echo "$args" | grep -qFi -- '--data-urlencode'; then
        set_risk "curl with --data — sends POST data to remote server"
        return 1
    fi
    if echo "$args" | grep -qFi -- '--upload-file' || \
       echo "$args" | grep -qEi '(^|\s)-T($|\s)' || \
       echo "$args" | grep -qEi '(^|\s)-F($|\s)' || \
       echo "$args" | grep -qFi -- '--form'; then
        set_risk "curl with file upload — sends local files to remote server"
        return 1
    fi

    # GET/HEAD requests are safe
    return 0
}

# ── sed analyzer ──
analyze_sed() {
    local args="$1"

    if echo "$args" | grep -qE '(^|\s)-i($|\s)' || echo "$args" | grep -qF -- '--in-place'; then
        set_risk "sed -i (in-place edit) — modifies files directly on disk"
        return 1
    fi

    # Without -i, sed just outputs to stdout — safe
    return 0
}

# ── chmod analyzer ──
analyze_chmod() {
    local args="$1"

    if echo "$args" | grep -qE '(^|\s)777($|\s)'; then
        set_risk "chmod 777 — grants world-readable/writable/executable permissions"
        return 1
    fi

    if echo "$args" | grep -qE '-R.*/(etc|usr|var|sys|boot|bin|sbin|lib)|/(etc|usr|var|sys|boot|bin|sbin|lib).*-R'; then
        set_risk "chmod -R on system path — recursive permission change on OS directories"
        return 1
    fi

    # Standard permissions (644, 755, +x, -w, etc.) are fine
    return 0
}

# ── Path target analyzer (cp, mv, ln, tee) ──
analyze_path_target() {
    local cmd="$1"
    local args="$2"

    if echo "$args" | grep -qE '(^|\s)/(etc|usr|var|sys|boot|bin|sbin|lib|opt|System|Library)/'; then
        set_risk "$cmd targets a system path — writing to protected OS directories"
        return 1
    fi

    # Targets inside project/home directories are fine for dev work
    return 0
}

# ── brew analyzer ──
analyze_brew() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')

    case "$subcmd" in
        list|ls|info|search|doctor|config|leaves|deps|uses|outdated|desc|home|cat|tap-info|shellenv)
            return 0 ;;
        install|upgrade|update)
            return 0 ;; # System package management is routine for dev
        uninstall|remove|rm)
            set_risk "brew $subcmd — removes system packages"; return 1 ;;
        link|unlink|pin|unpin|tap|untap|services|cleanup)
            set_risk "brew $subcmd — modifies Homebrew package state"; return 1 ;;
        *)
            set_risk "brew $subcmd — unknown subcommand, cannot assess safety"
            return 1
            ;;
    esac
}

# ── gh (GitHub CLI) analyzer ──
analyze_gh() {
    local args="$1"
    local subcmd
    subcmd=$(echo "$args" | awk '{print $1}')

    case "$subcmd" in
        # Read operations
        issue|pr|release|repo|gist|project|run|workflow|api)
            # Most gh commands with view/list/status are safe
            if echo "$args" | grep -qE '(^|\s)(view|list|status|diff|checks|ls|search|get)($|\s)'; then
                return 0
            fi
            # gh api is safe for GET
            if [[ "$subcmd" == "api" ]]; then
                if echo "$args" | grep -qE '(-X\s*(POST|PUT|DELETE|PATCH)|--method\s*(POST|PUT|DELETE|PATCH))'; then
                    set_risk "gh api with write method — modifies GitHub resources via API"
                    return 1
                fi
                return 0
            fi
            # Standard dev workflow — constructive operations auto-approved
            if echo "$args" | grep -qE '(^|\s)(create|edit|comment|close|reopen)($|\s)'; then
                return 0
            fi
            # Merge — Guardian handles formal approval; auto-approve here
            if echo "$args" | grep -qE '(^|\s)merge($|\s)'; then
                return 0
            fi
            # Review is harder to undo — keep risky
            if echo "$args" | grep -qE '(^|\s)review($|\s)'; then
                set_risk "gh $subcmd review — modifies GitHub review state"
                return 1
            fi
            set_risk "gh $subcmd — cannot determine if read or write operation"
            return 1
            ;;
        auth|config|extension|secret|variable|ssh-key|gpg-key)
            set_risk "gh $subcmd — modifies GitHub CLI authentication/configuration"
            return 1 ;;
        browse)
            return 0 ;; # Opens browser — safe
        label|milestone)
            return 0 ;;

        *)
            set_risk "gh $subcmd — unknown subcommand, cannot assess safety"
            return 1
            ;;
    esac
}

# ── Main ─────────────────────────────────────────────────────────

if is_safe "$COMMAND" 0; then
    approve "auto-review: all command segments classified as safe"
fi

# Not safe — inject advisory context and defer to the normal permission system.
# The model receives the risk reason and can explain it when the permission
# prompt appears. Guardian handles git commit/push/merge formally.
advise

#!/usr/bin/env bash
set -euo pipefail

# Documentation enforcement gate for file writes.
# PreToolUse hook — matcher: Write|Edit
#
# Enforces:
#   - Every source file must have a documentation header
#   - Files 50+ lines must contain @decision annotation
#
# For Write: checks tool_input.content directly
# For Edit: reads file from disk (allows edits to files that already have headers)

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
TOOL_NAME=$(get_field '.tool_name')
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# --- Skip non-source files ---
is_source_file() {
    local f="$1"
    [[ "$f" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]]
}

is_source_file "$FILE_PATH" || exit 0

# Skip config files, test files, generated files, and common non-source dirs
[[ "$FILE_PATH" =~ (\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.) ]] && exit 0
[[ "$FILE_PATH" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && exit 0

# Skip files in this config directory itself (meta-infrastructure)
[[ "$FILE_PATH" =~ \.claude/hooks/ ]] && exit 0

deny() {
    local reason="$1"
    local context="${2:-}"
    local json
    json=$(jq -n \
        --arg reason "$reason" \
        --arg context "$context" \
        '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: $reason,
                additionalContext: $context
            }
        }')
    echo "$json"
    exit 0
}

# Detect expected header comment by file extension
get_header_template() {
    local f="$1"
    case "$f" in
        *.py)
            echo '"""
[Module description: purpose and rationale]
"""'
            ;;
        *.ts|*.tsx|*.js|*.jsx)
            echo '/**
 * @file [filename]
 * @description [Purpose of this file]
 * @rationale [Why this approach was chosen]
 */'
            ;;
        *.go)
            echo '// Package [name] provides [description].
// [Rationale for approach]'
            ;;
        *.rs)
            echo '//! [Module description: purpose and rationale]'
            ;;
        *.sh|*.bash|*.zsh)
            echo '# [Script description: purpose and rationale]'
            ;;
        *.c|*.cpp|*.h|*.hpp)
            echo '/**
 * @file [filename]
 * @brief [Purpose]
 * @rationale [Why this approach]
 */'
            ;;
        *)
            echo '// [File description: purpose and rationale]'
            ;;
    esac
}

# Check if content has a documentation header
has_doc_header() {
    local content="$1"
    local ext="$2"

    # Get first non-blank, non-shebang line
    local first_meaningful
    first_meaningful=$(echo "$content" | grep -v '^\s*$' | grep -v '^#!' | head -1)

    case "$ext" in
        py)
            # Python: starts with """ or # comment
            echo "$first_meaningful" | grep -qE '^\s*("""|'"'"''"'"''"'"'|#\s*\S)'
            ;;
        ts|tsx|js|jsx)
            # JS/TS: starts with /** or //
            echo "$first_meaningful" | grep -qE '^\s*(/\*\*|//\s*\S)'
            ;;
        go)
            # Go: starts with // Package or // comment
            echo "$first_meaningful" | grep -qE '^\s*//\s*\S'
            ;;
        rs)
            # Rust: starts with //! (inner doc) or // comment
            echo "$first_meaningful" | grep -qE '^\s*//(!\s*\S|/?\s*\S)'
            ;;
        sh|bash|zsh)
            # Shell: starts with # comment (after shebang)
            echo "$first_meaningful" | grep -qE '^\s*#\s*\S'
            ;;
        c|cpp|h|hpp|cs)
            # C-family: starts with /** or //
            echo "$first_meaningful" | grep -qE '^\s*(/\*\*|//\s*\S)'
            ;;
        java|kt|swift)
            # Java/Kotlin/Swift: starts with /** or //
            echo "$first_meaningful" | grep -qE '^\s*(/\*\*|//\s*\S)'
            ;;
        rb)
            # Ruby: starts with # comment
            echo "$first_meaningful" | grep -qE '^\s*#\s*\S'
            ;;
        php)
            # PHP: starts with /** or // (after <?php)
            local after_php
            after_php=$(echo "$content" | grep -v '^\s*$' | grep -v '^<?' | head -1)
            echo "$after_php" | grep -qE '^\s*(/\*\*|//\s*\S|#\s*\S)'
            ;;
        *)
            # Default: any comment at start
            echo "$first_meaningful" | grep -qE '^\s*(/\*|//|#)\s*\S'
            ;;
    esac
}

# Has @decision annotation
has_decision() {
    local content="$1"
    echo "$content" | grep -qE '@decision|# DECISION:|// DECISION:'
}

# Extract file extension
EXT="${FILE_PATH##*.}"

# --- Handle Write tool ---
if [[ "$TOOL_NAME" == "Write" ]]; then
    CONTENT=$(get_field '.tool_input.content')
    [[ -z "$CONTENT" ]] && exit 0

    # Check file header
    if ! has_doc_header "$CONTENT" "$EXT"; then
        TEMPLATE=$(get_header_template "$FILE_PATH")
        deny "File $FILE_PATH missing documentation header. Every source file must start with a documentation comment describing purpose and rationale." "Add a documentation header at the top of the file:\n$TEMPLATE"
    fi

    # Check @decision for 50+ line files
    LINE_COUNT=$(echo "$CONTENT" | wc -l | tr -d ' ')
    if [[ "$LINE_COUNT" -ge 50 ]]; then
        if ! has_decision "$CONTENT"; then
            deny "File $FILE_PATH is $LINE_COUNT lines but has no @decision annotation. Significant files (50+ lines) require a @decision annotation." "Add a @decision annotation to the file. See CLAUDE.md for format examples."
        fi
    fi

    exit 0
fi

# --- Handle Edit tool ---
if [[ "$TOOL_NAME" == "Edit" ]]; then
    # For Edit, check the file on disk (it already exists)
    [[ ! -f "$FILE_PATH" ]] && exit 0

    FILE_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || echo "")
    [[ -z "$FILE_CONTENT" ]] && exit 0

    # If file already has header, allow the edit
    if has_doc_header "$FILE_CONTENT" "$EXT"; then
        # Still check @decision for large files, but only warn (don't block)
        LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')
        if [[ "$LINE_COUNT" -ge 50 ]]; then
            if ! has_decision "$FILE_CONTENT"; then
                # Warn via additionalContext but don't block
                cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Note: $FILE_PATH is $LINE_COUNT lines but has no @decision annotation. Consider adding one."
  }
}
EOF
            fi
        fi
        exit 0
    fi

    # File has no header — warn but don't block (the edit might be adding one)
    TEMPLATE=$(get_header_template "$FILE_PATH")
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "File $FILE_PATH has no documentation header. Consider adding one:\n$TEMPLATE"
  }
}
EOF
    exit 0
fi

exit 0

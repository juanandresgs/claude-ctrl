#!/usr/bin/env bash
# Documentation freshness enforcement gate for git commit and merge commands.
# PreToolUse hook — matcher: Bash
#
# @decision DEC-DOCFRESH-003
# @title doc-freshness.sh fires only on git commit/merge, not all Bash commands
# @status accepted
# @rationale Checking doc freshness on every Bash command would add latency to
#   every shell operation. The hook uses the same early-exit gate as guard.sh:
#   strip quoted strings, then check if 'git commit' or 'git merge' appears in
#   a command position. All other commands exit immediately (0ms overhead).
#
# @decision DEC-DOCFRESH-004
# @title Branch commits are advisory-only; merges to main/master can block
# @status accepted
# @rationale Blocking mid-feature commits on a branch creates too much friction —
#   the developer is iterating, not shipping. The merge to main is the natural
#   integration point where stale docs become a liability. This mirrors the
#   pattern in guard.sh (test gate only blocks merge, not branch commits).
#   Warn tier always shows message; block tier denies merge to main/master only.
#
# @decision DEC-DOCFRESH-005
# @title @no-doc bypass logged to .doc-drift for observatory SIG-DOC-BYPASS-RATE
# @status accepted
# @rationale An unconditional block frustrates legitimate cases (docs being
#   updated in a follow-up commit, doc rewrite in progress). @no-doc in the
#   commit message is the escape hatch. All bypasses are logged so the
#   observatory can detect if @no-doc becomes a permanent workaround (>30%
#   bypass rate signals the enforcement is too aggressive or docs are too stale).
set -euo pipefail

# --- Fail-closed crash trap (same pattern as guard.sh DEC-INTEGRITY-002) ---
_DOCFRESH_COMPLETED=false
_docfresh_deny_on_crash() {
    if [[ "$_DOCFRESH_COMPLETED" != "true" ]]; then
        cat <<'CRASHJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SAFETY: doc-freshness.sh crashed before completing checks. Command denied as precaution. Run: bash -n ~/.claude/hooks/doc-freshness.sh to diagnose."
  }
}
CRASHJSON
    fi
}
trap '_docfresh_deny_on_crash' EXIT

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')

# Exit silently if no command
if [[ -z "$COMMAND" ]]; then
    _DOCFRESH_COMPLETED=true
    exit 0
fi

# --- Early-exit gate: only process git commit/merge commands ---
# Strip quoted strings to avoid false matches in commit messages like "fix git committing"
_stripped=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
if ! echo "$_stripped" | grep -qE '(^|&&|\|\|?|;)\s*git\s+[^|;&]*\b(commit|merge)\b'; then
    _DOCFRESH_COMPLETED=true
    exit 0
fi

# Emit advisory output (allow with reason), then exit.
_docfresh_advisory() {
    local msg="$1"
    # Escape for JSON
    local escaped_msg
    escaped_msg=$(printf '%s' "$msg" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": $escaped_msg
  }
}
EOF
    _DOCFRESH_COMPLETED=true
    exit 0
}

# Emit deny output, then exit.
_docfresh_deny() {
    local reason="$1"
    local escaped_reason
    escaped_reason=$(printf '%s' "$reason" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $escaped_reason
  }
}
EOF
    _DOCFRESH_COMPLETED=true
    exit 0
}

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# --- Detect operation type ---
IS_MERGE=false
IS_MAIN_MERGE=false
if echo "$_stripped" | grep -qE '(^|&&|\|\|?|;)\s*git\s+[^|;&]*\bmerge\b'; then
    IS_MERGE=true
    # Check if merging into main/master
    CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
        IS_MAIN_MERGE=true
    fi
fi

# --- Bypass check 1: @no-doc in commit message ---
# Matches -m "..." and HEREDOC commit messages containing @no-doc
if echo "$COMMAND" | grep -qiE '@no-doc'; then
    # Log bypass to .doc-drift
    _DOC_DRIFT="${CLAUDE_DIR}/.doc-drift"
    if [[ -f "$_DOC_DRIFT" ]]; then
        _prev_bypass=$(grep '^bypass_count=' "$_DOC_DRIFT" 2>/dev/null | cut -d= -f2 || echo "0")
        _new_bypass=$(( _prev_bypass + 1 ))
        _tmp_drift="${_DOC_DRIFT}.tmp.$$"
        sed "s/^bypass_count=.*/bypass_count=${_new_bypass}/" "$_DOC_DRIFT" > "$_tmp_drift" 2>/dev/null \
            && mv "$_tmp_drift" "$_DOC_DRIFT" || rm -f "$_tmp_drift"
    fi
    _docfresh_advisory "DOC-BYPASS: @no-doc flag detected — doc freshness check skipped. Bypass logged to .doc-drift."
fi

# --- Bypass check 2: doc-only commit (only .md files staged) ---
STAGED_FILES=$(git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null || echo "")
if [[ -n "$STAGED_FILES" ]]; then
    NON_MD_STAGED=$(echo "$STAGED_FILES" | grep -v '\.md$' | grep -v '^$' || true)
    if [[ -z "$NON_MD_STAGED" ]]; then
        # All staged files are .md — doc-only commit, skip gate silently
        _DOCFRESH_COMPLETED=true
        exit 0
    fi
fi

# --- Get doc freshness data ---
get_doc_freshness "$PROJECT_ROOT"

# Nothing stale? Allow silently.
if [[ "$DOC_STALE_COUNT" -eq 0 && -z "$DOC_MOD_ADVISORY" ]]; then
    _DOCFRESH_COMPLETED=true
    exit 0
fi

# --- Bypass check 3: commit includes stale docs → reduce severity one tier ---
# For each doc in DENY list that appears in STAGED_FILES, downgrade to WARN.
# For each doc in WARN list that appears in STAGED_FILES, clear it entirely.
EFFECTIVE_DENY="$DOC_STALE_DENY"
EFFECTIVE_WARN="$DOC_STALE_WARN"

if [[ -n "$STAGED_FILES" ]]; then
    if [[ -n "$EFFECTIVE_DENY" ]]; then
        NEW_DENY=""
        for doc in $EFFECTIVE_DENY; do
            if echo "$STAGED_FILES" | grep -qxF "$doc" 2>/dev/null; then
                # Doc included — downgrade deny → warn
                EFFECTIVE_WARN="${EFFECTIVE_WARN:+$EFFECTIVE_WARN }$doc"
            else
                NEW_DENY="${NEW_DENY:+$NEW_DENY }$doc"
            fi
        done
        EFFECTIVE_DENY="$NEW_DENY"
    fi

    if [[ -n "$EFFECTIVE_WARN" ]]; then
        NEW_WARN=""
        for doc in $EFFECTIVE_WARN; do
            if ! echo "$STAGED_FILES" | grep -qxF "$doc" 2>/dev/null; then
                NEW_WARN="${NEW_WARN:+$NEW_WARN }$doc"
            fi
            # Doc included in commit → clear from warn (tier reduction)
        done
        EFFECTIVE_WARN="$NEW_WARN"
    fi
fi

# --- Build diagnostic helper ---
_doc_diag() {
    local doc="$1"
    local doc_path="$PROJECT_ROOT/$doc"
    local doc_age="unknown age"
    if git -C "$PROJECT_ROOT" log -1 --format='%cr' -- "$doc" 2>/dev/null | grep -q .; then
        doc_age=$(git -C "$PROJECT_ROOT" log -1 --format='%cr' -- "$doc" 2>/dev/null)
    fi
    echo "$doc (last updated $doc_age)"
}

# --- Enforcement decision ---

# On merge to main/master: block if any DENY tier docs remain after bypass reductions
if [[ "$IS_MAIN_MERGE" == "true" && -n "$EFFECTIVE_DENY" ]]; then
    DIAG=""
    for doc in $EFFECTIVE_DENY; do
        DIAG="${DIAG}
  - $(_doc_diag "$doc")"
    done
    _docfresh_deny "DOC-STALE BLOCK: Cannot merge to main — documentation is stale and must be updated before merging.

Stale docs requiring update:${DIAG}

Options:
  1. Update the listed docs and include them in this commit
  2. Add @no-doc to your commit message to bypass (logged to .doc-drift)

$DOC_FRESHNESS_SUMMARY"
fi

# Advisory: warn tier docs (on any commit) or deny-tier on branch commits
WARN_DOCS="${EFFECTIVE_DENY:+$EFFECTIVE_DENY }${EFFECTIVE_WARN}"
WARN_DOCS="${WARN_DOCS## }"
WARN_DOCS="${WARN_DOCS%% }"

if [[ -n "$WARN_DOCS" ]]; then
    DIAG=""
    for doc in $WARN_DOCS; do
        DIAG="${DIAG}
  - $(_doc_diag "$doc")"
    done
    _docfresh_advisory "DOC-STALE ADVISORY: Documentation may need updating.

Docs with stale indicators:${DIAG}

Branch commits are advisory-only. This becomes a block on merge to main.
Add @no-doc to bypass. $DOC_FRESHNESS_SUMMARY"
fi

# Modification churn advisory
if [[ -n "$DOC_MOD_ADVISORY" ]]; then
    _docfresh_advisory "DOC-MOD ADVISORY: High modification churn (>60%) in scope of: $DOC_MOD_ADVISORY — consider reviewing whether a doc update is needed."
fi

# All checks passed
_DOCFRESH_COMPLETED=true
exit 0

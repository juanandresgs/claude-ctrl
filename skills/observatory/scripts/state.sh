#!/usr/bin/env bash
# state.sh — Observatory v2 Phase 2: simplified state CRUD library
#
# Purpose: Manage persistent observatory state (state.json v4).
#          Provides init_state, get_pending, transition, log_action functions
#          used by analyze.sh, converge.sh, report.sh, and SKILL.md workflow.
#
# @decision DEC-OBS-V2-017
# @title State schema v4 — suggestions embedded in state.json
# @status accepted
# @rationale v3 state stored suggestions as SUG-*.json files in observatory/suggestions/
#             and tracked only implemented/rejected/deferred IDs in state.json. This
#             caused SUG-ID instability (renumbered on every run) and required
#             cross-file lookups. v4 embeds full suggestion objects directly in state.json
#             under .suggestions[], with stable IDs (SUG-001, SUG-002, ...) that never
#             change. Each suggestion has a metric field (for convergence_check evaluation)
#             and a status lifecycle: proposed → implemented → converged | ineffective.
#             The suggestions/ directory is no longer needed.
#
# @decision DEC-OBS-V2-018
# @title v3→v4 migration preserves implemented history in legacy section
# @status accepted
# @rationale v3 state.json had implemented[] (object array with sug_id/signal_id/implemented_at)
#             and rejected[] (plain strings). v4 migration moves these into a legacy_history
#             section under state.json so they remain inspectable but don't pollute the
#             new suggestions[] lifecycle. The migration detects version < 4 and runs
#             automatically in init_state(). The migration is idempotent (version check).
#
# @decision DEC-OBS-V2-005
# @title Sourceable library pattern retained from v3
# @status accepted
# @rationale state.sh is designed to be sourced (not executed) by other scripts.
#             This avoids subprocess overhead and lets callers share shell state.
#             Functions use OBS_DIR/STATE_FILE/HISTORY_FILE env vars so callers
#             can override paths for testing (isolation approach from DEC-OBS-003).
#             Removed: v1/v2 migration code (~40 lines), SUG-NNN known-map (~20 lines),
#             complex defer signature logic, auto_resurface, get_reassessable.
#
# Usage: source skills/observatory/scripts/state.sh
#        init_state
#        transition "SUG-001" "implemented"
#        log_action "analyzed" '{"trace_count": 358}'

set -euo pipefail

# --- Configuration (override via env for testing) ---
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
OBS_DIR="${OBS_DIR:-${CLAUDE_DIR}/observatory}"
STATE_FILE="${STATE_FILE:-${OBS_DIR}/state.json}"
HISTORY_FILE="${HISTORY_FILE:-${OBS_DIR}/history.jsonl}"

# --- _migrate_v3_to_v4 ---
# Internal: migrate state.json from v3 to v4 schema in-place.
# v3: has implemented[], rejected[], deferred[], pending_suggestion fields
# v4: has suggestions[] array with embedded objects, legacy_history for old data
#
# Migration is idempotent: checks .version before acting.
_migrate_v3_to_v4() {
    local version
    version=$(jq -r '.version // 1' "$STATE_FILE" 2>/dev/null || echo "1")

    if [[ "$version" -lt 4 ]]; then
        local tmp="${STATE_FILE}.tmp"
        local now
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        jq --arg now "$now" '
        {
            "version": 4,
            "last_analysis_at": (.last_analysis_at // $now),
            "suggestions": [],
            "legacy_history": {
                "migrated_at": $now,
                "source_version": (.version // 1),
                "implemented": (.implemented // []),
                "rejected": (.rejected // []),
                "deferred": (.deferred // [])
            }
        }
        ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    fi
}

# --- init_state ---
# Create observatory/state.json with empty v4 initial state if it does not exist.
# Idempotent: safe to call multiple times. Migrates v3 and earlier on existing files.
init_state() {
    mkdir -p "$OBS_DIR"
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'EOF'
{
  "version": 4,
  "last_analysis_at": null,
  "suggestions": []
}
EOF
    else
        # Migrate if needed (any version < 4)
        _migrate_v3_to_v4
    fi
}

# --- get_pending ---
# Return the first proposed suggestion ID, or "null" if none.
# Output: suggestion ID string (e.g. "SUG-001") or "null"
get_pending() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "null"
        return
    fi
    jq -r '
      (.suggestions // []) | map(select(.status == "proposed")) |
      if length > 0 then .[0].id else "null" end
    ' "$STATE_FILE" 2>/dev/null || echo "null"
}

# --- transition ---
# Move a suggestion to a new status and update state.json accordingly.
# Usage: transition "SUG-001" "implemented|rejected|deferred"
# - implemented: sets implemented_at timestamp
# - rejected:    marks rejected with timestamp
# - deferred:    marks deferred with timestamp (use for user-deferred suggestions)
transition() {
    local sug_id="$1"
    local new_status="$2"

    init_state

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp
    tmp="${STATE_FILE}.tmp"

    case "$new_status" in
        implemented)
            jq --arg id "$sug_id" \
               --arg ts "$ts" \
               --arg status "implemented" \
               '
               .suggestions = [
                   .suggestions[] |
                   if .id == $id then
                       . + {"status": $status, "implemented_at": $ts}
                   else .
                   end
               ]
               ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            log_action "implemented" "{\"id\": \"$sug_id\"}"
            ;;
        rejected)
            jq --arg id "$sug_id" \
               --arg ts "$ts" \
               --arg status "rejected" \
               '
               .suggestions = [
                   .suggestions[] |
                   if .id == $id then
                       . + {"status": $status, "rejected_at": $ts}
                   else .
                   end
               ]
               ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            log_action "rejected" "{\"id\": \"$sug_id\"}"
            ;;
        deferred)
            jq --arg id "$sug_id" \
               --arg ts "$ts" \
               --arg status "deferred" \
               '
               .suggestions = [
                   .suggestions[] |
                   if .id == $id then
                       . + {"status": $status, "deferred_at": $ts}
                   else .
                   end
               ]
               ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            log_action "deferred" "{\"id\": \"$sug_id\"}"
            ;;
        *)
            echo "ERROR: unknown status '$new_status'. Use: implemented|rejected|deferred" >&2
            return 1
            ;;
    esac
}

# --- log_action ---
# Append an action record to history.jsonl.
# Usage: log_action "action_name" '{"key": "value"}'
log_action() {
    local action="$1"
    local details="${2:-{}}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$(dirname "$HISTORY_FILE")"
    jq -cn \
        --arg ts "$ts" \
        --arg action "$action" \
        --argjson details "$details" \
        '{"ts": $ts, "action": $action, "details": $details}' \
        >> "$HISTORY_FILE" 2>/dev/null || true
}

# --- list_suggestions ---
# Print suggestions table to stdout.
# Usage: list_suggestions [status_filter]  (default: all)
list_suggestions() {
    local filter="${1:-all}"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No state file found. Run /observatory to initialize."
        return
    fi
    local filter_expr="."
    if [[ "$filter" != "all" ]]; then
        filter_expr="map(select(.status == \"$filter\"))"
    fi
    jq -r \
        --arg filter "$filter" \
        "(.suggestions // []) | $filter_expr | .[] |
        \"[\(.status)] \(.id): \(.title)\n  Metric: \(.metric) = \(.metric_value_at_suggestion // \"?\")\n  Convergence: \(.convergence_check)\n\"
        " "$STATE_FILE" 2>/dev/null || echo "No suggestions found."
}

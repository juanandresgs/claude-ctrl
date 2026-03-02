#!/usr/bin/env bash
# gaps-report.sh — Unified accountability gaps report for Claude Code projects.
#
# Purpose: Aggregates all accountability gaps into a single markdown (or JSON)
# report. Combines open backlog issues, untracked code markers, decision drift
# data, and staleness metrics into one actionable view of project health.
#
# @decision DEC-BL-GAPS-001
# @title Single-pass gaps aggregation with independent data sources
# @status accepted
# @rationale Each data source (gh issues, scan-backlog.sh, .plan-drift) can
# fail independently without breaking the report — each section is wrapped in
# a try/fallback pattern. This "best-effort aggregation" matches the design of
# scan-backlog.sh (graceful gh absence) and todo.sh (exit 0 always). The report
# is meant to be surfaced via the /gaps command and optionally in stop.sh, so
# reliability (always producing output) is more important than completeness
# (every section populated). Exit code 0 always — report generation never fails.
# JSON format mirrors the markdown structure as an object with section keys, not
# a flat array, because consumers typically care about the summary object.
#
# Usage: gaps-report.sh [--project-dir <path>] [--format markdown|json]
#
# Options:
#   --project-dir <path>  Project to report on (default: git root or cwd)
#   --format markdown     Human-readable markdown report (default)
#   --format json         JSON object with all sections
#
# Exit codes:
#   0  — Always (report generation is best-effort)
#
# Dependencies: gh (optional), scan-backlog.sh (optional), python3 (optional)
# Env: CLAUDE_TODO_GLOBAL_REPO (override global repo for issue queries)

set -euo pipefail

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TODO_LABEL="claude-todo"
STALE_DAYS=14

# --- Argument parsing ---
FORMAT="markdown"
PROJECT_DIR=""

_usage() {
    cat <<'USAGE'
Usage: gaps-report.sh [--project-dir <path>] [--format markdown|json]

Options:
  --project-dir <path>   Project directory to report on (default: git root or cwd)
  --format markdown      Human-readable markdown report (default)
  --format json          JSON object with all sections

Exit codes:
  0  Always (report generation is best-effort)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            shift
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: --project-dir requires a path argument" >&2
                exit 1
            fi
            PROJECT_DIR="$1"
            ;;
        --format)
            shift
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: --format requires an argument (markdown|json)" >&2
                exit 1
            fi
            FORMAT="$1"
            if [[ "$FORMAT" != "markdown" && "$FORMAT" != "json" ]]; then
                echo "ERROR: --format must be 'markdown' or 'json', got: '$FORMAT'" >&2
                exit 1
            fi
            ;;
        --help|-h)
            _usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            _usage >&2
            exit 1
            ;;
        *)
            echo "ERROR: unexpected argument: $1" >&2
            _usage >&2
            exit 1
            ;;
    esac
    shift
done

# --- Resolve project directory ---
if [[ -z "$PROJECT_DIR" ]]; then
    if GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
        PROJECT_DIR="$GIT_ROOT"
    else
        PROJECT_DIR="$PWD"
    fi
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: project directory not found: $PROJECT_DIR" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# --- Locate Claude dir (.claude at project root or $HOME/.claude) ---
# Prefer a .claude subdir adjacent to the project root; fall back to $HOME/.claude
if [[ -d "${PROJECT_DIR}/.claude" ]]; then
    CLAUDE_DIR="${PROJECT_DIR}/.claude"
elif [[ -d "$HOME/.claude" ]]; then
    CLAUDE_DIR="$HOME/.claude"
else
    CLAUDE_DIR=""
fi

# =============================================================================
# Section 1: Open Backlog Issues
# Query gh issue list --label claude-todo --state open
# Returns parallel arrays: ISSUE_NUMS, ISSUE_TITLES, ISSUE_AGES_DAYS
# =============================================================================
ISSUE_NUMS=()
ISSUE_TITLES=()
ISSUE_AGES_DAYS=()
ISSUES_AVAILABLE=false
ISSUES_ERROR=""

_load_open_issues() {
    if ! command -v gh >/dev/null 2>&1; then
        ISSUES_ERROR="gh CLI not found"
        return 0
    fi

    local raw_issues
    raw_issues=$(gh issue list \
        --label "$TODO_LABEL" \
        --state open \
        --json number,title,createdAt \
        --limit 100 \
        2>/dev/null) || {
        ISSUES_ERROR="gh issue list failed (not authenticated or no repo context)"
        return 0
    }

    ISSUES_AVAILABLE=true
    local now_epoch
    now_epoch=$(date +%s)

    # Parse with python3 or jq
    local parsed=""
    if command -v python3 >/dev/null 2>&1; then
        parsed=$(python3 -c "
import json, sys
from datetime import datetime, timezone
data = json.load(sys.stdin)
now = $now_epoch
for issue in data:
    num = str(issue.get('number', ''))
    title = issue.get('title', '').replace('\t', ' ').replace('\n', ' ')
    created = issue.get('createdAt', '')
    try:
        # Parse ISO 8601 timestamp
        ts = datetime.strptime(created, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
        age_days = (now - int(ts.timestamp())) // 86400
    except Exception:
        age_days = 0
    print(f'{num}\t{title}\t{age_days}')
" <<< "$raw_issues" 2>/dev/null) || true
    elif command -v jq >/dev/null 2>&1; then
        parsed=$(echo "$raw_issues" | jq -r --argjson now "$now_epoch" \
            '.[] | [(.number|tostring), .title, (($now - (.createdAt | fromdateiso8601)) / 86400 | floor | tostring)] | @tsv' \
            2>/dev/null) || true
    else
        ISSUES_ERROR="python3 and jq both unavailable — cannot parse issue dates"
        ISSUES_AVAILABLE=false
        return 0
    fi

    while IFS=$'\t' read -r num title age_days; do
        [[ -z "$num" ]] && continue
        ISSUE_NUMS+=("$num")
        ISSUE_TITLES+=("$title")
        ISSUE_AGES_DAYS+=("$age_days")
    done <<< "$parsed"
}

# =============================================================================
# Section 2: Untracked Code Markers
# Run scan-backlog.sh --format json and filter issue_ref == "untracked"
# =============================================================================
UNTRACKED_FILES=()
UNTRACKED_LINES=()
UNTRACKED_TYPES=()
UNTRACKED_TEXTS=()
MARKERS_AVAILABLE=false
MARKERS_ERROR=""

_load_untracked_markers() {
    local scan_script="${SCRIPT_DIR}/scan-backlog.sh"
    if [[ ! -x "$scan_script" ]]; then
        MARKERS_ERROR="scan-backlog.sh not found at ${scan_script}"
        return 0
    fi

    local scan_out
    local scan_ec=0
    scan_out=$(bash "$scan_script" --format json "$PROJECT_DIR" 2>/dev/null) || scan_ec=$?

    # scan-backlog.sh exits 1 when no markers found — that's OK
    if [[ $scan_ec -eq 2 ]]; then
        MARKERS_ERROR="scan-backlog.sh returned error (exit 2)"
        return 0
    fi

    MARKERS_AVAILABLE=true

    if [[ -z "$scan_out" || "$scan_out" == "[]" ]]; then
        return 0  # No markers at all — empty arrays
    fi

    # Parse JSON array — filter where issue_ref == "untracked"
    local parsed_untracked=""
    if command -v python3 >/dev/null 2>&1; then
        parsed_untracked=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for item in data:
    if item.get('issue_ref', '') == 'untracked':
        f = item.get('file', '').replace('\t', ' ')
        l = str(item.get('line', ''))
        t = item.get('type', '').replace('\t', ' ')
        x = item.get('text', '').replace('\t', ' ').replace('\n', ' ')
        print(f'{f}\t{l}\t{t}\t{x}')
" <<< "$scan_out" 2>/dev/null) || true
    elif command -v jq >/dev/null 2>&1; then
        parsed_untracked=$(echo "$scan_out" | jq -r \
            '.[] | select(.issue_ref == "untracked") | [.file, (.line|tostring), .type, .text] | @tsv' \
            2>/dev/null) || true
    else
        MARKERS_ERROR="python3 and jq both unavailable — cannot parse scan output"
        return 0
    fi

    while IFS=$'\t' read -r file line type text; do
        [[ -z "$file" ]] && continue
        UNTRACKED_FILES+=("$file")
        UNTRACKED_LINES+=("$line")
        UNTRACKED_TYPES+=("$type")
        UNTRACKED_TEXTS+=("$text")
    done <<< "$parsed_untracked"
}

# =============================================================================
# Section 3: Decision Drift
# Read .plan-drift (written by stop.sh surface section):
#   audit_epoch=<unix_ts>
#   unplanned_count=<N>
#   unimplemented_count=<N>
#   missing_decisions=<N>
#   total_decisions=<N>
# Note: .plan-drift stores counts only — the actual decision IDs are in the
# audit log. We display the counts with a note to run a session to get IDs.
# =============================================================================
DRIFT_AVAILABLE=false
DRIFT_ERROR=""
DRIFT_UNPLANNED_COUNT=0
DRIFT_UNIMPLEMENTED_COUNT=0
DRIFT_MISSING_COUNT=0
DRIFT_TOTAL_DECISIONS=0
DRIFT_EPOCH=0

_load_decision_drift() {
    # Search for .plan-drift: adjacent to project root's .claude dir,
    # or directly in the claude dir
    local drift_file=""
    if [[ -n "$CLAUDE_DIR" && -f "${CLAUDE_DIR}/.plan-drift" ]]; then
        drift_file="${CLAUDE_DIR}/.plan-drift"
    elif [[ -f "${PROJECT_DIR}/.plan-drift" ]]; then
        drift_file="${PROJECT_DIR}/.plan-drift"
    fi

    if [[ -z "$drift_file" ]]; then
        DRIFT_ERROR="No drift data — run a session with MASTER_PLAN.md to generate"
        return 0
    fi

    if [[ ! -s "$drift_file" ]]; then
        DRIFT_ERROR="No drift data — run a session with MASTER_PLAN.md to generate"
        return 0
    fi

    DRIFT_AVAILABLE=true

    # Parse key=value format
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue  # skip comments
        key="${key// /}"  # trim spaces
        value="${value// /}"  # trim spaces
        case "$key" in
            audit_epoch)           DRIFT_EPOCH="$value" ;;
            unplanned_count)       DRIFT_UNPLANNED_COUNT="$value" ;;
            unimplemented_count)   DRIFT_UNIMPLEMENTED_COUNT="$value" ;;
            missing_decisions)     DRIFT_MISSING_COUNT="$value" ;;
            total_decisions)       DRIFT_TOTAL_DECISIONS="$value" ;;
        esac
    done < "$drift_file"
}

# =============================================================================
# Accountability score computation
# Clean: 0 untracked + 0 drift
# Needs Attention: 1-5 untracked or drift items
# At Risk: 6+ untracked or drift items
# =============================================================================
_compute_score() {
    local untracked_count="$1"
    local drift_total="$2"

    local total=$(( untracked_count + drift_total ))

    if [[ $total -eq 0 ]]; then
        echo "Clean"
    elif [[ $total -le 5 ]]; then
        echo "Needs Attention"
    else
        echo "At Risk"
    fi
}

# =============================================================================
# JSON output: emit a JSON object with all sections
# =============================================================================
_json_escape() {
    local s="$1"
    # Escape backslash, double-quote, newline, tab, carriage return
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

_output_json() {
    local open_count=${#ISSUE_NUMS[@]}
    local untracked_count=${#UNTRACKED_FILES[@]}
    local drift_total=$(( DRIFT_UNPLANNED_COUNT + DRIFT_UNIMPLEMENTED_COUNT ))
    local score
    score=$(_compute_score "$untracked_count" "$drift_total")

    # Count stale issues
    local stale_count=0
    local i
    for (( i=0; i<${#ISSUE_AGES_DAYS[@]}; i++ )); do
        if [[ "${ISSUE_AGES_DAYS[$i]:-0}" -gt $STALE_DAYS ]]; then
            stale_count=$(( stale_count + 1 ))
        fi
    done

    echo "{"
    echo "  \"project\": \"$(_json_escape "$PROJECT_NAME")\","
    echo "  \"generated\": \"$(_json_escape "$TIMESTAMP")\","

    # Open issues array
    echo "  \"open_issues\": {"
    echo "    \"available\": $([ "$ISSUES_AVAILABLE" == "true" ] && echo true || echo false),"
    if [[ -n "$ISSUES_ERROR" ]]; then
        echo "    \"error\": \"$(_json_escape "$ISSUES_ERROR")\","
    fi
    echo "    \"count\": $open_count,"
    echo "    \"stale_count\": $stale_count,"
    if [[ $open_count -eq 0 ]]; then
        echo "    \"items\": []"
    else
        echo "    \"items\": ["
        for (( i=0; i<open_count; i++ )); do
            local comma=""
            [[ $(( i + 1 )) -lt $open_count ]] && comma=","
            printf '      {"number": %s, "title": "%s", "age_days": %s}%s\n' \
                "${ISSUE_NUMS[$i]}" \
                "$(_json_escape "${ISSUE_TITLES[$i]}")" \
                "${ISSUE_AGES_DAYS[$i]:-0}" \
                "$comma"
        done
        echo "    ]"
    fi
    echo "  },"

    # Untracked markers array
    echo "  \"untracked_markers\": {"
    echo "    \"available\": $([ "$MARKERS_AVAILABLE" == "true" ] && echo true || echo false),"
    if [[ -n "$MARKERS_ERROR" ]]; then
        echo "    \"error\": \"$(_json_escape "$MARKERS_ERROR")\","
    fi
    echo "    \"count\": $untracked_count,"
    if [[ $untracked_count -eq 0 ]]; then
        echo "    \"items\": []"
    else
        echo "    \"items\": ["
        for (( i=0; i<untracked_count; i++ )); do
            local comma=""
            [[ $(( i + 1 )) -lt $untracked_count ]] && comma=","
            printf '      {"file_line": "%s:%s", "type": "%s", "text": "%s"}%s\n' \
                "$(_json_escape "${UNTRACKED_FILES[$i]}")" \
                "${UNTRACKED_LINES[$i]}" \
                "$(_json_escape "${UNTRACKED_TYPES[$i]}")" \
                "$(_json_escape "${UNTRACKED_TEXTS[$i]}")" \
                "$comma"
        done
        echo "    ]"
    fi
    echo "  },"

    # Decision drift object
    echo "  \"decision_drift\": {"
    echo "    \"available\": $([ "$DRIFT_AVAILABLE" == "true" ] && echo true || echo false),"
    if [[ -n "$DRIFT_ERROR" ]]; then
        echo "    \"note\": \"$(_json_escape "$DRIFT_ERROR")\","
    fi
    echo "    \"unplanned_count\": $DRIFT_UNPLANNED_COUNT,"
    echo "    \"unimplemented_count\": $DRIFT_UNIMPLEMENTED_COUNT,"
    echo "    \"missing_decisions\": $DRIFT_MISSING_COUNT,"
    echo "    \"total_decisions\": $DRIFT_TOTAL_DECISIONS"
    echo "  },"

    # Summary
    echo "  \"summary\": {"
    echo "    \"open_issues\": $open_count,"
    echo "    \"stale_issues\": $stale_count,"
    echo "    \"untracked_markers\": $untracked_count,"
    echo "    \"decision_drift\": $drift_total,"
    echo "    \"accountability\": \"$score\""
    echo "  }"
    echo "}"
}

# =============================================================================
# Markdown output: emit the full accountability report
# =============================================================================
_output_markdown() {
    local open_count=${#ISSUE_NUMS[@]}
    local untracked_count=${#UNTRACKED_FILES[@]}
    local drift_total=$(( DRIFT_UNPLANNED_COUNT + DRIFT_UNIMPLEMENTED_COUNT ))
    local score
    score=$(_compute_score "$untracked_count" "$drift_total")

    # Count stale issues
    local stale_count=0
    local i
    for (( i=0; i<${#ISSUE_AGES_DAYS[@]}; i++ )); do
        if [[ "${ISSUE_AGES_DAYS[$i]:-0}" -gt $STALE_DAYS ]]; then
            stale_count=$(( stale_count + 1 ))
        fi
    done

    echo "# Gaps Report — ${PROJECT_NAME}"
    echo "Generated: ${TIMESTAMP}"
    echo ""

    # Section 1: Open Backlog
    echo "## Open Backlog (${open_count} items)"
    if [[ "$ISSUES_AVAILABLE" == "false" ]]; then
        echo ""
        echo "> Note: ${ISSUES_ERROR}"
        echo ""
    elif [[ $open_count -eq 0 ]]; then
        echo ""
        echo "No open backlog issues."
        echo ""
    else
        echo ""
        echo "| # | Title | Age |"
        echo "|---|-------|-----|"
        for (( i=0; i<open_count; i++ )); do
            local age_label="${ISSUE_AGES_DAYS[$i]:-0}d"
            if [[ "${ISSUE_AGES_DAYS[$i]:-0}" -gt $STALE_DAYS ]]; then
                age_label="${age_label} (stale)"
            fi
            printf "| #%s | %s | %s |\n" \
                "${ISSUE_NUMS[$i]}" \
                "${ISSUE_TITLES[$i]}" \
                "$age_label"
        done
        echo ""
        echo "Stale (>${STALE_DAYS} days): ${stale_count} items"
        echo ""
    fi

    # Section 2: Untracked Code Markers
    echo "## Untracked Code Markers (${untracked_count} items)"
    if [[ "$MARKERS_AVAILABLE" == "false" ]]; then
        echo ""
        echo "> Note: ${MARKERS_ERROR}"
        echo ""
    elif [[ $untracked_count -eq 0 ]]; then
        echo ""
        echo "No untracked markers found."
        echo ""
    else
        echo ""
        echo "| File:Line | Type | Text |"
        echo "|-----------|------|------|"
        for (( i=0; i<untracked_count; i++ )); do
            printf "| %s:%s | %s | %s |\n" \
                "${UNTRACKED_FILES[$i]}" \
                "${UNTRACKED_LINES[$i]}" \
                "${UNTRACKED_TYPES[$i]}" \
                "${UNTRACKED_TEXTS[$i]}"
        done
        echo ""
    fi

    # Section 3: Decision Drift
    echo "## Decision Drift"
    if [[ "$DRIFT_AVAILABLE" == "false" ]]; then
        echo ""
        echo "> ${DRIFT_ERROR}"
        echo ""
    else
        echo ""
        echo "### Unplanned (in code, not in plan)"
        if [[ $DRIFT_UNPLANNED_COUNT -eq 0 ]]; then
            echo "None."
        else
            echo "${DRIFT_UNPLANNED_COUNT} unplanned decision(s) detected."
            echo "> Run \`/scan\` and check the decision registry for details."
        fi
        echo ""
        echo "### Unimplemented (in plan, not in code)"
        if [[ $DRIFT_UNIMPLEMENTED_COUNT -eq 0 ]]; then
            echo "None."
        else
            echo "${DRIFT_UNIMPLEMENTED_COUNT} unimplemented decision(s) detected."
            echo "> Check MASTER_PLAN.md decision log for details."
        fi
        echo ""
        if [[ $DRIFT_MISSING_COUNT -gt 0 ]]; then
            echo "> ${DRIFT_MISSING_COUNT} source file(s) missing @decision annotations (of ${DRIFT_TOTAL_DECISIONS} total decisions tracked)"
            echo ""
        fi
    fi

    # Section 4: Summary
    echo "## Summary"
    echo "- Open issues: ${open_count} (${stale_count} stale)"
    echo "- Untracked markers: ${untracked_count}"
    echo "- Decision drift: ${drift_total}"
    echo "- Accountability: ${score}"
    echo ""
}

# =============================================================================
# Main: load data sources, emit report
# =============================================================================
_load_open_issues
_load_untracked_markers
_load_decision_drift

if [[ "$FORMAT" == "json" ]]; then
    _output_json
else
    _output_markdown
fi

exit 0

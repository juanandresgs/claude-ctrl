#!/usr/bin/env bash
# report.sh — Observatory Stage 3: comprehensive assessment report
#
# Purpose: Synthesize analysis-cache.json, suggestions/SUG-*.json,
#          comparison-matrix.json, and state.json into a structured markdown
#          report (assessment-report.md). Provides the full picture view that
#          /observatory report mode presents to the user.
#
# @decision DEC-OBS-016
# @title Report as generated markdown, not live terminal output
# @status accepted
# @rationale The report is written to assessment-report.md so it can be
#             committed, diffed, and reviewed asynchronously. SKILL.md reads
#             and presents it via cat — this keeps report.sh a pure generator
#             with no interactive dependencies. The file is overwritten on
#             each run (idempotent).
#
# @decision DEC-OBS-017
# @title Signal Landscape table uses pre-computed comparison-matrix.json
# @status accepted
# @rationale suggest.sh already computed batch grouping and effort buckets.
#             report.sh reads comparison-matrix.json directly rather than
#             re-deriving the same data. This makes the report a faithful
#             summary of what suggest.sh determined, and keeps the two stages
#             cleanly separated: compute (suggest.sh) vs. present (report.sh).
#
# @decision DEC-OBS-P2-108
# @title report.sh warns when analysis-cache is newer than the last report
# @status accepted
# @rationale The report can silently become stale if analyze.sh ran after the
#             last report was generated. The staleness check compares mtime of
#             analysis-cache.json vs assessment-report.md. If cache is newer,
#             a warning is printed to stderr so CI/automation scripts can detect
#             and trigger a re-run. The report header also shows the analysis
#             generated_at so readers can assess data freshness without comparing
#             file timestamps manually. Fix for issue #108.
#
# Input:  observatory/analysis-cache.json
#         observatory/suggestions/SUG-*.json
#         observatory/comparison-matrix.json
#         observatory/state.json
# Output: observatory/assessment-report.md
# Usage:  bash skills/observatory/scripts/report.sh [--skip-stale-check]

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
WORKTREE_DIR="${WORKTREE_DIR:-$CLAUDE_DIR}"
OBS_DIR="${OBS_DIR:-${WORKTREE_DIR}/observatory}"
CACHE_FILE="${OBS_DIR}/analysis-cache.json"
MATRIX_FILE="${OBS_DIR}/comparison-matrix.json"
STATE_FILE="${STATE_FILE:-${OBS_DIR}/state.json}"
SUGGESTIONS_DIR="${OBS_DIR}/suggestions"
REPORT_FILE="${OBS_DIR}/assessment-report.md"

# Parse flags
SKIP_STALE_CHECK=false
for arg in "$@"; do
    case "$arg" in
        --skip-stale-check) SKIP_STALE_CHECK=true ;;
    esac
done

# --- Preflight ---
mkdir -p "$OBS_DIR"

if [[ ! -f "$CACHE_FILE" ]]; then
    echo "ERROR: analysis-cache.json not found — run analyze.sh first" >&2
    exit 1
fi

if [[ ! -f "$MATRIX_FILE" ]]; then
    echo "ERROR: comparison-matrix.json not found — run suggest.sh first" >&2
    exit 1
fi

# --- Staleness check (issue #108) ---
# Warn when analysis-cache.json is newer than the current report.
# This means the report would be regenerated from fresh data — no action needed.
# If the REPORT already exists and is newer than the cache, warn that running
# this script will use potentially stale cache data.
if [[ "$SKIP_STALE_CHECK" == "false" && -f "$REPORT_FILE" ]]; then
    # Get mtimes (portable: Darwin uses stat -f %m, Linux uses stat -c %Y)
    if [[ "$(uname)" == "Darwin" ]]; then
        CACHE_MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo "0")
        REPORT_MTIME=$(stat -f %m "$REPORT_FILE" 2>/dev/null || echo "0")
    else
        CACHE_MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo "0")
        REPORT_MTIME=$(stat -c %Y "$REPORT_FILE" 2>/dev/null || echo "0")
    fi
    if [[ "$CACHE_MTIME" -gt "$REPORT_MTIME" ]]; then
        STALENESS_SECONDS=$(( CACHE_MTIME - REPORT_MTIME ))
        echo "INFO: analysis-cache.json is ${STALENESS_SECONDS}s newer than last report — regenerating from fresh data" >&2
    fi
fi

# --- Extract core stats ---
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CACHE_GENERATED=$(jq -r '.generated_at // "unknown"' "$CACHE_FILE")
TOTAL_TRACES=$(jq '.trace_stats.total // 0' "$CACHE_FILE")

# Historical traces context (from Stage 2c of analyze.sh — issue #107)
HIST_AVAILABLE=$(jq -r '.historical_traces.available // false' "$CACHE_FILE" 2>/dev/null || echo "false")
HIST_TOTAL=$(jq '.historical_traces.total // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
SIG_COUNT=$(jq '.improvement_signals | length' "$CACHE_FILE")

# Outcome distribution
OUTCOME_PARTIAL=$(jq '.trace_stats.outcome_dist.partial // 0' "$CACHE_FILE")
OUTCOME_SUCCESS=$(jq '.trace_stats.outcome_dist.success // 0' "$CACHE_FILE")
OUTCOME_CRASHED=$(jq '.trace_stats.outcome_dist.crashed // 0' "$CACHE_FILE")

# Compute percentages safely
safe_pct() {
    local num="$1" denom="$2"
    jq -n "if $denom > 0 then ($num / $denom * 100 | round) else 0 end" 2>/dev/null || echo "0"
}

PARTIAL_PCT=$(safe_pct "$OUTCOME_PARTIAL" "$TOTAL_TRACES")
SUCCESS_PCT=$(safe_pct "$OUTCOME_SUCCESS" "$TOTAL_TRACES")
CRASHED_PCT=$(safe_pct "$OUTCOME_CRASHED" "$TOTAL_TRACES")

# Artifact health
SUMMARY_RATE=$(jq '.artifact_health.completeness["summary.md"] // 0' "$CACHE_FILE")
TEST_RATE=$(jq '.artifact_health.completeness["test-output.txt"] // 0' "$CACHE_FILE")
DIFF_RATE=$(jq '.artifact_health.completeness["diff.patch"] // 0' "$CACHE_FILE")
FILES_RATE=$(jq '.artifact_health.completeness["files-changed.txt"] // 0' "$CACHE_FILE")

# Self-metrics
ACCEPT_RATE=$(jq '.self_metrics.acceptance_rate // "null"' "$CACHE_FILE")
IMPL_COUNT=$(jq '.self_metrics.implemented // 0' "$CACHE_FILE")
REJ_COUNT=$(jq '.self_metrics.rejected // 0' "$CACHE_FILE")

# Trends
TRENDS_AVAILABLE=$(jq '.trends != null' "$CACHE_FILE" 2>/dev/null || echo "false")
if [[ "$TRENDS_AVAILABLE" == "true" ]]; then
    TREND_DIRECTION=$(jq -r '.trends.signal_trend // "stable"' "$CACHE_FILE")
    TREND_DELTA=$(jq '.trends.signal_count_delta // 0' "$CACHE_FILE")
    TRACE_DELTA=$(jq '.trends.trace_count_delta // 0' "$CACHE_FILE")
else
    TREND_DIRECTION="no prior data"
    TREND_DELTA="n/a"
    TRACE_DELTA="n/a"
fi

# --- Count deferred items ---
DEFERRED_COUNT=0
if [[ -f "$STATE_FILE" ]]; then
    DEFERRED_COUNT=$(jq '.deferred | length' "$STATE_FILE" 2>/dev/null || echo "0")
fi

# --- Cohort regression data (DEC-OBS-021) ---
REGRESSION_COUNT=$(jq '[.cohort_regressions // [] | .[] | select(.regression == true)] | length' \
    "$CACHE_FILE" 2>/dev/null || echo "0")

# --- Matrix data ---
MATRIX_SIGNAL_COUNT=$(jq '.matrix | length' "$MATRIX_FILE" 2>/dev/null || echo "0")
QUICK_WIN_COUNT=$(jq '.effort_buckets.quick_wins | length' "$MATRIX_FILE" 2>/dev/null || echo "0")
MODERATE_COUNT=$(jq '.effort_buckets.moderate | length' "$MATRIX_FILE" 2>/dev/null || echo "0")
DEEP_COUNT=$(jq '.effort_buckets.deep | length' "$MATRIX_FILE" 2>/dev/null || echo "0")
BATCH_COUNT=$(jq '.batches | keys | length' "$MATRIX_FILE" 2>/dev/null || echo "0")

# --- Generate the report ---
{
# Build trace context line (active + historical if available)
if [[ "$HIST_AVAILABLE" == "true" && "$HIST_TOTAL" -gt 0 ]]; then
    TRACE_CONTEXT="${TOTAL_TRACES} active + ${HIST_TOTAL} historical (archived)"
else
    TRACE_CONTEXT="${TOTAL_TRACES} active"
fi

cat << HEADER
# Observatory Assessment Report

**Generated:** ${GENERATED_AT}
**Analysis data:** ${CACHE_GENERATED}
**Trace coverage:** ${TRACE_CONTEXT}

---

HEADER

# Regression Alerts section — only emitted when regressions are present
if [[ "$REGRESSION_COUNT" -gt 0 ]]; then
    echo "## Regression Alerts"
    echo ""
    echo "> **${REGRESSION_COUNT} previously-implemented signal(s) are still triggering on new traces.**"
    echo "> The fix was merged but the issue persists. These have been re-proposed with \`regression: true\`."
    echo ""
    echo "| Signal | Cohort Traces | Still Affected | Rate |"
    echo "|--------|--------------|----------------|------|"
    jq -c '.cohort_regressions[] | select(.regression == true)' "$CACHE_FILE" 2>/dev/null | \
    while IFS= read -r reg; do
        R_SIG=$(echo "$reg" | jq -r '.signal_id')
        R_SIZE=$(echo "$reg" | jq -r '.cohort_size')
        R_AFF=$(echo "$reg" | jq -r '.cohort_affected')
        R_RATE=$(jq -n "if $R_SIZE > 0 then ($R_AFF / $R_SIZE * 100 | round) else 0 end" 2>/dev/null || echo "?")
        echo "| ${R_SIG} | ${R_SIZE} new traces | ${R_AFF} (${R_RATE}%) | regression |"
    done
    echo ""
    echo "---"
    echo ""
fi

cat << HEALTH_HEADER
## System Health Summary

| Metric | Value |
|--------|-------|
| Active Traces | ${TOTAL_TRACES} |
| Historical Traces | ${HIST_TOTAL} (archived in oldTraces/) |
| Active Signals | ${SIG_COUNT} |
| Deferred Items | ${DEFERRED_COUNT} |
| Trend | ${TREND_DIRECTION} (signal delta: ${TREND_DELTA}, trace delta: ${TRACE_DELTA}) |

**Outcome Distribution:**
- success: ${OUTCOME_SUCCESS} (${SUCCESS_PCT}%)
- partial: ${OUTCOME_PARTIAL} (${PARTIAL_PCT}%)
- crashed: ${OUTCOME_CRASHED} (${CRASHED_PCT}%)

**Artifact Completeness:**
- summary.md: ${SUMMARY_RATE}
- test-output.txt: ${TEST_RATE}
- diff.patch: ${DIFF_RATE}
- files-changed.txt: ${FILES_RATE}

---

## Signal Landscape

HEALTH_HEADER

# Build the signal table from comparison matrix
if [[ "$MATRIX_SIGNAL_COUNT" -gt 0 ]]; then
    echo "| # | Signal | Severity | Affected | Priority | Effort | Batch | Status |"
    echo "|---|--------|----------|----------|----------|--------|-------|--------|"

    ROW_NUM=1
    jq -c '.matrix[]' "$MATRIX_FILE" 2>/dev/null | while IFS= read -r entry; do
        SIG_ID=$(echo "$entry" | jq -r '.signal_id')
        SEVERITY=$(echo "$entry" | jq -r '.severity')
        AFFECTED_PCT=$(echo "$entry" | jq -r '.affected_pct')
        PRIORITY=$(echo "$entry" | jq -r '.priority')
        EFFORT=$(echo "$entry" | jq -r '.effort')
        BATCH=$(echo "$entry" | jq -r '.batch')
        STATUS=$(echo "$entry" | jq -r '.status')
        SUG_ID=$(echo "$entry" | jq -r '.sug_id')

        # Uppercase severity, keep effort as-is (bash 3.2 compatible, no ${^^})
        SEV_UPPER=$(echo "$SEVERITY" | tr '[:lower:]' '[:upper:]')
        echo "| ${ROW_NUM} | ${SIG_ID} | ${SEV_UPPER} | ${AFFECTED_PCT}% | ${PRIORITY} | ${EFFORT} | ${BATCH} | ${STATUS} |"
        ROW_NUM=$((ROW_NUM + 1))
    done
else
    echo "_No active signals. System is healthy or all suggestions have been addressed._"
fi

echo ""
echo "---"
echo ""
echo "## Batch Analysis"
echo ""

# Describe each batch
BATCH_KEYS=$(jq -r '.batches | keys[]' "$MATRIX_FILE" 2>/dev/null | sort || echo "")
if [[ -n "$BATCH_KEYS" ]]; then
    while IFS= read -r batch_key; do
        [[ -z "$batch_key" ]] && continue
        BATCH_DATA=$(jq --arg k "$batch_key" '.batches[$k]' "$MATRIX_FILE" 2>/dev/null || echo '{}')
        BATCH_SIGS=$(echo "$BATCH_DATA" | jq -r '.signals | join(", ")')
        BATCH_FILES=$(echo "$BATCH_DATA" | jq -r '.files | join(", ")')
        BATCH_EFFORT=$(echo "$BATCH_DATA" | jq -r '.combined_effort')

        echo "### Batch ${batch_key}: ${BATCH_FILES}"
        echo ""
        echo "- **Signals:** ${BATCH_SIGS}"
        echo "- **Shared files:** \`${BATCH_FILES}\`"
        echo "- **Combined effort:** ${BATCH_EFFORT}"
        echo ""
    done <<< "$BATCH_KEYS"
else
    echo "_No batches — signals affect different files._"
    echo ""
fi

echo "---"
echo ""
echo "## Dependency Map"
echo ""

# Show dependency relationships (parentheses required for correct operator precedence)
DEP_ENTRIES=$(jq -c '[.matrix[] | select((.depends_on | length > 0) or (.unlocks | length > 0))]' "$MATRIX_FILE" 2>/dev/null || echo "[]")
DEP_COUNT=$(echo "$DEP_ENTRIES" | jq 'length')

if [[ "$DEP_COUNT" -gt 0 ]]; then
    echo "Fixing these signals unlocks better data for dependent signals:"
    echo ""
    jq -c '.matrix[] | select((.unlocks | length) > 0)' "$MATRIX_FILE" 2>/dev/null | while IFS= read -r entry; do
        SIG_ID=$(echo "$entry" | jq -r '.signal_id')
        UNLOCKS=$(echo "$entry" | jq -r '.unlocks | join(", ")')
        echo "- **${SIG_ID}** → unlocks: ${UNLOCKS}"
    done
    echo ""

    # Signals with dependencies
    echo "These signals depend on others for full effect:"
    echo ""
    jq -c '.matrix[] | select((.depends_on | length) > 0)' "$MATRIX_FILE" 2>/dev/null | while IFS= read -r entry; do
        SIG_ID=$(echo "$entry" | jq -r '.signal_id')
        DEPS=$(echo "$entry" | jq -r '.depends_on | join(", ")')
        echo "- **${SIG_ID}** depends on: ${DEPS}"
    done
else
    echo "_No dependency relationships between active signals._"
fi

echo ""
echo "---"
echo ""
echo "## Effort Buckets"
echo ""
echo "### Quick Wins (low complexity, function scope)"
echo ""

QUICK_WINS=$(jq -r '.effort_buckets.quick_wins[]' "$MATRIX_FILE" 2>/dev/null || echo "")
if [[ -n "$QUICK_WINS" ]]; then
    while IFS= read -r sug_id; do
        [[ -z "$sug_id" ]] && continue
        sug_file="${SUGGESTIONS_DIR}/${sug_id}.json"
        if [[ -f "$sug_file" ]]; then
            SIG_ID=$(jq -r '.signal_id' "$sug_file")
            TITLE=$(jq -r '.title' "$sug_file")
            echo "- **${sug_id}** (${SIG_ID}): ${TITLE}"
        fi
    done <<< "$QUICK_WINS"
else
    echo "_None_"
fi

echo ""
echo "### Moderate (medium complexity)"
echo ""
MODERATE=$(jq -r '.effort_buckets.moderate[]' "$MATRIX_FILE" 2>/dev/null || echo "")
if [[ -n "$MODERATE" ]]; then
    while IFS= read -r sug_id; do
        [[ -z "$sug_id" ]] && continue
        sug_file="${SUGGESTIONS_DIR}/${sug_id}.json"
        if [[ -f "$sug_file" ]]; then
            SIG_ID=$(jq -r '.signal_id' "$sug_file")
            TITLE=$(jq -r '.title' "$sug_file")
            echo "- **${sug_id}** (${SIG_ID}): ${TITLE}"
        fi
    done <<< "$MODERATE"
else
    echo "_None_"
fi

echo ""
echo "### Deep Changes (high complexity, multi-file)"
echo ""
DEEP=$(jq -r '.effort_buckets.deep[]' "$MATRIX_FILE" 2>/dev/null || echo "")
if [[ -n "$DEEP" ]]; then
    while IFS= read -r sug_id; do
        [[ -z "$sug_id" ]] && continue
        sug_file="${SUGGESTIONS_DIR}/${sug_id}.json"
        if [[ -f "$sug_file" ]]; then
            SIG_ID=$(jq -r '.signal_id' "$sug_file")
            TITLE=$(jq -r '.title' "$sug_file")
            echo "- **${sug_id}** (${SIG_ID}): ${TITLE}"
        fi
    done <<< "$DEEP"
else
    echo "_None_"
fi

echo ""
echo "---"
echo ""
echo "## Deferred / Backlog"
echo ""

# List deferred items with reassessment status
if [[ -f "$STATE_FILE" && "$DEFERRED_COUNT" -gt 0 ]]; then
    echo "| SUG-ID | Signal | Deferred At | Reassess After | Condition | Priority at Deferral |"
    echo "|--------|--------|-------------|----------------|-----------|---------------------|"
    jq -c '.deferred[]' "$STATE_FILE" 2>/dev/null | while IFS= read -r def; do
        SUG_ID=$(echo "$def" | jq -r '.sug_id // "?"')
        SIG_ID=$(echo "$def" | jq -r '.signal_id // "unknown"')
        DEF_AT=$(echo "$def" | jq -r '.deferred_at // "?"' | cut -c1-10)
        REASSESS=$(echo "$def" | jq -r '.reassess_after // "?"' | cut -c1-10)
        CONDITION=$(echo "$def" | jq -r '.reassess_condition // "-"')
        PRI=$(echo "$def" | jq -r '.priority_at_deferral // "-"')
        echo "| ${SUG_ID} | ${SIG_ID} | ${DEF_AT} | ${REASSESS} | ${CONDITION} | ${PRI} |"
    done
else
    echo "_No deferred items._"
fi

echo ""
echo "---"
echo ""
echo "## Observatory Self-Metrics"
echo ""
if [[ "$ACCEPT_RATE" != "null" ]]; then
    ACCEPT_PCT=$(jq -n "$ACCEPT_RATE * 100 | round" 2>/dev/null || echo "0")
    echo "- **Acceptance rate:** ${ACCEPT_PCT}%"
else
    echo "- **Acceptance rate:** n/a (no decisions yet)"
fi
echo "- **Implemented suggestions:** ${IMPL_COUNT}"
echo "- **Rejected suggestions:** ${REJ_COUNT}"
echo "- **Total active signals:** ${SIG_COUNT}"

# Agent breakdown (if available)
AGENT_DATA=$(jq '.agent_breakdown // []' "$CACHE_FILE" 2>/dev/null)
AGENT_COUNT=$(echo "$AGENT_DATA" | jq 'length')
if [[ "$AGENT_COUNT" -gt 0 ]]; then
    echo ""
    echo "### Agent-Type Breakdown"
    echo ""
    echo "| Agent Type | Traces | Artifact Rate | Avg Duration (s) |"
    echo "|------------|--------|---------------|-----------------|"
    echo "$AGENT_DATA" | jq -c '.[]' 2>/dev/null | while IFS= read -r agent; do
        AT=$(echo "$agent" | jq -r '.agent_type')
        CNT=$(echo "$agent" | jq -r '.count')
        AR=$(echo "$agent" | jq -r '(.artifact_rate * 100 | round | tostring) + "%"')
        AVG=$(echo "$agent" | jq -r '.avg_duration // "-"')
        echo "| ${AT} | ${CNT} | ${AR} | ${AVG} |"
    done
fi

echo ""
echo "---"
echo ""
echo "_Report generated by observatory/scripts/report.sh — re-run \`/observatory report\` to refresh._"

} > "$REPORT_FILE"

echo "Assessment report written → $REPORT_FILE"

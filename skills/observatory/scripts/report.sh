#!/usr/bin/env bash
# report.sh — Observatory v2 Phase 2: focused health report
#
# Purpose: Read observatory/metrics.json + converge.sh output + state.json
#          and produce a focused markdown health report (assessment-report.md).
#          Presents: health dashboard, convergence status, ineffective fixes,
#          and top 3 actionable items.
#
# @decision DEC-OBS-V2-015
# @title Focused 4-section report replaces multi-section signal landscape
# @status accepted
# @rationale The old report.sh (496 lines) had 10+ sections: signal landscape,
#             batch grouping, effort buckets, dependency maps, comparison matrix,
#             historical traces. These sections required analysis-cache.json,
#             comparison-matrix.json, and suggest.sh output — making the pipeline
#             fragile (fail if any input missing). The new report has 4 sections
#             (health dashboard, convergence, ineffective fixes, top 3 actionable),
#             all driven from metrics.json + converge.sh stdout + state.json.
#             This is simpler, faster, and more actionable for the user.
#
# @decision DEC-OBS-V2-016
# @title converge.sh runs inline (subprocess) from report.sh
# @status accepted
# @rationale converge.sh outputs JSON to stdout. report.sh captures it via
#             command substitution: CONV=$(bash converge.sh). This avoids an
#             intermediate convergence.json file and keeps the pipeline simple.
#             If converge.sh is absent, report.sh falls back to empty convergence.
#             The "run" mode of SKILL.md calls analyze.sh + report.sh sequentially —
#             report.sh handles convergence internally.
#
# Input:  observatory/metrics.json
#         observatory/state.json
#         observatory/metrics-history.jsonl (via converge.sh)
# Output: observatory/assessment-report.md (written)
#         stdout: summary for SKILL.md presentation
# Usage:  bash skills/observatory/scripts/report.sh

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
WORKTREE_DIR="${WORKTREE_DIR:-$CLAUDE_DIR}"
OBS_DIR="${OBS_DIR:-${WORKTREE_DIR}/observatory}"
METRICS_FILE="${OBS_DIR}/metrics.json"
STATE_FILE="${STATE_FILE:-${OBS_DIR}/state.json}"
REPORT_FILE="${OBS_DIR}/assessment-report.md"
CONVERGE_SCRIPT="$(dirname "$0")/converge.sh"

# --- Preflight ---
mkdir -p "$OBS_DIR"

if [[ ! -f "$METRICS_FILE" ]]; then
    echo "ERROR: metrics.json not found — run analyze.sh first" >&2
    exit 1
fi

# --- Run convergence analysis ---
CONV="{}"
INEFF_COUNT=0
if [[ -f "$CONVERGE_SCRIPT" ]]; then
    CONV=$(bash "$CONVERGE_SCRIPT" 2>/dev/null || echo '{"convergence":[],"ineffective_fixes":[],"window":5,"data_points":0}')
fi

# --- Read state.json ---
SUGGESTIONS="[]"
if [[ -f "$STATE_FILE" ]]; then
    SUGGESTIONS=$(jq '.suggestions // []' "$STATE_FILE" 2>/dev/null || echo "[]")
fi

GENERATED_AT=$(jq -r '.generated_at // "unknown"' "$METRICS_FILE" 2>/dev/null || echo "unknown")
TRACE_COUNT=$(jq -r '.trace_count // 0' "$METRICS_FILE" 2>/dev/null || echo "0")

# Pre-compute convergence variables before the report block so they remain in
# scope after the block closes (variables set inside "{ } > file" redirects are
# subshell-scoped on some shells; computing them here avoids the unbound-variable
# error at the final summary line that references $INEFF_COUNT).
CONV_DATA=$(echo "$CONV" | jq '.convergence // []' 2>/dev/null || echo "[]")
CONV_COUNT=$(echo "$CONV_DATA" | jq 'length' 2>/dev/null || echo "0")
INEFF=$(echo "$CONV" | jq '.ineffective_fixes // []' 2>/dev/null || echo "[]")
INEFF_COUNT=$(echo "$INEFF" | jq 'length' 2>/dev/null || echo "0")

# --- Generate report ---
{
    echo "# Observatory Health Report"
    echo ""
    echo "_Generated: ${GENERATED_AT}_  "
    echo "_Traces analyzed: ${TRACE_COUNT}_"
    echo ""

    # --- Section 1: Health Dashboard ---
    echo "## Health Dashboard"
    echo ""
    echo "| Agent | Count | Success Rate | Compliance Rate | Avg Duration |"
    echo "|-------|-------|-------------|-----------------|--------------|"

    # Compute per-agent rows
    jq -r '
      .by_agent_type | to_entries[] |
      .key as $agent |
      .value as $data |
      ($data.count // 0) as $count |
      ($data.outcomes.success // 0) as $succ |
      (if $count > 0 then ($succ / $count * 100 | round) else 0 end) as $succ_pct |
      ($data.compliance | to_entries |
        if length > 0 then
          (map(.value.rate) | add / length * 100 | round)
        else null
        end
      ) as $comp_pct |
      ($data.avg_duration_s | if . == null then "—" else "\(. | round)s" end) as $dur |
      "| \($agent) | \($count) | \($succ_pct)% | \(if $comp_pct == null then "—" else "\($comp_pct)%" end) | \($dur) |"
    ' "$METRICS_FILE" 2>/dev/null || true

    echo ""

    # --- Section 2: Convergence Status ---
    echo "## Convergence Status"
    echo ""

    if [[ "$CONV_COUNT" -eq 0 ]]; then
        echo "_No convergence history yet — run analyze.sh multiple times to track trends._"
    else
        echo "| Metric | Current Rate | Trend | Slope | Data Points |"
        echo "|--------|-------------|-------|-------|-------------|"
        echo "$CONV_DATA" | jq -r '
          .[] |
          (.trend) as $trend |
          (if $trend == "improving" then "↑"
           elif $trend == "degrading" then "↓"
           elif $trend == "flat" then "→"
           else "?" end) as $arrow |
          (.slope | if . == null then "—" else (. * 100 | round / 100 | tostring) end) as $slope_str |
          "| \(.agent_type).\(.artifact) | \(.current_rate * 100 | round)% | \($arrow) \($trend) | \($slope_str) | \(.data_points) |"
        ' 2>/dev/null || true
    fi
    echo ""

    # --- Section 3: Ineffective Fixes ---

    if [[ "$INEFF_COUNT" -gt 0 ]]; then
        echo "## Ineffective Fixes"
        echo ""
        echo "_The following implemented suggestions did not improve their target metric after 2+ runs:_"
        echo ""
        echo "$INEFF" | jq -r '
          .[] |
          "- **\(.id)**: \(.title)  " +
          "Metric `\(.metric)`: \(.baseline_rate * 100 | round)% → \(.current_rate * 100 | round)% " +
          "(improvement: \((.improvement * 100) | round)pp, runs since impl: \(.post_impl_runs))"
        ' 2>/dev/null || true
        echo ""
    fi

    # --- Section 4: Top 3 Actionable Items ---
    echo "## Top 3 Actionable Items"
    echo ""

    TOP3=$(echo "$SUGGESTIONS" | jq '[.[] | select(.status == "proposed")] | sort_by(.metric_value_at_suggestion) | .[0:3]' 2>/dev/null || echo "[]")
    TOP3_COUNT=$(echo "$TOP3" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$TOP3_COUNT" -eq 0 ]]; then
        echo "_No pending suggestions. System is healthy or analyze.sh has not run yet._"
    else
        echo "$TOP3" | jq -r '
          to_entries[] |
          "\(.key + 1). **\(.value.id)**: \(.value.title)  " +
          "  Metric: `\(.value.metric)` = \(.value.metric_value_at_suggestion * 100 | round)%  " +
          "  Target: \(.value.convergence_check)  " +
          "  Suggested: \(.value.suggested_at[0:10])"
        ' 2>/dev/null || true
    fi
    echo ""

    # --- Compliance Details ---
    echo "## Compliance Details"
    echo ""
    jq -r '
      .by_agent_type | to_entries[] |
      .key as $agent |
      .value.compliance | to_entries[] |
      "| \($agent) | \(.key) | \(.value.agent) | \(.value.auto) | \(.value.missing) | \(.value.rate * 100 | round)% |"
    ' "$METRICS_FILE" 2>/dev/null | (
        echo "| Agent | Artifact | Agent-Written | Auto-Captured | Missing | Rate |"
        echo "|-------|----------|--------------|---------------|---------|------|"
        cat
    ) || true
    echo ""

} > "$REPORT_FILE"

echo "Report written: $REPORT_FILE"
echo ""

# Print summary to stdout for SKILL.md
echo "=== Observatory Health Summary ==="
echo "Traces: ${TRACE_COUNT}  |  Generated: ${GENERATED_AT}"
echo ""

# Print the health dashboard rows (non-table format for terminal)
jq -r '
  .by_agent_type | to_entries[] |
  .key as $agent |
  .value as $data |
  ($data.count // 0) as $count |
  ($data.outcomes.success // 0) as $succ |
  (if $count > 0 then ($succ / $count * 100 | round) else 0 end) as $succ_pct |
  ($data.compliance | to_entries |
    if length > 0 then (map(.value.rate) | add / length * 100 | round)
    else null end
  ) as $comp_pct |
  "  \($agent): \($count) traces, \($succ_pct)% success\(if $comp_pct != null then ", \($comp_pct)% compliant" else "" end)"
' "$METRICS_FILE" 2>/dev/null || true

PENDING_COUNT=$(echo "$SUGGESTIONS" | jq '[.[] | select(.status == "proposed")] | length' 2>/dev/null || echo "0")
IMPL_COUNT=$(echo "$SUGGESTIONS" | jq '[.[] | select(.status == "implemented")] | length' 2>/dev/null || echo "0")
echo ""
echo "Suggestions: ${PENDING_COUNT} pending, ${IMPL_COUNT} implemented"
[[ "$INEFF_COUNT" -gt 0 ]] && echo "  WARNING: ${INEFF_COUNT} ineffective fix(es) detected" || true

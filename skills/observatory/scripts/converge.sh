#!/usr/bin/env bash
# converge.sh — Observatory v2 Phase 2: convergence tracking
#
# Purpose: Read metrics-history.jsonl and compute trend (slope) for each
#          tracked metric over the last N runs. Classify each metric as
#          improving / flat / degrading. For implemented suggestions, compare
#          current metric vs metric_value_at_suggestion — flag as "ineffective"
#          if no improvement within 2 runs of implementation.
#
# @decision DEC-OBS-V2-013
# @title Linear slope for trend classification
# @status accepted
# @rationale With 3–10 runs of history, simple linear slope (last_value - first_value
#             / N) is more stable than regression. Classification thresholds:
#             slope > 0.05 = improving, slope < -0.05 = degrading, else flat.
#             A 5-point window (default WINDOW=5) avoids noise from single-run
#             outliers without requiring long history. When fewer than 2 data
#             points exist for a metric, trend is "insufficient_data".
#
# @decision DEC-OBS-V2-014
# @title Ineffective fix detection uses 2-run grace period
# @status accepted
# @rationale When a suggestion is marked implemented, the next 2 analyze runs
#             are the grace period. After 2 runs, if the metric hasn't improved
#             by at least 0.10 (10 percentage points), the suggestion is flagged
#             "ineffective" in state.json. This gives agents time to produce new
#             traces before we declare the fix failed. The 2-run threshold is
#             intentionally lenient — false "ineffective" flags are more harmful
#             than missing a real failure (they create noise).
#
# Input:  observatory/metrics-history.jsonl
#         observatory/state.json (for implemented suggestions)
# Output: stdout (JSON convergence report consumed by report.sh)
#         observatory/state.json (updated suggestion statuses)
# Usage:  bash skills/observatory/scripts/converge.sh [--window N]

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
WORKTREE_DIR="${WORKTREE_DIR:-$CLAUDE_DIR}"
OBS_DIR="${OBS_DIR:-${WORKTREE_DIR}/observatory}"
HISTORY_FILE="${OBS_DIR}/metrics-history.jsonl"
STATE_FILE="${STATE_FILE:-${OBS_DIR}/state.json}"

WINDOW=5
for arg in "$@"; do
    case "$arg" in
        --window) ;;  # handled by next iteration
        [0-9]*) WINDOW="$arg" ;;
    esac
done
# Parse --window N properly
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window) WINDOW="${2:-5}"; shift 2 ;;
        *) shift ;;
    esac
done 2>/dev/null || true

if [[ ! -f "$HISTORY_FILE" ]]; then
    jq -cn '{"convergence": [], "ineffective_fixes": [], "window": 5, "data_points": 0}'
    exit 0
fi

# --- Stage 1: Load last WINDOW runs per metric ---
# metrics-history.jsonl has rows: {ts, agent_type, artifact, rate, count}
# We group by (agent_type, artifact) and take last WINDOW entries by ts.
METRIC_TRENDS=$(jq -sc \
    --argjson window "$WINDOW" \
    'group_by([.agent_type, .artifact]) | map(
        sort_by(.ts) |
        . as $all |
        (if length > $window then .[(length - $window):] else . end) as $wd |
        ($wd | length) as $n |
        (if $n < 2 then null else (($wd | last | .rate) - ($wd | first | .rate)) / $n end) as $slope |
        (if $slope == null then "insufficient_data"
         elif $slope > 0.05 then "improving"
         elif $slope < -0.05 then "degrading"
         else "flat" end) as $trend |
        {
            metric: "\($all[0].agent_type).\($all[0].artifact)",
            agent_type: $all[0].agent_type,
            artifact: $all[0].artifact,
            data_points: $n,
            current_rate: ($wd | last | .rate),
            first_rate: ($wd | first | .rate),
            slope: $slope,
            trend: $trend,
            history: ($wd | map({ts: .ts, rate: .rate}))
        }
    )' "$HISTORY_FILE" 2>/dev/null || echo "[]")

TOTAL_POINTS=$(jq -sc 'length' "$HISTORY_FILE" 2>/dev/null || echo "0")

# --- Stage 2: Check implemented suggestions for ineffectiveness ---
INEFFECTIVE_FIXES="[]"

if [[ -f "$STATE_FILE" ]]; then
    # Get implemented suggestions (status = "implemented")
    IMPLEMENTED=$(jq '[.suggestions[] | select(.status == "implemented")]' "$STATE_FILE" 2>/dev/null || echo "[]")
    IMPL_COUNT=$(echo "$IMPLEMENTED" | jq 'length')

    if [[ "$IMPL_COUNT" -gt 0 ]]; then
        # For each implemented suggestion, find its metric in history
        # and check if rate improved by >= 0.10 since implementation
        INEFFECTIVE_FIXES=$(echo "$IMPLEMENTED" | jq \
            --argjson trends "$METRIC_TRENDS" \
            '
            map(
                . as $sug |
                # Extract metric path: "compliance.agent.artifact.rate" → "agent.artifact"
                # The metric has format: compliance.<agent_type>.<artifact>.rate
                # Artifact names contain dots (e.g. "test-output.txt") so we strip
                # the known "compliance." prefix and ".rate" suffix.
                (.metric | ltrimstr("compliance.") | rtrimstr(".rate")) as $metric_key |
                # Find trend for this metric
                ($trends | map(select(.metric == $metric_key)) | first) as $trend |
                # Check: implemented_at in history, count entries after that ts
                if $trend == null then empty
                elif ($sug.implemented_at == null) then empty
                else
                    ($trend.history | map(select(.ts > $sug.implemented_at)) | length) as $post_impl_count |
                    ($sug.metric_value_at_suggestion) as $baseline |
                    ($trend.current_rate) as $current |
                    if $post_impl_count >= 2 and ($current - $baseline) < 0.10 then
                        {
                            id: $sug.id,
                            title: $sug.title,
                            metric: $metric_key,
                            baseline_rate: $baseline,
                            current_rate: $current,
                            improvement: ($current - $baseline),
                            post_impl_runs: $post_impl_count,
                            verdict: "ineffective"
                        }
                    else empty
                    end
                end
            )
            ' 2>/dev/null || echo "[]")

        # Update state.json: mark ineffective suggestions
        INEFFECTIVE_IDS=$(echo "$INEFFECTIVE_FIXES" | jq -r '.[].id' 2>/dev/null || echo "")
        if [[ -n "$INEFFECTIVE_IDS" ]]; then
            NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            TMP="${STATE_FILE}.tmp"
            jq --arg now "$NOW" \
               --argjson ineffective_ids "$(echo "$INEFFECTIVE_IDS" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
               '
               .suggestions = [
                   .suggestions[] |
                   if (.id | IN($ineffective_ids[])) and .status == "implemented" then
                       . + {"status": "ineffective", "flagged_at": $now}
                   else .
                   end
               ]
               ' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
        fi

        # Also mark converged suggestions (rate now > convergence_check threshold)
        # Convergence check format: "agent.artifact.compliance.rate > 0.60"
        # We parse the threshold and compare with current rate.
        ALL_SUGGESTIONS=$(jq '.suggestions // []' "$STATE_FILE" 2>/dev/null || echo "[]")
        NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        TMP="${STATE_FILE}.tmp"
        jq \
            --arg now "$NOW" \
            --argjson trends "$METRIC_TRENDS" \
            '
            .suggestions = [
                .suggestions[] |
                . as $sug |
                if .status == "implemented" then
                    # Parse convergence_check: "agent.artifact.compliance.rate > 0.60"
                    # Strip ".compliance.rate" suffix to get the trend metric key.
                    (.convergence_check | split(" ")) as $parts |
                    ($parts[0] | rtrimstr(".compliance.rate")) as $metric_key |
                    ($parts[2] | tonumber? // null) as $threshold |
                    ($trends | map(select(.metric == $metric_key)) | first | .current_rate // null) as $curr |
                    if $threshold != null and $curr != null and $curr > $threshold then
                        . + {"status": "converged", "converged_at": $now}
                    else .
                    end
                else .
                end
            ]
            ' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
    fi
fi

# --- Stage 3: Output convergence report (stdout for report.sh) ---
jq -cn \
    --argjson convergence "$METRIC_TRENDS" \
    --argjson ineffective_fixes "$INEFFECTIVE_FIXES" \
    --argjson window "$WINDOW" \
    --argjson data_points "$TOTAL_POINTS" \
    '{
        "convergence": $convergence,
        "ineffective_fixes": $ineffective_fixes,
        "window": $window,
        "data_points": $data_points
    }'

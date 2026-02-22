#!/usr/bin/env bash
# analyze.sh — Observatory v2 Phase 2: single-pass metrics analysis
#
# Purpose: Compute 3 core metrics from traces/index.jsonl and per-trace
#          compliance.json files. Produces observatory/metrics.json for
#          health dashboards and metrics-history.jsonl for convergence tracking.
#          Also generates up to 3 actionable suggestions stored in state.json.
#
# Metrics computed:
#   1. Agent success rate — outcome distribution by agent type (from index.jsonl)
#   2. Contract compliance rate — artifact presence by type, from compliance.json
#   3. Root cause attribution — why compliance is low (crash vs agent-fault vs no-trace)
#
# @decision DEC-OBS-V2-010
# @title Single-pass jq aggregation replaces multi-stage analysis pipeline
# @status accepted
# @rationale The old analyze.sh (938 lines) computed 12+ signals with cohort
#             regression, stale marker detection, and doc-drift scanning. The new
#             version focuses on 3 actionable metrics that drive the suggestion loop.
#             All analysis is done in one or two jq passes over index.jsonl, keeping
#             runtime under 2s even at 500+ traces. Signals/cohort-regression removed
#             because: (a) compliance.json gives direct per-trace ground truth, making
#             proxy signals unnecessary; (b) cohort regression requires multi-run
#             history, which metrics-history.jsonl now provides cleanly. The new
#             approach is smaller, faster, and produces more actionable output.
#
# @decision DEC-OBS-V2-011
# @title Root cause attribution uses three-tier filesystem check
# @status accepted
# @rationale When compliance is low, the question is "why?" Three root causes:
#             (1) agent ran but didn't write artifact (summary.md exists, artifact absent),
#             (2) agent crashed (summary.md absent, artifacts dir exists),
#             (3) trace never initialized (no artifacts dir at all).
#             We check the filesystem for each trace missing a required artifact rather
#             than relying solely on index.jsonl fields. This gives actionable blame
#             ("fix agent contract" vs "fix crash recovery" vs "fix trace init").
#             Bash 3.2 compatible — no associative arrays.
#
# @decision DEC-OBS-V2-012
# @title Suggestions written to state.json (not SUG-*.json files)
# @status accepted
# @rationale SUG-*.json files were renumbered on every suggest.sh run (DEC-OBS-022),
#             causing tracking instability. Embedding suggestions directly in state.json
#             with stable IDs (SUG-001, SUG-002, ...) and a metric field for
#             convergence_check makes each suggestion self-contained. The v4 schema
#             adds convergence_check (machine-evaluable condition), metric_value_at_suggestion
#             (baseline for measuring improvement), and status lifecycle.
#
# Input:  traces/index.jsonl, traces/<id>/artifacts/compliance.json
# Output: observatory/metrics.json, observatory/metrics-history.jsonl, observatory/state.json
# Usage:  bash skills/observatory/scripts/analyze.sh

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
WORKTREE_DIR="${WORKTREE_DIR:-$CLAUDE_DIR}"
TRACE_INDEX="${CLAUDE_DIR}/traces/index.jsonl"
TRACE_STORE="${CLAUDE_DIR}/traces"
OBS_DIR="${OBS_DIR:-${WORKTREE_DIR}/observatory}"
METRICS_FILE="${OBS_DIR}/metrics.json"
HISTORY_FILE="${OBS_DIR}/metrics-history.jsonl"
STATE_FILE="${STATE_FILE:-${OBS_DIR}/state.json}"

# --- Preflight ---
mkdir -p "$OBS_DIR"

if [[ ! -f "$TRACE_INDEX" ]]; then
    echo "ERROR: Trace index not found at $TRACE_INDEX" >&2
    exit 1
fi

GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Stage 1: Agent success rate (single-pass jq over index.jsonl) ---
# Groups traces by agent_type, computing outcome distribution and avg duration.
# Bash 3.2: no declare -A. We use jq to produce per-agent JSON, then iterate.
AGENT_STATS=$(jq -sc '
  group_by(.agent_type // "unknown") |
  map({
    key: (.[0].agent_type // "unknown"),
    value: {
      count: length,
      outcomes: (
        group_by(.outcome // "unknown") |
        map({key: (.[0].outcome // "unknown"), value: length}) |
        from_entries
      ),
      avg_duration_s: (
        [.[] | select(.duration_seconds != null and .duration_seconds > 0) | .duration_seconds] |
        if length > 0 then (add / length | . * 10 | round / 10) else null end
      )
    }
  }) |
  from_entries
' "$TRACE_INDEX" 2>/dev/null || echo '{}')

TOTAL_TRACES=$(jq -sc 'length' "$TRACE_INDEX" 2>/dev/null || echo "0")

# --- Stage 2: Contract compliance rate (scan compliance.json files) ---
# For each agent type, counts how many required artifacts were:
#   - agent: written by the agent (source=agent in compliance.json)
#   - auto: captured by auto-capture hooks
#   - missing: not present at all
#
# Required artifacts per agent type (bash 3.2: parallel arrays)
# Format: "agent_type:artifact1,artifact2,..."
AGENT_CONTRACTS=(
    "implementer:summary.md,test-output.txt,diff.patch,files-changed.txt"
    "tester:summary.md,test-output.txt"
    "guardian:summary.md,diff.patch"
    "planner:summary.md"
)

# We collect compliance data by scanning trace directories.
# Output format: one line per (agent_type, artifact): "agent_type|artifact|agent|auto|missing|root_cause"
# We accumulate into a temp file, then aggregate with jq.
COMPLIANCE_TMP=$(mktemp)
trap 'rm -f "$COMPLIANCE_TMP"' EXIT

# Process each active trace directory (exclude oldTraces/)
# Bash 3.2: use find + process substitution
while IFS= read -r trace_dir; do
    [[ -z "$trace_dir" ]] && continue
    trace_id=$(basename "$trace_dir")

    # Get agent type from index.jsonl (faster than reading manifest)
    agent_type=$(jq -r --arg id "$trace_id" \
        'select(.trace_id == $id) | .agent_type // "unknown"' \
        "$TRACE_INDEX" 2>/dev/null | head -1)
    [[ -z "$agent_type" || "$agent_type" == "null" ]] && agent_type="unknown"

    artifacts_dir="${trace_dir}/artifacts"
    compliance_json="${artifacts_dir}/compliance.json"
    summary_exists=false
    [[ -f "${trace_dir}/summary.md" ]] && summary_exists=true

    # Find which contract applies to this agent type
    contract_artifacts=""
    for entry in "${AGENT_CONTRACTS[@]}"; do
        entry_agent="${entry%%:*}"
        if [[ "$entry_agent" == "$agent_type" ]]; then
            contract_artifacts="${entry#*:}"
            break
        fi
    done
    [[ -z "$contract_artifacts" ]] && continue

    # Determine root cause tier for missing artifacts
    # tier1: artifacts dir exists, summary exists → agent ran, didn't write
    # tier2: artifacts dir exists, no summary → agent crashed
    # tier3: no artifacts dir → trace never initialized
    if [[ ! -d "$artifacts_dir" ]]; then
        root_cause="no_trace_dir"
    elif [[ "$summary_exists" == "false" ]]; then
        root_cause="agent_crashed"
    else
        root_cause="agent_fault"
    fi

    # Process each required artifact
    IFS=',' read -ra artifacts_list <<< "$contract_artifacts"
    for artifact in "${artifacts_list[@]}"; do
        # Determine artifact path (summary.md is at trace root, others in artifacts/)
        if [[ "$artifact" == "summary.md" ]]; then
            artifact_path="${trace_dir}/summary.md"
        else
            artifact_path="${artifacts_dir}/${artifact}"
        fi

        # Check compliance.json for recorded source
        source_recorded="none"
        if [[ -f "$compliance_json" ]]; then
            # compliance.json format: {"artifact": {"source": "agent|auto", "written_at": "..."}, ...}
            source_recorded=$(jq -r \
                --arg art "$artifact" \
                '.[$art].source // "none"' \
                "$compliance_json" 2>/dev/null || echo "none")
        fi

        # Classify: agent, auto, or missing
        if [[ "$source_recorded" == "agent" ]]; then
            bucket="agent"
        elif [[ "$source_recorded" == "auto" ]]; then
            bucket="auto"
        elif [[ -f "$artifact_path" ]]; then
            # File exists but no compliance record — treat as agent (pre-v2 trace)
            bucket="agent"
        else
            bucket="missing"
        fi

        echo "${agent_type}|${artifact}|${bucket}|${root_cause}" >> "$COMPLIANCE_TMP"
    done
done < <(find "$TRACE_STORE" -maxdepth 1 -mindepth 1 -type d \
    ! -name '.git' ! -name 'oldTraces' 2>/dev/null | sort)

# Aggregate compliance data into per-agent-type, per-artifact counts
# Output: JSON object keyed by agent_type
COMPLIANCE_DATA="{}"

if [[ -s "$COMPLIANCE_TMP" ]]; then
    # Build a JSON array of rows for jq aggregation
    COMPLIANCE_JSON_ROWS=$(awk -F'|' '{
        printf "{\"agent\":\"%s\",\"artifact\":\"%s\",\"bucket\":\"%s\",\"root_cause\":\"%s\"}\n",
        $1, $2, $3, $4
    }' "$COMPLIANCE_TMP" | jq -sc '.')

    COMPLIANCE_DATA=$(echo "$COMPLIANCE_JSON_ROWS" | jq '
      group_by(.agent) |
      map({
        key: .[0].agent,
        value: (
          . as $rows |
          ($rows | map(.artifact) | unique) |
          map(. as $art | {
            key: $art,
            value: (
              $rows | map(select(.artifact == $art)) |
              {
                agent:   (map(select(.bucket == "agent"))   | length),
                auto:    (map(select(.bucket == "auto"))    | length),
                missing: (map(select(.bucket == "missing")) | length),
                rate: (
                  . as $all |
                  (($all | map(select(.bucket == "agent" or .bucket == "auto")) | length) |
                    . / ($all | length) | . * 100 | round / 100)
                ),
                root_causes: (
                  map(select(.bucket == "missing")) |
                  group_by(.root_cause) |
                  map({key: .[0].root_cause, value: length}) |
                  from_entries
                )
              }
            )
          }) |
          from_entries
        )
      }) |
      from_entries
    ' 2>/dev/null || echo '{}')
fi

# --- Stage 3: Build by_agent_type (merge outcomes + compliance) ---
# Merge AGENT_STATS and COMPLIANCE_DATA into unified per-agent objects.
BY_AGENT=$(jq -cn \
    --argjson stats "$AGENT_STATS" \
    --argjson compliance "$COMPLIANCE_DATA" \
    '
    ($stats | keys) as $agent_types |
    $agent_types | map(. as $at | {
        key: $at,
        value: (
            ($stats[$at]) +
            { compliance: ($compliance[$at] // {}) }
        )
    }) | from_entries
    ' 2>/dev/null || echo '{}')

# --- Stage 4: Generate suggestions for worst-performing metrics ---
# Find up to 3 metrics with compliance rate < 0.6 (60%).
# Suggestions are written to state.json v4.

# Read existing suggestions to avoid duplicates
EXISTING_SUGGESTIONS="[]"
if [[ -f "$STATE_FILE" ]]; then
    EXISTING_SUGGESTIONS=$(jq '.suggestions // []' "$STATE_FILE" 2>/dev/null || echo "[]")
fi
EXISTING_IDS=$(echo "$EXISTING_SUGGESTIONS" | jq -r '.[].metric' 2>/dev/null || echo "")

# Find worst compliance metrics (rate < 0.60)
WORST_METRICS=$(echo "$BY_AGENT" | jq -r '
  to_entries[] |
  .key as $agent |
  .value.compliance | to_entries[] |
  .key as $artifact |
  select(.value.rate < 0.60) |
  "\($agent).\($artifact)=\(.value.rate)"
' 2>/dev/null | sort -t= -k2 -n | head -3)

NEW_SUGGESTIONS="[]"
SUG_COUNTER=$(echo "$EXISTING_SUGGESTIONS" | jq 'length' 2>/dev/null || echo "0")

while IFS= read -r metric_line; do
    [[ -z "$metric_line" ]] && continue
    metric_key="${metric_line%%=*}"
    metric_val="${metric_line##*=}"
    agent_type="${metric_key%%.*}"
    artifact="${metric_key#*.}"

    # Skip if a suggestion for this metric already exists
    if echo "$EXISTING_IDS" | grep -qF "$metric_key"; then
        continue
    fi

    SUG_COUNTER=$((SUG_COUNTER + 1))
    SUG_ID=$(printf "SUG-%03d" "$SUG_COUNTER")
    THRESHOLD="0.60"
    CONVERGENCE_CHECK="${metric_key}.compliance.rate > ${THRESHOLD}"
    TITLE="Improve ${agent_type} contract compliance for ${artifact}"

    NEW_SUGGESTIONS=$(echo "$NEW_SUGGESTIONS" | jq \
        --arg id "$SUG_ID" \
        --arg metric "compliance.${metric_key}.rate" \
        --argjson metric_val "$(echo "$metric_val" | jq -r 'tonumber | . * 100 | round / 100')" \
        --arg title "$TITLE" \
        --arg conv "$CONVERGENCE_CHECK" \
        --arg now "$GENERATED_AT" \
        '. + [{
            "id": $id,
            "metric": $metric,
            "metric_value_at_suggestion": $metric_val,
            "title": $title,
            "convergence_check": $conv,
            "status": "proposed",
            "suggested_at": $now,
            "implemented_at": null,
            "converged_at": null
        }]')
done <<< "$WORST_METRICS"

# Merge new suggestions with existing, write state.json v4
ALL_SUGGESTIONS=$(jq -cn \
    --argjson existing "$EXISTING_SUGGESTIONS" \
    --argjson new_sug "$NEW_SUGGESTIONS" \
    '$existing + $new_sug')

# Write state.json with v4 schema
jq -cn \
    --arg generated_at "$GENERATED_AT" \
    --argjson suggestions "$ALL_SUGGESTIONS" \
    '{
        "version": 4,
        "last_analysis_at": $generated_at,
        "suggestions": $suggestions
    }' > "$STATE_FILE"

# --- Stage 5: Assemble metrics.json ---
jq -cn \
    --arg generated_at "$GENERATED_AT" \
    --argjson trace_count "$TOTAL_TRACES" \
    --argjson by_agent_type "$BY_AGENT" \
    '{
        "generated_at": $generated_at,
        "trace_count": $trace_count,
        "by_agent_type": $by_agent_type
    }' > "$METRICS_FILE"

# --- Stage 6: Append flattened metrics to metrics-history.jsonl ---
# Each line is a flat record: {ts, agent_type, artifact, rate}
# Used by converge.sh to compute trends.
echo "$BY_AGENT" | jq -c \
    --arg ts "$GENERATED_AT" \
    'to_entries[] |
     .key as $agent |
     .value.compliance | to_entries[] |
     {ts: $ts, agent_type: $agent, artifact: .key, rate: .value.rate, count: (.value.agent + .value.auto + .value.missing)}
    ' 2>/dev/null >> "$HISTORY_FILE" || true

# --- Summary output ---
SIG_COUNT=$(echo "$NEW_SUGGESTIONS" | jq 'length')
echo "Analysis complete: ${TOTAL_TRACES} traces → ${METRICS_FILE}"
echo "  Agents tracked: $(echo "$BY_AGENT" | jq 'keys | length') types"
[[ "$SIG_COUNT" -gt 0 ]] && echo "  New suggestions: ${SIG_COUNT} → ${STATE_FILE}"
echo "  History appended: ${HISTORY_FILE}"

#!/usr/bin/env bash
# analyze.sh — Observatory Stage 1: trace analysis → analysis-cache.json
#
# Purpose: Read trace data from multiple sources and produce a structured
#          analysis-cache.json with data quality signals, temporal trends,
#          and agent-type breakdowns. This is the foundation of the self-
#          improving flywheel — bad data quality here is itself the first
#          signal to fix.
#
# @decision DEC-OBS-006
# @title Single-pass jq aggregation for trace stats
# @status accepted
# @rationale The trace index has 320+ entries and grows over time. Using
#             `jq -sc` reads the entire file in one pass and aggregates all
#             stats in a single jq expression, hitting the <2s performance
#             target. Multi-pass approaches (one jq call per stat) would be
#             O(N * queries) and visibly slow at scale.
#
# @decision DEC-OBS-007
# @title Hardcoded signal detection with evidence thresholds
# @status accepted
# @rationale Signals are known root causes from code inspection, not discovered
#             dynamically. Hardcoding them with evidence thresholds (affected_count > 0)
#             means signals only appear when the data confirms the bug, and disappear
#             once fixed. This is correct behavior for a self-improving system —
#             the signals document known bugs until the bugs are gone.
#             Extended from 5 to 12 signals in v2 (DEC-OBS-017).
#
# @decision DEC-OBS-013
# @title Temporal trends via analysis-cache.prev.json snapshot
# @status accepted
# @rationale Before overwriting analysis-cache.json, copy it to
#             analysis-cache.prev.json. Stage 4b then diffs current vs prev
#             to produce signal_count_delta and per-signal affected deltas.
#             This costs one extra file write but gives the report meaningful
#             trend arrows without any external state. If no prev exists
#             (first run), trends are null (not an error).
#
# @decision DEC-OBS-017
# @title 7 new signals across 3 new categories (v2 extension)
# @status accepted
# @rationale Extended from 5 signals (data_quality/trace_completeness) to 12
#             signals across 5 categories. New categories: workflow_compliance
#             (Sacred Practice violations), agent_performance (crash clusters,
#             stale markers), trace_infrastructure (proof_status capture gaps).
#             Stage 2b added for stale marker detection (file-system scan).
#             Stage 4c crash cluster analysis uses agent_breakdown output.
#             New fields: trace_stats.{main_impl_count,branch_unknown_count,
#             agent_type_plan_count}, stale_markers top-level object,
#             artifact_health.proof_unknown_count.
#
# @decision DEC-OBS-021
# @title Stage 5 cohort regression detection against post-implementation traces
# @status accepted
# @rationale Implemented signals are normally suppressed. But if the fix was
#             ineffective, new traces will still trigger the same signal —
#             creating a silent regression that nobody sees. Stage 5 filters
#             index.jsonl to only traces with started_at > implemented_at for
#             each implemented signal that has a timestamp. If cohort_size >= 10
#             and cohort_affected / cohort_size > 0.5, the signal is marked as
#             a regression in cohort_regressions[]. suggest.sh reads this field
#             to re-propose the signal with regression=true. Signals from v1/v2
#             state (no implemented_at timestamp) are skipped — backwards
#             compatible with pre-v3 state files.
#
# Output: ~/.claude/observatory/analysis-cache.json
#         ~/.claude/observatory/analysis-cache.prev.json (previous run snapshot)
# Usage: bash skills/observatory/scripts/analyze.sh

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
WORKTREE_DIR="${WORKTREE_DIR:-$CLAUDE_DIR}"
TRACE_INDEX="${CLAUDE_DIR}/traces/index.jsonl"
TRACE_STORE="${CLAUDE_DIR}/traces"
OBS_DIR="${OBS_DIR:-${WORKTREE_DIR}/observatory}"
CACHE_FILE="${OBS_DIR}/analysis-cache.json"
PREV_CACHE_FILE="${OBS_DIR}/analysis-cache.prev.json"
STATE_FILE="${STATE_FILE:-${OBS_DIR}/state.json}"

# --- Preflight ---
mkdir -p "$OBS_DIR"

if [[ ! -f "$TRACE_INDEX" ]]; then
    echo "ERROR: Trace index not found at $TRACE_INDEX" >&2
    exit 1
fi

# Snapshot previous analysis for trend tracking (Stage 4b)
if [[ -f "$CACHE_FILE" ]]; then
    cp "$CACHE_FILE" "$PREV_CACHE_FILE"
fi

# --- Stage 1: Trace index stats (single-pass jq) ---
# Includes v2 fields: main_impl_count, branch_unknown_count, agent_type_plan_count
TRACE_STATS=$(jq -sc '
  {
    total: length,
    outcome_dist: (
      group_by(.outcome) |
      map({key: (.[0].outcome // "unknown"), value: length}) |
      from_entries
    ),
    test_dist: (
      group_by(.test_result) |
      map({key: (.[0].test_result // "unknown"), value: length}) |
      from_entries
    ),
    files_changed_zero_count: (map(select(.files_changed == 0)) | length),
    negative_duration_count: (map(select(.duration_seconds < 0)) | length),
    zero_duration_count: (map(select(.duration_seconds == 0)) | length),
    main_impl_count: (map(select(.agent_type == "implementer" and (.branch == "main" or .branch == "master"))) | length),
    branch_unknown_count: (map(select(.branch == "unknown")) | length),
    agent_type_plan_count: (map(select(.agent_type == "Plan")) | length)
  }
' "$TRACE_INDEX" 2>/dev/null)

TOTAL=$(echo "$TRACE_STATS" | jq '.total')
FILES_ZERO=$(echo "$TRACE_STATS" | jq '.files_changed_zero_count')
NEG_DUR=$(echo "$TRACE_STATS" | jq '.negative_duration_count')
ZERO_DUR=$(echo "$TRACE_STATS" | jq '.zero_duration_count')
BAD_DUR=$((NEG_DUR + ZERO_DUR))
# v2 workflow_compliance counts
MAIN_IMPL_COUNT=$(echo "$TRACE_STATS" | jq '.main_impl_count')
BRANCH_UNKNOWN_COUNT=$(echo "$TRACE_STATS" | jq '.branch_unknown_count')
AGENT_TYPE_PLAN_COUNT=$(echo "$TRACE_STATS" | jq '.agent_type_plan_count')

# Compute percentage of zero files_changed
FILES_ZERO_PCT=$(jq -n "$FILES_ZERO / $TOTAL * 100" 2>/dev/null || echo "0")

# Count unknown test results
UNKNOWN_TEST=$(echo "$TRACE_STATS" | jq '.test_dist.unknown // 0')
PARTIAL_OUTCOME=$(echo "$TRACE_STATS" | jq '.outcome_dist.partial // 0')

# Add files_changed_zero_pct to stats
TRACE_STATS=$(echo "$TRACE_STATS" | jq \
    --argjson pct "$FILES_ZERO_PCT" \
    '. + {files_changed_zero_pct: ($pct | round * 10 / 10)}')

# --- Stage 2: Artifact health (scan actual trace dirs) ---
# Includes proof_unknown_count for SIG-PROOF-UNKNOWN detection
TOTAL_TRACE_DIRS=0
SUMMARY_EXISTS=0
TEST_OUTPUT_EXISTS=0
DIFF_EXISTS=0
FILES_CHANGED_EXISTS=0
PROOF_UNKNOWN=0

while IFS= read -r trace_dir; do
    artifacts_dir="${trace_dir}/artifacts"
    (( TOTAL_TRACE_DIRS++ ))
    [[ -f "${trace_dir}/summary.md" ]] && (( SUMMARY_EXISTS++ )) || true
    [[ -f "${artifacts_dir}/test-output.txt" ]] && (( TEST_OUTPUT_EXISTS++ )) || true
    [[ -f "${artifacts_dir}/diff.patch" ]] && (( DIFF_EXISTS++ )) || true
    [[ -f "${artifacts_dir}/files-changed.txt" ]] && (( FILES_CHANGED_EXISTS++ )) || true
    # Count traces where proof_status is unknown or missing
    if [[ -f "${trace_dir}/manifest.json" ]]; then
        local_proof=$(jq -r '.proof_status // "missing"' "${trace_dir}/manifest.json" 2>/dev/null || echo "missing")
        if [[ "$local_proof" == "unknown" || "$local_proof" == "missing" ]]; then
            (( PROOF_UNKNOWN++ )) || true
        fi
    fi
done < <(find "$TRACE_STORE" -maxdepth 1 -mindepth 1 -type d ! -name '.git' 2>/dev/null | sort)

# Compute completeness rates
compute_rate() {
    local count="$1" total="$2"
    if [[ "$total" -eq 0 ]]; then echo "0"; return; fi
    jq -n "$count / $total" 2>/dev/null || echo "0"
}

SUMMARY_RATE=$(compute_rate "$SUMMARY_EXISTS" "$TOTAL_TRACE_DIRS")
TEST_RATE=$(compute_rate "$TEST_OUTPUT_EXISTS" "$TOTAL_TRACE_DIRS")
DIFF_RATE=$(compute_rate "$DIFF_EXISTS" "$TOTAL_TRACE_DIRS")
FILES_RATE=$(compute_rate "$FILES_CHANGED_EXISTS" "$TOTAL_TRACE_DIRS")

ARTIFACT_HEALTH=$(jq -cn \
    --argjson total "$TOTAL_TRACE_DIRS" \
    --argjson summary "$SUMMARY_RATE" \
    --argjson test_out "$TEST_RATE" \
    --argjson diff "$DIFF_RATE" \
    --argjson files "$FILES_RATE" \
    --argjson proof_unknown "$PROOF_UNKNOWN" \
    '{
      total_traces: $total,
      proof_unknown_count: $proof_unknown,
      completeness: {
        "summary.md": ($summary | . * 100 | round / 100),
        "test-output.txt": ($test_out | . * 100 | round / 100),
        "diff.patch": ($diff | . * 100 | round / 100),
        "files-changed.txt": ($files | . * 100 | round / 100)
      }
    }')

# --- Stage 2b: Stale marker detection ---
# .active-* files in TRACE_STORE are created by init_trace() and should be
# removed by finalize_trace(). Orphaned markers cause false "agent already running"
# blocks and indicate crash scenarios where cleanup didn't run.
STALE_MARKER_COUNT=0
STALE_MARKERS="[]"
while IFS= read -r marker_file; do
    [[ -z "$marker_file" ]] && continue
    (( STALE_MARKER_COUNT++ )) || true
    marker_name=$(basename "$marker_file")
    marker_age=$(( $(date +%s) - $(stat -c %Y "$marker_file" 2>/dev/null || stat -f %m "$marker_file" 2>/dev/null || echo "0") ))
    STALE_MARKERS=$(echo "$STALE_MARKERS" | jq \
        --arg name "$marker_name" \
        --argjson age "$marker_age" \
        '. + [{"name": $name, "age_seconds": $age}]')
done < <(find "$TRACE_STORE" -maxdepth 1 -name '.active-*' -type f 2>/dev/null)

# --- Stage 3: Self-metrics from state.json ---
SELF_METRICS='{"total_suggestions": 0, "implemented": 0, "rejected": 0, "acceptance_rate": null}'
if [[ -f "$STATE_FILE" ]]; then
    IMPL_COUNT=$(jq '.implemented | length' "$STATE_FILE" 2>/dev/null || echo "0")
    REJ_COUNT=$(jq '.rejected | length' "$STATE_FILE" 2>/dev/null || echo "0")
    TOTAL_SIGS=$((IMPL_COUNT + REJ_COUNT))
    if [[ "$TOTAL_SIGS" -gt 0 ]]; then
        ACCEPT_RATE=$(jq -n "$IMPL_COUNT / $TOTAL_SIGS" 2>/dev/null || echo "null")
    else
        ACCEPT_RATE="null"
    fi
    SELF_METRICS=$(jq -cn \
        --argjson impl "$IMPL_COUNT" \
        --argjson rej "$REJ_COUNT" \
        --argjson total "$TOTAL_SIGS" \
        --argjson rate "$ACCEPT_RATE" \
        '{total_suggestions: $total, implemented: $impl, rejected: $rej, acceptance_rate: $rate}')
fi

# --- Stage 4: Build improvement signals ---
# Only emit a signal when evidence shows the bug is present (affected_count > 0).
# Signals auto-disappear once the underlying bug is fixed.

SIGNALS="[]"

# SIG-DURATION-BUG: negative or zero durations dominate
if [[ "$BAD_DUR" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$BAD_DUR" \
        --argjson total "$TOTAL" \
        '. + [{
          "id": "SIG-DURATION-BUG",
          "category": "data_quality",
          "severity": "high",
          "description": "date -j -f missing -u flag causes negative/zero durations",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "finalize_trace() in context-lib.sh line 569: date -j -f parses UTC string as local time without -u flag"
        }]')
fi

# SIG-TEST-UNKNOWN: high rate of unknown test results
if [[ "$UNKNOWN_TEST" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$UNKNOWN_TEST" \
        --argjson total "$TOTAL" \
        '. + [{
          "id": "SIG-TEST-UNKNOWN",
          "category": "data_quality",
          "severity": "high",
          "description": "High rate of unknown test_result in trace index",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "finalize_trace only checks test-output.txt artifact, no fallback to .test-status file in project root"
        }]')
fi

# SIG-FILES-ZERO: high rate of zero files_changed
if [[ "$FILES_ZERO" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$FILES_ZERO" \
        --argjson total "$TOTAL" \
        '. + [{
          "id": "SIG-FILES-ZERO",
          "category": "data_quality",
          "severity": "medium",
          "description": "High rate of zero files_changed in trace index",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "finalize_trace only checks files-changed.txt artifact, no git diff --stat fallback"
        }]')
fi

# SIG-OUTCOME-FLAT: partial outcome dominates (>50% is a signal)
PARTIAL_THRESHOLD=$(jq -n "$TOTAL * 0.5" | jq 'floor')
if [[ "$PARTIAL_OUTCOME" -gt "$PARTIAL_THRESHOLD" ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$PARTIAL_OUTCOME" \
        --argjson total "$TOTAL" \
        '. + [{
          "id": "SIG-OUTCOME-FLAT",
          "category": "data_quality",
          "severity": "medium",
          "description": "Outcome field dominated by partial — classification too binary",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "Outcome only becomes success if test_result==pass, failure if fail, else partial — no crashed/timeout/skipped states"
        }]')
fi

# SIG-ARTIFACT-MISSING: low artifact completeness (< 20% for summary.md is a signal)
SUMMARY_PCT=$(jq -n "$SUMMARY_EXISTS / ($TOTAL_TRACE_DIRS == 0 | if . then 1 else $TOTAL_TRACE_DIRS end) * 100" 2>/dev/null || echo "100")
LOW_COMPLETENESS_THRESHOLD=20
if (( TOTAL_TRACE_DIRS > 0 )) && \
   [[ $(jq -n "$SUMMARY_PCT < $LOW_COMPLETENESS_THRESHOLD" 2>/dev/null) == "true" ]]; then
    MISSING_ARTIFACT_COUNT=$(( TOTAL_TRACE_DIRS - SUMMARY_EXISTS ))
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$MISSING_ARTIFACT_COUNT" \
        --argjson total "$TOTAL_TRACE_DIRS" \
        '. + [{
          "id": "SIG-ARTIFACT-MISSING",
          "category": "trace_completeness",
          "severity": "medium",
          "description": "Most trace directories lack expected artifacts (summary.md, test-output.txt, etc.)",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "Agents do not consistently write to TRACE_DIR/artifacts/ — missing TRACE_DIR env or early exit"
        }]')
fi

# --- Stage 4 (v2): Workflow compliance signals ---

# SIG-MAIN-IMPL: implementer agents on main/master branch (Sacred Practice #2)
if [[ "$MAIN_IMPL_COUNT" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$MAIN_IMPL_COUNT" \
        --argjson total "$TOTAL" \
        '. + [{
          "id": "SIG-MAIN-IMPL",
          "category": "workflow_compliance",
          "severity": "high",
          "description": "Implementer agents running on main/master branch instead of worktrees — Sacred Practice #2 violation",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "Implementer dispatched without creating a worktree first"
        }]')
fi

# SIG-BRANCH-UNKNOWN: traces where branch capture failed (git not available)
if [[ "$BRANCH_UNKNOWN_COUNT" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$BRANCH_UNKNOWN_COUNT" \
        --argjson total "$TOTAL" \
        '. + [{
          "id": "SIG-BRANCH-UNKNOWN",
          "category": "workflow_compliance",
          "severity": "low",
          "description": "Traces with branch='\''unknown'\'' — git metadata not captured at trace creation",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "init_trace() doesn'\''t capture branch when project isn'\''t a git repo or git rev-parse fails"
        }]')
fi

# SIG-AGENT-TYPE-MISMATCH: "Plan" (capital P) instead of normalized "planner"
if [[ "$AGENT_TYPE_PLAN_COUNT" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$AGENT_TYPE_PLAN_COUNT" \
        --argjson total "$TOTAL" \
        '. + [{
          "id": "SIG-AGENT-TYPE-MISMATCH",
          "category": "workflow_compliance",
          "severity": "medium",
          "description": "Agent type '\''Plan'\'' used instead of '\''planner'\'' — inconsistent naming fragments analysis",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "Task subagent_type='\''Plan'\'' not normalized to '\''planner'\'' in init_trace()"
        }]')
fi

# --- Stage 4 (v2): Agent performance signals ---

# SIG-STALE-MARKERS: orphaned .active-* marker files
if [[ "$STALE_MARKER_COUNT" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$STALE_MARKER_COUNT" \
        --argjson total "$TOTAL" \
        --argjson markers "$STALE_MARKERS" \
        '. + [{
          "id": "SIG-STALE-MARKERS",
          "category": "agent_performance",
          "severity": "low",
          "description": "Orphaned .active-* marker files left by crashed agents — can cause false '\''agent already running'\'' blocks",
          "evidence": {"affected_count": $affected, "total": $total, "stale_markers": $markers},
          "root_cause": "finalize_trace() cleanup path not reached when agents crash or are killed"
        }]')
fi

# --- Stage 4 (v2): Trace infrastructure signals ---

# SIG-PROOF-UNKNOWN: >80% of trace manifests have proof_status unknown/missing
# Only emit when we have enough traces to make a meaningful assessment
PROOF_UNKNOWN_PCT=$(jq -n "if $TOTAL_TRACE_DIRS > 0 then $PROOF_UNKNOWN / $TOTAL_TRACE_DIRS else 0 end" 2>/dev/null || echo "0")
# Threshold: >= 0.8 (80% or more unknown = systemic capture failure)
if (( TOTAL_TRACE_DIRS > 0 )) && \
   [[ $(jq -n "$PROOF_UNKNOWN_PCT >= 0.8" 2>/dev/null) == "true" ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$PROOF_UNKNOWN" \
        --argjson total "$TOTAL_TRACE_DIRS" \
        '. + [{
          "id": "SIG-PROOF-UNKNOWN",
          "category": "trace_infrastructure",
          "severity": "medium",
          "description": "proof_status not tracked in most traces — verification gate state lost",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "finalize_trace() checks .proof-status file but most traces don'\''t have one because the file is project-scoped, not trace-scoped"
        }]')
fi

# --- Stage 4b: Temporal trends (compare with previous run) ---
# If analysis-cache.prev.json exists, compute deltas to detect trends.
TRENDS="null"
if [[ -f "$PREV_CACHE_FILE" ]]; then
    PREV_SIG_COUNT=$(jq '.improvement_signals | length' "$PREV_CACHE_FILE" 2>/dev/null || echo "0")
    CURR_SIG_COUNT=$(echo "$SIGNALS" | jq 'length')
    SIG_DELTA=$((CURR_SIG_COUNT - PREV_SIG_COUNT))

    # Determine trend direction
    if [[ "$SIG_DELTA" -lt 0 ]]; then
        SIG_TREND="improving"
    elif [[ "$SIG_DELTA" -gt 0 ]]; then
        SIG_TREND="worsening"
    else
        SIG_TREND="stable"
    fi

    PREV_TOTAL=$(jq '.trace_stats.total // 0' "$PREV_CACHE_FILE" 2>/dev/null || echo "0")
    TRACE_DELTA=$((TOTAL - PREV_TOTAL))

    # Per-signal affected-count deltas: did affected counts go up or down?
    PER_SIGNAL_TRENDS=$(echo "$SIGNALS" | jq \
        --slurpfile prev <(cat "$PREV_CACHE_FILE") \
        '[.[] | {
          id: .id,
          current_affected: .evidence.affected_count,
          prev_affected: (
            ($prev[0].improvement_signals // []) |
            map(select(.id == .id)) |
            if length > 0 then .[0].evidence.affected_count else null end
          ),
          delta: (
            .evidence.affected_count as $curr |
            (($prev[0].improvement_signals // []) | map(select(.id == .id)) | if length > 0 then .[0].evidence.affected_count else null end) as $prev_val |
            if $prev_val != null then ($curr - $prev_val) else null end
          )
        }]' 2>/dev/null || echo "[]")

    # New signals since last run
    NEW_SIGNALS=$(echo "$SIGNALS" | jq \
        --slurpfile prev <(cat "$PREV_CACHE_FILE") \
        '[.[] | .id] - [($prev[0].improvement_signals // []) | .[].id]' 2>/dev/null || echo "[]")

    TRENDS=$(jq -cn \
        --argjson sig_delta "$SIG_DELTA" \
        --arg sig_trend "$SIG_TREND" \
        --argjson trace_delta "$TRACE_DELTA" \
        --argjson per_signal "$PER_SIGNAL_TRENDS" \
        --argjson new_signals "$NEW_SIGNALS" \
        '{
          signal_count_delta: $sig_delta,
          signal_trend: $sig_trend,
          trace_count_delta: $trace_delta,
          per_signal: $per_signal,
          new_signals: $new_signals
        }')
fi

# --- Stage 4c: Agent-type breakdown ---
# Aggregate traces by agent_type field (if present in index entries).
# Not all entries have agent_type — those without are grouped as "unknown".
AGENT_BREAKDOWN=$(jq -sc '
  group_by(.agent_type // "unknown") |
  map({
    agent_type: (.[0].agent_type // "unknown"),
    count: length,
    outcome_dist: (
      group_by(.outcome) |
      map({key: (.[0].outcome // "unknown"), value: length}) |
      from_entries
    ),
    artifact_rate: (
      (map(select(.files_changed != null and .files_changed > 0)) | length) / length
    ),
    avg_duration: (
      [.[] | select(.duration_seconds != null and .duration_seconds > 0) | .duration_seconds] |
      if length > 0 then (add / length | . * 10 | round / 10) else null end
    )
  }) |
  sort_by(-.count)
' "$TRACE_INDEX" 2>/dev/null || echo "[]")

# --- Stage 4d: SIG-CRASH-CLUSTER — agent types with >50% crash rate AND >5 traces ---
# Uses AGENT_BREAKDOWN computed above. Must run after Stage 4c.
CRASH_CLUSTER_COUNT=0
CRASH_CLUSTER_AGENTS="[]"
if [[ "$AGENT_BREAKDOWN" != "[]" ]]; then
    CRASH_CLUSTER_AGENTS=$(echo "$AGENT_BREAKDOWN" | jq '[
        .[] |
        select(.count > 5) |
        select(
            (.outcome_dist.crashed // 0) / .count > 0.5
        ) |
        {
            agent_type,
            count,
            crashed: (.outcome_dist.crashed // 0),
            crash_rate: ((.outcome_dist.crashed // 0) / .count * 100 | round)
        }
    ]' 2>/dev/null || echo "[]")
    CRASH_CLUSTER_COUNT=$(echo "$CRASH_CLUSTER_AGENTS" | jq 'length' 2>/dev/null || echo "0")
fi

if [[ "$CRASH_CLUSTER_COUNT" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$CRASH_CLUSTER_COUNT" \
        --argjson total "$TOTAL" \
        --argjson agents "$CRASH_CLUSTER_AGENTS" \
        '. + [{
          "id": "SIG-CRASH-CLUSTER",
          "category": "agent_performance",
          "severity": "high",
          "description": "Agent types with >50% crash rate — indicates systematic failure in agent dispatch or prompt",
          "evidence": {"affected_count": $affected, "total": $total, "crash_cluster_agents": $agents},
          "root_cause": "Certain agent types consistently crash — likely prompt issues, missing env vars, or improper dispatch"
        }]')
fi

# --- Stage 5: Cohort regression detection (DEC-OBS-021) ---
# For each implemented signal with an implemented_at timestamp, filter the
# trace index to only post-implementation traces and re-evaluate the signal's
# evidence gate. Records cohort_size, cohort_affected, and regression flag.
# Signals with no timestamp (legacy v1/v2 format) are skipped silently.

# check_cohort_regression <signal_id> <implemented_at>
# Outputs: "<cohort_size>|<cohort_affected>"
check_cohort_regression() {
    local signal_id="$1"
    local implemented_at="$2"

    # Single-pass aggregation of post-implementation cohort stats
    local cohort_stats
    cohort_stats=$(jq -sc --arg since "$implemented_at" '
        [.[] | select(.started_at != null and .started_at > $since)] |
        {
            cohort_size: length,
            test_unknown:   (map(select(.test_result == "unknown")) | length),
            files_zero:     (map(select(.files_changed == 0 or .files_changed == null)) | length),
            bad_duration:   (map(select(.duration_seconds != null and .duration_seconds <= 0)) | length),
            main_impl:      (map(select(.agent_type == "implementer" and (.branch == "main" or .branch == "master"))) | length),
            branch_unknown: (map(select(.branch == "unknown")) | length),
            agent_type_plan:(map(select(.agent_type == "Plan")) | length),
            partial_outcome:(map(select(.outcome == "partial")) | length)
        }
    ' "$TRACE_INDEX" 2>/dev/null || echo '{"cohort_size":0}')

    local cohort_size cohort_affected
    cohort_size=$(echo "$cohort_stats" | jq '.cohort_size // 0')

    case "$signal_id" in
        SIG-TEST-UNKNOWN)        cohort_affected=$(echo "$cohort_stats" | jq '.test_unknown // 0') ;;
        SIG-FILES-ZERO)          cohort_affected=$(echo "$cohort_stats" | jq '.files_zero // 0') ;;
        SIG-DURATION-BUG)        cohort_affected=$(echo "$cohort_stats" | jq '.bad_duration // 0') ;;
        SIG-MAIN-IMPL)           cohort_affected=$(echo "$cohort_stats" | jq '.main_impl // 0') ;;
        SIG-BRANCH-UNKNOWN)      cohort_affected=$(echo "$cohort_stats" | jq '.branch_unknown // 0') ;;
        SIG-AGENT-TYPE-MISMATCH) cohort_affected=$(echo "$cohort_stats" | jq '.agent_type_plan // 0') ;;
        SIG-OUTCOME-FLAT)
            # Partial-outcome regression uses the same >50% threshold as the signal itself
            local partial total_c
            partial=$(echo "$cohort_stats" | jq '.partial_outcome // 0')
            total_c="$cohort_size"
            # Only affected if partial > 50% of cohort
            cohort_affected=$(jq -n \
                --argjson p "$partial" --argjson t "$total_c" \
                'if $t > 0 and ($p / $t) > 0.5 then $p else 0 end' 2>/dev/null || echo "0")
            ;;
        *)                       cohort_affected=0 ;;
    esac

    echo "${cohort_size}|${cohort_affected}"
}

COHORT_REGRESSIONS="[]"

if [[ -f "$STATE_FILE" ]]; then
    # Process only object-format implemented entries (have signal_id + implemented_at)
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == "null" ]] && continue
        signal_id=$(echo "$entry" | jq -r '.signal_id // empty' 2>/dev/null)
        impl_at=$(echo "$entry" | jq -r '.implemented_at // empty' 2>/dev/null)
        sug_id=$(echo "$entry" | jq -r '.sug_id // empty' 2>/dev/null)

        # Skip entries without a timestamp or signal_id (legacy format)
        [[ -z "$signal_id" || "$signal_id" == "null" ]] && continue
        [[ -z "$impl_at"   || "$impl_at"   == "null" ]] && continue

        result=$(check_cohort_regression "$signal_id" "$impl_at")
        c_size="${result%%|*}"
        c_affected="${result##*|}"

        # Regression: cohort >= 10 AND affected > 50% of cohort
        if [[ "$c_size" -ge 10 ]] && (( c_affected * 2 > c_size )); then
            COHORT_REGRESSIONS=$(echo "$COHORT_REGRESSIONS" | jq \
                --arg sig "$signal_id" \
                --arg sug "$sug_id" \
                --argjson size "$c_size" \
                --argjson affected "$c_affected" \
                '. + [{"signal_id": $sig, "sug_id": $sug, "cohort_size": $size, "cohort_affected": $affected, "regression": true}]')
        fi
    done < <(jq -c '.implemented[] | select(type == "object")' "$STATE_FILE" 2>/dev/null || true)
fi

# --- Stage 6: Assemble and write output ---
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build stale_markers summary object for top-level output
STALE_MARKERS_OBJ=$(jq -cn \
    --argjson count "$STALE_MARKER_COUNT" \
    --argjson details "$STALE_MARKERS" \
    '{"count": $count, "details": $details}')

jq -cn \
    --arg generated_at "$GENERATED_AT" \
    --argjson trace_stats "$TRACE_STATS" \
    --argjson artifact_health "$ARTIFACT_HEALTH" \
    --argjson self_metrics "$SELF_METRICS" \
    --argjson signals "$SIGNALS" \
    --argjson trends "$TRENDS" \
    --argjson agent_breakdown "$AGENT_BREAKDOWN" \
    --argjson stale_markers "$STALE_MARKERS_OBJ" \
    --argjson cohort_regressions "$COHORT_REGRESSIONS" \
    '{
      version: 3,
      generated_at: $generated_at,
      trace_stats: $trace_stats,
      artifact_health: $artifact_health,
      self_metrics: $self_metrics,
      improvement_signals: $signals,
      cohort_regressions: $cohort_regressions,
      trends: $trends,
      agent_breakdown: $agent_breakdown,
      stale_markers: $stale_markers
    }' > "$CACHE_FILE"

SIG_COUNT=$(echo "$SIGNALS" | jq 'length')
echo "Analysis complete: $TOTAL traces, $SIG_COUNT signals detected → $CACHE_FILE"

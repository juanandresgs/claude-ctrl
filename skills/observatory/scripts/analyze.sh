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

# --- Pre-Stage: Re-finalize stale traces and rebuild index ---
# Ensures observatory analyzes accurate data by correcting manifests where
# artifacts arrived after initial finalization, then rebuilding the index.
# log.sh must be sourced before context-lib.sh (provides get_claude_dir()).
# Guarded with set +e so a malformed manifest doesn't abort the analysis run.
#
# @decision DEC-REFINALIZE-004
# @title Pre-stage re-finalization before Observatory analysis
# @status accepted
# @rationale analyze.sh reads index.jsonl which was written at SubagentStop time,
#   before agents finish writing artifacts. Running refinalize_stale_traces() here
#   corrects stale manifests (test_result=unknown, files_changed=0) and rebuilds
#   the index so Stage 1 stats reflect the true artifact state. The rebuild is
#   skipped when no traces were updated to avoid unnecessary I/O on clean runs.
if [[ -f "${CLAUDE_DIR}/hooks/log.sh" && -f "${CLAUDE_DIR}/hooks/context-lib.sh" ]]; then
    set +e
    # shellcheck source=/dev/null
    source "${CLAUDE_DIR}/hooks/log.sh"
    # shellcheck source=/dev/null
    source "${CLAUDE_DIR}/hooks/context-lib.sh"
    REFINALIZED=$(refinalize_stale_traces 2>/dev/null || echo "0")
    if [[ "${REFINALIZED:-0}" -gt 0 ]]; then
        rebuild_index 2>/dev/null || true
        echo "Pre-stage: re-finalized ${REFINALIZED} trace(s), rebuilt index"
    fi
    set -e
fi

# --- Stage 0: Dataset Integrity Check ---
# Detects data loss (trace count dropped >30%) and missing historical baseline
# (no prior analysis run exists with a different generated_at). These flags
# suppress trend analysis and add a "Data Integrity" section to the report to
# prevent false trend signals.
#
# @decision DEC-TRACE-PROT-004
# @title Stage 0 dataset integrity check before analysis
# @status accepted
# @rationale Trend comparisons (Stage 4b) are only meaningful when the dataset
#   is stable. If traces were deleted since the last run, the signal count delta
#   reflects data loss rather than real improvements — a false "improving" trend.
#   DATA_LOSS_SUSPECTED and NO_HISTORICAL_BASELINE flags are written to
#   dataset_integrity in the cache.
#
# @decision DEC-OBS-P2-109
# @title NO_HISTORICAL_BASELINE uses prior-run detection, not calendar-day uniqueness
# @status accepted
# @rationale The original implementation set NO_HISTORICAL_BASELINE when all active
#   traces fell on the same calendar day. This false-flagged multi-run observatory
#   sessions within a single day (e.g., developer runs /observatory three times on
#   the same day). The correct indicator of "no historical baseline" is whether a
#   prior analysis run exists: if analysis-cache.prev.json is absent or has the
#   same generated_at as the current run (meaning this is the first run), trends
#   cannot be computed. A single-day-only warning is kept as a secondary advisory
#   in the dataset_integrity output but does NOT suppress trend analysis.
#   Fix for issue #109.
DATA_LOSS_SUSPECTED=false
NO_HISTORICAL_BASELINE=false
SINGLE_DAY_ONLY=false
PREV_TRACE_COUNT=0
PREV_GENERATED_AT=""

# Read previous trace count and generated_at from previous cache
if [[ -f "$PREV_CACHE_FILE" ]]; then
    PREV_TRACE_COUNT=$(jq -r '.trace_stats.total // 0' "$PREV_CACHE_FILE" 2>/dev/null || echo "0")
    PREV_GENERATED_AT=$(jq -r '.generated_at // ""' "$PREV_CACHE_FILE" 2>/dev/null || echo "")
fi

# Count active trace directories only (exclude oldTraces/ and hidden dirs)
# oldTraces/ is archived data — it must not inflate the active trace count.
#
# @decision DEC-OBS-P2-107
# @title Exclude oldTraces/ from active trace directory count in Stage 0
# @status accepted
# @rationale oldTraces/ contains 489 archived traces that should not be counted
#   as active traces. Including them would inflate CURRENT_TRACE_DIR_COUNT,
#   making the data-loss detection threshold meaningless and skewing artifact
#   health stats. Stage 2c (below) reads oldTraces/ separately for historical context.
#   Fix for issue #107.
CURRENT_TRACE_DIR_COUNT=$(find "$TRACE_STORE" -maxdepth 1 -mindepth 1 -type d \
    ! -name '.*' ! -name 'oldTraces' 2>/dev/null | wc -l | tr -d ' ')
CURRENT_TRACE_DIR_COUNT="${CURRENT_TRACE_DIR_COUNT:-0}"

# Data loss: current < prev * 0.7 (i.e., >30% drop)
if [[ "$PREV_TRACE_COUNT" -gt 0 && "$CURRENT_TRACE_DIR_COUNT" -lt "$PREV_TRACE_COUNT" ]]; then
    LOSS_THRESHOLD=$(( PREV_TRACE_COUNT * 70 / 100 ))
    if [[ "$CURRENT_TRACE_DIR_COUNT" -lt "$LOSS_THRESHOLD" ]]; then
        DATA_LOSS_SUSPECTED=true
    fi
fi

# No historical baseline: no prior analysis run with a different generated_at.
# This is the correct indicator — calendar-day uniqueness was too aggressive and
# blocked trend analysis for all single-day multi-run scenarios (issue #109).
if [[ -z "$PREV_GENERATED_AT" ]]; then
    # No prev cache at all — first run ever
    NO_HISTORICAL_BASELINE=true
fi
# Note: if PREV_GENERATED_AT matches GENERATED_AT that would be a clock issue;
# in practice prev cache is from a prior run so they will always differ once
# the new cache is written. We do NOT compare them here since GENERATED_AT is
# set later (Stage 6). The presence of prev cache is sufficient signal.

# Secondary advisory: detect single-day-only runs (informational, does not suppress trends)
UNIQUE_DAYS=0
if [[ "$CURRENT_TRACE_DIR_COUNT" -gt 0 ]]; then
    UNIQUE_DAYS=$(find "$TRACE_STORE" -maxdepth 2 -name 'manifest.json' -type f \
        ! -path '*/oldTraces/*' 2>/dev/null \
        | xargs jq -r '.started_at // empty' 2>/dev/null \
        | cut -c1-10 \
        | sort -u \
        | wc -l | tr -d ' ')
    if [[ "${UNIQUE_DAYS:-0}" -le 1 && "$CURRENT_TRACE_DIR_COUNT" -ge 2 ]]; then
        SINGLE_DAY_ONLY=true
    fi
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

# --- Stage 2: Artifact health (scan active trace dirs only) ---
# Excludes oldTraces/ — archived traces are not expected to have current
# artifact patterns and must not skew completeness rates.
# Includes proof_unknown_count for SIG-PROOF-UNKNOWN detection.
#
# @decision DEC-OBS-P2-107-STAGE2
# @title Exclude oldTraces/ from Stage 2 artifact health scan
# @status accepted
# @rationale oldTraces/ contains archived traces with older artifact conventions.
#   Including them in completeness rates produces misleadingly low rates (e.g., 2%)
#   that drown out signals from current traces. Stage 2c collects oldTraces aggregate
#   stats separately. Fix for issue #107.
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
done < <(find "$TRACE_STORE" -maxdepth 1 -mindepth 1 -type d \
    ! -name '.git' ! -name 'oldTraces' 2>/dev/null | sort)

# --- Stage 2c: Historical traces aggregate (oldTraces/) ---
# oldTraces/ is an archive of older traces that are not indexed in index.jsonl.
# This stage reads their manifests to produce aggregate stats for historical
# context (e.g., "489 historical + 43 active traces"). It does NOT modify
# the active index.
#
# @decision DEC-OBS-P2-107-STAGE2C
# @title Stage 2c reads oldTraces/ manifests for historical aggregate stats
# @status accepted
# @rationale The observatory needs historical context to provide meaningful trend
#   anchors. Instead of ignoring 489 archived traces, we aggregate their outcome
#   distribution and agent type breakdown. These stats appear in analysis-cache.json
#   under historical_traces and are referenced by report.sh for context lines like
#   "489 historical + 43 active". The active index is unchanged. Fix for issue #107.
HISTORICAL_TRACES='{"available": false, "total": 0, "outcome_dist": {}, "agent_type_dist": {}}'
OLD_TRACES_DIR="${TRACE_STORE}/oldTraces"

if [[ -d "$OLD_TRACES_DIR" ]]; then
    OLD_MANIFESTS=()
    while IFS= read -r mf; do
        [[ -n "$mf" ]] && OLD_MANIFESTS+=("$mf")
    done < <(find "$OLD_TRACES_DIR" -maxdepth 2 -name 'manifest.json' -type f 2>/dev/null | sort)

    OLD_TOTAL="${#OLD_MANIFESTS[@]}"
    if [[ "$OLD_TOTAL" -gt 0 ]]; then
        # Single-pass aggregate of all old manifests
        HISTORICAL_TRACES=$(jq -sc '
          {
            available: true,
            total: length,
            outcome_dist: (
              group_by(.outcome // "unknown") |
              map({key: (.[0].outcome // "unknown"), value: length}) |
              from_entries
            ),
            agent_type_dist: (
              group_by(.agent_type // "unknown") |
              map({key: (.[0].agent_type // "unknown"), value: length}) |
              from_entries
            )
          }
        ' "${OLD_MANIFESTS[@]}" 2>/dev/null || echo '{"available": true, "total": '"$OLD_TOTAL"', "outcome_dist": {}, "agent_type_dist": {}, "parse_error": true}')
    fi
fi

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

# --- Stage 4 (v3): Documentation freshness signals ---
# Reads .doc-drift file written by surface.sh to detect doc-related issues.

# SIG-DOCS-STALE: tracked docs with structural churn that haven't been updated
DOC_DRIFT_FILE="${CLAUDE_DIR}/.doc-drift"
DOC_STALE_COUNT_RAW=0
DOC_STALE_DOCS_RAW=""
DOC_BYPASS_COUNT_RAW=0
SCOPE_MAP_FILE="${CLAUDE_DIR}/hooks/doc-scope.json"
SCOPE_TOTAL_DOCS=0

if [[ -f "$DOC_DRIFT_FILE" ]]; then
    DOC_STALE_COUNT_RAW=$(grep '^stale_count=' "$DOC_DRIFT_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    DOC_STALE_DOCS_RAW=$(grep '^stale_docs=' "$DOC_DRIFT_FILE" 2>/dev/null | cut -d= -f2- || echo "")
    DOC_BYPASS_COUNT_RAW=$(grep '^bypass_count=' "$DOC_DRIFT_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
fi

if [[ -f "$SCOPE_MAP_FILE" ]]; then
    SCOPE_TOTAL_DOCS=$(jq 'keys | length' "$SCOPE_MAP_FILE" 2>/dev/null || echo "0")
fi

if [[ "${DOC_STALE_COUNT_RAW:-0}" -gt 0 ]]; then
    # Build evidence list from space-separated stale_docs
    DOC_STALE_EVIDENCE=$(echo "$DOC_STALE_DOCS_RAW" | tr ' ' '\n' | grep -v '^$' | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$DOC_STALE_COUNT_RAW" \
        --argjson total "$SCOPE_TOTAL_DOCS" \
        --argjson evidence "$DOC_STALE_EVIDENCE" \
        '. + [{
          "id": "SIG-DOCS-STALE",
          "category": "doc_freshness",
          "severity": "medium",
          "description": "Tracked docs have stale structural churn — files added/deleted without doc update",
          "evidence": {"affected_count": $affected, "total": $total, "stale_docs": $evidence},
          "root_cause": "hooks/doc-scope.json tracks docs that should reflect structural changes. stale_count > 0 means one or more docs are past warn/block threshold."
        }]')
fi

# SIG-CHANGELOG-GAP: merges to main that didn't update CHANGELOG.md
CHANGELOG_MERGES_TOTAL=0
CHANGELOG_MERGES_MISSING=0
if command -v git &>/dev/null && git -C "$CLAUDE_DIR" rev-parse HEAD &>/dev/null 2>&1; then
    while IFS= read -r merge_hash; do
        [[ -z "$merge_hash" ]] && continue
        (( CHANGELOG_MERGES_TOTAL++ )) || true
        # Check if CHANGELOG.md appeared in this merge's diff
        if ! git -C "$CLAUDE_DIR" diff-tree --no-commit-id -r --name-only "$merge_hash" 2>/dev/null \
           | grep -qF 'CHANGELOG.md' 2>/dev/null; then
            (( CHANGELOG_MERGES_MISSING++ )) || true
        fi
    done < <(git -C "$CLAUDE_DIR" log --merges --first-parent main -20 --format='%H' 2>/dev/null || true)
fi

if [[ "$CHANGELOG_MERGES_MISSING" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$CHANGELOG_MERGES_MISSING" \
        --argjson total "$CHANGELOG_MERGES_TOTAL" \
        '. + [{
          "id": "SIG-CHANGELOG-GAP",
          "category": "doc_freshness",
          "severity": "low",
          "description": "Merges to main without CHANGELOG.md update — feature changes are not documented",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "check-guardian.sh Check 6 warns on merge without CHANGELOG update, but the warning is advisory. Persistent gaps indicate check is not effective."
        }]')
fi

# SIG-DOC-BYPASS-RATE: @no-doc bypass usage above acceptable threshold (>30%)
DOC_BYPASS_RATE_SIG=false
if [[ "${DOC_BYPASS_COUNT_RAW:-0}" -gt 0 ]]; then
    # Count total commits since doc-freshness was deployed (approximated as all commits touching hooks/)
    TOTAL_HOOK_COMMITS=$(git -C "$CLAUDE_DIR" log --oneline -- hooks/ 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$TOTAL_HOOK_COMMITS" -gt 0 ]]; then
        BYPASS_RATE_PCT=$(jq -n "$DOC_BYPASS_COUNT_RAW / $TOTAL_HOOK_COMMITS * 100" 2>/dev/null || echo "0")
        if [[ $(jq -n "$BYPASS_RATE_PCT > 30" 2>/dev/null) == "true" ]]; then
            DOC_BYPASS_RATE_SIG=true
        fi
    fi
fi

if [[ "$DOC_BYPASS_RATE_SIG" == "true" ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$DOC_BYPASS_COUNT_RAW" \
        --argjson total "$TOTAL_HOOK_COMMITS" \
        '. + [{
          "id": "SIG-DOC-BYPASS-RATE",
          "category": "doc_freshness",
          "severity": "medium",
          "description": "@no-doc bypass rate >30% — enforcement may be too aggressive or docs are chronically stale",
          "evidence": {"affected_count": $affected, "total": $total},
          "root_cause": "doc-freshness.sh @no-doc escape hatch used too frequently. Either doc thresholds in doc-scope.json are too tight, or docs need a bulk update."
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

# --- Stage 5b: Cross-project state contamination detection ---
#
# Reads traces/index.jsonl, groups traces by session_id, and checks whether
# any single session produced traces for more than one distinct project_name.
# A session touching multiple projects is a contamination risk: state files
# scoped to project A (proof-status, active-worktree-path) may be read by
# project B's hooks if CLAUDE_DIR resolves the same way for both.
#
# Secondary check: scans .active-* marker files in TRACE_STORE and detects
# markers whose embedded phash (12-char suffix) appears alongside markers
# from a different phash in the same session. A session writing markers for
# two distinct phashes has definitely written cross-project state.
#
# Emits SIG-CROSS-PROJECT-STATE when contamination is detected.
#
# Implementation uses only POSIX-compatible tools (awk, sort, uniq) because
# the observatory runs on macOS with bash 3.2 where declare -A is unavailable.
#
# @decision DEC-OBS-022
# @title Stage 5b cross-project state contamination detection (bash 3.2 compatible)
# @status accepted
# @rationale Project isolation bugs are silent: the wrong proof-status file is read,
#   the wrong breadcrumb is followed, and the wrong worktree is cleaned up. These bugs
#   only surface when two projects are active in the same session — a relatively rare
#   event that makes them hard to notice manually. Automated detection via session_id
#   grouping of trace index entries gives the observatory visibility into this class
#   without requiring any code changes to the hooks being monitored.
#   Uses awk+sort+uniq for bash 3.2 compatibility (no declare -A available on macOS).

CROSS_PROJECT_CONTAMINATION_COUNT=0
CROSS_PROJECT_SESSIONS="[]"

# Guard: only run when the trace index exists
if [[ -f "$TRACE_INDEX" ]]; then
    # Step 1: Find sessions that appear with more than one project_name in the index.
    # jq extracts session_id+project_name pairs; awk groups by session_id to count
    # distinct project names per session. Sessions with >1 distinct project are suspects.
    #
    # Output format per line: <session_id> <distinct_project_count> <project_names_csv>
    MULTI_PROJECT_SESSIONS=""
    MULTI_PROJECT_SESSIONS=$(jq -r \
        'select(.session_id != null and .session_id != "" and .project_name != null and .project_name != "") |
         [.session_id, .project_name] | @tsv' \
        "$TRACE_INDEX" 2>/dev/null \
        | sort -u \
        | awk '
            {
                sid = $1
                proj = $2
                if (!(sid in seen_projects) || index(seen_projects[sid], proj) == 0) {
                    if (sid in seen_projects) {
                        seen_projects[sid] = seen_projects[sid] "," proj
                        counts[sid]++
                    } else {
                        seen_projects[sid] = proj
                        counts[sid] = 1
                    }
                }
            }
            END {
                for (sid in counts) {
                    if (counts[sid] > 1) {
                        print sid "\t" counts[sid] "\t" seen_projects[sid]
                    }
                }
            }
        ' 2>/dev/null || true)

    # Step 2: For each multi-project session, record it as a contamination event.
    if [[ -n "$MULTI_PROJECT_SESSIONS" ]]; then
        while IFS=$'\t' read -r sid pcount projs; do
            [[ -z "$sid" ]] && continue
            CROSS_PROJECT_CONTAMINATION_COUNT=$((CROSS_PROJECT_CONTAMINATION_COUNT + 1))
            CROSS_PROJECT_SESSIONS=$(echo "$CROSS_PROJECT_SESSIONS" | jq \
                --arg session_id "$sid" \
                --argjson distinct_projects "$pcount" \
                --arg projects "$projs" \
                '. + [{"session_id": $session_id, "distinct_projects": $distinct_projects, "project_names": $projects}]' \
                2>/dev/null || echo "$CROSS_PROJECT_SESSIONS")
        done <<< "$MULTI_PROJECT_SESSIONS"
    fi

    # Step 3: Secondary check — scan .active-* marker filenames for sessions
    # that wrote markers with more than one distinct 12-char phash suffix.
    # Marker format: .active-{type}-{session_id}-{phash12}
    # We extract (session_id, phash) pairs by stripping the known prefix and suffix.
    # awk groups by session_id and counts distinct phashes.
    STALE_MARKER_DIR="$TRACE_STORE"
    MARKER_CONTAM_SESSIONS=""
    if [[ -d "$STALE_MARKER_DIR" ]]; then
        MARKER_CONTAM_SESSIONS=$(find "$STALE_MARKER_DIR" -maxdepth 1 \
            -name '.active-*-*' -type f 2>/dev/null \
            | while IFS= read -r mf; do
                mname=$(basename "$mf")
                # Extract phash: last 12 hex chars before end
                if [[ "$mname" =~ -([0-9a-f]{12})$ ]]; then
                    phash="${BASH_REMATCH[1]}"
                    # Strip .active- prefix, type, and phash suffix to get session_id
                    # Remove ".active-TYPE-" prefix (TYPE has no '-' by convention)
                    rest="${mname#.active-*-}"
                    # rest is now "SESSION_ID-PHASH"
                    session_part="${rest%-${phash}}"
                    if [[ -n "$session_part" && -n "$phash" ]]; then
                        printf '%s\t%s\n' "$session_part" "$phash"
                    fi
                fi
              done \
            | sort -u \
            | awk '
                {
                    sid = $1; phash = $2
                    if (!(sid in phashes) || index(phashes[sid], phash) == 0) {
                        if (sid in phashes) {
                            phashes[sid] = phashes[sid] "," phash
                            counts[sid]++
                        } else {
                            phashes[sid] = phash
                            counts[sid] = 1
                        }
                    }
                }
                END {
                    for (sid in counts) {
                        if (counts[sid] > 1) print sid "\t" counts[sid] "\t" phashes[sid]
                    }
                }
            ' 2>/dev/null || true)
    fi

    if [[ -n "$MARKER_CONTAM_SESSIONS" ]]; then
        while IFS=$'\t' read -r sid hcount hashes; do
            [[ -z "$sid" ]] && continue
            # Avoid double-counting sessions already caught by Step 2
            already_counted=false
            if [[ "$CROSS_PROJECT_SESSIONS" == *"\"$sid\""* ]]; then
                already_counted=true
            fi
            if [[ "$already_counted" == "false" ]]; then
                CROSS_PROJECT_CONTAMINATION_COUNT=$((CROSS_PROJECT_CONTAMINATION_COUNT + 1))
                CROSS_PROJECT_SESSIONS=$(echo "$CROSS_PROJECT_SESSIONS" | jq \
                    --arg session_id "$sid" \
                    --argjson distinct_hashes "$hcount" \
                    --arg phashes "$hashes" \
                    '. + [{"session_id": $session_id, "distinct_hashes_from_markers": $distinct_hashes, "phashes": $phashes}]' \
                    2>/dev/null || echo "$CROSS_PROJECT_SESSIONS")
            fi
        done <<< "$MARKER_CONTAM_SESSIONS"
    fi
fi

if [[ "${CROSS_PROJECT_CONTAMINATION_COUNT:-0}" -gt 0 ]]; then
    SIGNALS=$(echo "$SIGNALS" | jq \
        --argjson affected "$CROSS_PROJECT_CONTAMINATION_COUNT" \
        --argjson total "$TOTAL" \
        --argjson sessions "$CROSS_PROJECT_SESSIONS" \
        '. + [{
          "id": "SIG-CROSS-PROJECT-STATE",
          "category": "state_isolation",
          "severity": "high",
          "description": "Sessions active across multiple projects — cross-project state contamination risk detected",
          "evidence": {"affected_count": $affected, "total": $total, "contaminated_sessions": $sessions},
          "root_cause": "Hooks writing .active-* markers or .proof-status files without project hash scoping, causing state from one project to bleed into another project'\''s session"
        }]')
fi

# --- Stage 6: Assemble and write output ---
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build stale_markers summary object for top-level output
STALE_MARKERS_OBJ=$(jq -cn \
    --argjson count "$STALE_MARKER_COUNT" \
    --argjson details "$STALE_MARKERS" \
    '{"count": $count, "details": $details}')

# Stage 0 post-processing: suppress trends when dataset integrity is compromised.
# Trend analysis is meaningless if traces were deleted between runs (DATA_LOSS_SUSPECTED)
# or if there is no historical baseline (NO_HISTORICAL_BASELINE — no prior analysis run).
# SINGLE_DAY_ONLY is informational only and does NOT suppress trends (issue #109 fix).
if [[ "$DATA_LOSS_SUSPECTED" == "true" || "$NO_HISTORICAL_BASELINE" == "true" ]]; then
    TRENDS="null"
fi

# Build dataset_integrity object for the cache
DATASET_INTEGRITY=$(jq -cn \
    --argjson data_loss "$DATA_LOSS_SUSPECTED" \
    --argjson no_baseline "$NO_HISTORICAL_BASELINE" \
    --argjson single_day_only "$SINGLE_DAY_ONLY" \
    --argjson prev_count "$PREV_TRACE_COUNT" \
    --argjson curr_count "$CURRENT_TRACE_DIR_COUNT" \
    --argjson unique_days "${UNIQUE_DAYS:-0}" \
    '{
      data_loss_suspected: $data_loss,
      no_historical_baseline: $no_baseline,
      single_day_only: $single_day_only,
      prev_trace_count: $prev_count,
      current_trace_dir_count: $curr_count,
      unique_days: $unique_days
    }')

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
    --argjson dataset_integrity "$DATASET_INTEGRITY" \
    --argjson historical_traces "$HISTORICAL_TRACES" \
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
      stale_markers: $stale_markers,
      dataset_integrity: $dataset_integrity,
      historical_traces: $historical_traces
    }' > "$CACHE_FILE"

SIG_COUNT=$(echo "$SIGNALS" | jq 'length')
HIST_TOTAL=$(echo "$HISTORICAL_TRACES" | jq '.total // 0' 2>/dev/null || echo "0")
if [[ "$HIST_TOTAL" -gt 0 ]]; then
    echo "Analysis complete: $TOTAL active + $HIST_TOTAL historical traces, $SIG_COUNT signals detected → $CACHE_FILE"
else
    echo "Analysis complete: $TOTAL traces, $SIG_COUNT signals detected → $CACHE_FILE"
fi

#!/usr/bin/env bash
# suggest.sh — Observatory Stage 2: signals → ranked SUG-NNN.json + comparison matrix
#
# Purpose: Read analysis-cache.json signals and produce prioritized suggestion
#          files in observatory/suggestions/. Each suggestion maps one signal
#          to an actionable implementation plan with a computed priority score.
#          Also generates comparison-matrix.json for the report.sh stage.
#
# @decision DEC-OBS-008
# @title Priority formula: impact × feasibility × category_weight
# @status accepted
# @rationale Three-factor ranking balances severity (how bad is it), effort
#             (how hard to fix), and strategic alignment (data quality vs
#             completeness). This prevents high-severity-but-impossible fixes
#             from crowding out quick wins, and ensures data quality issues
#             (which unblock all deeper analysis) rank above completeness issues.
#             Formula: priority = impact_score × feasibility_score × category_weight
#             where impact = (affected/total) × severity_mult
#                   feasibility = complexity_factor × blast_radius_factor
#
# @decision DEC-OBS-009
# @title Skip already-implemented suggestions — with cohort regression exception
# @status accepted
# @rationale The state.json implemented list is checked before generating each
#             suggestion. This prevents the flywheel from re-proposing fixes
#             already merged. The state file is the authoritative source of
#             what has been acted on — it persists across sessions.
#             Exception (DEC-OBS-021): if analyze.sh cohort check detects that
#             a signal is still triggering on post-implementation traces at >50%
#             rate with >=10 cohort traces, it is re-proposed with regression=true.
#             This surfaces broken fixes before they go undetected.
#             Skip logic reads signal_id directly from state v3 objects (DEC-OBS-022)
#             — no SUG-file indirection. This makes tracking stable across
#             suggest.sh runs that renumber SUG-NNN files. Deferred signals are
#             also skipped until resurfaced by auto_resurface().
#
# @decision DEC-OBS-010
# @title Use jq-based metadata lookup instead of bash associative arrays
# @status accepted
# @rationale macOS ships with bash 3.2 which lacks declare -A. Rather than
#             require bash 4+ or use eval-based hacks, signal metadata is
#             stored in a self-contained jq object and queried with jq -r.
#             This is more portable and keeps the metadata co-located with
#             the query logic.
#
# @decision DEC-OBS-014
# @title Dependency boost: +15% priority for signals that unlock others
# @status accepted
# @rationale A signal that unlocks better data for downstream signals has
#             compounded impact. The +15% boost is applied after the base
#             priority calculation and capped at 1.0. This is declared
#             statically in SIGNAL_METADATA.depends_on/unlocks fields so
#             the dependency graph is explicit and auditable.
#
# @decision DEC-OBS-015
# @title Batch grouping by overlapping files
# @status accepted
# @rationale Signals that touch the same files should be implemented together
#             to avoid repeated diffs on the same code region. Batch labels
#             (A, B, C) are assigned in priority order — highest-priority
#             signal anchors the batch. Combined_effort = max effort in batch.
#
# Output: observatory/suggestions/SUG-NNN.json (one per active signal)
#         observatory/comparison-matrix.json (full signal comparison table)
# Usage: bash skills/observatory/scripts/suggest.sh

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
WORKTREE_DIR="${WORKTREE_DIR:-$CLAUDE_DIR}"
OBS_DIR="${OBS_DIR:-${WORKTREE_DIR}/observatory}"
CACHE_FILE="${OBS_DIR}/analysis-cache.json"
SUGGESTIONS_DIR="${OBS_DIR}/suggestions"
STATE_FILE="${STATE_FILE:-${OBS_DIR}/state.json}"
MATRIX_FILE="${OBS_DIR}/comparison-matrix.json"

# --- Preflight ---
mkdir -p "$SUGGESTIONS_DIR"

if [[ ! -f "$CACHE_FILE" ]]; then
    echo "ERROR: analysis-cache.json not found at $CACHE_FILE — run analyze.sh first" >&2
    exit 1
fi

# --- Signal metadata (jq object, bash 3.2 compatible) ---
# Each entry: { complexity, blast, files, approach, test_strategy, title, desc, depends_on, unlocks }
# complexity: low|medium|high  blast: function|file|multi
# depends_on: signals that must be implemented before this one for full effect
# unlocks:    signals whose data quality improves once this signal is implemented
SIGNAL_METADATA=$(cat << 'METADATA_EOF'
{
  "SIG-DURATION-BUG": {
    "title": "Fix UTC timezone bug in finalize_trace duration calculation",
    "desc": "Add -u flag to date -j -f on line 569 of context-lib.sh so UTC timestamps are parsed correctly instead of as local time",
    "complexity": "low",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "Add -u flag: change 'date -j -f \"%Y-%m-%dT%H:%M:%SZ\" \"$started_at\" +%s' to 'date -u -j -f \"%Y-%m-%dT%H:%M:%SZ\" \"$started_at\" +%s' on line 569",
    "test": "Unit test with known UTC timestamp: date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-01-01T12:00:00Z' +%s should equal 1735732800",
    "depends_on": [],
    "unlocks": ["SIG-OUTCOME-FLAT"]
  },
  "SIG-TEST-UNKNOWN": {
    "title": "Add .test-status fallback to finalize_trace test result detection",
    "desc": "finalize_trace currently only checks for test-output.txt artifact. Most agents write .test-status file to project root instead. Adding a fallback check would resolve 97.5% unknown test results.",
    "complexity": "medium",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "After lines 583-589: add fallback check for $project_root/.test-status and $project_root/.claude/.test-status files",
    "test": "Create a trace dir with no test-output.txt but with .test-status=pass. Run finalize_trace. Verify test_result=pass in manifest.",
    "depends_on": [],
    "unlocks": ["SIG-OUTCOME-FLAT"]
  },
  "SIG-FILES-ZERO": {
    "title": "Add git diff --stat fallback to finalize_trace files_changed count",
    "desc": "finalize_trace only reads files-changed.txt artifact. When agents don't write that file, files_changed stays 0. A git diff --stat fallback against the pre-session commit would give accurate counts.",
    "complexity": "medium",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "After lines 613-616: if files_changed==0, try git -C project_root diff --stat HEAD~1 HEAD 2>/dev/null | tail -1 | awk '{print $1}'",
    "test": "Create trace dir with no files-changed.txt but with a git commit. Run finalize_trace. Verify files_changed > 0 in manifest.",
    "depends_on": [],
    "unlocks": []
  },
  "SIG-OUTCOME-FLAT": {
    "title": "Expand outcome classification beyond success/failure/partial",
    "desc": "The outcome field only has 3 values: success (test pass), failure (test fail), partial (everything else). Richer classification enables better analysis.",
    "complexity": "medium",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "In finalize_trace outcome logic (lines 604-610): add timeout outcome when duration > 600s and test_result==unknown, add skipped when no artifacts at all",
    "test": "Unit test: trace with duration>600 and no test-output.txt should get outcome=timeout not partial",
    "depends_on": ["SIG-DURATION-BUG", "SIG-TEST-UNKNOWN"],
    "unlocks": []
  },
  "SIG-ARTIFACT-MISSING": {
    "title": "Add TRACE_DIR validation to agent prompts to ensure artifact writing",
    "desc": "Most traces lack summary.md and other artifacts because agents exit early or don't have TRACE_DIR set. Adding a preflight check and reminder in the implementer/tester prompts would increase compliance.",
    "complexity": "high",
    "blast": "multi",
    "files": ["agents/implementer.md", "agents/tester.md", "hooks/context-lib.sh"],
    "approach": "Add TRACE_DIR check at start of agent prompts. Add artifact-writing reminder in Session End Protocol. Add PostToolUse hook that warns when TRACE_DIR is set but artifacts dir is empty after 30min.",
    "test": "Run implementer with TRACE_DIR set. Verify artifacts/ dir is created and summary.md exists after completion.",
    "depends_on": [],
    "unlocks": []
  },
  "SIG-MAIN-IMPL": {
    "title": "Block implementer dispatch on main/master branch in task-track.sh",
    "desc": "Implementer agents ran on main/master branch instead of a feature worktree, violating Sacred Practice #2. The task-track.sh PreToolUse:Task gate should reject implementer dispatch when the current branch is main or master.",
    "complexity": "medium",
    "blast": "multi",
    "files": ["agents/implementer.md", "hooks/task-track.sh"],
    "approach": "Add branch check to task-track.sh PreToolUse:Task gate — reject implementer dispatch when on main/master unless override flag set",
    "test": "Dispatch implementer on main branch without override. Verify task-track.sh blocks it.",
    "depends_on": [],
    "unlocks": []
  },
  "SIG-BRANCH-UNKNOWN": {
    "title": "Use 'no-git' fallback branch name in init_trace() for non-git directories",
    "desc": "Traces with branch='unknown' indicate git metadata capture failed. Using 'no-git' as a fallback distinguishes non-git projects from actual capture failures, enabling more accurate filtering.",
    "complexity": "low",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "In init_trace(), add fallback: if git rev-parse fails, set branch to 'no-git' instead of 'unknown' to distinguish non-git projects from capture failures",
    "test": "Create trace in a non-git directory. Verify branch='no-git' in manifest.",
    "depends_on": [],
    "unlocks": []
  },
  "SIG-AGENT-TYPE-MISMATCH": {
    "title": "Normalize agent_type 'Plan' to 'planner' in init_trace()",
    "desc": "The Task subagent_type field uses 'Plan' (capital P) but the system expects 'planner'. This mismatch fragments agent-type analysis by splitting the same agent type into two groups.",
    "complexity": "low",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "In init_trace(), normalize agent_type: map 'Plan' to 'planner', 'Explore' to 'explore'. Add case statement for known mappings.",
    "test": "Call init_trace with agent_type='Plan'. Verify manifest shows 'planner'.",
    "depends_on": [],
    "unlocks": ["SIG-CRASH-CLUSTER"]
  },
  "SIG-CRASH-CLUSTER": {
    "title": "Investigate and fix systematic crash cluster in affected agent types",
    "desc": "One or more agent types have >50% crash rates with sufficient sample sizes (>5 traces), indicating a systematic dispatch or prompt failure. This requires reading crashed trace summaries to identify the root cause.",
    "complexity": "high",
    "blast": "multi",
    "files": ["agents/planner.md", "agents/implementer.md", "hooks/task-track.sh"],
    "approach": "Investigate crash clusters by reading crashed trace summaries. Fix agent prompts or dispatch logic causing crashes.",
    "test": "After fix, re-run observatory. Verify crash rate for affected agent types drops below 50%.",
    "depends_on": ["SIG-AGENT-TYPE-MISMATCH"],
    "unlocks": []
  },
  "SIG-STALE-MARKERS": {
    "title": "Add age-based cleanup of stale .active-* markers in init_trace()",
    "desc": "Orphaned .active-* files from crashed agents can block new agent runs with false 'agent already running' errors. Cleaning markers older than 2 hours at init time prevents this.",
    "complexity": "low",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "Add age-based cleanup: in init_trace(), remove any .active-* markers older than 2 hours before creating a new one",
    "test": "Create a stale .active-* marker older than 2 hours. Run init_trace. Verify stale marker is cleaned up.",
    "depends_on": [],
    "unlocks": []
  },
  "SIG-PROOF-UNKNOWN": {
    "title": "Propagate project .proof-status to trace manifest in finalize_trace()",
    "desc": "Most trace manifests have proof_status='unknown' because finalize_trace() only checks a trace-scoped file that rarely exists. Reading the project-scoped .proof-status file would capture the actual verification state.",
    "complexity": "medium",
    "blast": "function",
    "files": ["hooks/context-lib.sh"],
    "approach": "In finalize_trace(), when proof_status is 'unknown', try reading the last known proof status from the session's .proof-status file relative to project root",
    "test": "Create trace with .proof-status=verified in project root. Run finalize_trace. Verify proof_status='verified' in manifest.",
    "depends_on": [],
    "unlocks": []
  }
}
METADATA_EOF
)

# --- Load already-implemented and deferred signal IDs to skip ---
# Reads signal_id directly from v3 state objects — no SUG-file indirection
# (DEC-OBS-022). The SUG-file fallback was removed because suggest.sh renumbers
# SUG-NNN files on every run, making file-based lookups unreliable. After v1→v3
# migration in init_state/_migrate_state, all entries are v3 objects with
# signal_id resolved from the known-map. Null signal_ids are skipped silently
# (they neither block nor pollute the implemented-signal check).
IMPLEMENTED_SIGS=""
DEFERRED_SIGS=""
if [[ -f "$STATE_FILE" ]]; then
    # Build from signal_id fields directly — no SUG file indirection
    IMPLEMENTED_SIGS=$(jq -r '
      .implemented[]? |
      if type == "object" then .signal_id // empty else empty end
    ' "$STATE_FILE" 2>/dev/null | tr '\n' ' ')

    DEFERRED_SIGS=$(jq -r '
      .deferred[]? |
      if type == "object" then .signal_id // empty else empty end
    ' "$STATE_FILE" 2>/dev/null | tr '\n' ' ')

    # Validate that all implemented entries have implemented_at timestamps.
    # Missing timestamps prevent accurate cohort analysis (the cohort window
    # is computed from implemented_at; without it the cohort size is always 0,
    # causing regression checks to silently produce 0 and never re-propose).
    # @decision DEC-OBS-OVERHAUL-004
    # @title Warn on missing implemented_at timestamps in state.json
    # @status accepted
    # @rationale Without implemented_at, cohort regression detection cannot
    #   compute the post-implementation trace window. The timestamp is mandatory
    #   for the regression path to function. We warn (not error) so the pipeline
    #   continues; the warning surfaces the data quality gap for operators.
    MISSING_TS_COUNT=$(jq -r '
      [.implemented[]? |
       select(type == "object" and (.implemented_at // "") == "")]
      | length
    ' "$STATE_FILE" 2>/dev/null || echo "0")
    if [[ "$MISSING_TS_COUNT" -gt 0 ]]; then
        echo "WARNING: $MISSING_TS_COUNT implemented entry/entries missing implemented_at timestamp — cohort regression detection may be impaired" >&2
    fi
fi

# --- Compute priority scores for each signal ---
SCORE_LIST=""
DIAG_PROCESSED=0
DIAG_SKIPPED_IMPL=0
DIAG_SKIPPED_DEFER=0
DIAG_REGRESSION=0

while IFS= read -r signal; do
    SIG_ID=$(echo "$signal" | jq -r '.id')
    CATEGORY=$(echo "$signal" | jq -r '.category')
    SEVERITY=$(echo "$signal" | jq -r '.severity')
    AFFECTED=$(echo "$signal" | jq -r '.evidence.affected_count')
    TOTAL=$(echo "$signal" | jq -r '.evidence.total')
    DIAG_PROCESSED=$(( DIAG_PROCESSED + 1 ))

    # Skip if currently deferred — wait for auto_resurface() to re-enable it
    if echo "$DEFERRED_SIGS" | grep -qw "$SIG_ID" 2>/dev/null; then
        echo "Skipping $SIG_ID — currently deferred"
        DIAG_SKIPPED_DEFER=$(( DIAG_SKIPPED_DEFER + 1 ))
        continue
    fi

    # Skip if already implemented — unless cohort regression detected
    if echo "$IMPLEMENTED_SIGS" | grep -qw "$SIG_ID" 2>/dev/null; then
        # Check cohort_regressions in analysis cache (DEC-OBS-021)
        local_regression=$(jq -r --arg sig "$SIG_ID" \
            '.cohort_regressions // [] | map(select(.signal_id == $sig and .regression == true)) | length' \
            "$CACHE_FILE" 2>/dev/null || echo "0")
        if [[ "$local_regression" -gt 0 ]]; then
            echo "REGRESSION: $SIG_ID — cohort check shows fix not working on new traces, re-proposing"
            IS_REGRESSION="true"
            # Fall through — generate suggestion with regression flag
            DIAG_REGRESSION=$(( DIAG_REGRESSION + 1 ))
        else
            echo "Skipping $SIG_ID — already implemented (cohort clean)"
            DIAG_SKIPPED_IMPL=$(( DIAG_SKIPPED_IMPL + 1 ))
            continue
        fi
    else
        IS_REGRESSION="false"
    fi

    # Check if we have metadata for this signal
    HAS_META=$(echo "$SIGNAL_METADATA" | jq -e --arg id "$SIG_ID" '.[$id] // empty' > /dev/null 2>&1 && echo "yes" || echo "no")
    if [[ "$HAS_META" == "no" ]]; then
        echo "WARNING: No metadata for signal $SIG_ID — skipping" >&2
        continue
    fi

    # Extract metadata
    COMPLEXITY=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].complexity')
    BLAST=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].blast')

    # Count how many signals this one unlocks (for dependency boost calculation)
    UNLOCKS_COUNT=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].unlocks | length')

    # severity_multiplier
    case "$SEVERITY" in
        high)   SEV_MULT="0.9" ;;
        medium) SEV_MULT="0.6" ;;
        *)      SEV_MULT="0.3" ;;
    esac

    # complexity_factor
    case "$COMPLEXITY" in
        low)    COMPLEXITY_F="0.95" ;;
        medium) COMPLEXITY_F="0.7"  ;;
        high)   COMPLEXITY_F="0.4"  ;;
        *)      COMPLEXITY_F="0.7"  ;;
    esac

    # blast_radius_factor
    case "$BLAST" in
        function) BLAST_F="0.95" ;;
        file)     BLAST_F="0.8"  ;;
        multi)    BLAST_F="0.6"  ;;
        *)        BLAST_F="0.8"  ;;
    esac

    # category_weight — higher weight = higher strategic priority
    # data_quality: foundational (must fix first for any analysis to be valid)
    # workflow_compliance: Sacred Practice enforcement (high business value)
    # trace_completeness: coverage (important but secondary)
    # agent_performance: operational health (meaningful but narrower impact)
    # trace_infrastructure: plumbing (low blast, background fix)
    case "$CATEGORY" in
        data_quality)         CAT_W="1.0" ;;
        workflow_compliance)  CAT_W="0.85" ;;
        trace_completeness)   CAT_W="0.9" ;;
        agent_performance)    CAT_W="0.75" ;;
        trace_infrastructure) CAT_W="0.7" ;;
        *)                    CAT_W="0.8" ;;
    esac

    # Base priority = (affected/total × sev) × (complexity × blast) × cat_weight
    # Dependency boost: +15% if signal unlocks 1+ other signals, capped at 1.0
    PRIORITY=$(jq -n \
        --argjson affected "$AFFECTED" \
        --argjson total "$TOTAL" \
        --argjson sev "$SEV_MULT" \
        --argjson comp "$COMPLEXITY_F" \
        --argjson blast "$BLAST_F" \
        --argjson catw "$CAT_W" \
        --argjson unlocks_count "$UNLOCKS_COUNT" \
        '
        (($affected / $total) * $sev) * ($comp * $blast) * $catw as $base |
        (if $unlocks_count > 0 then ($base * 1.15) else $base end) |
        [., 1.0] | min |
        . * 1000 | round / 1000
        ')

    # Include IS_REGRESSION flag in score list so the writer loop can use it
    SCORE_LIST="${SCORE_LIST}${PRIORITY}|${SIG_ID}|${IS_REGRESSION}"$'\n'
done < <(jq -c '.improvement_signals[]' "$CACHE_FILE" 2>/dev/null)

# --- Diagnostic summary: always log signal processing counts ---
# This makes it visible why 0 suggestions were produced (all implemented, none in cache, etc.)
echo "Diagnostic: signals processed=$DIAG_PROCESSED skipped_implemented=$DIAG_SKIPPED_IMPL skipped_deferred=$DIAG_SKIPPED_DEFER regression_reprops=$DIAG_REGRESSION"

if [[ -z "$SCORE_LIST" ]]; then
    echo "No signals to suggest — processed $DIAG_PROCESSED total: $DIAG_SKIPPED_IMPL skipped (implemented + cohort clean), $DIAG_SKIPPED_DEFER deferred, $DIAG_REGRESSION regressions detected"
    # Write an empty matrix
    jq -cn '{"matrix": [], "batches": {}, "effort_buckets": {"quick_wins": [], "moderate": [], "deep": []}}' > "$MATRIX_FILE"
    exit 0
fi

# --- Sort by priority descending ---
SORTED=$(printf '%s' "$SCORE_LIST" | sort -t'|' -k1 -rn | grep -v '^$')

# --- Write SUG-NNN.json files ---
# Also accumulate data for the comparison matrix
SUG_NUM=1
MATRIX_ENTRIES="[]"
declare -a BATCH_FILE_MAP=()   # track which files are in which batch
declare -a BATCH_LABELS=()     # batch labels assigned so far
NEXT_BATCH_LETTER=65           # ASCII 'A'

while IFS='|' read -r PRIORITY SIG_ID IS_REG; do
    [[ -z "$SIG_ID" ]] && continue
    IS_REG="${IS_REG:-false}"

    # Get signal data from cache
    SIGNAL=$(jq -c --arg id "$SIG_ID" '.improvement_signals[] | select(.id == $id)' "$CACHE_FILE")
    AFFECTED=$(echo "$SIGNAL" | jq -r '.evidence.affected_count')
    TOTAL=$(echo "$SIGNAL" | jq -r '.evidence.total')
    SEVERITY=$(echo "$SIGNAL" | jq -r '.severity')
    CATEGORY=$(echo "$SIGNAL" | jq -r '.category')

    # Get metadata
    TITLE=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].title')
    DESC=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].desc')
    FILES=$(echo "$SIGNAL_METADATA" | jq -c --arg id "$SIG_ID" '.[$id].files')
    APPROACH=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].approach')
    TEST_STRAT=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].test')
    COMPLEXITY=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].complexity')
    BLAST=$(echo "$SIGNAL_METADATA" | jq -r --arg id "$SIG_ID" '.[$id].blast')
    DEPENDS_ON=$(echo "$SIGNAL_METADATA" | jq -c --arg id "$SIG_ID" '.[$id].depends_on')
    UNLOCKS=$(echo "$SIGNAL_METADATA" | jq -c --arg id "$SIG_ID" '.[$id].unlocks')

    SUG_ID=$(printf "SUG-%03d" "$SUG_NUM")
    SUG_FILE="${SUGGESTIONS_DIR}/${SUG_ID}.json"

    SCOPE_PCT=$(jq -n "($AFFECTED / $TOTAL * 100) | round | tostring" 2>/dev/null || echo "?")
    AFFECTED_PCT=$(jq -n "($AFFECTED / $TOTAL * 100) | round" 2>/dev/null || echo "0")

    # --- Batch assignment ---
    # A batch groups signals that share at least one file in common.
    # We iterate over already-assigned batch entries to find a match.
    BATCH_LABEL=""
    FILES_ARRAY=$(echo "$FILES" | jq -r '.[]' 2>/dev/null || echo "")

    # Look for an existing batch that shares files with this signal
    for file in $FILES_ARRAY; do
        # Search through MATRIX_ENTRIES for an entry with this file
        EXISTING_BATCH=$(echo "$MATRIX_ENTRIES" | jq -r \
            --arg file "$file" \
            '[.[] | select(.files | index($file))] | if length > 0 then .[0].batch else "" end' \
            2>/dev/null || echo "")
        if [[ -n "$EXISTING_BATCH" && "$EXISTING_BATCH" != "null" ]]; then
            BATCH_LABEL="$EXISTING_BATCH"
            break
        fi
    done

    # Assign new batch label if no match found
    if [[ -z "$BATCH_LABEL" ]]; then
        BATCH_LABEL=$(printf "\\x$(printf '%x' "$NEXT_BATCH_LETTER")")
        NEXT_BATCH_LETTER=$((NEXT_BATCH_LETTER + 1))
    fi

    # Convert IS_REG string to boolean for jq
    IS_REG_BOOL="false"
    [[ "$IS_REG" == "true" ]] && IS_REG_BOOL="true"

    # Write SUG-NNN.json with extended fields (regression flag included)
    jq -cn \
        --arg id "$SUG_ID" \
        --arg signal_id "$SIG_ID" \
        --arg title "$TITLE" \
        --arg description "$DESC" \
        --argjson affected "$AFFECTED" \
        --argjson total "$TOTAL" \
        --arg scope_pct "$SCOPE_PCT" \
        --arg severity "$SEVERITY" \
        --argjson files "$FILES" \
        --arg approach "$APPROACH" \
        --arg test_strategy "$TEST_STRAT" \
        --argjson priority "$PRIORITY" \
        --arg complexity "$COMPLEXITY" \
        --arg blast "$BLAST" \
        --arg batch "$BATCH_LABEL" \
        --argjson depends_on "$DEPENDS_ON" \
        --argjson unlocks "$UNLOCKS" \
        --argjson is_regression "$IS_REG_BOOL" \
        '{
          id: $id,
          status: "proposed",
          signal_id: $signal_id,
          title: $title,
          description: $description,
          regression: $is_regression,
          impact: {
            scope: ($affected | tostring) + " of " + ($total | tostring) + " traces (" + $scope_pct + "%)",
            severity: $severity,
            enables: ["accurate trace analysis", "better observatory signal quality"]
          },
          implementation: {
            files_to_modify: $files,
            approach: $approach,
            test_strategy: $test_strategy,
            complexity: $complexity,
            blast_radius: $blast
          },
          priority_score: $priority,
          batch: $batch,
          depends_on: $depends_on,
          unlocks: $unlocks
        }' > "$SUG_FILE"

    # Accumulate matrix entry
    MATRIX_ENTRIES=$(echo "$MATRIX_ENTRIES" | jq \
        --arg sug_id "$SUG_ID" \
        --arg signal_id "$SIG_ID" \
        --arg severity "$SEVERITY" \
        --argjson affected_pct "$AFFECTED_PCT" \
        --argjson priority "$PRIORITY" \
        --arg effort "$COMPLEXITY" \
        --arg blast "$BLAST" \
        --arg batch "$BATCH_LABEL" \
        --argjson files "$FILES" \
        --argjson depends_on "$DEPENDS_ON" \
        --argjson unlocks "$UNLOCKS" \
        '. + [{
          sug_id: $sug_id,
          signal_id: $signal_id,
          severity: $severity,
          affected_pct: $affected_pct,
          priority: $priority,
          effort: $effort,
          blast: $blast,
          batch: $batch,
          files: $files,
          depends_on: $depends_on,
          unlocks: $unlocks,
          status: "proposed"
        }]')

    echo "Created $SUG_ID → $SIG_ID (priority: $PRIORITY, batch: $BATCH_LABEL)"
    SUG_NUM=$((SUG_NUM + 1))
done <<< "$SORTED"

# --- Build batches summary ---
BATCHES=$(echo "$MATRIX_ENTRIES" | jq '
  group_by(.batch) |
  map({
    label: .[0].batch,
    signals: [.[].signal_id],
    files: ([.[].files] | add | unique),
    combined_effort: (
      [.[].effort] |
      if index("high") then "high"
      elif index("medium") then "medium"
      else "low" end
    )
  }) |
  map({key: .label, value: {
    label: .label,
    signals: .signals,
    files: .files,
    combined_effort: .combined_effort
  }}) |
  from_entries
' 2>/dev/null || echo '{}')

# --- Build effort buckets ---
EFFORT_BUCKETS=$(echo "$MATRIX_ENTRIES" | jq '
  {
    quick_wins:  [.[] | select(.effort == "low") | .sug_id],
    moderate:    [.[] | select(.effort == "medium") | .sug_id],
    deep:        [.[] | select(.effort == "high") | .sug_id]
  }
' 2>/dev/null || echo '{"quick_wins": [], "moderate": [], "deep": []}')

# --- Write comparison-matrix.json ---
jq -cn \
    --argjson matrix "$MATRIX_ENTRIES" \
    --argjson batches "$BATCHES" \
    --argjson effort_buckets "$EFFORT_BUCKETS" \
    '{
      matrix: $matrix,
      batches: $batches,
      effort_buckets: $effort_buckets
    }' > "$MATRIX_FILE"

TOTAL_SUGS=$((SUG_NUM - 1))
echo "Suggestion generation complete: $TOTAL_SUGS suggestions in $SUGGESTIONS_DIR"
echo "Comparison matrix written → $MATRIX_FILE"

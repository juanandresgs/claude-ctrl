#!/usr/bin/env bash
# test-obs-pipeline.sh — End-to-end observatory pipeline integration test (W-OBS-4).
#
# Production sequence exercised:
#   1. Seed + Summary:       emit synthetic metrics → obs summary → verify analysis keys
#   2. Suggestion lifecycle: suggest → accept → seed more metrics → converge → verify result
#   3. Pattern detection:    emit 5+ guard_denial rows for same policy → summary → verify
#                            patterns contains repeated_denial
#   4. Sidecar report:       python3 sidecars/observatory/observe.py produces valid JSON
#                            with all generate_report() analysis sections
#   5. Sidecar read-only:    count obs_metrics + obs_suggestions rows before/after sidecar
#                            run — counts match (obs_runs will gain 1 row from record_run,
#                            which is the domain module's internal bookkeeping, documented
#                            here and in DEC-SIDECAR-001)
#
# All scenarios use a fresh isolated state.db to prevent cross-test pollution.
#
# @decision DEC-OBS-PIPE-001
# @title test-obs-pipeline.sh proves the full observatory flywheel end-to-end
# @status accepted
# @rationale W-OBS-4 upgrades the sidecar to call generate_report(). This test
#   verifies the complete production path: emit → summary → patterns → suggest →
#   accept → converge. Unit tests of the Python layer exist in runtime/tests/;
#   this scenario test proves the shell CLI, Python domain module, and sidecar
#   all wire together correctly in the combined runtime environment.
set -euo pipefail

TEST_NAME="test-obs-pipeline"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_ROOT="$REPO_ROOT/runtime"
SIDECAR="$REPO_ROOT/sidecars/observatory/observe.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"

PASS=0
FAIL=0

# shellcheck disable=SC2329  # invoked via trap
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"

# ---------------------------------------------------------------------------
# Helper: provision a fresh schema for each sub-test.
# ---------------------------------------------------------------------------
provision_db() {
    rm -f "$TEST_DB"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Helper: run obs CLI subcommand and return stdout.
# ---------------------------------------------------------------------------
obs_cli() {
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" obs "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: count rows in a table.
# ---------------------------------------------------------------------------
row_count() {
    local table="$1"
    python3 - <<PYEOF
import sqlite3, sys
conn = sqlite3.connect("$TEST_DB")
n = conn.execute("SELECT COUNT(*) FROM $table").fetchone()[0]
conn.close()
print(n)
PYEOF
}

# ===========================================================================
# Scenario 1: Seed + Summary — verify generate_report() analysis keys present
# ===========================================================================
provision_db

# Emit a handful of mixed metrics to give the analysis something to work with
obs_cli emit agent_duration_s 12.5 --role implementer >/dev/null
obs_cli emit agent_duration_s 14.0 --role implementer >/dev/null
obs_cli emit agent_duration_s 10.0 --role reviewer >/dev/null
obs_cli emit test_result 1.0 --role reviewer >/dev/null
obs_cli emit test_result 0.0 --role reviewer >/dev/null
obs_cli emit eval_verdict 1.0 >/dev/null

summary_out=$(obs_cli summary)

# Verify all six required keys are present
missing=()
for key in metrics_summary trends patterns suggestions convergence review_gate_health; do
    val=$(printf '%s' "$summary_out" | jq --arg k "$key" 'has($k)' 2>/dev/null || echo "false")
    if [[ "$val" != "true" ]]; then
        missing+=("$key")
    fi
done

if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "PASS: $TEST_NAME — scenario 1: summary has all analysis keys"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 1: summary missing keys: ${missing[*]}"
    echo "  output: $summary_out"
    (( FAIL++ )) || true
fi

# Also verify metrics_summary.total > 0
total=$(printf '%s' "$summary_out" | jq '.metrics_summary.total // 0' 2>/dev/null || echo "0")
if [[ "$total" -gt 0 ]]; then
    echo "PASS: $TEST_NAME — scenario 1: metrics_summary.total=$total > 0"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 1: metrics_summary.total=$total (expected > 0)"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Scenario 2: Suggestion lifecycle — suggest → accept → seed → converge
# ===========================================================================
provision_db

# Create a suggestion targeting agent_duration_s with a baseline of 20.0
suggest_out=$(obs_cli suggest perf "Reduce agent duration" \
    --target-metric agent_duration_s --baseline 20.0 2>/dev/null)
sugg_id=$(printf '%s' "$suggest_out" | jq '.id // 0' 2>/dev/null || echo "0")

if [[ "$sugg_id" -gt 0 ]]; then
    echo "PASS: $TEST_NAME — scenario 2: suggestion created id=$sugg_id"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 2: suggest returned id=$sugg_id (expected >0)"
    echo "  output: $suggest_out"
    (( FAIL++ )) || true
fi

# Accept it — set measure_after to now (epoch 0 = already past) so converge fires
accept_out=$(obs_cli accept "$sugg_id" --measure-after 0 2>/dev/null)
accepted_status=$(printf '%s' "$accept_out" | jq -r '.status // ""' 2>/dev/null || echo "")

if [[ "$accepted_status" == "accepted" ]]; then
    echo "PASS: $TEST_NAME — scenario 2: suggestion accepted"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 2: accept returned status='$accepted_status'"
    echo "  output: $accept_out"
    (( FAIL++ )) || true
fi

# Seed fresh agent_duration_s metrics below baseline (should show improvement)
obs_cli emit agent_duration_s 10.0 --role implementer >/dev/null
obs_cli emit agent_duration_s 8.0  --role implementer >/dev/null
obs_cli emit agent_duration_s 9.0  --role implementer >/dev/null

# Run converge — should produce at least one result for sugg_id
converge_out=$(obs_cli converge 2>/dev/null)
converge_count=$(printf '%s' "$converge_out" | jq '.count // 0' 2>/dev/null || echo "0")

if [[ "$converge_count" -ge 1 ]]; then
    echo "PASS: $TEST_NAME — scenario 2: converge returned $converge_count result(s)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 2: converge returned $converge_count results (expected >=1)"
    echo "  output: $converge_out"
    (( FAIL++ )) || true
fi

# Verify effective field is present on the first convergence item
effective=$(printf '%s' "$converge_out" | jq '.items[0].effective // "missing"' 2>/dev/null || echo "missing")
if [[ "$effective" != "missing" ]]; then
    echo "PASS: $TEST_NAME — scenario 2: convergence item has effective=$effective"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 2: convergence item missing effective field"
    echo "  output: $converge_out"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Scenario 3: Pattern detection — 5 guard_denial rows for same policy → repeated_denial
# ===========================================================================
provision_db

policy_label='{"policy":"write_guard","actor":"implementer"}'
for _i in 1 2 3 4 5; do
    obs_cli emit guard_denial 1.0 --labels "$policy_label" >/dev/null
done

pattern_out=$(obs_cli summary)
pattern_types=$(printf '%s' "$pattern_out" \
    | jq '[.patterns[].pattern_type] | join(",")' 2>/dev/null || echo "")

if printf '%s' "$pattern_types" | grep -q "repeated_denial"; then
    echo "PASS: $TEST_NAME — scenario 3: patterns contains repeated_denial ($pattern_types)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 3: patterns does not contain repeated_denial"
    echo "  pattern_types: $pattern_types"
    echo "  full output: $pattern_out"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Scenario 4: Sidecar standalone — produces valid JSON with analysis sections
# ===========================================================================
provision_db

# Seed a few metrics so generate_report has something to work with
obs_cli emit agent_duration_s 5.0 --role implementer >/dev/null
obs_cli emit test_result 1.0 --role reviewer >/dev/null

sidecar_out=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$SIDECAR" 2>/dev/null)

# Verify it parses as JSON
if printf '%s' "$sidecar_out" | jq . >/dev/null 2>&1; then
    echo "PASS: $TEST_NAME — scenario 4: sidecar produced valid JSON"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 4: sidecar output is not valid JSON"
    echo "  output: $sidecar_out"
    (( FAIL++ )) || true
fi

# Verify legacy keys still present. proof_count was removed with
# DEC-CATEGORY-C-PROOF-RETIRE-001.
for key in name observed_at health active_agents pending_dispatches worktree_count recent_event_count; do
    val=$(printf '%s' "$sidecar_out" | jq --arg k "$key" 'has($k)' 2>/dev/null || echo "false")
    if [[ "$val" == "true" ]]; then
        echo "PASS: $TEST_NAME — scenario 4: sidecar report has legacy key '$key'"
        (( PASS++ )) || true
    else
        echo "FAIL: $TEST_NAME — scenario 4: sidecar report missing legacy key '$key'"
        (( FAIL++ )) || true
    fi
done

# Verify analysis sections present
for key in metrics_summary trends patterns suggestions convergence review_gate_health; do
    val=$(printf '%s' "$sidecar_out" | jq --arg k "$key" 'has($k)' 2>/dev/null || echo "false")
    if [[ "$val" == "true" ]]; then
        echo "PASS: $TEST_NAME — scenario 4: sidecar report has analysis key '$key'"
        (( PASS++ )) || true
    else
        echo "FAIL: $TEST_NAME — scenario 4: sidecar report missing analysis key '$key'"
        (( FAIL++ )) || true
    fi
done

# ===========================================================================
# Scenario 5: Sidecar is read-only — obs_metrics and obs_suggestions unchanged
#
# Note: obs_runs will gain 1 row from record_run() called inside generate_report().
# That is the domain module's own internal bookkeeping (DEC-SIDECAR-001).
# We assert only that obs_metrics and obs_suggestions are not written by the sidecar.
# ===========================================================================
provision_db

# Seed some data first
obs_cli emit agent_duration_s 7.0 --role implementer >/dev/null
obs_cli emit agent_duration_s 9.0 --role reviewer >/dev/null
obs_cli suggest perf "test suggestion" >/dev/null

metrics_before=$(row_count obs_metrics)
suggestions_before=$(row_count obs_suggestions)

# Run sidecar
CLAUDE_POLICY_DB="$TEST_DB" python3 "$SIDECAR" >/dev/null 2>&1

metrics_after=$(row_count obs_metrics)
suggestions_after=$(row_count obs_suggestions)

if [[ "$metrics_before" -eq "$metrics_after" ]]; then
    echo "PASS: $TEST_NAME — scenario 5: obs_metrics rows unchanged ($metrics_before before, $metrics_after after)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 5: obs_metrics changed ($metrics_before → $metrics_after)"
    (( FAIL++ )) || true
fi

if [[ "$suggestions_before" -eq "$suggestions_after" ]]; then
    echo "PASS: $TEST_NAME — scenario 5: obs_suggestions rows unchanged ($suggestions_before before, $suggestions_after after)"
    (( PASS++ )) || true
else
    echo "FAIL: $TEST_NAME — scenario 5: obs_suggestions changed ($suggestions_before → $suggestions_after)"
    (( FAIL++ )) || true
fi

# ===========================================================================
# Summary
# ===========================================================================
echo "---"
echo "$TEST_NAME: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0

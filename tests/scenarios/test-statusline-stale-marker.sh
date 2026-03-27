#!/usr/bin/env bash
# test-statusline-stale-marker.sh: proves the statusline snapshot exposes
# marker_age_seconds correctly for fresh, stale, and absent markers.
#
# Sub-tests:
#   1. Fresh marker  → active_agent set, marker_age_seconds >= 0 and < 300
#   2. Stale marker  → marker_age_seconds >= 300 (started_at forced 10m ago)
#   3. No marker     → marker_age_seconds is JSON null, active_agent absent
#
# @decision DEC-SELF-004
# @title Scenario: statusline shows marker age and stale threshold
# @status accepted
# @rationale TKT-023 replaces the actor-implying ⚡impl label with a
#   conservative "marker: impl (age)" label. This scenario validates the
#   data layer (snapshot) that scripts/statusline.sh reads. Testing at the
#   CLI boundary proves the full Python stack (markers.py → statusline.py →
#   cli.py) works end-to-end before the bash rendering layer is involved.
set -euo pipefail

TEST_NAME="test-statusline-stale-marker"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/runtime/cli.py"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" schema ensure >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Sub-test 1: Fresh marker → marker_age_seconds < 300, active_agent set
# ---------------------------------------------------------------------------
CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker set "agent-fresh" "implementer" >/dev/null 2>&1
snap=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" statusline snapshot 2>&1)
age=$(printf '%s' "$snap" | jq -r '.marker_age_seconds // -1')
agent=$(printf '%s' "$snap" | jq -r '.active_agent // empty')

if [[ "$agent" != "implementer" ]]; then
    echo "FAIL: $TEST_NAME sub-test 1 — expected active_agent=implementer, got '$agent'"
    exit 1
fi
if [[ "$age" -lt 0 || "$age" -ge 300 ]]; then
    echo "FAIL: $TEST_NAME sub-test 1 — expected fresh age in [0,300), got $age"
    exit 1
fi

# ---------------------------------------------------------------------------
# Sub-test 2: Stale marker (started_at 10 minutes ago) → age >= 300
# ---------------------------------------------------------------------------
old_ts=$(( $(date +%s) - 600 ))
CLAUDE_POLICY_DB="$TEST_DB" python3 - <<PYEOF
import sqlite3
conn = sqlite3.connect("$TEST_DB")
conn.execute(
    "UPDATE agent_markers SET started_at = ?, is_active = 1 WHERE agent_id = ?",
    ($old_ts, "agent-fresh"),
)
conn.commit()
conn.close()
PYEOF

snap_stale=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" statusline snapshot 2>&1)
age_stale=$(printf '%s' "$snap_stale" | jq -r '.marker_age_seconds // -1')

if [[ "$age_stale" -lt 300 ]]; then
    echo "FAIL: $TEST_NAME sub-test 2 — expected stale age >=300, got $age_stale"
    exit 1
fi

# ---------------------------------------------------------------------------
# Sub-test 3: No active marker → marker_age_seconds is null, active_agent absent
# ---------------------------------------------------------------------------
CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" marker deactivate "agent-fresh" >/dev/null 2>&1
snap_none=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$CLI" statusline snapshot 2>&1)
age_none=$(printf '%s' "$snap_none" | jq -r '.marker_age_seconds // "null"')
agent_none=$(printf '%s' "$snap_none" | jq -r '.active_agent // "null"')

if [[ "$agent_none" != "null" ]]; then
    echo "FAIL: $TEST_NAME sub-test 3 — expected no active_agent, got '$agent_none'"
    exit 1
fi
if [[ "$age_none" != "null" ]]; then
    echo "FAIL: $TEST_NAME sub-test 3 — expected null marker_age_seconds, got '$age_none'"
    exit 1
fi

echo "PASS: $TEST_NAME (3 sub-tests)"
exit 0

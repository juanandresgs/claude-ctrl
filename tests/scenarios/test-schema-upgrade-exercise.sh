#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/tmp/test-schema-upgrade-exercise-$$"
SOURCE_DB="$TMP/project/.claude/state.db.pre-v6-test.bak"
WORK_DIR="$TMP/exercise"
mkdir -p "$(dirname "$SOURCE_DB")" "$WORK_DIR"
trap 'rm -rf "$TMP"' EXIT

sqlite3 "$SOURCE_DB" <<'SQL'
CREATE TABLE critic_runs (
    run_id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    lease_id TEXT,
    role TEXT NOT NULL,
    provider TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
INSERT INTO critic_runs (
    run_id, workflow_id, role, provider, status, started_at, updated_at
) VALUES (
    'old-run', 'wf-old', 'critic', 'codex', 'completed', 1, 1
);
SQL

OUT=$(
  python3 "$ROOT/runtime/cli.py" schema exercise-upgrade \
    --source-db "$SOURCE_DB" \
    --work-dir "$WORK_DIR" \
    --require-reset
)

printf '%s' "$OUT" | jq -e '.ok == true' >/dev/null
printf '%s' "$OUT" | jq -e '.before_schema_major == ""' >/dev/null
printf '%s' "$OUT" | jq -e '.schema_major == "6"' >/dev/null
printf '%s' "$OUT" | jq -e '.reset_exercised == true' >/dev/null
printf '%s' "$OUT" | jq -e '.archive_exists == true' >/dev/null
printf '%s' "$OUT" | jq -e '.last_reset_reason == "schema_major_mismatch:missing"' >/dev/null

# The source DB must remain stale; deleting/replacing it is not a valid test.
sqlite3 "$SOURCE_DB" "PRAGMA table_info(critic_runs)" | grep -q '|run_id|'
if sqlite3 "$SOURCE_DB" "PRAGMA table_info(critic_runs)" | grep -q '|stage_run_id|'; then
  echo "FAIL: source DB was mutated in place" >&2
  exit 1
fi

DOCTOR=$(
  python3 "$ROOT/runtime/cli.py" doctor \
    --project-root "$TMP/project" \
    --exercise-schema-upgrade
)
printf '%s' "$DOCTOR" | jq -e '.checks[] | select(.name == "schema_upgrade_exercise" and .ok == true)' >/dev/null

echo "PASS test-schema-upgrade-exercise"

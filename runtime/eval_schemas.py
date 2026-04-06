"""
Behavioral Evaluation Framework — SQLite schema for eval_results.db.

This module is the sole DDL authority for the eval database. It is
intentionally separate from runtime/schemas.py and state.db so that
behavioral eval data never mixes with workflow control-plane state.

@decision DEC-EVAL-SCHEMA-001
Title: eval_results.db schema lives in a separate module from state.db
Status: accepted
Rationale: Eval data (run summaries, per-scenario scores, raw outputs)
  has a different retention and access pattern than workflow control-plane
  state. Keeping the schemas in separate modules with separate connections
  enforces the invariant at the import level: no eval DDL can accidentally
  land in state.db via ALL_DDL, and no workflow DDL can appear in
  eval_results.db. ensure_eval_schema() mirrors the pattern of ensure_schema()
  in schemas.py — idempotent, single-transaction, CREATE TABLE IF NOT EXISTS.

@decision DEC-EVAL-SCHEMA-002
Title: EVAL_VERDICTS mirrors EVALUATION_STATUSES from schemas.py
Status: accepted
Rationale: The verdict space for eval scenarios is the same status vocabulary
  used by the evaluator workflow (idle, pending, needs_changes,
  ready_for_guardian, blocked_by_plan). Reusing EVALUATION_STATUSES avoids
  a second authoritative list that could diverge. Scenarios also use
  domain-specific verdicts like 'deny' captured in verdict_expected; those
  are validated at the scenario-runner layer, not here.
"""

from __future__ import annotations

import sqlite3

from runtime.schemas import EVALUATION_STATUSES

# ---------------------------------------------------------------------------
# DDL — one constant per table, mirroring the pattern in schemas.py
# ---------------------------------------------------------------------------

EVAL_RUNS_DDL = """
CREATE TABLE IF NOT EXISTS eval_runs (
    run_id          TEXT    PRIMARY KEY,
    started_at      INTEGER NOT NULL,
    finished_at     INTEGER,
    mode            TEXT    NOT NULL,
    scenario_count  INTEGER NOT NULL DEFAULT 0,
    pass_count      INTEGER NOT NULL DEFAULT 0,
    fail_count      INTEGER NOT NULL DEFAULT 0,
    error_count     INTEGER NOT NULL DEFAULT 0,
    metadata_json   TEXT
)
"""

EVAL_SCORES_DDL = """
CREATE TABLE IF NOT EXISTS eval_scores (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id               TEXT    NOT NULL REFERENCES eval_runs(run_id),
    scenario_id          TEXT    NOT NULL,
    category             TEXT    NOT NULL,
    verdict_expected     TEXT    NOT NULL,
    verdict_actual       TEXT,
    verdict_correct      INTEGER NOT NULL DEFAULT 0,
    defect_recall        REAL,
    evidence_score       REAL,
    false_positive_count INTEGER DEFAULT 0,
    confidence_expected  TEXT,
    confidence_actual    TEXT,
    duration_ms          INTEGER,
    error_message        TEXT,
    scored_at            INTEGER NOT NULL
)
"""

EVAL_OUTPUTS_DDL = """
CREATE TABLE IF NOT EXISTS eval_outputs (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id        TEXT    NOT NULL REFERENCES eval_runs(run_id),
    scenario_id   TEXT    NOT NULL,
    raw_output    TEXT    NOT NULL,
    trailer_json  TEXT,
    evidence_text TEXT,
    coverage_json TEXT,
    captured_at   INTEGER NOT NULL
)
"""

# Indexes — one list so ensure_eval_schema() applies them all atomically
EVAL_INDEXES_DDL: list[str] = [
    "CREATE INDEX IF NOT EXISTS idx_eval_scores_run      ON eval_scores (run_id)",
    "CREATE INDEX IF NOT EXISTS idx_eval_scores_scenario ON eval_scores (scenario_id)",
    "CREATE INDEX IF NOT EXISTS idx_eval_scores_category ON eval_scores (category)",
    "CREATE INDEX IF NOT EXISTS idx_eval_outputs_run     ON eval_outputs (run_id)",
]

# Ordered list used by ensure_eval_schema() — tables before indexes
EVAL_ALL_DDL: list[str] = [
    EVAL_RUNS_DDL,
    EVAL_SCORES_DDL,
    EVAL_OUTPUTS_DDL,
]

# ---------------------------------------------------------------------------
# Domain constants
# ---------------------------------------------------------------------------

EVAL_CATEGORIES: frozenset[str] = frozenset({"gate", "judgment", "adversarial"})

EVAL_MODES: frozenset[str] = frozenset({"deterministic", "live"})

# Verdict space mirrors EVALUATION_STATUSES — see DEC-EVAL-SCHEMA-002 above.
EVAL_VERDICTS: frozenset[str] = EVALUATION_STATUSES


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------


def ensure_eval_schema(conn: sqlite3.Connection) -> None:
    """Create all eval tables and indexes idempotently.

    Safe to call on every startup — CREATE TABLE/INDEX IF NOT EXISTS means this
    is a no-op once the schema exists. All DDL runs in a single transaction so
    a partial failure leaves the database in its prior state.

    This function must NEVER be called with a state.db connection. The caller
    is responsible for passing a connection to eval_results.db.
    """
    with conn:
        for ddl in EVAL_ALL_DDL:
            conn.execute(ddl)
        for idx_ddl in EVAL_INDEXES_DDL:
            conn.execute(idx_ddl)

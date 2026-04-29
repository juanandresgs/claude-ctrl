"""
Shared runtime schemas and constants.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: All workflow state (proof, agents, events, worktrees, dispatch)
  lives in a single WAL-mode SQLite database reached through cc-policy.
  Flat files and breadcrumbs are explicitly NOT authority — they may exist
  as evidence or recovery material only (DEC-FORK-007, DEC-FORK-013).
  Tables are created idempotently via CREATE TABLE IF NOT EXISTS so schema
  bootstrapping is safe to call multiple times from any entrypoint.
"""

from __future__ import annotations

import sqlite3

from runtime.core.stage_registry import ACTIVE_STAGES

# ---------------------------------------------------------------------------
# Marker cleanup whitelist — derived from the single authority (stage_registry)
#
# @decision DEC-CONV-002-AMEND-001
# Title: _MARKER_ACTIVE_ROLES derives from stage_registry.ACTIVE_STAGES
# Status: accepted
# Rationale: The original DEC-CONV-002 cleanup UPDATE used a hardcoded 4-role
#   whitelist ('planner','implementer','reviewer','guardian'). This excluded
#   compound-stage roles like 'guardian:land' and 'guardian:provision', causing
#   every SubagentStart that correctly seated a compound-stage marker to have
#   it silently wiped on the very next CLI invocation (since every _get_conn()
#   triggers ensure_schema()). Root cause confirmed in GS1-F-4 (global-soak-main).
#
#   Fix: derive the whitelist from runtime.core.stage_registry.ACTIVE_STAGES —
#   the declared single authority for dispatch-significant roles (DEC-CLAUDEX-
#   STAGE-REGISTRY-001). The bare "guardian" string is retained in the union for
#   backward compatibility with legacy statusline seeders and test helpers that
#   write bare-role markers; a follow-up cleanup slice will remove it once those
#   callers are migrated to compound-stage form.
#
#   Any future addition to ACTIVE_STAGES automatically propagates here —
#   making architectural divergence mechanically difficult (CLAUDE.md
#   "Architecture Preservation").
# ---------------------------------------------------------------------------
_MARKER_ACTIVE_ROLES: frozenset = frozenset(ACTIVE_STAGES) | {"guardian"}

# ---------------------------------------------------------------------------
# DDL — one constant per table so callers can reference individual statements
# ---------------------------------------------------------------------------

AGENT_MARKERS_DDL = """
CREATE TABLE IF NOT EXISTS agent_markers (
    agent_id    TEXT    PRIMARY KEY,
    role        TEXT    NOT NULL,
    started_at  INTEGER NOT NULL,
    stopped_at  INTEGER,
    is_active   INTEGER NOT NULL DEFAULT 1,
    status      TEXT    NOT NULL DEFAULT 'active',
    workflow_id TEXT
)
"""

EVENTS_DDL = """
CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    type       TEXT    NOT NULL,
    source     TEXT,
    detail     TEXT,
    created_at INTEGER NOT NULL
)
"""

WORKTREES_DDL = """
CREATE TABLE IF NOT EXISTS worktrees (
    path       TEXT    PRIMARY KEY,
    branch     TEXT    NOT NULL,
    ticket     TEXT,
    created_at INTEGER NOT NULL,
    removed_at INTEGER
)
"""

TRACES_DDL = """
CREATE TABLE IF NOT EXISTS traces (
    session_id  TEXT    PRIMARY KEY,
    agent_role  TEXT,
    ticket      TEXT,
    started_at  INTEGER NOT NULL,
    ended_at    INTEGER,
    summary     TEXT
)
"""

TRACE_MANIFEST_DDL = """
CREATE TABLE IF NOT EXISTS trace_manifest (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT    NOT NULL,
    entry_type  TEXT    NOT NULL,
    path        TEXT,
    detail      TEXT,
    created_at  INTEGER NOT NULL,
    FOREIGN KEY (session_id) REFERENCES traces(session_id)
)
"""

SESSION_TOKENS_DDL = """
CREATE TABLE IF NOT EXISTS session_tokens (
    session_id   TEXT    NOT NULL,
    project_hash TEXT    NOT NULL,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL,
    PRIMARY KEY (session_id, project_hash)
)
"""

TODO_STATE_DDL = """
CREATE TABLE IF NOT EXISTS todo_state (
    project_hash   TEXT    PRIMARY KEY,
    project_count  INTEGER NOT NULL DEFAULT 0,
    global_count   INTEGER NOT NULL DEFAULT 0,
    updated_at     INTEGER NOT NULL
)
"""

WORKFLOW_BINDINGS_DDL = """
CREATE TABLE IF NOT EXISTS workflow_bindings (
    workflow_id   TEXT    PRIMARY KEY,
    worktree_path TEXT    NOT NULL,
    branch        TEXT    NOT NULL,
    base_branch   TEXT    NOT NULL DEFAULT 'main',
    ticket        TEXT,
    initiative    TEXT,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
)
"""

WORKFLOW_SCOPE_DDL = """
CREATE TABLE IF NOT EXISTS workflow_scope (
    workflow_id       TEXT    PRIMARY KEY REFERENCES workflow_bindings(workflow_id),
    allowed_paths     TEXT,
    required_paths    TEXT,
    forbidden_paths   TEXT,
    authority_domains TEXT,
    updated_at        INTEGER NOT NULL
)
"""

EVALUATION_STATE_DDL = """
CREATE TABLE IF NOT EXISTS evaluation_state (
    workflow_id  TEXT    PRIMARY KEY,
    status       TEXT    NOT NULL DEFAULT 'idle',
    head_sha     TEXT,
    blockers     INTEGER DEFAULT 0,
    major        INTEGER DEFAULT 0,
    minor        INTEGER DEFAULT 0,
    updated_at   INTEGER NOT NULL
)
"""

BUGS_DDL = """
CREATE TABLE IF NOT EXISTS bugs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    fingerprint      TEXT    NOT NULL UNIQUE,
    bug_type         TEXT    NOT NULL,
    title            TEXT    NOT NULL,
    body             TEXT,
    scope            TEXT    NOT NULL DEFAULT 'global',
    source_component TEXT,
    file_path        TEXT,
    evidence         TEXT,
    disposition      TEXT    NOT NULL DEFAULT 'pending',
    issue_number     INTEGER,
    issue_url        TEXT,
    first_seen_at    INTEGER NOT NULL,
    last_seen_at     INTEGER NOT NULL,
    encounter_count  INTEGER NOT NULL DEFAULT 1
)
"""

APPROVALS_DDL = """
CREATE TABLE IF NOT EXISTS approvals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    workflow_id TEXT    NOT NULL,
    op_type     TEXT    NOT NULL,
    granted_by  TEXT    NOT NULL DEFAULT 'user',
    created_at  INTEGER NOT NULL,
    consumed    INTEGER NOT NULL DEFAULT 0,
    consumed_at INTEGER
)
"""

BOOTSTRAP_REQUESTS_DDL = """
CREATE TABLE IF NOT EXISTS bootstrap_requests (
    token             TEXT    PRIMARY KEY,
    workflow_id       TEXT    NOT NULL,
    worktree_path     TEXT    NOT NULL,
    requested_by      TEXT    NOT NULL,
    justification     TEXT    NOT NULL,
    payload_json      TEXT    NOT NULL DEFAULT '{}',
    created_at        INTEGER NOT NULL,
    expires_at        INTEGER NOT NULL,
    consumed          INTEGER NOT NULL DEFAULT 0,
    consumed_at       INTEGER,
    consumed_by       TEXT
)
"""

BOOTSTRAP_REQUESTS_INDEX_WORKFLOW_DDL = """
CREATE INDEX IF NOT EXISTS idx_bootstrap_requests_workflow
    ON bootstrap_requests (workflow_id, created_at DESC)
"""

BOOTSTRAP_REQUESTS_INDEX_ACTIVE_DDL = """
CREATE INDEX IF NOT EXISTS idx_bootstrap_requests_active
    ON bootstrap_requests (worktree_path, consumed, expires_at)
"""

DISPATCH_LEASES_DDL = """
CREATE TABLE IF NOT EXISTS dispatch_leases (
    lease_id           TEXT    PRIMARY KEY,
    agent_id           TEXT,
    role               TEXT    NOT NULL,
    workflow_id        TEXT,
    worktree_path      TEXT,
    branch             TEXT,
    allowed_ops_json   TEXT    NOT NULL DEFAULT '["routine_local"]',
    blocked_ops_json   TEXT    NOT NULL DEFAULT '[]',
    requires_eval      INTEGER NOT NULL DEFAULT 1,
    head_sha           TEXT,
    approval_scope_json TEXT,
    next_step          TEXT,
    status             TEXT    NOT NULL DEFAULT 'active',
    issued_at          INTEGER NOT NULL,
    expires_at         INTEGER NOT NULL,
    released_at        INTEGER,
    metadata_json      TEXT
)
"""

DISPATCH_LEASES_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_lease_worktree_active
       ON dispatch_leases (worktree_path, status) WHERE status = 'active'""",
    """CREATE INDEX IF NOT EXISTS idx_lease_agent_active
       ON dispatch_leases (agent_id, status) WHERE status = 'active'""",
    """CREATE INDEX IF NOT EXISTS idx_lease_workflow_active
       ON dispatch_leases (workflow_id, status) WHERE status = 'active'""",
    """CREATE INDEX IF NOT EXISTS idx_lease_status
       ON dispatch_leases (status)""",
]

COMPLETION_RECORDS_DDL = """
CREATE TABLE IF NOT EXISTS completion_records (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    lease_id        TEXT    NOT NULL,
    workflow_id     TEXT    NOT NULL,
    role            TEXT    NOT NULL,
    verdict         TEXT    NOT NULL,
    valid           INTEGER NOT NULL DEFAULT 0,
    payload_json    TEXT    NOT NULL,
    missing_fields  TEXT,
    created_at      INTEGER NOT NULL
)
"""

CRITIC_REVIEWS_DDL = """
CREATE TABLE IF NOT EXISTS critic_reviews (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    workflow_id  TEXT    NOT NULL,
    lease_id     TEXT,
    role         TEXT    NOT NULL,
    provider     TEXT    NOT NULL,
    verdict      TEXT    NOT NULL,
    summary      TEXT,
    detail       TEXT,
    fingerprint  TEXT,
    metadata_json TEXT   NOT NULL DEFAULT '{}',
    created_at   INTEGER NOT NULL
)
"""

CRITIC_REVIEWS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_critic_reviews_workflow_role_time
       ON critic_reviews (workflow_id, role, created_at DESC, id DESC)""",
    """CREATE INDEX IF NOT EXISTS idx_critic_reviews_lease
       ON critic_reviews (lease_id) WHERE lease_id IS NOT NULL AND lease_id != ''""",
]

TEST_STATE_DDL = """
CREATE TABLE IF NOT EXISTS test_state (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    project_root TEXT    NOT NULL UNIQUE,
    head_sha     TEXT,
    status       TEXT    NOT NULL DEFAULT 'unknown',
    pass_count   INTEGER NOT NULL DEFAULT 0,
    fail_count   INTEGER NOT NULL DEFAULT 0,
    total_count  INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL
)
"""

TEST_STATE_INDEX_DDL = (
    "CREATE INDEX IF NOT EXISTS idx_test_state_project ON test_state (project_root)"
)

# ---------------------------------------------------------------------------
# Observatory DDL (W-OBS-1)
# ---------------------------------------------------------------------------

OBS_METRICS_DDL = """
CREATE TABLE IF NOT EXISTS obs_metrics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metric_name TEXT    NOT NULL,
    value       REAL    NOT NULL,
    role        TEXT,
    labels_json TEXT,
    session_id  TEXT,
    created_at  INTEGER NOT NULL
)
"""

OBS_METRICS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_obs_metrics_name_time
       ON obs_metrics (metric_name, created_at)""",
    """CREATE INDEX IF NOT EXISTS idx_obs_metrics_role
       ON obs_metrics (role) WHERE role IS NOT NULL""",
]

OBS_SUGGESTIONS_DDL = """
CREATE TABLE IF NOT EXISTS obs_suggestions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    signal_id       TEXT,
    category        TEXT    NOT NULL,
    title           TEXT    NOT NULL,
    body            TEXT,
    target_metric   TEXT,
    baseline_value  REAL,
    status          TEXT    NOT NULL DEFAULT 'proposed',
    reject_reason   TEXT,
    disposition_at  INTEGER,
    measure_after   INTEGER,
    measured_value  REAL,
    effective       INTEGER,
    defer_reassess_after INTEGER,
    source_session  TEXT,
    created_at      INTEGER NOT NULL
)
"""

OBS_SUGGESTIONS_INDEXES_DDL: list[str] = [
    """CREATE INDEX IF NOT EXISTS idx_obs_suggestions_status
       ON obs_suggestions (status)""",
    """CREATE INDEX IF NOT EXISTS idx_obs_suggestions_signal
       ON obs_suggestions (signal_id) WHERE signal_id IS NOT NULL""",
]

OBS_RUNS_DDL = """
CREATE TABLE IF NOT EXISTS obs_runs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ran_at           INTEGER NOT NULL,
    metrics_snapshot TEXT,
    trace_count      INTEGER,
    suggestion_count INTEGER
)
"""

# @decision DEC-CONFIG-AUTHORITY-001
# Title: Policy engine is the canonical authority for enforcement toggles
# Status: accepted
# Rationale: Before this table, enforcement toggles were scattered across
#   settings.json, the codex plugin's state.json, and hardcoded defaults.
#   The policy engine had no knowledge of plugin-side toggles. This table
#   centralises toggle storage in cc_state.db so that cc-policy is the sole
#   authority. Plugin code (codex setup) becomes a thin shim that delegates
#   to this module via cc-policy config set. Scope precedence (lookup order):
#   workflow=<id> → project=<root> → global → None
ENFORCEMENT_CONFIG_DDL = """
CREATE TABLE IF NOT EXISTS enforcement_config (
    scope       TEXT NOT NULL,         -- 'global' | 'project=<root>' | 'workflow=<id>'
    key         TEXT NOT NULL,         -- e.g. 'review_gate_regular_stop'
    value       TEXT NOT NULL,         -- string-encoded; callers parse
    updated_at  INTEGER NOT NULL,
    PRIMARY KEY (scope, key)
)
"""

ENFORCEMENT_CONFIG_INDEX_DDL = """
CREATE INDEX IF NOT EXISTS idx_enforcement_config_key ON enforcement_config (key, scope)
"""

# ---------------------------------------------------------------------------
# ClauDEX canonical decision/work registry (shadow-only persistence surface)
#
# @decision DEC-CLAUDEX-DW-REGISTRY-001
# Title: decisions + work_items SQLite tables are the first canonical persistence layer for the decision/work registry
# Status: proposed (shadow-mode, Phase 1 constitutional kernel)
# Rationale: CUTOVER_PLAN §Decision and Work Record Architecture requires
#   runtime-owned machine-readable records for decisions, work items,
#   scope manifests, evaluation contracts, supersessions, authority
#   changes, and landed-commit links. This slice establishes the
#   narrow persistence substrate for the first two entity kinds
#   (decisions and work items) so later slices can migrate markdown
#   `@decision` annotations, render decision digests, and link git
#   trailers to canonical records without rebuilding the schema.
#
#   Status enums are enforced at the Python layer
#   (runtime/core/decision_work_registry.py) rather than via SQL CHECK
#   so error messages stay human-readable JSON, matching the repo
#   convention (see PROOF_STATUSES / EVALUATION_STATUSES above).
#
#   Supersession is modelled via two self-referential columns:
#     * decisions.supersedes    — the predecessor this decision replaces
#     * decisions.superseded_by — the successor that replaced this one
#   Both are nullable TEXT to avoid SQLite foreign-key bootstrap ordering
#   headaches; referential integrity is enforced by the domain-layer
#   `supersede_decision()` helper, which runs the whole operation in a
#   single transaction.
# ---------------------------------------------------------------------------

DECISIONS_DDL = """
CREATE TABLE IF NOT EXISTS decisions (
    decision_id   TEXT    PRIMARY KEY,
    title         TEXT    NOT NULL,
    status        TEXT    NOT NULL,
    rationale     TEXT    NOT NULL,
    version       INTEGER NOT NULL,
    author        TEXT    NOT NULL,
    scope         TEXT    NOT NULL,
    supersedes    TEXT,
    superseded_by TEXT,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
)
"""

DECISIONS_INDEX_STATUS_DDL = """
CREATE INDEX IF NOT EXISTS idx_decisions_status ON decisions (status)
"""

DECISIONS_INDEX_SCOPE_DDL = """
CREATE INDEX IF NOT EXISTS idx_decisions_scope ON decisions (scope)
"""

DECISIONS_INDEX_SUPERSEDES_DDL = """
CREATE INDEX IF NOT EXISTS idx_decisions_supersedes ON decisions (supersedes)
"""

WORK_ITEMS_DDL = """
CREATE TABLE IF NOT EXISTS work_items (
    work_item_id    TEXT    PRIMARY KEY,
    goal_id         TEXT    NOT NULL,
    workflow_id     TEXT,
    title           TEXT    NOT NULL,
    status          TEXT    NOT NULL,
    version         INTEGER NOT NULL,
    author          TEXT    NOT NULL,
    scope_json      TEXT    NOT NULL DEFAULT '{}',
    evaluation_json TEXT    NOT NULL DEFAULT '{}',
    head_sha        TEXT,
    reviewer_round  INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
)
"""

WORK_ITEMS_INDEX_GOAL_DDL = """
CREATE INDEX IF NOT EXISTS idx_work_items_goal ON work_items (goal_id)
"""

WORK_ITEMS_INDEX_STATUS_DDL = """
CREATE INDEX IF NOT EXISTS idx_work_items_status ON work_items (status)
"""

WORK_ITEMS_INDEX_WORKFLOW_DDL = """
CREATE INDEX IF NOT EXISTS idx_work_items_workflow
    ON work_items (workflow_id) WHERE workflow_id IS NOT NULL
"""

# ---------------------------------------------------------------------------
# ClauDEX canonical goal-contract persistence (shadow-only)
#
# @decision DEC-CLAUDEX-GOAL-CONTRACTS-001
# Title: goal_contracts SQLite table is the narrow persistence substrate for contracts.GoalContract
# Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract persistence)
# Rationale: The Phase 2 capstone helper
#   ``runtime.core.prompt_pack.compile_prompt_pack_for_stage`` still
#   requires callers to pass a typed ``contracts.GoalContract`` /
#   ``contracts.WorkItemContract`` pair by hand because no persistence
#   layer exists for goal contracts. The work-item side already has
#   ``work_items`` (DEC-CLAUDEX-DW-REGISTRY-001); this slice mirrors
#   that pattern for goal contracts so a later prompt-pack workflow
#   capture helper can resolve a ``workflow_id`` (or ``goal_id``) to
#   the typed records the capstone already accepts.
#
#   Field mapping (mirrors ``contracts.GoalContract``):
#     * goal_id, desired_end_state, status            → simple columns
#     * autonomy_budget                                → INTEGER, default 0
#     * continuation_rules / stop_conditions /
#       escalation_boundaries / user_decision_boundaries
#                                                      → JSON-encoded TEXT
#                                                        (mirrors the
#                                                        ``scope_json`` /
#                                                        ``evaluation_json``
#                                                        pattern in
#                                                        work_items)
#     * created_at / updated_at                        → INTEGER NOT NULL
#
#   Statuses are enforced at the Python layer against
#   ``runtime.core.contracts.GOAL_STATUSES`` so the error message stays
#   human-readable JSON (matching every other status family in this
#   file). The table carries no SQL CHECK constraint.
# ---------------------------------------------------------------------------

GOAL_CONTRACTS_DDL = """
CREATE TABLE IF NOT EXISTS goal_contracts (
    goal_id                       TEXT    PRIMARY KEY,
    workflow_id                   TEXT,
    desired_end_state             TEXT    NOT NULL,
    status                        TEXT    NOT NULL,
    autonomy_budget               INTEGER NOT NULL DEFAULT 0,
    continuation_rules_json       TEXT    NOT NULL DEFAULT '[]',
    stop_conditions_json          TEXT    NOT NULL DEFAULT '[]',
    escalation_boundaries_json    TEXT    NOT NULL DEFAULT '[]',
    user_decision_boundaries_json TEXT    NOT NULL DEFAULT '[]',
    created_at                    INTEGER NOT NULL,
    updated_at                    INTEGER NOT NULL
)
"""

GOAL_CONTRACTS_INDEX_STATUS_DDL = """
CREATE INDEX IF NOT EXISTS idx_goal_contracts_status ON goal_contracts (status)
"""

GOAL_CONTRACTS_INDEX_WORKFLOW_DDL = """
CREATE INDEX IF NOT EXISTS idx_goal_contracts_workflow
    ON goal_contracts (workflow_id) WHERE workflow_id IS NOT NULL
"""

# ---------------------------------------------------------------------------
# pending_agent_requests — SubagentStart contract carrier
# (DEC-CLAUDEX-SA-CARRIER-001)
#
# Design notes:
#   * Real SubagentStart harness payloads carry only six harness fields;
#     the six contract fields (workflow_id … generated_at) are absent.
#   * The orchestrator embeds those fields as a CLAUDEX_CONTRACT_BLOCK
#     marker in tool_input.prompt at Agent-call time.
#   * pre-agent.sh (PreToolUse:Agent) extracts the block and writes a row
#     here, keyed by (session_id, agent_type).
#   * subagent-start.sh reads and atomically deletes the row at SubagentStart
#     time, merging the six fields into HOOK_INPUT so the runtime-first path
#     fires in production.
#   * File sidecars are explicitly rejected: a tmp file is a second
#     non-runtime authority for a control-plane fact
#     (DEC-CLAUDEX-SA-PAYLOAD-SHAPE-001).
# ---------------------------------------------------------------------------

PENDING_AGENT_REQUESTS_DDL = """
CREATE TABLE IF NOT EXISTS pending_agent_requests (
    session_id     TEXT    NOT NULL,
    agent_type     TEXT    NOT NULL,
    workflow_id    TEXT    NOT NULL,
    stage_id       TEXT    NOT NULL,
    goal_id        TEXT    NOT NULL,
    work_item_id   TEXT    NOT NULL,
    decision_scope TEXT    NOT NULL,
    generated_at   INTEGER NOT NULL,
    written_at     INTEGER NOT NULL,
    PRIMARY KEY (session_id, agent_type)
)
"""

# ---------------------------------------------------------------------------
# ClauDEX Phase 2b — Agent-Agnostic Supervision Domain
#
# @decision DEC-CLAUDEX-SUPERVISION-DOMAIN-001
# Title: agent_sessions, seats, supervision_threads, dispatch_attempts are the
#        runtime-owned schema authority for the supervision fabric
# Status: accepted
# Rationale: CUTOVER_PLAN §Phase 2b requires the runtime to own dispatch claim/ack,
#   seat binding, supervision-thread state, and timeout policy. The current bridge
#   stack stores this truth in tmux pane ids, relay sentinels, helper pids, and
#   queue files — none of which is a canonical runtime authority.
#
#   This slice establishes the four core tables that will replace those surfaces:
#
#   agent_sessions  — one live agent instance bound to a workflow and transport.
#                     `transport` identifies the adapter class (e.g. 'tmux', 'mcp',
#                     'claude_code'); `transport_handle` is the provider-specific
#                     handle (pane id, MCP session id, etc.) as a diagnostics field
#                     only — it is NOT authority.
#   seats           — named role within a session: 'worker', 'supervisor',
#                     'reviewer', 'observer'. Seats are the unit of supervision
#                     relationships, not raw pane ids.
#   supervision_threads
#                   — an explicit relationship where one seat steers or audits
#                     another. Thread type encodes the relationship intent:
#                     'analysis', 'review', 'autopilot', 'observer'.
#   dispatch_attempts
#                   — one issued instruction with delivery claim, acknowledgment,
#                     retry, and timeout state. This table will become the sole
#                     authority for "did the worker actually receive the task?" —
#                     replacing queue-file timestamps, sentinel echoes, and
#                     pane-text heuristics once adapters are wired.
#
#   This slice is schema-only. No adapter contracts, claim/ack helpers, or
#   recovery loops are added here. Those are Phase 2b subsequent slices once
#   these tables are the accepted schema authority.
#
#   Status enums are enforced at the Python layer (AGENT_SESSION_STATUSES,
#   SEAT_STATUSES, SUPERVISION_THREAD_STATUSES, DISPATCH_ATTEMPT_STATUSES) to
#   match the existing convention in this file.
# ---------------------------------------------------------------------------

AGENT_SESSIONS_DDL = """
CREATE TABLE IF NOT EXISTS agent_sessions (
    session_id       TEXT    PRIMARY KEY,
    workflow_id      TEXT,
    transport        TEXT    NOT NULL,
    transport_handle TEXT,
    status           TEXT    NOT NULL DEFAULT 'active',
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL
)
"""

AGENT_SESSIONS_INDEX_WORKFLOW_DDL = """
CREATE INDEX IF NOT EXISTS idx_agent_sessions_workflow
    ON agent_sessions (workflow_id) WHERE workflow_id IS NOT NULL
"""

AGENT_SESSIONS_INDEX_STATUS_DDL = """
CREATE INDEX IF NOT EXISTS idx_agent_sessions_status ON agent_sessions (status)
"""

SEATS_DDL = """
CREATE TABLE IF NOT EXISTS seats (
    seat_id    TEXT    PRIMARY KEY,
    session_id TEXT    NOT NULL REFERENCES agent_sessions(session_id),
    role       TEXT    NOT NULL,
    status     TEXT    NOT NULL DEFAULT 'active',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
)
"""

SEATS_INDEX_SESSION_DDL = """
CREATE INDEX IF NOT EXISTS idx_seats_session ON seats (session_id)
"""

SEATS_INDEX_STATUS_DDL = """
CREATE INDEX IF NOT EXISTS idx_seats_status ON seats (status)
"""

SUPERVISION_THREADS_DDL = """
CREATE TABLE IF NOT EXISTS supervision_threads (
    thread_id          TEXT    PRIMARY KEY,
    supervisor_seat_id TEXT    NOT NULL REFERENCES seats(seat_id),
    worker_seat_id     TEXT    NOT NULL REFERENCES seats(seat_id),
    thread_type        TEXT    NOT NULL,
    status             TEXT    NOT NULL DEFAULT 'active',
    created_at         INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL
)
"""

SUPERVISION_THREADS_INDEX_SUPERVISOR_DDL = """
CREATE INDEX IF NOT EXISTS idx_supervision_threads_supervisor
    ON supervision_threads (supervisor_seat_id)
"""

SUPERVISION_THREADS_INDEX_WORKER_DDL = """
CREATE INDEX IF NOT EXISTS idx_supervision_threads_worker
    ON supervision_threads (worker_seat_id)
"""

DISPATCH_ATTEMPTS_DDL = """
CREATE TABLE IF NOT EXISTS dispatch_attempts (
    attempt_id          TEXT    PRIMARY KEY,
    seat_id             TEXT    NOT NULL REFERENCES seats(seat_id),
    workflow_id         TEXT,
    instruction         TEXT    NOT NULL,
    status              TEXT    NOT NULL DEFAULT 'pending',
    delivery_claimed_at INTEGER,
    acknowledged_at     INTEGER,
    retry_count         INTEGER NOT NULL DEFAULT 0,
    timeout_at          INTEGER,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
)
"""

DISPATCH_ATTEMPTS_INDEX_SEAT_STATUS_DDL = """
CREATE INDEX IF NOT EXISTS idx_dispatch_attempts_seat_status
    ON dispatch_attempts (seat_id, status)
"""

DISPATCH_ATTEMPTS_INDEX_WORKFLOW_DDL = """
CREATE INDEX IF NOT EXISTS idx_dispatch_attempts_workflow
    ON dispatch_attempts (workflow_id) WHERE workflow_id IS NOT NULL
"""

# Ordered list of all DDL statements — used by ensure_schema()
ALL_DDL: list[str] = [
    AGENT_MARKERS_DDL,
    EVENTS_DDL,
    WORKTREES_DDL,
    TRACES_DDL,
    TRACE_MANIFEST_DDL,
    SESSION_TOKENS_DDL,
    TODO_STATE_DDL,
    WORKFLOW_BINDINGS_DDL,
    WORKFLOW_SCOPE_DDL,
    APPROVALS_DDL,
    BOOTSTRAP_REQUESTS_DDL,
    BOOTSTRAP_REQUESTS_INDEX_WORKFLOW_DDL,
    BOOTSTRAP_REQUESTS_INDEX_ACTIVE_DDL,
    EVALUATION_STATE_DDL,
    BUGS_DDL,
    DISPATCH_LEASES_DDL,
    COMPLETION_RECORDS_DDL,
    CRITIC_REVIEWS_DDL,
    TEST_STATE_DDL,
    OBS_METRICS_DDL,
    OBS_SUGGESTIONS_DDL,
    OBS_RUNS_DDL,
    ENFORCEMENT_CONFIG_DDL,
    ENFORCEMENT_CONFIG_INDEX_DDL,
    # ClauDEX Phase 1 canonical decision/work registry
    # (DEC-CLAUDEX-DW-REGISTRY-001). Indexes are listed individually
    # because CREATE INDEX IF NOT EXISTS is idempotent and the
    # existing ALL_DDL style puts per-table indexes inline.
    DECISIONS_DDL,
    DECISIONS_INDEX_STATUS_DDL,
    DECISIONS_INDEX_SCOPE_DDL,
    DECISIONS_INDEX_SUPERSEDES_DDL,
    WORK_ITEMS_DDL,
    WORK_ITEMS_INDEX_GOAL_DDL,
    WORK_ITEMS_INDEX_STATUS_DDL,
    # ClauDEX Phase 2 canonical goal-contract persistence
    # (DEC-CLAUDEX-GOAL-CONTRACTS-001).
    GOAL_CONTRACTS_DDL,
    GOAL_CONTRACTS_INDEX_STATUS_DDL,
    # ClauDEX Phase 2 SubagentStart contract carrier
    # (DEC-CLAUDEX-SA-CARRIER-001).
    PENDING_AGENT_REQUESTS_DDL,
    # ClauDEX Phase 2b supervision fabric schema authority
    # (DEC-CLAUDEX-SUPERVISION-DOMAIN-001).
    AGENT_SESSIONS_DDL,
    AGENT_SESSIONS_INDEX_WORKFLOW_DDL,
    AGENT_SESSIONS_INDEX_STATUS_DDL,
    SEATS_DDL,
    SEATS_INDEX_SESSION_DDL,
    SEATS_INDEX_STATUS_DDL,
    SUPERVISION_THREADS_DDL,
    SUPERVISION_THREADS_INDEX_SUPERVISOR_DDL,
    SUPERVISION_THREADS_INDEX_WORKER_DDL,
    DISPATCH_ATTEMPTS_DDL,
    DISPATCH_ATTEMPTS_INDEX_SEAT_STATUS_DDL,
    DISPATCH_ATTEMPTS_INDEX_WORKFLOW_DDL,
]

# ---------------------------------------------------------------------------
# ClauDEX Phase 4 — Reviewer Findings Ledger
#
# @decision DEC-CLAUDEX-REVIEWER-FINDINGS-SCHEMA-001
# Title: reviewer_findings table is the runtime-owned structured findings ledger
# Status: accepted
# Rationale: CUTOVER_PLAN §Phase 4 requires the runtime to represent reviewer
#   completions and findings natively. Reviewer findings need a persistent,
#   structured ledger so that convergence state, invalidation on post-review
#   source changes, and prompt-pack compilation have a canonical data source.
#   This table stores individual findings (one row per finding) rather than a
#   blob per completion, enabling per-finding status transitions (open →
#   resolved/waived) and per-finding queries by severity, file, or round.
#
#   Status/severity vocabularies are enforced at the domain layer
#   (FINDING_STATUSES, FINDING_SEVERITIES) following the existing convention.
# ---------------------------------------------------------------------------

REVIEWER_FINDINGS_DDL = """
CREATE TABLE IF NOT EXISTS reviewer_findings (
    finding_id     TEXT    PRIMARY KEY,
    workflow_id    TEXT    NOT NULL,
    work_item_id   TEXT,
    reviewer_round INTEGER NOT NULL DEFAULT 0,
    head_sha       TEXT,
    severity       TEXT    NOT NULL,
    status         TEXT    NOT NULL,
    title          TEXT    NOT NULL,
    detail         TEXT    NOT NULL,
    file_path      TEXT,
    line           INTEGER,
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL
)
"""

REVIEWER_FINDINGS_INDEX_WORKFLOW_DDL = """
CREATE INDEX IF NOT EXISTS idx_reviewer_findings_workflow
    ON reviewer_findings (workflow_id, work_item_id)
"""

REVIEWER_FINDINGS_INDEX_STATUS_DDL = """
CREATE INDEX IF NOT EXISTS idx_reviewer_findings_status
    ON reviewer_findings (status)
"""

REVIEWER_FINDINGS_INDEX_SEVERITY_DDL = """
CREATE INDEX IF NOT EXISTS idx_reviewer_findings_severity
    ON reviewer_findings (severity)
"""

# Append Phase 4 reviewer findings DDL to the master list.
ALL_DDL.extend([
    REVIEWER_FINDINGS_DDL,
    REVIEWER_FINDINGS_INDEX_WORKFLOW_DDL,
    REVIEWER_FINDINGS_INDEX_STATUS_DDL,
    REVIEWER_FINDINGS_INDEX_SEVERITY_DDL,
])

# Reviewer finding status vocabulary (DEC-CLAUDEX-REVIEWER-FINDINGS-SCHEMA-001).
# Enforced at domain layer in runtime/core/reviewer_findings.py.
#   open     — finding identified, not yet addressed
#   resolved — finding addressed by implementer or confirmed fixed
#   waived   — finding acknowledged but intentionally deferred or accepted
FINDING_STATUSES: frozenset[str] = frozenset({"open", "resolved", "waived"})

# Reviewer finding severity vocabulary.
#   blocking — must be resolved before guardian landing
#   concern  — should be resolved but does not block landing
#   note     — informational observation, no action required
FINDING_SEVERITIES: frozenset[str] = frozenset({"blocking", "concern", "note"})

# Named sentinel for the "blocking" severity — sole read-path authority for
# constructing severity filter values in runtime/core consumers.  Consumers
# MUST import this constant rather than hard-coding the literal "blocking" so
# that any future rename of the vocabulary member propagates automatically and
# no read-path filter silently becomes a no-op.
# Single-authority invariant: FINDING_SEVERITY_BLOCKING is definitionally a
# member of FINDING_SEVERITIES; tests enforce this at import time.
# @decision DEC-CLAUDEX-FINDING-SEVERITY-SENTINEL-AUTH-001
# Title: FINDING_SEVERITY_BLOCKING is the sole named sentinel for the "blocking"
#   severity; no runtime/core consumer may use a bare string literal for severity
#   filtering or comparison — they must import this constant.
# Status: accepted
# Rationale: reviewer_convergence.py:172 used a bare "blocking" literal in
#   finding_filters; if the vocabulary ever renames that member the filter
#   becomes a no-op (false-ready-for-guardian). Introducing a named sentinel
#   colocated with FINDING_SEVERITIES makes the single-authority contract
#   mechanically enforceable via an AST-scanner invariant test (T2 in
#   tests/runtime/test_finding_severity_sentinel_auth.py).
FINDING_SEVERITY_BLOCKING: str = "blocking"

# Valid status values — enforced at the domain layer, not via SQL CHECK
# so that the error message is human-readable JSON rather than a constraint
# violation traceback.
PROOF_STATUSES: frozenset[str] = frozenset({"idle", "pending", "verified"})
EVALUATION_STATUSES: frozenset[str] = frozenset(
    {
        "idle",
        "pending",
        "needs_changes",
        "ready_for_guardian",
        "blocked_by_plan",
    }
)
# Approval token op_type values — must match approvals.py VALID_OP_TYPES.
# These are the user-gated destructive/history-rewrite/admin-recovery ops;
# straightforward Guardian push is no longer approval-token gated.
# Enforcement happens in the domain layer (ValueError), not SQL CHECK.
APPROVAL_OP_TYPES: frozenset[str] = frozenset(
    {
        "rebase",
        "reset",
        "force_push",
        "destructive_cleanup",
        "non_ff_merge",
        # Direct ref/object plumbing: commit-tree, update-ref, symbolic-ref,
        # filter-branch, and filter-repo. Normal Guardian landing uses
        # porcelain git commit/plain merge/straightforward push instead.
        "plumbing",
        # Admin recovery: merge --abort and reset --merge.
        # These require an approval token but NOT evaluation readiness.
        "admin_recovery",
    }
)

# Lease lifecycle statuses — enforced at domain layer, not SQL CHECK.
LEASE_STATUSES: frozenset[str] = frozenset({"active", "released", "revoked", "expired"})

# ClauDEX canonical decision lifecycle statuses (DEC-CLAUDEX-DW-REGISTRY-001).
# Enforced at the domain layer in runtime/core/decision_work_registry.py.
#   proposed   — authored but not yet accepted
#   accepted   — active decision, current authority
#   rejected   — rejected before acceptance; kept for audit
#   superseded — replaced by a later accepted decision (supersedes/superseded_by)
#   deprecated — retired without a direct successor
DECISION_STATUSES: frozenset[str] = frozenset(
    {
        "proposed",
        "accepted",
        "rejected",
        "superseded",
        "deprecated",
    }
)

# ClauDEX Phase 2b supervision fabric status constants
# (DEC-CLAUDEX-SUPERVISION-DOMAIN-001). Enforced at domain layer, not SQL CHECK.
#
#   agent_sessions: active — live and accepting dispatches
#                   completed — session ended normally
#                   dead — transport confirmed unreachable
#                   orphaned — session lost contact without clean shutdown
AGENT_SESSION_STATUSES: frozenset[str] = frozenset(
    {"active", "completed", "dead", "orphaned"}
)

#   seats: active — seat is operating
#          released — seat cleanly gave up its role
#          dead — seat host is unreachable
SEAT_STATUSES: frozenset[str] = frozenset({"active", "released", "dead"})

# Named roles a seat may occupy (DEC-CLAUDEX-SUPERVISION-DOMAIN-001).
SEAT_ROLES: frozenset[str] = frozenset({"worker", "supervisor", "reviewer", "observer"})

# @decision DEC-CLAUDEX-SEAT-ROLE-SENTINEL-AUTH-001
# Named sentinel constants for every member of SEAT_ROLES. Any runtime/core
# seat-write call site that constructs a seats row (seats.create or direct
# INSERT INTO seats) MUST reference these sentinels rather than bare string
# literals. Pinned exhaustively by tests/runtime/test_seat_role_sentinel_auth.py
# T1 (sentinel coverage) + T2 (narrow AST ratchet on seat-write call sites).
SEAT_ROLE_WORKER: str = "worker"
SEAT_ROLE_SUPERVISOR: str = "supervisor"
SEAT_ROLE_REVIEWER: str = "reviewer"
SEAT_ROLE_OBSERVER: str = "observer"

#   supervision_threads: active — thread relationship is live
#                        completed — thread ended normally (e.g. reviewer gave verdict)
#                        abandoned — supervisor seat went dead before completing
SUPERVISION_THREAD_STATUSES: frozenset[str] = frozenset(
    {"active", "completed", "abandoned"}
)

# Thread type vocabulary for supervision_threads.
SUPERVISION_THREAD_TYPES: frozenset[str] = frozenset(
    {"analysis", "review", "autopilot", "observer"}
)

#   dispatch_attempts: pending — issued, not yet claimed by transport
#                      delivered — transport adapter recorded delivery claim
#                      acknowledged — agent confirmed receipt
#                      timed_out — timeout_at exceeded without ack
#                      failed — non-retryable delivery failure
#                      cancelled — revoked before delivery
DISPATCH_ATTEMPT_STATUSES: frozenset[str] = frozenset(
    {"pending", "delivered", "acknowledged", "timed_out", "failed", "cancelled"}
)

# Default lease time-to-live: 2 hours.
DEFAULT_LEASE_TTL: int = 7200

# Enforced completion roles are determined by ROLE_SCHEMAS in completions.py.
# The keyset of ROLE_SCHEMAS is the authoritative enforced-role set.
# This constant was removed in W-CONV-5 (dead code — nothing consumed it).


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create all tables and indexes idempotently.

    Safe to call on every startup — CREATE TABLE/INDEX IF NOT EXISTS means this
    is a no-op once the schema exists. All DDL runs in a single transaction
    so a partial failure leaves the database in its prior state.
    Indexes for dispatch_leases are applied after table creation.

    ALTER TABLE migrations are applied after table creation so that existing
    DBs that predate a column addition are brought forward automatically.

    @decision DEC-RT-024
    Title: ALTER TABLE migrations in ensure_schema for agent_markers evolution
    Status: accepted
    Rationale: CREATE TABLE IF NOT EXISTS is idempotent but never adds new
      columns to an existing table. Old DBs created before the `status` column
      was added to AGENT_MARKERS_DDL would fail every markers.py operation that
      references `status`. The standard pattern for SQLite schema evolution is
      to attempt ALTER TABLE ADD COLUMN and swallow the OperationalError when
      the column already exists. This keeps ensure_schema as the single
      migration authority without requiring a separate migration runner.
    """
    with conn:
        # Migrate test_state: the pre-WS3 schema used workflow_id as the PRIMARY KEY
        # and had no project_root column. WS3 changes the primary key to project_root
        # (UNIQUE). Since SQLite cannot ALTER a PRIMARY KEY, we drop and recreate the
        # table when the old schema is detected. Data loss is acceptable: the old
        # test_state rows used workflow_id as key and are incompatible with the new
        # project_root-keyed rows. test-runner.sh will repopulate after the next run.
        #
        # @decision DEC-WS3-003
        # Title: DROP old test_state when pre-WS3 schema is detected
        # Status: accepted
        # Rationale: The old test_state table (workflow_id PK) was never fully wired
        #   into any enforcement hook — it was a stub from an earlier incomplete attempt.
        #   WS3 is the first complete implementation. Dropping and recreating is safer
        #   than a multi-step ALTER that would still leave the wrong primary key.
        #   Existing rows carry no useful state; they will be repopulated by test-runner.sh.
        try:
            existing_columns = {
                row[1] for row in conn.execute("PRAGMA table_info(test_state)").fetchall()
            }
            if existing_columns and "project_root" not in existing_columns:
                # Old schema detected — drop and let CREATE TABLE IF NOT EXISTS rebuild it.
                conn.execute("DROP TABLE IF EXISTS test_state")
                conn.execute("DROP INDEX IF EXISTS idx_test_state_project")
        except sqlite3.OperationalError:
            pass  # table does not exist yet — CREATE TABLE IF NOT EXISTS handles it

        for ddl in ALL_DDL:
            conn.execute(ddl)
        for idx_ddl in DISPATCH_LEASES_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in CRITIC_REVIEWS_INDEXES_DDL:
            conn.execute(idx_ddl)
        conn.execute(TEST_STATE_INDEX_DDL)
        for idx_ddl in OBS_METRICS_INDEXES_DDL:
            conn.execute(idx_ddl)
        for idx_ddl in OBS_SUGGESTIONS_INDEXES_DDL:
            conn.execute(idx_ddl)

        # Migrate agent_markers: add status column if missing.
        # Old DBs (pre-TKT-STAB-A4) have is_active but no status.
        # Swallow OperationalError — it fires when the column already exists.
        try:
            conn.execute(
                "ALTER TABLE agent_markers ADD COLUMN status TEXT NOT NULL DEFAULT 'active'"
            )
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Migrate agent_markers: add workflow_id column if missing.
        # Some intermediate DBs have workflow_id from an earlier migration;
        # newer fresh DBs get it from AGENT_MARKERS_DDL above.
        try:
            conn.execute("ALTER TABLE agent_markers ADD COLUMN workflow_id TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Migrate agent_markers: add project_root column if missing.
        # W-CONV-2 (DEC-CONV-002) scopes marker queries by project_root so that
        # markers from one project do not contaminate actor-role inference in
        # another. Old DBs (pre-W-CONV-2) lack this column; ALTER TABLE adds it
        # with NULL default so all existing rows remain valid (unscoped).
        #
        # @decision DEC-CONV-002
        # Title: project_root added to agent_markers for per-project scoping
        # Status: accepted
        # Rationale: get_active() without project_root uses unscoped fallback
        #   (backward compat for statusline.py). get_active(project_root=X) must
        #   filter to markers written with that root — this column is the predicate.
        try:
            conn.execute("ALTER TABLE agent_markers ADD COLUMN project_root TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Migrate work_items: add reviewer_round column if missing.
        # Old DBs (pre-DEC-CLAUDEX-WORK-ITEM-REVIEWER-ROUND-001) created
        # the work_items table without reviewer_round, but the
        # WorkItemRecord dataclass and contracts.WorkItemContract both
        # carry that field. ALTER TABLE adds it with default 0 so
        # existing rows remain valid (start at the first reviewer
        # round) and new code paths can read / write it without
        # special-casing migration state.
        #
        # @decision DEC-CLAUDEX-WORK-ITEM-REVIEWER-ROUND-001
        # Title: work_items.reviewer_round persists the inner-loop reviewer cycle counter
        # Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract bridge)
        # Rationale: contracts.WorkItemContract carries reviewer_round
        #   as part of the inner-loop convergence shape, but the
        #   work_items SQLite table did not. A future
        #   work_item_contract_codec must round-trip every contract
        #   field; without this column it would have to invent
        #   reviewer_round, which would create a second authority for
        #   the reviewer cycle counter. Adding the column here is the
        #   single-authority fix.
        try:
            conn.execute(
                "ALTER TABLE work_items ADD COLUMN reviewer_round INTEGER NOT NULL DEFAULT 0"
            )
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Migrate work_items: add workflow_id column if missing.
        # DEC-CLAUDEX-DW-WORKFLOW-JOIN-001 requires workflow-scoped
        # goal/work-item resolution in the agent-prompt producer.
        # Legacy rows may have workflow_id NULL and are intentionally
        # excluded from workflow-scoped lookups.
        try:
            conn.execute("ALTER TABLE work_items ADD COLUMN workflow_id TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Migrate goal_contracts: add workflow_id column if missing.
        # Same rationale as work_items above; NULL remains valid for
        # pre-migration legacy rows.
        try:
            conn.execute("ALTER TABLE goal_contracts ADD COLUMN workflow_id TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists — no-op

        # Workflow-scoped indexes are created after the ALTER migrations so
        # existing databases without workflow_id columns are upgraded first.
        conn.execute(WORK_ITEMS_INDEX_WORKFLOW_DDL)
        conn.execute(GOAL_CONTRACTS_INDEX_WORKFLOW_DDL)

        # Cleanup migration (W-CONV-2): deactivate any active markers whose role
        # is NOT a dispatch-significant role. Explore, Bash, and general-purpose
        # agents accumulated ghost markers before the subagent-start.sh filter
        # was added. Running this on startup ensures stale lightweight markers
        # cannot pollute actor-role inference in build_context().
        #
        # @decision DEC-CONV-002
        # Title: One-time cleanup of lightweight-role ghost markers
        # Status: accepted
        # Rationale: Accumulated Explore/Bash/unknown markers with is_active=1
        #   were returned by get_active() as the "newest active" marker, silently
        #   overriding the real implementer/reviewer/guardian role. The cleanup
        #   runs every time ensure_schema() is called (idempotent: rows already
        #   stopped are not touched). Dispatch-significant roles are whitelisted
        #   via _MARKER_ACTIVE_ROLES (see module-level DEC-CONV-002-AMEND-001);
        #   everything else is deactivated with status='stopped'. Phase 8
        #   Slice 11 removed the legacy ``tester`` role from the retained set —
        #   stale tester markers are now deactivated on ensure_schema().
        #   GS1-F-4 (DEC-CONV-002-AMEND-001) replaced the hardcoded 4-role
        #   whitelist with the dynamic _MARKER_ACTIVE_ROLES derived from
        #   stage_registry.ACTIVE_STAGES so compound-stage roles like
        #   'guardian:land' and 'guardian:provision' survive the cleanup.
        _placeholders = ",".join("?" * len(_MARKER_ACTIVE_ROLES))
        conn.execute(
            f"UPDATE agent_markers "
            f"SET    is_active  = 0, "
            f"       status     = 'stopped', "
            f"       stopped_at = COALESCE(stopped_at, CAST(strftime('%s', 'now') AS INTEGER)) "
            f"WHERE  is_active  = 1 "
            f"  AND  role NOT IN ({_placeholders})",
            tuple(sorted(_MARKER_ACTIVE_ROLES)),
        )

        # Seed enforcement_config global defaults if not yet present.
        # INSERT OR IGNORE means this is idempotent — re-running ensure_schema()
        # will not overwrite values that have been deliberately changed.
        # Fail-safe defaults: regular Stop model review off, implementer critic
        # on, provider=codex. Regular Stop now uses deterministic
        # hooks/stop-advisor.sh for obvious-action triage; model review remains
        # explicit/provider-backed only.
        # (DEC-CONFIG-AUTHORITY-001)
        _defaults = [
            ("global", "critic_enabled_implementer_stop", "true"),
            ("global", "critic_retry_limit", "2"),
            ("global", "review_gate_regular_stop", "false"),
            ("global", "review_gate_provider", "codex"),
        ]
        for _scope, _key, _value in _defaults:
            conn.execute(
                "INSERT OR IGNORE INTO enforcement_config (scope, key, value, updated_at) "
                "VALUES (?, ?, ?, CAST(strftime('%s','now') AS INTEGER))",
                (_scope, _key, _value),
            )

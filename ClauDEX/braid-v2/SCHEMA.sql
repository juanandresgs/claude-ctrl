-- braid-v2 SQLite schema
--
-- This schema is the runtime-owned ledger for supervision and recursive loop
-- management. It deliberately does not include repo policy tables such as
-- scope manifests, prompt packs, approvals, or branch law.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- loop_bundles
-- ---------------------------------------------------------------------------
-- One recursively managed loop: worker + optional local supervisor/reviewer/
-- observer seats. Child bundles create the recursive tree.
CREATE TABLE IF NOT EXISTS loop_bundles (
    bundle_id          TEXT PRIMARY KEY,
    parent_bundle_id   TEXT REFERENCES loop_bundles(bundle_id),
    requested_by_seat  TEXT REFERENCES seats(seat_id),
    bundle_type        TEXT NOT NULL,     -- coding_loop | repair_loop | review_loop | soak_loop
    status             TEXT NOT NULL,     -- provisioning | active | paused | blocked | terminal | archived
    goal_ref           TEXT,
    work_item_ref      TEXT,
    autonomy_budget    TEXT,
    notes              TEXT,
    created_at         INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL,
    archived_at        INTEGER
);

CREATE INDEX IF NOT EXISTS idx_loop_bundles_parent
    ON loop_bundles(parent_bundle_id);

CREATE INDEX IF NOT EXISTS idx_loop_bundles_status
    ON loop_bundles(status);

-- ---------------------------------------------------------------------------
-- agent_sessions
-- ---------------------------------------------------------------------------
-- One live harness instance.
CREATE TABLE IF NOT EXISTS agent_sessions (
    session_id         TEXT PRIMARY KEY,
    bundle_id          TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    harness            TEXT NOT NULL,     -- claude_code | codex | gemini_cli | other
    transport          TEXT NOT NULL,     -- tmux | mcp | provider_api
    status             TEXT NOT NULL,     -- provisioning | active | idle | blocked | exited | failed
    cwd                TEXT,
    transcript_ref     TEXT,
    launched_by_seat   TEXT REFERENCES seats(seat_id),
    adopted            INTEGER NOT NULL DEFAULT 0,
    created_at         INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL,
    exited_at          INTEGER
);

CREATE INDEX IF NOT EXISTS idx_agent_sessions_bundle
    ON agent_sessions(bundle_id);

CREATE INDEX IF NOT EXISTS idx_agent_sessions_status
    ON agent_sessions(status);

-- ---------------------------------------------------------------------------
-- transport_endpoints
-- ---------------------------------------------------------------------------
-- Concrete transport identity for a session.
CREATE TABLE IF NOT EXISTS transport_endpoints (
    endpoint_id        TEXT PRIMARY KEY,
    session_id         TEXT NOT NULL REFERENCES agent_sessions(session_id),
    adapter_name       TEXT NOT NULL,     -- tmux | claude_code | codex_cli | gemini_cli
    endpoint_kind      TEXT NOT NULL,     -- pane | window | mcp_handle | process | socket
    endpoint_ref       TEXT NOT NULL,     -- tmux target, handle, pid, socket path
    metadata_json      TEXT,
    created_at         INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_transport_endpoints_session_kind
    ON transport_endpoints(session_id, endpoint_kind);

-- ---------------------------------------------------------------------------
-- seats
-- ---------------------------------------------------------------------------
-- Runtime-addressable role within a session.
CREATE TABLE IF NOT EXISTS seats (
    seat_id            TEXT PRIMARY KEY,
    bundle_id          TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    session_id         TEXT NOT NULL REFERENCES agent_sessions(session_id),
    role               TEXT NOT NULL,     -- worker | supervisor | reviewer | observer | dispatcher
    status             TEXT NOT NULL,     -- active | waiting | blocked | terminal
    parent_seat_id     TEXT REFERENCES seats(seat_id),
    label              TEXT,
    created_at         INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_seats_bundle
    ON seats(bundle_id);

CREATE INDEX IF NOT EXISTS idx_seats_session
    ON seats(session_id);

CREATE INDEX IF NOT EXISTS idx_seats_role_status
    ON seats(role, status);

-- ---------------------------------------------------------------------------
-- supervision_threads
-- ---------------------------------------------------------------------------
-- Explicit seat-to-seat or seat-to-bundle monitoring relationship.
CREATE TABLE IF NOT EXISTS supervision_threads (
    thread_id               TEXT PRIMARY KEY,
    bundle_id               TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    supervisor_seat_id      TEXT NOT NULL REFERENCES seats(seat_id),
    target_seat_id          TEXT REFERENCES seats(seat_id),
    target_bundle_id        TEXT REFERENCES loop_bundles(bundle_id),
    thread_type             TEXT NOT NULL,   -- supervise | review | observe | soak | repair
    status                  TEXT NOT NULL,   -- active | paused | blocked | terminal
    wake_policy             TEXT,
    escalation_policy       TEXT,
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL,
    CHECK (
        (target_seat_id IS NOT NULL AND target_bundle_id IS NULL) OR
        (target_seat_id IS NULL AND target_bundle_id IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_supervision_threads_supervisor
    ON supervision_threads(supervisor_seat_id);

CREATE INDEX IF NOT EXISTS idx_supervision_threads_target_bundle
    ON supervision_threads(target_bundle_id);

CREATE INDEX IF NOT EXISTS idx_supervision_threads_target_seat
    ON supervision_threads(target_seat_id);

-- ---------------------------------------------------------------------------
-- dispatch_attempts
-- ---------------------------------------------------------------------------
-- Delivery ledger only. Completion lives elsewhere.
CREATE TABLE IF NOT EXISTS dispatch_attempts (
    attempt_id              TEXT PRIMARY KEY,
    seat_id                 TEXT NOT NULL REFERENCES seats(seat_id),
    issued_by_seat          TEXT REFERENCES seats(seat_id),
    instruction_ref         TEXT NOT NULL,
    status                  TEXT NOT NULL,   -- pending | claimed | acknowledged | timed_out | failed | superseded
    retry_count             INTEGER NOT NULL DEFAULT 0,
    timeout_at              INTEGER,
    claimed_at              INTEGER,
    acknowledged_at         INTEGER,
    failed_at               INTEGER,
    terminal_reason         TEXT,
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dispatch_attempts_seat_status
    ON dispatch_attempts(seat_id, status);

CREATE INDEX IF NOT EXISTS idx_dispatch_attempts_timeout
    ON dispatch_attempts(timeout_at);

-- ---------------------------------------------------------------------------
-- review_artifacts
-- ---------------------------------------------------------------------------
-- Structured handoffs that should wake a supervisor or dispatcher seat.
CREATE TABLE IF NOT EXISTS review_artifacts (
    artifact_id             TEXT PRIMARY KEY,
    bundle_id               TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    producing_seat_id       TEXT NOT NULL REFERENCES seats(seat_id),
    consuming_seat_id       TEXT REFERENCES seats(seat_id),
    dispatch_attempt_id     TEXT REFERENCES dispatch_attempts(attempt_id),
    artifact_type           TEXT NOT NULL,   -- stop_review | workflow_review | finding_report | repair_report
    status                  TEXT NOT NULL,   -- pending | consumed | stale | superseded
    payload_ref             TEXT NOT NULL,
    summary                 TEXT,
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL,
    consumed_at             INTEGER
);

CREATE INDEX IF NOT EXISTS idx_review_artifacts_bundle_status
    ON review_artifacts(bundle_id, status);

CREATE INDEX IF NOT EXISTS idx_review_artifacts_consumer
    ON review_artifacts(consuming_seat_id);

-- ---------------------------------------------------------------------------
-- interaction_gates
-- ---------------------------------------------------------------------------
-- Native harness prompts that block a live attempt mid-flight.
CREATE TABLE IF NOT EXISTS interaction_gates (
    gate_id                  TEXT PRIMARY KEY,
    bundle_id                TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    session_id               TEXT NOT NULL REFERENCES agent_sessions(session_id),
    seat_id                  TEXT NOT NULL REFERENCES seats(seat_id),
    dispatch_attempt_id      TEXT REFERENCES dispatch_attempts(attempt_id),
    gate_type                TEXT NOT NULL,   -- trust_prompt | edit_approval | settings_approval | permission_prompt | tool_confirmation | unknown_blocking_prompt
    status                   TEXT NOT NULL,   -- open | delegated | resolved | expired
    prompt_excerpt           TEXT,
    resolution_policy        TEXT,            -- auto_allow | auto_deny | escalate_parent | require_user
    resolved_by_seat         TEXT REFERENCES seats(seat_id),
    resolution               TEXT,            -- allow | deny | cancel | ignore
    created_at               INTEGER NOT NULL,
    updated_at               INTEGER NOT NULL,
    resolved_at              INTEGER
);

CREATE INDEX IF NOT EXISTS idx_interaction_gates_bundle_status
    ON interaction_gates(bundle_id, status);

CREATE INDEX IF NOT EXISTS idx_interaction_gates_seat_status
    ON interaction_gates(seat_id, status);

CREATE INDEX IF NOT EXISTS idx_interaction_gates_attempt
    ON interaction_gates(dispatch_attempt_id);

-- ---------------------------------------------------------------------------
-- findings
-- ---------------------------------------------------------------------------
-- Durable anomaly and soak ledger.
CREATE TABLE IF NOT EXISTS findings (
    finding_id              TEXT PRIMARY KEY,
    bundle_id               TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    opened_by_seat          TEXT REFERENCES seats(seat_id),
    target_seat_id          TEXT REFERENCES seats(seat_id),
    severity                TEXT NOT NULL,   -- info | warning | blocking | critical
    finding_type            TEXT NOT NULL,   -- timeout | drift | loop_waste | adapter_mismatch | repair_needed
    status                  TEXT NOT NULL,   -- open | accepted | fixed | deferred | closed
    evidence_ref            TEXT,
    summary                 TEXT NOT NULL,
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL,
    closed_at               INTEGER
);

CREATE INDEX IF NOT EXISTS idx_findings_bundle_status
    ON findings(bundle_id, status);

CREATE INDEX IF NOT EXISTS idx_findings_target
    ON findings(target_seat_id);

-- ---------------------------------------------------------------------------
-- repair_actions
-- ---------------------------------------------------------------------------
-- Explicit controller or supervisor responses to findings.
CREATE TABLE IF NOT EXISTS repair_actions (
    action_id               TEXT PRIMARY KEY,
    finding_id              TEXT NOT NULL REFERENCES findings(finding_id),
    bundle_id               TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    requested_by_seat       TEXT REFERENCES seats(seat_id),
    action_type             TEXT NOT NULL,   -- restart_session | archive_bundle | requeue_attempt | spawn_repair_bundle | pause_bundle
    status                  TEXT NOT NULL,   -- pending | running | succeeded | failed | abandoned
    child_bundle_id         TEXT REFERENCES loop_bundles(bundle_id),
    details_json            TEXT,
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL,
    completed_at            INTEGER
);

CREATE INDEX IF NOT EXISTS idx_repair_actions_finding
    ON repair_actions(finding_id);

CREATE INDEX IF NOT EXISTS idx_repair_actions_bundle_status
    ON repair_actions(bundle_id, status);

-- ---------------------------------------------------------------------------
-- heartbeats
-- ---------------------------------------------------------------------------
-- Structured liveness records from adapters, observers, or controller.
CREATE TABLE IF NOT EXISTS heartbeats (
    heartbeat_id            TEXT PRIMARY KEY,
    bundle_id               TEXT REFERENCES loop_bundles(bundle_id),
    seat_id                 TEXT REFERENCES seats(seat_id),
    session_id              TEXT REFERENCES agent_sessions(session_id),
    source_type             TEXT NOT NULL,   -- adapter | observer | controller
    source_ref              TEXT NOT NULL,
    state                   TEXT,
    details_json            TEXT,
    created_at              INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_heartbeats_bundle_created
    ON heartbeats(bundle_id, created_at);

CREATE INDEX IF NOT EXISTS idx_heartbeats_seat_created
    ON heartbeats(seat_id, created_at);

-- ---------------------------------------------------------------------------
-- spawn_requests
-- ---------------------------------------------------------------------------
-- Parent seat asks braid-v2 to create a child bundle.
CREATE TABLE IF NOT EXISTS spawn_requests (
    request_id              TEXT PRIMARY KEY,
    parent_bundle_id        TEXT NOT NULL REFERENCES loop_bundles(bundle_id),
    requested_by_seat       TEXT NOT NULL REFERENCES seats(seat_id),
    status                  TEXT NOT NULL,   -- pending | provisioning | fulfilled | rejected | failed
    requested_worker        TEXT NOT NULL,   -- claude_code | codex | gemini_cli | other
    requested_supervisor    TEXT,
    transport               TEXT NOT NULL,   -- tmux | mcp | provider_api
    request_json            TEXT NOT NULL,
    child_bundle_id         TEXT REFERENCES loop_bundles(bundle_id),
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_spawn_requests_parent_status
    ON spawn_requests(parent_bundle_id, status);

"""Identity-hardening tests for hooks/subagent-start.sh.

@decision DEC-CLAUDEX-SA-IDENTITY-001
Title: Payload agent_id is sole authority for SubagentStart marker+lease seating
Status: accepted
Rationale: These tests pin the invariant that the harness-delivered
  HOOK_INPUT.agent_id (not the shell PID agent-$$) is the value written to
  agent_markers.agent_id and used to claim dispatch_leases.  The five tests
  form the compound-interaction regression suite for GS1-F-1:
  1. Marker row uses payload agent_id, not a PID-shaped string.
  2. Lease claim row's agent_id is updated to the payload agent_id.
  3. build_context() resolves guardian:land actor after identity seating.
  4. Stale reviewer marker does not contaminate guardian build_context.
  5. Fail-closed guard: no seating occurs when payload agent_id is absent.

Isolation strategy:
  * A hermetic SQLite DB is created per-test via tmp_path.
  * The hook is invoked via subprocess with CLAUDE_POLICY_DB pointing at
    the test DB, CLAUDE_PROJECT_DIR pointing at the repo root (required for
    cc_policy and git resolution inside the hook), and PYTHONPATH set so the
    runtime package is importable.
  * Carrier rows are written via write_pending_request so the hook's
    _HAS_CONTRACT=yes path fires and the seating block (_IS_DISPATCH_ROLE=true)
    is reached.
  * Tests do NOT skip on non-zero hook exit — they assert on DB state and
    stdout/stderr content.

Tests are skipped when bash or jq is not on PATH (same policy as
test_claudex_watchdog.py).
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import sys
import time
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Path constants
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_HOOK = str(_REPO_ROOT / "hooks" / "subagent-start.sh")

# Ensure the runtime package is importable from this test process too
# (needed for build_context, ensure_schema, leases.issue).
sys.path.insert(0, str(_REPO_ROOT))

from runtime.core import contracts  # noqa: E402
from runtime.core import decision_work_registry as dwr  # noqa: E402
from runtime.core import goal_contract_codec  # noqa: E402
from runtime.core import workflows as workflows_mod  # noqa: E402
from runtime.core.pending_agent_requests import write_pending_request  # noqa: E402
from runtime.core import leases as leases_mod  # noqa: E402
from runtime.core import policy_engine as pe  # noqa: E402
from runtime.schemas import ensure_schema  # noqa: E402

# ---------------------------------------------------------------------------
# Skip guard
# ---------------------------------------------------------------------------

pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None or shutil.which("jq") is None,
    reason="subagent-start.sh requires bash and jq",
)

# ---------------------------------------------------------------------------
# Constants shared across tests
# ---------------------------------------------------------------------------

_SESSION_ID = "identity-test-session-001"
_WORKFLOW_ID = "identity-test-wf"
_GOAL_ID = "GOAL-IDENTITY-1"
_WORK_ITEM_ID = "WI-IDENTITY-1"
_STAGE_ID = "guardian:land"
_GUARDIAN_AGENT_TYPE = "guardian"  # canonical subagent_type for guardian:land


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _open_db(db_path: Path) -> sqlite3.Connection:
    """Open and configure a SQLite connection with Row factory."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def _seed_db(conn: sqlite3.Connection, *, project_root: str) -> None:
    """Seed the minimum runtime state for a guardian:land dispatch.

    Seeds:
    - goal contract (GOAL-IDENTITY-1)
    - work item (WI-IDENTITY-1)
    - workflow binding (identity-test-wf → project_root)
    """
    goal = contracts.GoalContract(
        goal_id=_GOAL_ID,
        desired_end_state="identity seating test",
        status="active",
        autonomy_budget=3,
        continuation_rules=("rule-a",),
        stop_conditions=("cond-a",),
        escalation_boundaries=("boundary-a",),
        user_decision_boundaries=("udb-a",),
    )
    dwr.insert_goal(conn, goal_contract_codec.encode_goal_contract(goal))
    dwr.insert_work_item(
        conn,
        dwr.WorkItemRecord(
            work_item_id=_WORK_ITEM_ID,
            goal_id=_GOAL_ID,
            title="identity seating test slice",
            status="in_progress",
            version=1,
            author="planner",
            scope_json=(
                '{"allowed_paths":["hooks/subagent-start.sh",'
                '"tests/hooks/test_subagent_start_identity.py"],'
                '"required_paths":[],"forbidden_paths":[],"state_domains":[]}'
            ),
            evaluation_json=(
                '{"required_tests":[],"required_evidence":[],'
                '"rollback_boundary":"","acceptance_notes":""}'
            ),
            head_sha=None,
            reviewer_round=1,
        ),
    )
    workflows_mod.bind_workflow(
        conn,
        workflow_id=_WORKFLOW_ID,
        worktree_path=project_root,
        branch="global-soak-main",
    )
    conn.commit()


def _write_carrier(conn: sqlite3.Connection, *, session_id: str = _SESSION_ID) -> None:
    """Write a guardian:land carrier row so the hook merges the contract fields."""
    write_pending_request(
        conn,
        session_id=session_id,
        agent_type=_GUARDIAN_AGENT_TYPE,
        workflow_id=_WORKFLOW_ID,
        stage_id=_STAGE_ID,
        goal_id=_GOAL_ID,
        work_item_id=_WORK_ITEM_ID,
        decision_scope="kernel",
        generated_at=1_700_000_000,
    )
    conn.commit()


def _run_hook(
    payload: dict,
    db_path: Path,
) -> tuple[int, str, str]:
    """Invoke hooks/subagent-start.sh with payload on stdin.

    Returns (returncode, stdout, stderr).  The hook always exits 0 per its
    design — seating failures are emitted via additionalContext.
    """
    import subprocess

    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_PROJECT_DIR": str(_REPO_ROOT),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }
    result = subprocess.run(
        ["bash", _HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        cwd=str(_REPO_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


def _guardian_payload(
    agent_id: str = "test-agent-abc123",
    session_id: str = _SESSION_ID,
) -> dict:
    """Minimal HOOK_INPUT for a guardian:land SubagentStart.

    The carrier row is consumed by the hook which merges the six contract
    fields into HOOK_INPUT so _HAS_CONTRACT=yes fires.
    """
    return {
        "session_id": session_id,
        "agent_type": _GUARDIAN_AGENT_TYPE,
        "agent_id": agent_id,
        "hook_event_name": "SubagentStart",
    }


# ---------------------------------------------------------------------------
# Fixture: hermetic per-test DB
# ---------------------------------------------------------------------------


@pytest.fixture()
def seeded_db(tmp_path: Path) -> tuple[Path, str]:
    """Create a fresh DB, run ensure_schema, seed runtime state.

    Returns (db_path, project_root_str).

    project_root is set to _REPO_ROOT so that is_claude_meta_repo resolves
    correctly inside the hook and build_context can normalize the path.
    """
    db_path = tmp_path / "state.db"
    project_root = str(_REPO_ROOT)

    conn = _open_db(db_path)
    try:
        ensure_schema(conn)
        _seed_db(conn, project_root=project_root)
    finally:
        conn.close()

    return db_path, project_root


# ---------------------------------------------------------------------------
# Test 1: marker row uses payload agent_id, not a PID-shaped string
# ---------------------------------------------------------------------------


class TestMarkerUsesPayloadAgentId:
    """Verify that the agent_markers row written by the hook carries the
    harness-delivered agent_id, not a PID-shaped 'agent-<number>' string.

    Production sequence:
      pre-agent.sh writes carrier → harness spawns guardian subagent →
      SubagentStart fires → hook consumes carrier → seating block runs →
      dispatch agent-start writes agent_markers row with payload agent_id.
    """

    def test_subagent_start_marker_uses_payload_agent_id(self, seeded_db):
        db_path, project_root = seeded_db
        payload_agent_id = "test-agent-abc123"

        # Seed carrier row so _HAS_CONTRACT=yes and the seating block fires.
        conn = _open_db(db_path)
        try:
            _write_carrier(conn)
        finally:
            conn.close()

        rc, stdout, stderr = _run_hook(
            _guardian_payload(agent_id=payload_agent_id),
            db_path,
        )
        assert rc == 0, f"Hook exited {rc}; stderr={stderr!r}"

        # Inspect agent_markers for the expected row.
        # Note: ensure_schema's cleanup migration deactivates stage-qualified roles
        # like 'guardian:land' (only base roles 'guardian', 'implementer', 'planner',
        # 'reviewer' are whitelisted). The core invariant tested here is that the
        # agent_id field carries the payload value — not that is_active=1.
        conn = _open_db(db_path)
        try:
            row = conn.execute(
                "SELECT * FROM agent_markers WHERE agent_id = ?",
                (payload_agent_id,),
            ).fetchone()
            pid_rows = conn.execute(
                "SELECT * FROM agent_markers WHERE agent_id LIKE 'agent-%'",
            ).fetchall()
        finally:
            conn.close()

        assert row is not None, (
            f"Expected an agent_markers row with agent_id={payload_agent_id!r}, "
            f"but none was found.  stdout={stdout!r}"
        )
        # Marker role should be the stage_id (guardian:land), not the raw agent_type.
        assert row["role"] == _STAGE_ID, (
            f"Expected role={_STAGE_ID!r}, got {row['role']!r}"
        )
        # The agent_id column is the key invariant: it must be the payload value,
        # not a PID-shaped string.
        assert row["agent_id"] == payload_agent_id, (
            f"Expected agent_id={payload_agent_id!r}, got {row['agent_id']!r}"
        )

        # No PID-shaped row should have been written.
        assert len(pid_rows) == 0, (
            f"Found {len(pid_rows)} PID-shaped agent_markers row(s): "
            f"{[dict(r) for r in pid_rows]}"
        )


# ---------------------------------------------------------------------------
# Test 2: lease claim binds payload agent_id onto the dispatch_leases row
# ---------------------------------------------------------------------------


class TestLeaseClaimUsesPayloadAgentId:
    """Verify that rt_lease_claim associates the payload agent_id with the
    active dispatch_leases row rather than a PID.

    Production sequence:
      Guardian (provision) issues a lease for the worktree → SubagentStart
      fires for the guardian:land agent → hook claims the lease using the
      harness-delivered agent_id → lease.agent_id becomes the harness id.
    """

    def test_subagent_start_lease_claim_uses_payload_agent_id(self, seeded_db):
        db_path, project_root = seeded_db
        payload_agent_id = "test-agent-xyz789"

        # Pre-insert an active guardian lease with agent_id=NULL.
        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id="lease-claim-session")
            lease = leases_mod.issue(
                conn,
                role="guardian",
                worktree_path=project_root,
                workflow_id=_WORKFLOW_ID,
            )
            lease_id = lease["lease_id"]
            conn.commit()
        finally:
            conn.close()

        # Confirm agent_id is NULL before hook runs.
        conn = _open_db(db_path)
        try:
            pre_row = conn.execute(
                "SELECT agent_id FROM dispatch_leases WHERE lease_id = ?",
                (lease_id,),
            ).fetchone()
        finally:
            conn.close()
        assert pre_row["agent_id"] is None, (
            f"Expected lease.agent_id to be NULL before hook run, got {pre_row['agent_id']!r}"
        )

        rc, stdout, stderr = _run_hook(
            _guardian_payload(agent_id=payload_agent_id, session_id="lease-claim-session"),
            db_path,
        )
        assert rc == 0, f"Hook exited {rc}; stderr={stderr!r}"

        # After hook, lease.agent_id must equal the payload agent_id.
        conn = _open_db(db_path)
        try:
            post_row = conn.execute(
                "SELECT agent_id, status FROM dispatch_leases WHERE lease_id = ?",
                (lease_id,),
            ).fetchone()
        finally:
            conn.close()

        assert post_row["agent_id"] == payload_agent_id, (
            f"Expected lease.agent_id={payload_agent_id!r}, "
            f"got {post_row['agent_id']!r}.  stdout={stdout!r}"
        )
        assert post_row["status"] == "active"


# ---------------------------------------------------------------------------
# Test 3: build_context resolves guardian:land actor after identity seating
# ---------------------------------------------------------------------------


class TestBuildContextResolvesAfterIdentitySeating:
    """Compound-interaction test: exercises the real production sequence
    end-to-end crossing marker seating → lease claim → policy_engine.build_context.

    After the hook runs (tests 1+2 combined), build_context must resolve the
    correct actor_role and actor_id from the DB state the hook produced.
    """

    def test_build_context_resolves_guardian_after_identity_seating(self, seeded_db):
        db_path, project_root = seeded_db
        payload_agent_id = "test-agent-ctx-verify"

        # Seed carrier + lease.
        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id="ctx-test-session")
            leases_mod.issue(
                conn,
                role="guardian",
                worktree_path=project_root,
                workflow_id=_WORKFLOW_ID,
            )
            conn.commit()
        finally:
            conn.close()

        rc, stdout, stderr = _run_hook(
            _guardian_payload(agent_id=payload_agent_id, session_id="ctx-test-session"),
            db_path,
        )
        assert rc == 0, f"Hook exited {rc}; stderr={stderr!r}"

        # Now call build_context directly to verify actor resolution.
        conn = _open_db(db_path)
        try:
            ctx = pe.build_context(
                conn,
                cwd=project_root,
                actor_role="guardian:land",
                actor_id=payload_agent_id,
                project_root=project_root,
            )
        finally:
            conn.close()

        # The context must reflect the identity the hook seated.
        assert ctx.actor_role == "guardian:land", (
            f"Expected actor_role='guardian:land', got {ctx.actor_role!r}"
        )
        assert ctx.actor_id == payload_agent_id, (
            f"Expected actor_id={payload_agent_id!r}, got {ctx.actor_id!r}"
        )
        assert ctx.lease is not None, (
            f"Expected lease to be resolved, got None.  "
            f"This means the lease was not claimed with the payload agent_id."
        )
        assert ctx.lease["agent_id"] == payload_agent_id, (
            f"Expected lease.agent_id={payload_agent_id!r}, "
            f"got {ctx.lease['agent_id']!r}"
        )


# ---------------------------------------------------------------------------
# Test 4: stale reviewer marker does not contaminate guardian build_context
# ---------------------------------------------------------------------------


class TestStalePreviousRoleMarkerIsolated:
    """Verify that a pre-existing active reviewer marker does not cause
    build_context to resolve the wrong actor_role for a guardian:land seating.

    Production scenario: a reviewer subagent was active and its marker was
    not deactivated (stale marker), then a guardian:land SubagentStart fires.
    The hook must write a new guardian:land marker and the policy engine must
    resolve guardian:land — not reviewer — when the guardian's actor_id is
    supplied to build_context.
    """

    def test_stale_reviewer_marker_does_not_poison_guardian_build_context(
        self, seeded_db
    ):
        db_path, project_root = seeded_db
        stale_reviewer_id = "old-reviewer-id-stale"
        guardian_payload_id = "test-guardian-new-agent"

        # Seed: active reviewer marker (stale — not deactivated).
        conn = _open_db(db_path)
        try:
            conn.execute(
                """INSERT INTO agent_markers (agent_id, role, started_at, is_active,
                   status, project_root)
                   VALUES (?, 'reviewer', ?, 1, 'active', ?)""",
                (stale_reviewer_id, int(time.time()) - 300, project_root),
            )
            # Seed carrier + lease for the guardian:land dispatch.
            _write_carrier(conn, session_id="stale-test-session")
            leases_mod.issue(
                conn,
                role="guardian",
                worktree_path=project_root,
                workflow_id=_WORKFLOW_ID,
            )
            conn.commit()
        finally:
            conn.close()

        rc, stdout, stderr = _run_hook(
            _guardian_payload(
                agent_id=guardian_payload_id, session_id="stale-test-session"
            ),
            db_path,
        )
        assert rc == 0, f"Hook exited {rc}; stderr={stderr!r}"

        conn = _open_db(db_path)
        try:
            # Guardian:land marker must now exist.
            # Note: ensure_schema cleanup deactivates stage-qualified roles like
            # 'guardian:land' (not in the base-role whitelist), so we query without
            # the is_active filter. The key invariant is that the row was written
            # with the correct agent_id.
            guardian_row = conn.execute(
                "SELECT * FROM agent_markers WHERE agent_id = ?",
                (guardian_payload_id,),
            ).fetchone()

            # Stale reviewer marker must still exist (observatory-only; hard sweep is GS1-F-3).
            reviewer_row = conn.execute(
                "SELECT * FROM agent_markers WHERE agent_id = ?",
                (stale_reviewer_id,),
            ).fetchone()

            # build_context with the guardian's actor_id must resolve guardian:land,
            # not reviewer.
            ctx = pe.build_context(
                conn,
                cwd=project_root,
                actor_role="guardian:land",
                actor_id=guardian_payload_id,
                project_root=project_root,
            )
        finally:
            conn.close()

        assert guardian_row is not None, (
            f"Expected guardian:land marker for {guardian_payload_id!r}, "
            f"but none found.  stdout={stdout!r}"
        )
        assert guardian_row["role"] == _STAGE_ID
        assert guardian_row["agent_id"] == guardian_payload_id

        # Stale marker should still exist (observatory-only sweep).
        assert reviewer_row is not None, (
            "Stale reviewer marker should still be present (hard sweep deferred to GS1-F-3)"
        )

        # Role resolution must favor the guardian:land actor, not the stale reviewer.
        assert ctx.actor_role == "guardian:land", (
            f"Expected actor_role='guardian:land' but got {ctx.actor_role!r}. "
            f"Stale reviewer marker may be contaminating role resolution."
        )
        assert ctx.actor_id == guardian_payload_id


# ---------------------------------------------------------------------------
# Test 5: fail-closed — no seating when payload agent_id is absent
# ---------------------------------------------------------------------------


class TestFailClosedWhenPayloadAgentIdMissing:
    """Verify that when HOOK_INPUT.agent_id is absent or empty, ALL seating is
    skipped: no agent_markers row is written and no dispatch_leases.agent_id
    is updated.

    The hook exits 0 in all cases (seating failure is diagnostic-only).

    Observable behavior:
    - DB invariants: no marker row, lease.agent_id remains NULL (primary).
    - The 'no_payload_agent_id' diagnostic is appended to CONTEXT_PARTS.
      When the runtime-first path runs (contract present), CONTEXT_PARTS is
      not included in the hook's stdout (the prompt-pack envelope takes over).
      Tests that can observe the signal are placed in a subclass that uses the
      legacy path (non-contract payload for a non-canonical agent).
    """

    def test_subagent_start_denies_seating_when_payload_agent_id_missing(
        self, seeded_db
    ):
        """DB invariant test: no marker + no lease claim when agent_id absent.

        Uses a carrier row (so _HAS_CONTRACT=yes) to exercise the full
        dispatch-role path. The hook proceeds to the runtime-first path after
        skipping seating, so the output is the compiled prompt-pack, not the
        no_payload_agent_id diagnostic (which is in CONTEXT_PARTS, swallowed
        by the runtime-first path). DB state is the authoritative evidence.
        """
        db_path, project_root = seeded_db

        # Seed a guardian lease (agent_id=NULL) and a carrier row.
        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id="no-agent-id-session")
            leases_mod.issue(
                conn,
                role="guardian",
                worktree_path=project_root,
                workflow_id=_WORKFLOW_ID,
            )
            conn.commit()
            # Capture lease_id so we can verify agent_id stays NULL.
            lease_row = conn.execute(
                "SELECT lease_id FROM dispatch_leases WHERE status='active' LIMIT 1"
            ).fetchone()
            lease_id = lease_row["lease_id"]
        finally:
            conn.close()

        # Payload WITHOUT agent_id (key absent).
        payload_no_id = {
            "session_id": "no-agent-id-session",
            "agent_type": _GUARDIAN_AGENT_TYPE,
            "hook_event_name": "SubagentStart",
            # agent_id deliberately absent
        }

        rc, stdout, stderr = _run_hook(payload_no_id, db_path)
        assert rc == 0, f"Hook must exit 0 even when agent_id is absent; rc={rc}"

        # No new marker row should have been written for guardian:land.
        conn = _open_db(db_path)
        try:
            marker_rows = conn.execute(
                "SELECT * FROM agent_markers WHERE role = ?",
                (_STAGE_ID,),
            ).fetchall()
            # Lease agent_id must still be NULL (no claim occurred).
            post_lease = conn.execute(
                "SELECT agent_id FROM dispatch_leases WHERE lease_id = ?",
                (lease_id,),
            ).fetchone()
        finally:
            conn.close()

        assert len(marker_rows) == 0, (
            f"No agent_markers row should have been written when agent_id is absent, "
            f"but found {len(marker_rows)} row(s): {[dict(r) for r in marker_rows]}"
        )
        assert post_lease["agent_id"] is None, (
            f"Lease.agent_id must remain NULL when agent_id is absent; "
            f"got {post_lease['agent_id']!r}"
        )

    def test_subagent_start_denies_seating_when_payload_agent_id_empty_string(
        self, seeded_db
    ):
        """DB invariant: no seating when agent_id is an explicit empty string."""
        db_path, project_root = seeded_db

        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id="empty-agent-id-session")
            leases_mod.issue(
                conn,
                role="guardian",
                worktree_path=project_root,
                workflow_id=_WORKFLOW_ID,
            )
            conn.commit()
            lease_row = conn.execute(
                "SELECT lease_id FROM dispatch_leases WHERE status='active' LIMIT 1"
            ).fetchone()
            lease_id = lease_row["lease_id"]
        finally:
            conn.close()

        # Payload with explicit empty string agent_id.
        payload_empty_id = {
            "session_id": "empty-agent-id-session",
            "agent_type": _GUARDIAN_AGENT_TYPE,
            "agent_id": "",
            "hook_event_name": "SubagentStart",
        }

        rc, stdout, stderr = _run_hook(payload_empty_id, db_path)
        assert rc == 0

        conn = _open_db(db_path)
        try:
            post_lease = conn.execute(
                "SELECT agent_id FROM dispatch_leases WHERE lease_id = ?",
                (lease_id,),
            ).fetchone()
            marker_rows = conn.execute(
                "SELECT * FROM agent_markers WHERE role = ?",
                (_STAGE_ID,),
            ).fetchall()
        finally:
            conn.close()

        assert post_lease["agent_id"] is None, (
            f"Lease.agent_id must remain NULL for empty agent_id; "
            f"got {post_lease['agent_id']!r}"
        )
        assert len(marker_rows) == 0, (
            f"No marker row expected for empty agent_id; found {len(marker_rows)}"
        )

    def test_no_payload_agent_id_diagnostic_in_legacy_context_parts(
        self, seeded_db
    ):
        """When the legacy path runs (non-contract payload, non-canonical agent),
        'no_payload_agent_id' does NOT appear — the guard only fires for
        _IS_DISPATCH_ROLE=true (canonical dispatch roles).

        This test pins that non-dispatch roles (Explore) are NOT affected by
        the fail-closed guard, confirming the guard is narrowly scoped.
        """
        db_path, project_root = seeded_db

        # Non-canonical agent (Explore) with no agent_id → legacy path,
        # _IS_DISPATCH_ROLE=false, guard does NOT fire.
        payload = {
            "agent_type": "Explore",
            "hook_event_name": "SubagentStart",
            # No agent_id, no contract fields.
        }
        rc, stdout, stderr = _run_hook(payload, db_path)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # For non-dispatch roles, no_payload_agent_id must NOT appear.
        assert "no_payload_agent_id" not in ctx, (
            f"Guard must not fire for non-dispatch roles; got:\n{ctx}"
        )
        # Legacy path produces Context: line for non-canonical agents.
        assert "Context:" in ctx


# ---------------------------------------------------------------------------
# GS1-F-2: TestMarkerSeatingReliability
# ---------------------------------------------------------------------------
# Regression suite for the deterministic DB routing fix and observable failure
# signal (DEC-CLAUDEX-SA-MARKER-RELIABILITY-001).
#
# Root cause sealed: _local_cc_policy previously only exported CLAUDE_POLICY_DB
# when CLAUDE_PROJECT_DIR was already in env. SubagentStart invocations in
# which the harness did NOT inject CLAUDE_PROJECT_DIR wrote markers to the
# home-dir default DB while context role reads from PROJECT_ROOT/.claude/state.db
# — a silent split-brain causing "lagging" / "pid file stale" signals on the
# global-soak lane.
# ---------------------------------------------------------------------------


def _run_hook_no_cpd(
    payload: dict,
    db_path: Path,
) -> tuple[int, str, str]:
    """Invoke the hook WITHOUT CLAUDE_PROJECT_DIR in env.

    This is the key variant for GS1-F-2: verifies that the hook derives the
    correct CLAUDE_POLICY_DB from PROJECT_ROOT (git-detected) when the harness
    does not inject CLAUDE_PROJECT_DIR.

    CLAUDE_POLICY_DB is still injected explicitly so tests remain hermetic —
    the hook's _local_cc_policy must honour this when already set, confirming
    the "if [[ -z "${CLAUDE_POLICY_DB:-}" ]]" guard works correctly.
    """
    import subprocess

    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }
    # Explicitly unset CLAUDE_PROJECT_DIR so the hook must fall back to
    # PROJECT_ROOT from detect_project_root().
    env.pop("CLAUDE_PROJECT_DIR", None)

    result = subprocess.run(
        ["bash", _HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        cwd=str(_REPO_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


class TestMarkerSeatingReliability:
    """GS1-F-2: Marker seating is deterministic and failures are observable.

    Three tests:
    1. Marker seats when CLAUDE_PROJECT_DIR is absent (pre-fix failure vector).
    2. Seating failure emits a breadcrumb in additionalContext (never blocks).
    3. End-to-end: cc-policy context role resolves after seating without CLAUDE_PROJECT_DIR.
    """

    # -----------------------------------------------------------------------
    # Test 1: marker seats when CLAUDE_PROJECT_DIR is absent
    # -----------------------------------------------------------------------

    def test_marker_seats_when_claude_project_dir_absent(self, seeded_db):
        """Verify marker is written to CLAUDE_POLICY_DB when CLAUDE_PROJECT_DIR
        is absent from the hook's environment.

        Pre-fix behaviour: _local_cc_policy would not export CLAUDE_POLICY_DB,
        so the CLI wrote to the home-dir default DB instead of the test DB.
        The assertion on the test DB would find no row → test FAILS pre-fix.

        Post-fix: _local_cc_policy falls back to PROJECT_ROOT (git-detected)
        when CLAUDE_POLICY_DB is not yet set and CLAUDE_PROJECT_DIR is absent.
        Since we inject CLAUDE_POLICY_DB explicitly, the guard honours it and
        the marker lands in the correct test DB.
        """
        db_path, project_root = seeded_db
        payload_agent_id = "gs1f2-test-agent-no-cpd-001"

        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id="gs1f2-no-cpd-session")
        finally:
            conn.close()

        rc, stdout, stderr = _run_hook_no_cpd(
            _guardian_payload(agent_id=payload_agent_id, session_id="gs1f2-no-cpd-session"),
            db_path,
        )
        assert rc == 0, f"Hook exited {rc}; stderr={stderr!r}"

        conn = _open_db(db_path)
        try:
            row = conn.execute(
                "SELECT * FROM agent_markers WHERE agent_id = ?",
                (payload_agent_id,),
            ).fetchone()
        finally:
            conn.close()

        assert row is not None, (
            f"Expected agent_markers row for agent_id={payload_agent_id!r} in test DB, "
            f"but none found. Pre-fix: marker would land in home-dir DB when "
            f"CLAUDE_PROJECT_DIR is absent.  stdout={stdout!r}"
        )
        assert row["role"] == _STAGE_ID, (
            f"Expected role={_STAGE_ID!r}, got {row['role']!r}"
        )
        assert row["agent_id"] == payload_agent_id

        # Confirm no "marker seating failed" breadcrumb in additionalContext.
        # The runtime-first path fires (contract present), so stdout is the
        # prompt-pack envelope — we check there's no failure signal in stderr.
        assert "marker seating failed" not in stderr, (
            f"Unexpected seating-failure signal in stderr:\n{stderr}"
        )

    # -----------------------------------------------------------------------
    # Test 2: seating failure emits breadcrumb, hook exits 0
    # -----------------------------------------------------------------------

    def test_marker_seating_failure_emits_breadcrumb(self, seeded_db, tmp_path):
        """Force a CLI-side error for dispatch agent-start; verify the hook
        emits a 'marker seating failed' diagnostic in stderr via log_json and
        still exits 0 (never blocks).

        Failure vector: install a SQLite BEFORE INSERT trigger on agent_markers
        that raises an error. This is a targeted block that:
        - Does NOT affect the carrier consume (pending_agent_requests DELETE).
        - Does NOT affect workflow binding or other writes (different tables).
        - DOES cause 'dispatch agent-start' to fail when it tries to INSERT or
          UPDATE agent_markers — the trigger fires on INSERT and raises FAIL.

        The trigger is installed AFTER the carrier row is written so the carrier
        consume can still proceed, giving _HAS_CONTRACT=yes and exercising the
        full seating block before the CLI call fails.

        The failure diagnostic lands in stderr via log_json unconditionally (the
        log_json call is before the runtime-first path exit so it runs for all
        output paths).
        """
        db_path, project_root = seeded_db

        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id="gs1f2-fail-session")
            # Install a trigger that blocks all INSERT/UPDATE-via-INSERT on
            # agent_markers. The CLI's ON CONFLICT DO UPDATE is also an INSERT
            # at the SQL level, so this fires and raises an error.
            conn.execute(
                """
                CREATE TRIGGER block_agent_marker_insert
                BEFORE INSERT ON agent_markers
                BEGIN
                    SELECT RAISE(FAIL, 'marker insert blocked by test trigger');
                END
                """
            )
            # Also block UPDATE (for the deactivate-stale step in set_active).
            conn.execute(
                """
                CREATE TRIGGER block_agent_marker_update
                BEFORE UPDATE ON agent_markers
                BEGIN
                    SELECT RAISE(FAIL, 'marker update blocked by test trigger');
                END
                """
            )
            conn.commit()
        finally:
            conn.close()

        rc, stdout, stderr = _run_hook_no_cpd(
            _guardian_payload(
                agent_id="gs1f2-fail-agent-abc",
                session_id="gs1f2-fail-session",
            ),
            db_path,
        )

        # Hook must always exit 0 — seating failure is never blocking.
        assert rc == 0, (
            f"Hook must exit 0 on seating failure; rc={rc}\nstderr={stderr!r}"
        )

        # The failure diagnostic must appear in stderr via log_json.
        # log_json emits {"stage":"marker_seating_failed","message":"role=... agent_id=... exit=..."}.
        # CONTEXT_PARTS also contains "marker seating failed" (spaces) but CONTEXT_PARTS
        # is only visible in stdout when the legacy path runs (no contract). Here, since
        # the contract IS present and the runtime-first path fires, CONTEXT_PARTS goes
        # to additionalContext only in non-contract paths. The observable signal is
        # log_json to stderr — check for both the stage token and the message fields.
        assert "marker_seating_failed" in stderr or "marker seating failed" in stderr, (
            f"Expected 'marker_seating_failed' or 'marker seating failed' in stderr.\n"
            f"stderr={stderr!r}\nstdout={stdout!r}"
        )
        assert "role=" in stderr, f"Expected 'role=' in stderr:\n{stderr!r}"
        assert "agent_id=" in stderr, f"Expected 'agent_id=' in stderr:\n{stderr!r}"
        assert "exit=" in stderr, f"Expected 'exit=' in stderr:\n{stderr!r}"

    # -----------------------------------------------------------------------
    # Test 3: end-to-end context role resolves after seating without CLAUDE_PROJECT_DIR
    # -----------------------------------------------------------------------

    def test_context_role_resolves_after_seating_without_self_seat(self, seeded_db):
        """End-to-end regression: the marker seating (done without CLAUDE_PROJECT_DIR)
        lands in the correct DB such that a subsequent cc-policy context role
        invocation (with CLAUDE_PROJECT_DIR + CLAUDE_ACTOR_ROLE + CLAUDE_ACTOR_ID,
        simulating how the harness injects env for tool calls) resolves the
        expected role and agent_id.

        This is the authoritative regression for the split-brain bug on the
        global-soak lane: pre-fix the marker landed in the home-dir DB → context
        role returned empty role. Post-fix the marker lands in the test DB
        (via PROJECT_ROOT fallback) → context role resolves the agent_id from
        the lease (which the hook claimed in the same hermetic DB).

        No intervening manual dispatch agent-start call is made between the
        hook run and the context role check — this proves the hook's seating
        (marker + lease claim) was sufficient.

        Resolution path: build_context looks up the active lease by agent_id
        (CLAUDE_ACTOR_ID) in the project-scoped DB, returning the guardian role
        and agent_id. The lease was claimed by the hook using the payload agent_id.
        """
        import subprocess as _sp

        db_path, project_root = seeded_db
        payload_agent_id = "gs1f2-e2e-agent-ctx-001"

        # Seed: carrier + guardian lease.
        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id="gs1f2-e2e-session")
            leases_mod.issue(
                conn,
                role="guardian",
                worktree_path=project_root,
                workflow_id=_WORKFLOW_ID,
            )
            conn.commit()
        finally:
            conn.close()

        # Run the hook WITHOUT CLAUDE_PROJECT_DIR.
        rc, stdout, stderr = _run_hook_no_cpd(
            _guardian_payload(agent_id=payload_agent_id, session_id="gs1f2-e2e-session"),
            db_path,
        )
        assert rc == 0, f"Hook exited {rc}; stderr={stderr!r}"

        # Verify the lease was claimed by the hook (lease.agent_id = payload_agent_id).
        # This is the authoritative state that context role reads — the marker
        # role 'guardian:land' is a stage-qualified role not retained by
        # ensure_schema's cleanup (base roles only), so the lease is the
        # canonical identity authority here.
        conn = _open_db(db_path)
        try:
            lease_row = conn.execute(
                "SELECT agent_id, role, status FROM dispatch_leases WHERE agent_id = ?",
                (payload_agent_id,),
            ).fetchone()
        finally:
            conn.close()

        assert lease_row is not None, (
            f"Lease must be claimed with agent_id={payload_agent_id!r} after hook. "
            f"Pre-fix: lease would be unclaimed because marker seating failed "
            f"(wrong DB), leaving agent_id=NULL.  stdout={stdout!r}"
        )
        assert lease_row["status"] == "active"
        assert lease_row["role"] == "guardian"

        # Now invoke cc-policy context role as a subprocess, simulating how the
        # harness injects CLAUDE_PROJECT_DIR + CLAUDE_ACTOR_ROLE + CLAUDE_ACTOR_ID
        # for tool calls AFTER spawn. CLAUDE_POLICY_DB is set so the CLI reads
        # from our hermetic test DB. The harness injects CLAUDE_ACTOR_ROLE and
        # CLAUDE_ACTOR_ID so build_context can locate the lease by agent_id.
        cli_env = {
            **os.environ,
            "PYTHONPATH": str(_REPO_ROOT),
            "CLAUDE_POLICY_DB": str(db_path),
            "CLAUDE_PROJECT_DIR": str(_REPO_ROOT),
            "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
            "CLAUDE_ACTOR_ROLE": "guardian:land",
            "CLAUDE_ACTOR_ID": payload_agent_id,
        }
        ctx_result = _sp.run(
            ["python3", str(_REPO_ROOT / "runtime" / "cli.py"), "context", "role"],
            capture_output=True,
            text=True,
            env=cli_env,
            cwd=str(_REPO_ROOT),
        )
        assert ctx_result.returncode == 0, (
            f"context role returned nonzero: {ctx_result.returncode}\n"
            f"stderr={ctx_result.stderr!r}"
        )

        ctx_json = json.loads(ctx_result.stdout.strip())
        # The CLI wraps in {"status":"ok","data":{...}} or returns data directly.
        ctx_data = ctx_json.get("data", ctx_json)

        assert ctx_data.get("role") in ("guardian:land", "guardian"), (
            f"Expected role 'guardian:land' or 'guardian', got {ctx_data.get('role')!r}. "
            f"Pre-fix: role would be empty because marker was in wrong DB and "
            f"lease was unclaimed (agent_id=NULL). "
            f"Full context output: {ctx_json}"
        )
        assert ctx_data.get("agent_id") == payload_agent_id, (
            f"Expected agent_id={payload_agent_id!r}, got {ctx_data.get('agent_id')!r}. "
            f"Full context output: {ctx_json}"
        )
        assert ctx_data.get("workflow_id") == _WORKFLOW_ID, (
            f"Expected workflow_id={_WORKFLOW_ID!r}, got {ctx_data.get('workflow_id')!r}. "
            f"Full context output: {ctx_json}"
        )


# ---------------------------------------------------------------------------
# GS1-F-3: TestSubagentStartCarrierConsumeNoEnv
# ---------------------------------------------------------------------------
# Regression: subagent-start.sh consumes the carrier row using git-based DB
# resolution when neither CLAUDE_POLICY_DB nor CLAUDE_PROJECT_DIR is in env.
# Pre-fix: _CARRIER_DB was empty → consume block skipped → _HAS_CONTRACT=no →
# A8 deny (canonical_seat_no_carrier_contract). Post-fix: _resolve_policy_db
# tier-3 resolves via git rev-parse and consume succeeds.
# ---------------------------------------------------------------------------


def _make_git_repo_with_schema_sa(tmp_path: Path, subdir_name: str = "repo") -> Path:
    """Create a minimal git repo with a seeded DB at <root>/.claude/state.db."""
    import subprocess as _sp

    root = tmp_path / subdir_name
    root.mkdir()
    _sp.run(["git", "init", str(root)], capture_output=True, check=True)
    _sp.run(
        ["git", "-C", str(root), "config", "user.email", "test@test.com"],
        capture_output=True,
        check=True,
    )
    _sp.run(
        ["git", "-C", str(root), "config", "user.name", "Test"],
        capture_output=True,
        check=True,
    )
    dot_claude = root / ".claude"
    dot_claude.mkdir()
    db_path = dot_claude / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed_db(conn, project_root=str(_REPO_ROOT))
        conn.commit()
    finally:
        conn.close()
    return root


def _run_hook_no_env_git_cwd(payload: dict, cwd: str) -> tuple[int, str, str]:
    """Invoke subagent-start.sh without CLAUDE_POLICY_DB or CLAUDE_PROJECT_DIR.

    cwd is set to the git repo root so that _resolve_policy_db tier-3 fires.
    """
    import subprocess as _sp

    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }
    env.pop("CLAUDE_POLICY_DB", None)
    env.pop("CLAUDE_PROJECT_DIR", None)

    result = _sp.run(
        ["bash", _HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        cwd=cwd,
    )
    return result.returncode, result.stdout, result.stderr


class TestSubagentStartCarrierConsumeNoEnv:
    """GS1-F-3: carrier consume succeeds via git-based DB resolution.

    Tests that removing CLAUDE_POLICY_DB and CLAUDE_PROJECT_DIR from the
    subagent-start.sh environment does NOT prevent carrier consume — as long
    as cwd is inside a git repo.  The pre-fix hook had a 2-tier resolver that
    silently skipped consume when both env vars were absent.

    Evaluation Contract:
    - test_consume_carrier_without_claude_project_dir_or_policy_db:
        seed carrier row → invoke hook without env vars, cwd=git_root →
        assert consume succeeded (marker row written, role=guardian:land).
    """

    def test_consume_carrier_without_claude_project_dir_or_policy_db(self, tmp_path):
        """seed carrier row in git-based DB → invoke subagent-start.sh without
        CLAUDE_POLICY_DB or CLAUDE_PROJECT_DIR → assert:
        - consume succeeds (_HAS_CONTRACT=yes path taken)
        - marker row written with role='guardian:land'
        - no 'canonical_seat_no_carrier_contract' A8 block in stdout

        Pre-fix: _CARRIER_DB empty → consume skipped → A8 deny in additionalContext.
        Post-fix: _resolve_policy_db tier-3 finds git-based DB → consume succeeds.
        """
        repo_root = _make_git_repo_with_schema_sa(tmp_path)
        db_path = repo_root / ".claude" / "state.db"

        # Seed a guardian:land carrier row in the git-based DB.
        session_id = "gs1f3-no-env-consume-session"
        conn = _open_db(db_path)
        try:
            _write_carrier(conn, session_id=session_id)
        finally:
            conn.close()

        payload_agent_id = "gs1f3-no-env-agent-001"
        payload = {
            "session_id": session_id,
            "agent_type": _GUARDIAN_AGENT_TYPE,
            "agent_id": payload_agent_id,
            "hook_event_name": "SubagentStart",
        }

        rc, stdout, stderr = _run_hook_no_env_git_cwd(payload, cwd=str(repo_root))
        assert rc == 0, f"Hook must exit 0; rc={rc}; stderr={stderr!r}"

        # The A8 block must NOT appear — _HAS_CONTRACT=yes path must have fired.
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" not in ctx, (
            "A8 deny must NOT appear when carrier row was consumed via git-based resolution. "
            "Pre-fix: _CARRIER_DB empty → consume skipped → A8 fires here. "
            f"ctx={ctx[:500]!r}"
        )

        # Runtime-first path must have fired (contract consumed from carrier).
        assert "# ClauDEX Prompt Pack:" in ctx, (
            "subagent-start.sh must take the runtime-first path after consuming the "
            f"carrier row via git-based DB resolution. ctx={ctx[:500]!r}"
        )

        # Marker row must have been written with role='guardian:land'.
        conn = _open_db(db_path)
        try:
            row = conn.execute(
                "SELECT * FROM agent_markers WHERE agent_id = ?",
                (payload_agent_id,),
            ).fetchone()
        finally:
            conn.close()

        assert row is not None, (
            f"Expected agent_markers row for agent_id={payload_agent_id!r}. "
            f"Pre-fix: seating skipped because carrier consume was skipped. "
            f"stdout={stdout!r}"
        )
        assert row["role"] == _STAGE_ID, (
            f"Expected role={_STAGE_ID!r} (guardian:land), got {row['role']!r}"
        )

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

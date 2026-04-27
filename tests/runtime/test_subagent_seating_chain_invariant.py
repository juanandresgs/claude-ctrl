"""
Slice 20: P1 subagent-seating chain invariant — payload-agent_id parity.

@decision DEC-CLAUDEX-SEATING-CHAIN-PARITY-001
@title Payload-agent_id is the single authority for marker+lease seating
@status accepted
@rationale The P1 seating chain (pre-agent → carrier write → subagent-start
  consume → marker seat → lease claim) has been empirically clean across 15
  consecutive landings + 25+ auto-seat proofs. No single mechanical test
  observed agent_markers / dispatch_leases state after a real hook-chain
  subprocess run and asserted payload-agent_id parity. This file closes that
  gap by running REAL subprocess invocations of hooks/pre-agent.sh and
  hooks/subagent-start.sh against a per-test isolated SQLite DB, then
  asserting:
    1. agent_markers.agent_id == SubagentStart HOOK_INPUT.agent_id
    2. dispatch_leases.agent_id == SubagentStart HOOK_INPUT.agent_id
    3. agent_markers.role == contract.stage_id (not AGENT_TYPE, not empty)
    4. pending_agent_requests row is consumed (absent) after the chain
    5. cc-policy context role (production resolver) sees the seated identity
    6. Without a pre-agent.sh carrier write, no marker/lease is seated
       (A8 deny path fires, vacuous-truth guard)

Implementation note (DEC-CLAUDEX-SEATING-CHAIN-PARITY-001 / Risk §3):
  T7 invokes cc-policy context role via runtime/cli.py directly as
  `python3 <repo>/runtime/cli.py context role` with CLAUDE_POLICY_DB set to
  the per-test DB. This avoids $PATH dependency on the `cc-policy` binary and
  matches the pattern used by _local_cc_policy() inside subagent-start.sh.

Isolation invariant: every test uses a fresh per-test tmp_path DB.
CLAUDE_PROJECT_DIR is set to _REPO_ROOT (the git repo, not a tmp dir) so
that detect_project_root() returns _REPO_ROOT and the hook can locate
hooks/*.sh and runtime/core/*.py via relative imports. CLAUDE_POLICY_DB
is set to the per-test tmp DB so production state is never touched.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import time
from pathlib import Path

import pytest

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec
from runtime.core import leases as leases_mod
from runtime.core import workflows as workflows_mod
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Repo-relative paths
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_PRE_AGENT = str(_REPO_ROOT / "hooks" / "pre-agent.sh")
_SUBAGENT_START = str(_REPO_ROOT / "hooks" / "subagent-start.sh")
_RUNTIME_CLI = str(_REPO_ROOT / "runtime" / "cli.py")

# ---------------------------------------------------------------------------
# Shared canonical test contract
# (One stable (workflow_id, goal_id, work_item_id) triplet for all tests
# that require a prompt-pack compile to succeed. Tests that only assert
# marker/lease seating and NOT the prompt-pack contents can reuse this.)
# ---------------------------------------------------------------------------

_WORKFLOW_ID = "wf-seating-invariant"
_GOAL_ID = "GOAL-SEATING-20"
_WORK_ITEM_ID = "WI-SEATING-20"

_BASE_CONTRACT = {
    "workflow_id": _WORKFLOW_ID,
    "stage_id": "planner",
    "goal_id": _GOAL_ID,
    "work_item_id": _WORK_ITEM_ID,
    "decision_scope": "kernel",
    "generated_at": 1_700_000_000,
}
_CONTRACT_BLOCK_LINE = "CLAUDEX_CONTRACT_BLOCK:" + json.dumps(_BASE_CONTRACT)

_PLANNER_PAYLOAD_AGENT_ID = "planner-slice20-agent-001"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _seed_db(conn: sqlite3.Connection, workflow_id: str = _WORKFLOW_ID) -> None:
    """Seed goal, work_item, workflow_binding so prompt-pack compile succeeds."""
    goal = contracts.GoalContract(
        goal_id=_GOAL_ID,
        desired_end_state="seating chain invariant test",
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
            title="seating chain invariant test slice",
            status="in_progress",
            version=1,
            author="planner",
            scope_json=(
                '{"allowed_paths":["tests/runtime/test_subagent_seating_chain_invariant.py"],'
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
        workflow_id=workflow_id,
        worktree_path=str(_REPO_ROOT),
        branch="global-soak-main",
    )


def _shared_env(db_path: Path) -> dict:
    """Env vars that wire hooks to the per-test isolated DB.

    CLAUDE_POLICY_DB: per-test DB (isolation from production).
    CLAUDE_PROJECT_DIR: the actual repo root — needed so detect_project_root()
      returns _REPO_ROOT and hooks can find their sibling scripts.
    CLAUDE_RUNTIME_ROOT: the local runtime dir so cc_policy wrapper in
      runtime-bridge.sh resolves to the worktree's cli.py, not ~/.claude/runtime.
    PYTHONPATH: ensures `from runtime.core import ...` works.
    """
    return {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_PROJECT_DIR": str(_REPO_ROOT),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }


def _run_pre_agent(payload: dict, db_path: Path) -> tuple[int, str, str]:
    """Run hooks/pre-agent.sh with JSON payload on stdin."""
    result = subprocess.run(
        ["bash", _PRE_AGENT],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=_shared_env(db_path),
        cwd=str(_REPO_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


def _run_subagent_start(payload: dict, db_path: Path) -> tuple[int, str, str]:
    """Run hooks/subagent-start.sh with JSON payload on stdin."""
    result = subprocess.run(
        ["bash", _SUBAGENT_START],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=_shared_env(db_path),
        cwd=str(_REPO_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


def _run_context_role(db_path: Path) -> dict:
    """Run `python3 runtime/cli.py context role` via direct invocation.

    Uses python3 + absolute path to runtime/cli.py to avoid $PATH dependency
    on the `cc-policy` binary. CLAUDE_POLICY_DB directs it to the per-test DB.
    CLAUDE_PROJECT_DIR ensures cwd resolution matches the hooks.
    Returns parsed JSON dict.
    """
    result = subprocess.run(
        ["python3", _RUNTIME_CLI, "context", "role"],
        capture_output=True,
        text=True,
        env=_shared_env(db_path),
        cwd=str(_REPO_ROOT),
    )
    assert result.returncode == 0, (
        f"cc-policy context role returned non-zero: {result.stderr!r}"
    )
    return json.loads(result.stdout.strip())


def _pre_agent_payload(
    *,
    agent_type: str = "planner",
    agent_id: str = _PLANNER_PAYLOAD_AGENT_ID,
    session_id: str = "seating-test-session-001",
    stage_id: str = "planner",
    workflow_id: str = _WORKFLOW_ID,
    goal_id: str = _GOAL_ID,
    work_item_id: str = _WORK_ITEM_ID,
) -> dict:
    """Canonical PreToolUse:Agent payload for pre-agent.sh."""
    contract = {
        "workflow_id": workflow_id,
        "stage_id": stage_id,
        "goal_id": goal_id,
        "work_item_id": work_item_id,
        "decision_scope": "kernel",
        "generated_at": 1_700_000_000,
    }
    block_line = "CLAUDEX_CONTRACT_BLOCK:" + json.dumps(contract)
    prompt = f"{block_line}\n\nYou are a {stage_id} agent.\nBegin.\n"
    return {
        "session_id": session_id,
        "tool_name": "Agent",
        "tool_input": {
            "subagent_type": agent_type,
            "prompt": prompt,
        },
    }


def _subagent_start_payload(
    *,
    agent_type: str = "planner",
    agent_id: str = _PLANNER_PAYLOAD_AGENT_ID,
    session_id: str = "seating-test-session-001",
) -> dict:
    """Canonical SubagentStart payload for subagent-start.sh."""
    return {
        "agent_type": agent_type,
        "agent_id": agent_id,
        "session_id": session_id,
    }


def _read_active_markers(db_path: Path) -> list[dict]:
    """Return all active agent_markers rows as list of dicts."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT agent_id, role, is_active, status, project_root, workflow_id "
            "FROM agent_markers WHERE is_active = 1"
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def _read_claimed_leases(db_path: Path, agent_id: str | None = None) -> list[dict]:
    """Return dispatch_leases rows with agent_id set (claimed)."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        if agent_id is not None:
            rows = conn.execute(
                "SELECT lease_id, agent_id, role, status, worktree_path, workflow_id "
                "FROM dispatch_leases WHERE agent_id = ?",
                (agent_id,),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT lease_id, agent_id, role, status, worktree_path, workflow_id "
                "FROM dispatch_leases WHERE agent_id IS NOT NULL AND agent_id != ''"
            ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def _carrier_row_exists(db_path: Path, session_id: str, agent_type: str) -> bool:
    """Return True if a pending_agent_requests row exists for (session_id, agent_type)."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT 1 FROM pending_agent_requests WHERE session_id = ? AND agent_type = ?",
            (session_id, agent_type),
        ).fetchone()
        return row is not None
    finally:
        conn.close()


def _issue_lease(conn: sqlite3.Connection, role: str, worktree_path: str, workflow_id: str) -> str:
    """Issue an active dispatch lease for the given role + worktree.

    Returns the lease_id. Requires that worktree_path matches the normalized
    path that subagent-start.sh will use (i.e., os.path.realpath(_REPO_ROOT)).
    """
    lease = leases_mod.issue(
        conn,
        role=role,
        worktree_path=worktree_path,
        workflow_id=workflow_id,
        head_sha=None,
        next_step="slice 20 seating chain invariant test",
    )
    return lease["lease_id"]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def seating_db(tmp_path: Path) -> Path:
    """Per-test isolated DB with schema + goal/work_item/workflow seeds."""
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed_db(conn)
        conn.commit()
    finally:
        conn.close()
    return db_path


@pytest.fixture
def seating_db_with_lease(seating_db: Path) -> tuple[Path, str]:
    """seating_db with a pre-issued planner lease for _REPO_ROOT worktree.

    The lease must exist before subagent-start.sh runs so rt_lease_claim
    can find and claim it (one active lease per worktree invariant).
    Returns (db_path, lease_id).
    """
    import os
    worktree_path = os.path.realpath(str(_REPO_ROOT))
    conn = sqlite3.connect(str(seating_db))
    conn.row_factory = sqlite3.Row
    try:
        lease_id = _issue_lease(conn, "planner", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()
    return seating_db, lease_id


# ===========================================================================
# Vacuous-truth guard: hook scripts exist and DB has required tables
# ===========================================================================


class TestSeatingChainInvariantPrerequisites:
    """Guard tests: if these fail, all other tests in this file are suspect."""

    def test_pre_agent_sh_exists_and_nonzero(self):
        """pre-agent.sh must exist and be non-empty."""
        p = Path(_PRE_AGENT)
        assert p.exists(), f"pre-agent.sh not found at {_PRE_AGENT}"
        assert p.stat().st_size > 0, "pre-agent.sh is empty"

    def test_subagent_start_sh_exists_and_nonzero(self):
        """subagent-start.sh must exist and be non-empty."""
        p = Path(_SUBAGENT_START)
        assert p.exists(), f"subagent-start.sh not found at {_SUBAGENT_START}"
        assert p.stat().st_size > 0, "subagent-start.sh is empty"

    def test_runtime_cli_exists_and_nonzero(self):
        """runtime/cli.py must exist (used for context role)."""
        p = Path(_RUNTIME_CLI)
        assert p.exists(), f"runtime/cli.py not found at {_RUNTIME_CLI}"
        assert p.stat().st_size > 0, "runtime/cli.py is empty"

    def test_schema_has_agent_markers_table(self, seating_db: Path):
        """agent_markers table must be created by ensure_schema."""
        conn = sqlite3.connect(str(seating_db))
        try:
            tables = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
        finally:
            conn.close()
        assert "agent_markers" in tables, (
            "agent_markers table absent — ensure_schema() may not have run"
        )

    def test_schema_has_dispatch_leases_table(self, seating_db: Path):
        """dispatch_leases table must be created by ensure_schema."""
        conn = sqlite3.connect(str(seating_db))
        try:
            tables = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
        finally:
            conn.close()
        assert "dispatch_leases" in tables

    def test_schema_has_pending_agent_requests_table(self, seating_db: Path):
        """pending_agent_requests (carrier) table must exist."""
        conn = sqlite3.connect(str(seating_db))
        try:
            tables = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
        finally:
            conn.close()
        assert "pending_agent_requests" in tables


# ===========================================================================
# T1: Happy-path end-to-end: marker is seated from payload agent_id
# ===========================================================================


class TestFullChainSeatsMarkerFromPayloadAgentId:
    """After pre-agent.sh → subagent-start.sh, agent_markers must contain
    an active row with agent_id == HOOK_INPUT.agent_id.

    DEC-CLAUDEX-SEATING-CHAIN-PARITY-001 anchor: the payload agent_id is the
    single authority for marker seating. Any regression that replaces it with
    a shell PID or empty string breaks this test.
    """

    def test_marker_is_seated_with_payload_agent_id(self, seating_db_with_lease):
        """Active agent_markers.agent_id == HOOK_INPUT.agent_id after chain."""
        db_path, _ = seating_db_with_lease
        session_id = "T1-session"
        agent_id = "planner-slice20-agent-T1"

        # Step 1: pre-agent.sh writes carrier row
        pre_rc, _pre_out, pre_err = _run_pre_agent(
            _pre_agent_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert pre_rc == 0, f"pre-agent.sh failed (rc={pre_rc}): {pre_err}"
        assert _carrier_row_exists(db_path, session_id, "planner"), (
            "pre-agent.sh must have written a pending_agent_requests row"
        )

        # Step 2: subagent-start.sh consumes carrier + seats marker
        sa_rc, _sa_out, sa_err = _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert sa_rc == 0, f"subagent-start.sh failed (rc={sa_rc}): {sa_err}"

        # Step 3: assert marker is active and agent_id matches payload
        markers = _read_active_markers(db_path)
        assert len(markers) == 1, (
            f"Expected exactly 1 active marker, got {len(markers)}: {markers}"
        )
        assert markers[0]["agent_id"] == agent_id, (
            f"agent_markers.agent_id={markers[0]['agent_id']!r} != "
            f"payload agent_id={agent_id!r} — DEC-CLAUDEX-SA-IDENTITY-001 violated"
        )


# ===========================================================================
# T2: Drift mode #1 — marker.role == stage_id, NOT raw AGENT_TYPE
# ===========================================================================


class TestMarkerRoleEqualsStageIdNotAgentType:
    """The seated marker's role must equal contract.stage_id.

    In subagent-start.sh, for contract-present dispatches,
    `_MARKER_ROLE = stage_id` (not the raw AGENT_TYPE). If a future edit
    replaces `_MARKER_ROLE` with `"${AGENT_TYPE:-unknown}"` in the
    agent-start CLI call, this test fires.
    """

    def test_marker_role_is_stage_id_not_agent_type(self, seating_db_with_lease):
        """agent_markers.role == contract.stage_id ('planner') after chain."""
        db_path, _ = seating_db_with_lease
        session_id = "T2-session"
        agent_id = "planner-slice20-agent-T2"

        pre_rc, _, pre_err = _run_pre_agent(
            _pre_agent_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert pre_rc == 0, f"pre-agent.sh failed: {pre_err}"

        _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )

        markers = _read_active_markers(db_path)
        assert len(markers) >= 1, "No active marker found after chain"
        marker = next(m for m in markers if m["agent_id"] == agent_id)
        assert marker["role"] == "planner", (
            f"agent_markers.role={marker['role']!r} — expected 'planner' (=stage_id), "
            "not the raw AGENT_TYPE or a default 'unknown'. "
            "DEC-CLAUDEX-SEATING-CHAIN-PARITY-001 / T2."
        )
        assert marker["role"] != "unknown", (
            "marker.role='unknown' means _MARKER_ROLE defaulted — "
            "contract stage_id was not propagated correctly"
        )


# ===========================================================================
# T3: Drift mode #2 — lease is claimed by payload agent_id, NOT shell PID
# ===========================================================================


class TestLeaseIsClaimedByPayloadAgentIdNotShellPid:
    """After the chain, any claimed lease must have agent_id == payload agent_id.

    Before DEC-CLAUDEX-SA-IDENTITY-001, the lease claim used `agent-$$`
    (shell PID). A regression to PID-shaped identity produces a lease with
    agent_id matching `^agent-[0-9]+$` — this test detects that.
    """

    def test_lease_claimed_with_payload_agent_id(self, seating_db_with_lease):
        """dispatch_leases.agent_id == payload agent_id after claim."""
        db_path, _ = seating_db_with_lease
        session_id = "T3-session"
        agent_id = "planner-slice20-agent-T3-notpid"

        pre_rc, _, pre_err = _run_pre_agent(
            _pre_agent_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert pre_rc == 0, f"pre-agent.sh failed: {pre_err}"

        _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )

        leases = _read_claimed_leases(db_path, agent_id=agent_id)
        assert len(leases) >= 1, (
            f"No lease claimed with agent_id={agent_id!r}. "
            "rt_lease_claim must find and bind the pre-issued lease to the payload agent_id."
        )
        for lease in leases:
            assert lease["agent_id"] == agent_id, (
                f"lease.agent_id={lease['agent_id']!r} != payload {agent_id!r}"
            )
            # Regression guard: PID-shaped agent_id looks like 'agent-12345'
            assert not re.match(r"^agent-[0-9]+$", lease["agent_id"]), (
                f"Lease agent_id={lease['agent_id']!r} looks like a shell PID "
                "(agent-<number>). DEC-CLAUDEX-SA-IDENTITY-001 violated: "
                "payload agent_id must be used, not shell PID."
            )


# ===========================================================================
# T4: Drift mode #3 — triple parity: marker.agent_id == lease.agent_id == payload
# ===========================================================================


class TestMarkerAgentIdEqualsLeaseAgentIdEqualsPayloadAgentId:
    """Strict triple equality: marker.agent_id == lease.agent_id == payload agent_id.

    DEC-CLAUDEX-SA-IDENTITY-001 anchor: any drift where marker and lease are
    seated from different identity sources fires this test.
    """

    def test_triple_parity_agent_id(self, seating_db_with_lease):
        """agent_markers.agent_id == dispatch_leases.agent_id == HOOK_INPUT.agent_id."""
        db_path, _ = seating_db_with_lease
        session_id = "T4-session"
        agent_id = "planner-slice20-agent-T4-parity"

        pre_rc, _, pre_err = _run_pre_agent(
            _pre_agent_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert pre_rc == 0, f"pre-agent.sh failed: {pre_err}"

        _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )

        markers = _read_active_markers(db_path)
        leases = _read_claimed_leases(db_path, agent_id=agent_id)

        # Marker must have the payload agent_id
        assert len(markers) >= 1, "No active marker after chain"
        marker = next((m for m in markers if m["agent_id"] == agent_id), None)
        assert marker is not None, (
            f"No active marker with agent_id={agent_id!r}. "
            f"Active markers: {markers}"
        )

        # Lease must have the payload agent_id
        assert len(leases) >= 1, (
            f"No claimed lease with agent_id={agent_id!r}. "
            "rt_lease_claim must have matched the pre-issued lease."
        )
        lease = leases[0]

        # Triple parity assertion
        assert marker["agent_id"] == agent_id, (
            f"marker.agent_id={marker['agent_id']!r} != payload {agent_id!r}"
        )
        assert lease["agent_id"] == agent_id, (
            f"lease.agent_id={lease['agent_id']!r} != payload {agent_id!r}"
        )
        assert marker["agent_id"] == lease["agent_id"], (
            f"marker.agent_id={marker['agent_id']!r} != lease.agent_id={lease['agent_id']!r}. "
            "Marker and lease seated from different identity sources — "
            "DEC-CLAUDEX-SA-IDENTITY-001 violated."
        )


# ===========================================================================
# T5: Drift mode #4 — carrier consumed AND marker+lease present (conjunction)
# ===========================================================================


class TestCarrierRowAbsentAndMarkerLeasePresentAfterChain:
    """Strong conjunction: after chain, carrier absent AND marker+lease present.

    Any refactor that reorders operations (consume after seating, or skips
    seating when _HAS_CONTRACT="no" after a merged carrier) breaks this.
    """

    def test_conjunction_carrier_absent_marker_present_lease_present(
        self, seating_db_with_lease
    ):
        """After chain: carrier absent, marker active, lease claimed (all three true)."""
        db_path, _ = seating_db_with_lease
        session_id = "T5-session"
        agent_id = "planner-slice20-agent-T5-conjunction"

        pre_rc, _, pre_err = _run_pre_agent(
            _pre_agent_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert pre_rc == 0, f"pre-agent.sh failed: {pre_err}"

        # Carrier must be present between pre-agent and subagent-start
        assert _carrier_row_exists(db_path, session_id, "planner"), (
            "Carrier row must exist after pre-agent.sh (before subagent-start.sh)"
        )

        sa_rc, _, sa_err = _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert sa_rc == 0, f"subagent-start.sh failed: {sa_err}"

        # (a) Carrier row must be consumed (absent after subagent-start)
        assert not _carrier_row_exists(db_path, session_id, "planner"), (
            "pending_agent_requests row must be atomically deleted after "
            "subagent-start.sh consumes it. T5 conjunction (a) failed."
        )

        # (b) Active marker must be present
        markers = _read_active_markers(db_path)
        assert len(markers) >= 1, (
            "agent_markers must have an active row after the chain. "
            "T5 conjunction (b) failed — marker seating was skipped."
        )
        marker = next((m for m in markers if m["agent_id"] == agent_id), None)
        assert marker is not None, (
            f"Active marker with agent_id={agent_id!r} not found. "
            f"Active markers: {markers}"
        )

        # (c) Claimed lease must be present
        leases = _read_claimed_leases(db_path, agent_id=agent_id)
        assert len(leases) >= 1, (
            f"No claimed lease with agent_id={agent_id!r}. "
            "T5 conjunction (c) failed — lease claim was skipped."
        )


# ===========================================================================
# T6: Vacuous-truth guard — no pre-agent.sh → A8 deny, no marker/lease seated
# ===========================================================================


class TestDispatchWithoutPreAgentWriteDoesNotSeatMarkerOrLease:
    """Without a prior pre-agent.sh carrier write, subagent-start.sh must NOT
    seat a marker or claim a lease (A8 deny path fires instead).

    Proves the positive tests (T1–T5) are NOT vacuously true — i.e., the
    mechanism actually requires the carrier to produce state, and SubagentStart
    alone cannot create a marker/lease from thin air.
    """

    def test_no_marker_seated_without_carrier(self, seating_db_with_lease):
        """subagent-start.sh without carrier row: no active marker for this agent_id."""
        db_path, _ = seating_db_with_lease
        session_id = "T6-session-nocarrier"
        agent_id = "planner-slice20-agent-T6-nocarrier"

        # Do NOT call pre-agent.sh — no carrier row

        sa_rc, sa_out, _ = _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert sa_rc == 0  # hook always exits 0

        # A8 deny path fires: canonical_seat_no_carrier_contract in additionalContext
        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx, (
            "A8 deny path must fire when canonical seat launches without a "
            "carrier-backed contract. T6 failed — hook may have taken legacy path."
        )

        # No active marker for this agent_id must exist
        markers = _read_active_markers(db_path)
        agent_markers = [m for m in markers if m["agent_id"] == agent_id]
        assert len(agent_markers) == 0, (
            f"Marker was seated without a carrier row (agent_id={agent_id!r}). "
            "T6 vacuous-truth guard failed — markers accumulate without carrier proof."
        )

    def test_no_lease_claimed_without_carrier(self, seating_db_with_lease):
        """subagent-start.sh without carrier row: no lease claimed for this agent_id."""
        db_path, _ = seating_db_with_lease
        session_id = "T6b-session-nocarrier"
        agent_id = "planner-slice20-agent-T6b-nocarrier"

        # Do NOT call pre-agent.sh
        _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )

        leases = _read_claimed_leases(db_path, agent_id=agent_id)
        assert len(leases) == 0, (
            f"A lease was claimed with agent_id={agent_id!r} even without a "
            "carrier row. T6 vacuous-truth guard failed — lease claim must require "
            "the carrier-backed contract path."
        )


# ===========================================================================
# T7: Context-role resolver parity — production sequence end-to-end
# ===========================================================================


class TestCcPolicyContextRoleReflectsSeatedIdentityAfterChain:
    """After the happy-path chain, `python3 runtime/cli.py context role`
    must return role=stage_id and agent_id==HOOK_INPUT.agent_id.

    This is the production-sequence consumer: pre-bash.sh calls
    `cc-policy context role` before every Bash tool call to resolve the
    active actor. Pinning it here closes the observability loop back to
    the downstream consumer.

    Teeth: a regression where seating writes to a different DB than
    `cc-policy context role` reads (a re-introduction of the
    _resolve_policy_db 2-tier bug from DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001)
    produces an empty role or wrong agent_id and this test fires.
    """

    def test_context_role_resolves_seated_agent_id_and_role(
        self, seating_db_with_lease
    ):
        """cc-policy context role returns (role=planner, agent_id=payload_agent_id)."""
        db_path, _ = seating_db_with_lease
        session_id = "T7-session"
        agent_id = "planner-slice20-agent-T7-context"

        pre_rc, _, pre_err = _run_pre_agent(
            _pre_agent_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert pre_rc == 0, f"pre-agent.sh failed: {pre_err}"

        sa_rc, _, sa_err = _run_subagent_start(
            _subagent_start_payload(session_id=session_id, agent_id=agent_id),
            db_path,
        )
        assert sa_rc == 0, f"subagent-start.sh failed: {sa_err}"

        # Verify marker was seated before calling context role
        markers = _read_active_markers(db_path)
        assert any(m["agent_id"] == agent_id for m in markers), (
            f"No active marker with agent_id={agent_id!r} — "
            "context role test is meaningless without a seated marker"
        )

        # Production sequence: context role resolution
        ctx_result = _run_context_role(db_path)

        assert ctx_result.get("role") == "planner", (
            f"context role returned role={ctx_result.get('role')!r} — "
            f"expected 'planner'. Seated marker or lease not visible to "
            f"build_context(). T7 — DEC-CLAUDEX-SEATING-CHAIN-PARITY-001."
        )
        assert ctx_result.get("agent_id") == agent_id, (
            f"context role returned agent_id={ctx_result.get('agent_id')!r} — "
            f"expected {agent_id!r}. Identity resolution is broken or "
            f"resolving from a different DB. T7 — DEC-CLAUDEX-SA-IDENTITY-001."
        )

"""Slice 29 invariant suite — DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001.

Proves the real-harness sole-identity-authority invariant:
  agent_id is the SOLE identity authority across marker and lease seating.
  After any SubagentStart in a project+workflow, at most ONE agent_markers row
  is is_active=1. That row's agent_id equals HOOK_INPUT.agent_id. Stale prior
  markers from other roles are superseded (Part A fix: project-scoped supersede
  in markers.set_active). SubagentStop correctly deactivates compound-staged
  markers (Part B fix: lease_role_for_stage canonicalization in
  lifecycle.on_stop_by_role).

Test layout:
  (a) test_a_marker_seats_under_live_payload_agent_id     — real subprocess chain
  (b) test_b_lease_claimed_by_live_agent_id               — real subprocess chain
  (c) test_c_context_role_returns_guardian_after_seating  — real subprocess chain
  (d) test_d_stale_prior_marker_cannot_override_guardian  — real subprocess chain (Part A proof)
  (e) test_e_post_guardian_next_dispatch_cycles_cleanly   — real subprocess chain (Part B proof)
  (f) test_f_markers_set_active_project_scoped_supersede_unit — unit, :memory:
  (g) test_g_lifecycle_on_stop_accepts_compound_stage         — unit, :memory:
  (h) test_h_authority_registry_canonicalizer_still_maps_compound_to_base — read-only
  (i) test_i_decision_id_in_module_docstring                  — module docstring pin

Real-path cases (a-e) run actual hook subprocess chains against per-test isolated
SQLite DBs (CLAUDE_POLICY_DB=<tmp_path>). Never touch the production DB.

@decision DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001
@title Real-harness sole-identity-authority landing-path fix (Slice 29)
@status accepted
@rationale Bug A: markers.set_active supersede scoped by (role, project_root,
  workflow_id) left prior markers of OTHER roles active. Bug B: lifecycle.
  on_stop_by_role equality compared compound stage ("guardian:land") against
  base agent_type ("guardian") — always failing for compound dispatches.
  Together these let stale reviewer/implementer markers accumulate as is_active=1,
  causing markers.get_active to return the wrong agent_id at PreToolUse:Bash
  time and blocking guardian landing. Fix: (A) remove role from supersede WHERE;
  (B) canonicalize both sides via authority_registry.lease_role_for_stage.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Optional

import pytest

# ---------------------------------------------------------------------------
# Repo-relative paths (identical pattern to test_subagent_seating_chain_invariant.py)
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_PRE_AGENT = str(_REPO_ROOT / "hooks" / "pre-agent.sh")
_SUBAGENT_START = str(_REPO_ROOT / "hooks" / "subagent-start.sh")
_RUNTIME_CLI = str(_REPO_ROOT / "runtime" / "cli.py")

sys.path.insert(0, str(_REPO_ROOT))

from runtime.core import contracts  # noqa: E402
from runtime.core import decision_work_registry as dwr  # noqa: E402
from runtime.core import goal_contract_codec  # noqa: E402
from runtime.core import leases as leases_mod  # noqa: E402
from runtime.core import lifecycle  # noqa: E402
from runtime.core import markers as markers_mod  # noqa: E402
from runtime.core import workflows as workflows_mod  # noqa: E402
from runtime.core.authority_registry import lease_role_for_stage  # noqa: E402
from runtime.core.db import connect_memory  # noqa: E402
from runtime.schemas import ensure_schema  # noqa: E402

# ---------------------------------------------------------------------------
# Canonical test identifiers (unique to this file to avoid cross-test leakage)
# ---------------------------------------------------------------------------

_WORKFLOW_ID = "wf-sole-identity-authority-s29"
_GOAL_ID = "GOAL-SOLE-IDENTITY-S29"
_WORK_ITEM_ID = "WI-SOLE-IDENTITY-S29"


# ---------------------------------------------------------------------------
# Helper: seed goal/work_item/workflow binding so prompt-pack compile succeeds
# ---------------------------------------------------------------------------


def _seed_db(conn: sqlite3.Connection, workflow_id: str = _WORKFLOW_ID) -> None:
    """Seed the minimum records required for the hook chain to proceed.

    Mirrors the _seed_db pattern in test_subagent_seating_chain_invariant.py.
    """
    goal = contracts.GoalContract(
        goal_id=_GOAL_ID,
        desired_end_state="sole-identity-authority invariant test",
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
            title="sole identity authority invariant slice",
            status="in_progress",
            version=1,
            author="planner",
            scope_json=(
                '{"allowed_paths":["tests/runtime/test_harness_agent_id_sole_identity_authority.py"],'
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
    """Build the per-test environment dict.

    CLAUDE_POLICY_DB → per-test isolated DB (never touches production).
    CLAUDE_PROJECT_DIR → actual repo root so detect_project_root() resolves.
    CLAUDE_RUNTIME_ROOT → in-worktree runtime/ dir.
    PYTHONPATH → ensures `from runtime.core import ...` works in subprocesses.
    """
    return {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_PROJECT_DIR": str(_REPO_ROOT),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }


def _issue_lease(
    conn: sqlite3.Connection,
    role: str,
    worktree_path: str,
    workflow_id: str,
) -> str:
    """Issue a pending dispatch lease and return its lease_id.

    worktree_path must be the realpath so rt_lease_claim in subagent-start.sh
    matches the normalized path stored in dispatch_leases.
    """
    lease = leases_mod.issue(
        conn,
        role=role,
        worktree_path=worktree_path,
        workflow_id=workflow_id,
        head_sha=None,
        next_step="sole identity authority invariant test",
    )
    return lease["lease_id"]


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------


def _run_pre_agent(payload: dict, db_path: Path) -> tuple[int, str, str]:
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
    """Run `python3 runtime/cli.py context role` — DEC-CLAUDEX-SEATING-CHAIN-PARITY-001 Risk §3."""
    result = subprocess.run(
        ["python3", _RUNTIME_CLI, "context", "role"],
        capture_output=True,
        text=True,
        env=_shared_env(db_path),
        cwd=str(_REPO_ROOT),
    )
    assert result.returncode == 0, (
        f"context role returned non-zero: stderr={result.stderr!r}"
    )
    return json.loads(result.stdout.strip())


def _run_lifecycle_on_stop(
    role: str,
    db_path: Path,
    project_root: Optional[str] = None,
) -> dict:
    """Run `python3 runtime/cli.py lifecycle on-stop <role> [--project-root ...]`."""
    cmd = ["python3", _RUNTIME_CLI, "lifecycle", "on-stop", role]
    if project_root:
        cmd += ["--project-root", project_root]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=_shared_env(db_path),
        cwd=str(_REPO_ROOT),
    )
    assert result.returncode == 0, (
        f"lifecycle on-stop returned non-zero: stderr={result.stderr!r} stdout={result.stdout!r}"
    )
    return json.loads(result.stdout.strip())


def _pre_agent_payload(
    *,
    agent_type: str,
    agent_id: str,
    session_id: str,
    stage_id: str,
    workflow_id: str = _WORKFLOW_ID,
    goal_id: str = _GOAL_ID,
    work_item_id: str = _WORK_ITEM_ID,
) -> dict:
    """Build a canonical PreToolUse:Agent payload for pre-agent.sh."""
    contract = {
        "workflow_id": workflow_id,
        "stage_id": stage_id,
        "goal_id": goal_id,
        "work_item_id": work_item_id,
        "decision_scope": "kernel",
        "generated_at": 1_700_000_000,
    }
    block_line = "CLAUDEX_CONTRACT_BLOCK:" + json.dumps(contract)
    prompt = f"{block_line}\nYou are a {stage_id} agent.\nBegin.\n"
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
    agent_type: str,
    agent_id: str,
    session_id: str,
) -> dict:
    """Build a canonical SubagentStart payload for subagent-start.sh."""
    return {
        "agent_type": agent_type,
        "agent_id": agent_id,
        "session_id": session_id,
    }


def _read_active_markers(db_path: Path) -> list[dict]:
    """Return all is_active=1 rows from agent_markers."""
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


def _read_marker(db_path: Path, agent_id: str) -> Optional[dict]:
    """Return the agent_markers row for agent_id (any status)."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT agent_id, role, is_active, status, stopped_at, project_root, workflow_id "
            "FROM agent_markers WHERE agent_id = ?",
            (agent_id,),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def _read_active_leases(db_path: Path) -> list[dict]:
    """Return all dispatch_leases rows with status='active' and agent_id set."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT lease_id, agent_id, role, status, worktree_path, workflow_id "
            "FROM dispatch_leases WHERE status = 'active' AND agent_id IS NOT NULL AND agent_id != ''"
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def _carrier_row_exists(db_path: Path, session_id: str, agent_type: str) -> bool:
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


# ---------------------------------------------------------------------------
# Fixture: per-test isolated DB with schema + seeds
# ---------------------------------------------------------------------------


@pytest.fixture
def sole_identity_db(tmp_path: Path) -> Path:
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
def sole_identity_db_with_guardian_lease(sole_identity_db: Path) -> tuple[Path, str]:
    """sole_identity_db with a pre-issued guardian lease at _REPO_ROOT."""
    worktree_path = os.path.realpath(str(_REPO_ROOT))
    conn = sqlite3.connect(str(sole_identity_db))
    conn.row_factory = sqlite3.Row
    try:
        lease_id = _issue_lease(conn, "guardian", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()
    return sole_identity_db, lease_id


@pytest.fixture
def sole_identity_db_with_reviewer_then_guardian(
    sole_identity_db: Path,
) -> tuple[Path, str, str]:
    """sole_identity_db with a pre-issued guardian lease AND a pre-issued reviewer lease.

    Returns (db_path, reviewer_lease_id, guardian_lease_id).
    The reviewer lease is issued first; then the guardian lease supersedes it
    at the DB level (one-active-per-worktree enforced by leases.issue).
    We issue the guardian lease after the reviewer so the guardian lease
    is the active one at fixture time. The review marker will be added via
    the hook chain in test_d.
    """
    worktree_path = os.path.realpath(str(_REPO_ROOT))
    conn = sqlite3.connect(str(sole_identity_db))
    conn.row_factory = sqlite3.Row
    try:
        # Issue guardian lease (reviewer's lease would be revoked by leases.issue
        # one-active-per-worktree rule, so issue guardian directly)
        lease_id = _issue_lease(conn, "guardian", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()
    return sole_identity_db, "", lease_id


# ===========================================================================
# Case (a): Marker seats under the live payload agent_id
# ===========================================================================


def test_a_marker_seats_under_live_payload_agent_id(
    sole_identity_db_with_guardian_lease: tuple[Path, str],
) -> None:
    """After pre-agent + subagent-start for guardian:land, exactly one active marker
    has agent_id == HOOK_INPUT.agent_id and role == 'guardian:land'.

    DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001 anchor:
    The live harness agent_id is the sole identity authority. Any regression
    where a PID, empty string, or stale value is stored breaks this test.
    """
    db_path, _ = sole_identity_db_with_guardian_lease
    session_id = "s29-a-session"
    agent_id = "LIVE-guardian-agent-id-s29-aaaa"

    # Step 1: pre-agent writes carrier row
    pre_rc, _, pre_err = _run_pre_agent(
        _pre_agent_payload(
            agent_type="guardian",
            agent_id=agent_id,
            session_id=session_id,
            stage_id="guardian:land",
        ),
        db_path,
    )
    assert pre_rc == 0, f"pre-agent.sh failed (rc={pre_rc}): {pre_err}"
    assert _carrier_row_exists(db_path, session_id, "guardian"), (
        "pre-agent.sh must write a pending_agent_requests row"
    )

    # Step 2: subagent-start consumes carrier + seats marker + claims lease
    sa_rc, _, sa_err = _run_subagent_start(
        _subagent_start_payload(
            agent_type="guardian",
            agent_id=agent_id,
            session_id=session_id,
        ),
        db_path,
    )
    assert sa_rc == 0, f"subagent-start.sh failed (rc={sa_rc}): {sa_err}"

    # (a1) Exactly one active marker
    active = _read_active_markers(db_path)
    assert len(active) == 1, (
        f"Expected exactly 1 active marker; got {len(active)}: {active}"
    )
    m = active[0]
    # (a2) agent_id matches the live payload agent_id
    assert m["agent_id"] == agent_id, (
        f"agent_markers.agent_id={m['agent_id']!r} != payload {agent_id!r}. "
        "DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001 violated."
    )
    # (a3) role is the compound stage_id from the contract
    assert m["role"] == "guardian:land", (
        f"Expected role='guardian:land' (compound from contract); got {m['role']!r}"
    )
    # (a4) carrier row consumed
    assert not _carrier_row_exists(db_path, session_id, "guardian"), (
        "pending_agent_requests row must be consumed after subagent-start"
    )


# ===========================================================================
# Case (b): Pending guardian lease is claimed by the live agent_id
# ===========================================================================


def test_b_lease_claimed_by_live_agent_id(
    sole_identity_db_with_guardian_lease: tuple[Path, str],
) -> None:
    """After the hook chain, exactly one active dispatch_leases row has
    agent_id == HOOK_INPUT.agent_id, role == 'guardian', worktree_path == _REPO_ROOT.

    Extends case (a). Lease is keyed by base role 'guardian' (not compound
    'guardian:land') per the _EFFECTIVE_LEASE_ROLE derivation in subagent-start.sh.
    """
    db_path, _ = sole_identity_db_with_guardian_lease
    session_id = "s29-b-session"
    agent_id = "LIVE-guardian-agent-id-s29-bbbb"

    _run_pre_agent(
        _pre_agent_payload(
            agent_type="guardian",
            agent_id=agent_id,
            session_id=session_id,
            stage_id="guardian:land",
        ),
        db_path,
    )
    _run_subagent_start(
        _subagent_start_payload(
            agent_type="guardian",
            agent_id=agent_id,
            session_id=session_id,
        ),
        db_path,
    )

    active_leases = _read_active_leases(db_path)
    assert len(active_leases) == 1, (
        f"Expected exactly 1 active claimed lease; got {len(active_leases)}: {active_leases}"
    )
    lease = active_leases[0]
    assert lease["agent_id"] == agent_id, (
        f"dispatch_leases.agent_id={lease['agent_id']!r} != payload {agent_id!r}. "
        "Lease not claimed with payload agent_id."
    )
    # lease role is the base role (guardian), not the compound stage_id
    assert lease["role"] == lease_role_for_stage("guardian:land"), (
        f"dispatch_leases.role={lease['role']!r} — expected "
        f"{lease_role_for_stage('guardian:land')!r} (lease_role_for_stage('guardian:land'))"
    )
    # worktree_path is normalised realpath of _REPO_ROOT
    expected_worktree = os.path.realpath(str(_REPO_ROOT))
    assert lease["worktree_path"] == expected_worktree, (
        f"dispatch_leases.worktree_path={lease['worktree_path']!r} != {expected_worktree!r}"
    )
    assert lease["workflow_id"] == _WORKFLOW_ID, (
        f"dispatch_leases.workflow_id={lease['workflow_id']!r} != {_WORKFLOW_ID!r}"
    )


# ===========================================================================
# Case (c): context role returns guardian identity after seating
# ===========================================================================


def test_c_context_role_returns_guardian_after_seating(
    sole_identity_db_with_guardian_lease: tuple[Path, str],
) -> None:
    """After seating guardian:land, `python3 runtime/cli.py context role` returns
    a role that canonicalizes to 'guardian' and agent_id == HOOK_INPUT.agent_id.

    The exact returned role may be 'guardian:land' (from the marker fallback in
    build_context) or 'guardian' (from the lease). Either is acceptable as long as
    lease_role_for_stage(role) or role itself equals 'guardian'.
    """
    db_path, _ = sole_identity_db_with_guardian_lease
    session_id = "s29-c-session"
    agent_id = "LIVE-guardian-agent-id-s29-cccc"

    _run_pre_agent(
        _pre_agent_payload(
            agent_type="guardian",
            agent_id=agent_id,
            session_id=session_id,
            stage_id="guardian:land",
        ),
        db_path,
    )
    _run_subagent_start(
        _subagent_start_payload(
            agent_type="guardian",
            agent_id=agent_id,
            session_id=session_id,
        ),
        db_path,
    )

    ctx = _run_context_role(db_path)

    returned_role = ctx.get("role", "")
    # Accept compound or base form — canonical check via lease_role_for_stage
    canonical = lease_role_for_stage(returned_role) or returned_role
    assert canonical == "guardian", (
        f"context role returned role={returned_role!r} which canonicalizes to {canonical!r}; "
        "expected 'guardian'. Guardian identity not visible to policy engine after seating."
    )
    assert ctx.get("agent_id") == agent_id, (
        f"context role returned agent_id={ctx.get('agent_id')!r} — expected {agent_id!r}. "
        "Identity resolution returned wrong agent."
    )


# ===========================================================================
# Case (d): Stale reviewer marker cannot override guardian's landing identity
# ===========================================================================


def test_d_stale_prior_marker_cannot_override_guardian(
    sole_identity_db_with_reviewer_then_guardian: tuple[Path, str, str],
) -> None:
    """Run reviewer chain (agent A), then guardian:land chain (agent B).
    After the second chain, ONLY guardian marker is is_active=1.
    Reviewer marker is is_active=0 AND status='replaced'.
    context role sees guardian identity (agent B).

    This DIRECTLY proves Part A of the fix. Before the fix, set_active scoped
    by (role, project_root, workflow_id) so the reviewer marker was untouched
    when guardian:land was seated. After the fix, the project+workflow scoped
    supersede deactivates the reviewer marker.
    """
    db_path, _reviewer_lease_id, _guardian_lease_id = (
        sole_identity_db_with_reviewer_then_guardian
    )
    worktree_path = os.path.realpath(str(_REPO_ROOT))

    # --- Step 1: seat reviewer (agent A) ---
    # Need a reviewer lease to seat reviewer
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        reviewer_lease_id = _issue_lease(conn, "reviewer", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()

    session_reviewer = "s29-d-session-reviewer"
    agent_id_reviewer = "LIVE-reviewer-agent-id-s29-bbbb"

    pre_rc, _, pre_err = _run_pre_agent(
        _pre_agent_payload(
            agent_type="reviewer",
            agent_id=agent_id_reviewer,
            session_id=session_reviewer,
            stage_id="reviewer",
        ),
        db_path,
    )
    assert pre_rc == 0, f"reviewer pre-agent.sh failed: {pre_err}"
    sa_rc, _, sa_err = _run_subagent_start(
        _subagent_start_payload(
            agent_type="reviewer",
            agent_id=agent_id_reviewer,
            session_id=session_reviewer,
        ),
        db_path,
    )
    assert sa_rc == 0, f"reviewer subagent-start.sh failed: {sa_err}"

    # Confirm reviewer is active
    active_after_reviewer = _read_active_markers(db_path)
    reviewer_active = [m for m in active_after_reviewer if m["agent_id"] == agent_id_reviewer]
    assert reviewer_active, (
        f"Reviewer marker not active after chain: active={active_after_reviewer}"
    )

    # --- Step 2: seat guardian:land (agent B) — THIS is the Part A proof point ---
    # Re-issue guardian lease (reviewer's claim revoked the previous one)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _issue_lease(conn, "guardian", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()

    session_guardian = "s29-d-session-guardian"
    agent_id_guardian = "LIVE-guardian-agent-id-s29-aaaa"

    pre_rc2, _, pre_err2 = _run_pre_agent(
        _pre_agent_payload(
            agent_type="guardian",
            agent_id=agent_id_guardian,
            session_id=session_guardian,
            stage_id="guardian:land",
        ),
        db_path,
    )
    assert pre_rc2 == 0, f"guardian pre-agent.sh failed: {pre_err2}"
    sa_rc2, _, sa_err2 = _run_subagent_start(
        _subagent_start_payload(
            agent_type="guardian",
            agent_id=agent_id_guardian,
            session_id=session_guardian,
        ),
        db_path,
    )
    assert sa_rc2 == 0, f"guardian subagent-start.sh failed: {sa_err2}"

    # --- Assertions (Part A proof) ---

    # (d1) Exactly ONE active marker total
    active_after_guardian = _read_active_markers(db_path)
    assert len(active_after_guardian) == 1, (
        f"Expected exactly 1 active marker after guardian:land seating; "
        f"got {len(active_after_guardian)}: {active_after_guardian}. "
        "Bug A: reviewer marker was not superseded by the project-scoped supersede."
    )

    # (d2) The active marker is the guardian one
    guardian_row = active_after_guardian[0]
    assert guardian_row["agent_id"] == agent_id_guardian, (
        f"Active marker agent_id={guardian_row['agent_id']!r} — expected {agent_id_guardian!r}. "
        "Guardian identity is not the active marker."
    )
    assert guardian_row["role"] == "guardian:land", (
        f"Active marker role={guardian_row['role']!r} — expected 'guardian:land'."
    )

    # (d3) Reviewer marker is replaced
    reviewer_row = _read_marker(db_path, agent_id_reviewer)
    assert reviewer_row is not None, "Reviewer marker row must still exist (just deactivated)"
    assert reviewer_row["is_active"] == 0, (
        f"Reviewer marker is still is_active=1 after guardian:land seating. "
        "Part A fix did not supersede the reviewer marker."
    )
    assert reviewer_row["status"] == "replaced", (
        f"Reviewer marker status={reviewer_row['status']!r} — expected 'replaced'. "
        "Supersede must write status='replaced'."
    )

    # (d4) context role sees guardian identity
    ctx = _run_context_role(db_path)
    returned_role = ctx.get("role", "")
    canonical = lease_role_for_stage(returned_role) or returned_role
    assert canonical == "guardian", (
        f"context role returned {returned_role!r} (canonical={canonical!r}) after guardian seating. "
        "Expected guardian identity. Stale reviewer marker may have hijacked resolution."
    )
    assert ctx.get("agent_id") == agent_id_guardian, (
        f"context role agent_id={ctx.get('agent_id')!r} — expected {agent_id_guardian!r}. "
        "Reviewer agent identity leaked into policy resolution."
    )


# ===========================================================================
# Case (e): After guardian stops, next dispatch cycle seats planner cleanly
# ===========================================================================


def test_e_post_guardian_next_dispatch_cycles_cleanly(
    sole_identity_db_with_reviewer_then_guardian: tuple[Path, str, str],
) -> None:
    """After (d) steady state: lifecycle on-stop deactivates guardian:land marker,
    then a fresh planner chain seats cleanly.

    This DIRECTLY proves Part B of the fix. Before the fix, lifecycle.on_stop_by_role
    compared active.role="guardian:land" != agent_type="guardian" → found=False →
    no deactivation. After the fix, both sides canonicalize to "guardian" → deactivated.
    """
    db_path, _, _ = sole_identity_db_with_reviewer_then_guardian
    worktree_path = os.path.realpath(str(_REPO_ROOT))

    # --- Reproduce (d) steady state (reviewer then guardian:land) ---
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _issue_lease(conn, "reviewer", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()

    session_reviewer = "s29-e-session-reviewer"
    agent_id_reviewer = "LIVE-reviewer-agent-id-s29-eeee"

    _run_pre_agent(
        _pre_agent_payload(
            agent_type="reviewer",
            agent_id=agent_id_reviewer,
            session_id=session_reviewer,
            stage_id="reviewer",
        ),
        db_path,
    )
    _run_subagent_start(
        _subagent_start_payload(
            agent_type="reviewer",
            agent_id=agent_id_reviewer,
            session_id=session_reviewer,
        ),
        db_path,
    )

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _issue_lease(conn, "guardian", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()

    session_guardian = "s29-e-session-guardian"
    agent_id_guardian = "LIVE-guardian-agent-id-s29-eeee"

    _run_pre_agent(
        _pre_agent_payload(
            agent_type="guardian",
            agent_id=agent_id_guardian,
            session_id=session_guardian,
            stage_id="guardian:land",
        ),
        db_path,
    )
    _run_subagent_start(
        _subagent_start_payload(
            agent_type="guardian",
            agent_id=agent_id_guardian,
            session_id=session_guardian,
        ),
        db_path,
    )

    # Confirm guardian is active before on-stop
    active_pre_stop = _read_active_markers(db_path)
    assert any(m["agent_id"] == agent_id_guardian for m in active_pre_stop), (
        f"Guardian marker not active before on-stop: {active_pre_stop}"
    )

    # --- Step 2: lifecycle on-stop guardian (Part B proof) ---
    result = _run_lifecycle_on_stop(
        "guardian",
        db_path,
        project_root=str(_REPO_ROOT),
    )

    # (e1) on-stop found and deactivated the guardian marker
    assert result.get("found") is True, (
        f"lifecycle on-stop returned found=False for guardian. "
        f"Result: {result}. "
        "Part B fix failed: active.role='guardian:land' still not matched against "
        "agent_type='guardian' after canonicalization."
    )
    assert result.get("deactivated") is True, (
        f"lifecycle on-stop returned deactivated=False. Result: {result}"
    )

    # (e2) Guardian marker is now is_active=0 status='stopped' stopped_at NOT NULL
    guardian_row = _read_marker(db_path, agent_id_guardian)
    assert guardian_row is not None
    assert guardian_row["is_active"] == 0, (
        f"Guardian marker is still is_active=1 after on-stop. "
        "Part B fix did not deactivate the compound-staged marker."
    )
    assert guardian_row["status"] == "stopped", (
        f"Guardian marker status={guardian_row['status']!r} — expected 'stopped'."
    )
    assert guardian_row["stopped_at"] is not None, (
        "Guardian marker stopped_at is NULL after deactivation."
    )

    # --- Step 3: seat planner (agent C) for the next dispatch cycle ---
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _issue_lease(conn, "planner", worktree_path, _WORKFLOW_ID)
        conn.commit()
    finally:
        conn.close()

    session_planner = "s29-e-session-planner"
    agent_id_planner = "LIVE-planner-agent-id-s29-cccc"

    _run_pre_agent(
        _pre_agent_payload(
            agent_type="planner",
            agent_id=agent_id_planner,
            session_id=session_planner,
            stage_id="planner",
        ),
        db_path,
    )
    _run_subagent_start(
        _subagent_start_payload(
            agent_type="planner",
            agent_id=agent_id_planner,
            session_id=session_planner,
        ),
        db_path,
    )

    # (e3) Exactly one active marker — planner
    active_post_planner = _read_active_markers(db_path)
    assert len(active_post_planner) == 1, (
        f"Expected exactly 1 active marker after planner seating; "
        f"got {len(active_post_planner)}: {active_post_planner}"
    )
    planner_active = active_post_planner[0]
    assert planner_active["agent_id"] == agent_id_planner, (
        f"Active marker agent_id={planner_active['agent_id']!r} — expected {agent_id_planner!r}"
    )
    assert planner_active["role"] == "planner", (
        f"Active marker role={planner_active['role']!r} — expected 'planner'"
    )

    # (e4) context role sees planner identity
    ctx = _run_context_role(db_path)
    returned_role = ctx.get("role", "")
    assert returned_role == "planner", (
        f"context role returned {returned_role!r} — expected 'planner' after planner seating."
    )
    assert ctx.get("agent_id") == agent_id_planner, (
        f"context role agent_id={ctx.get('agent_id')!r} — expected {agent_id_planner!r}."
    )


# ===========================================================================
# Case (f): Unit pin — project-scoped supersede (Part A, no subprocess)
# ===========================================================================


def test_f_markers_set_active_project_scoped_supersede_unit() -> None:
    """Unit-level proof of Part A: set_active(aid-1, 'reviewer', project_root='/p'),
    then set_active(aid-2, 'guardian', project_root='/p') — second call supersedes first.

    Only aid-2 is is_active=1; aid-1 is is_active=0 status='replaced'.
    Uses :memory: SQLite — no on-disk DB.
    """
    conn = connect_memory()
    ensure_schema(conn)

    markers_mod.set_active(conn, "aid-1", "reviewer", project_root="/p")
    # Verify aid-1 is active before the second call
    row1_before = conn.execute(
        "SELECT is_active FROM agent_markers WHERE agent_id = 'aid-1'"
    ).fetchone()
    assert row1_before is not None
    assert row1_before["is_active"] == 1, "aid-1 must be active before second set_active"

    markers_mod.set_active(conn, "aid-2", "guardian", project_root="/p")

    # aid-2 is active
    row2 = conn.execute(
        "SELECT is_active, status FROM agent_markers WHERE agent_id = 'aid-2'"
    ).fetchone()
    assert row2 is not None
    assert row2["is_active"] == 1, "aid-2 must be is_active=1 (the new active marker)"
    assert row2["status"] == "active", f"aid-2 status={row2['status']!r} — expected 'active'"

    # aid-1 is replaced
    row1 = conn.execute(
        "SELECT is_active, status FROM agent_markers WHERE agent_id = 'aid-1'"
    ).fetchone()
    assert row1 is not None
    assert row1["is_active"] == 0, (
        "aid-1 is still is_active=1 after second set_active for the same project_root. "
        "Part A fix did not supersede the reviewer marker. Bug A is still present."
    )
    assert row1["status"] == "replaced", (
        f"aid-1 status={row1['status']!r} — expected 'replaced'. "
        "Supersede must write status='replaced' (not 'stopped')."
    )

    # Only one active row in project /p
    active_count = conn.execute(
        "SELECT COUNT(*) FROM agent_markers WHERE is_active = 1 AND project_root = '/p'"
    ).fetchone()[0]
    assert active_count == 1, (
        f"Expected 1 active marker in project /p; got {active_count}. "
        "One-active-marker-per-project-workflow invariant violated."
    )

    conn.close()


# ===========================================================================
# Case (g): Unit pin — lifecycle on_stop accepts compound stage (Part B)
# ===========================================================================


def test_g_lifecycle_on_stop_accepts_compound_stage() -> None:
    """Unit-level proof of Part B: seat a marker with role='guardian:land',
    then call lifecycle.on_stop_by_role(conn, 'guardian', project_root='/p').
    The function must return found=True, deactivated=True.

    Before the fix, active.role='guardian:land' != agent_type='guardian' →
    found=False. After the fix, both canonicalize to 'guardian' → deactivated.
    Uses :memory: SQLite — no on-disk DB.
    """
    conn = connect_memory()
    ensure_schema(conn)

    markers_mod.set_active(conn, "aid-g", "guardian:land", project_root="/p")

    # Verify the marker is seated
    active_before = markers_mod.get_active(conn, project_root="/p")
    assert active_before is not None, "Marker not found before on-stop"
    assert active_before["role"] == "guardian:land", (
        f"Marker role={active_before['role']!r} — expected 'guardian:land'"
    )

    # Call on_stop_by_role with base role 'guardian' — must match compound 'guardian:land'
    result = lifecycle.on_stop_by_role(conn, "guardian", project_root="/p")

    assert result.get("found") is True, (
        f"on_stop_by_role returned found=False for agent_type='guardian' "
        f"when active marker role is 'guardian:land'. Result: {result}. "
        "Part B fix failed: compound-vs-base equality still broken."
    )
    assert result.get("deactivated") is True, (
        f"on_stop_by_role returned deactivated=False. Result: {result}"
    )

    # DB row must be stopped
    row = conn.execute(
        "SELECT is_active, status, stopped_at FROM agent_markers WHERE agent_id = 'aid-g'"
    ).fetchone()
    assert row is not None
    assert row["is_active"] == 0, (
        "Marker is still is_active=1 after on_stop_by_role. Deactivation did not occur."
    )
    assert row["status"] == "stopped", (
        f"Marker status={row['status']!r} — expected 'stopped'."
    )
    assert row["stopped_at"] is not None, "stopped_at must be set after deactivation."

    conn.close()


# ===========================================================================
# Case (h): Read-only pin — authority_registry canonicalizer maps compound to base
# ===========================================================================


def test_h_authority_registry_canonicalizer_still_maps_compound_to_base() -> None:
    """Pin that authority_registry.lease_role_for_stage maps compound forms correctly.

    This is the read-only dependency proof for Part B: lifecycle.py imports and
    relies on this function. If it drifts, Part B breaks.
    """
    assert lease_role_for_stage("guardian:land") == "guardian", (
        "lease_role_for_stage('guardian:land') must return 'guardian'. "
        "Part B canonicalization depends on this."
    )
    assert lease_role_for_stage("guardian:provision") == "guardian", (
        "lease_role_for_stage('guardian:provision') must return 'guardian'."
    )
    # Base roles that ARE in STAGE_CAPABILITIES map to themselves
    assert lease_role_for_stage("planner") == "planner", (
        "lease_role_for_stage('planner') must return 'planner'."
    )
    assert lease_role_for_stage("implementer") == "implementer", (
        "lease_role_for_stage('implementer') must return 'implementer'."
    )
    assert lease_role_for_stage("reviewer") == "reviewer", (
        "lease_role_for_stage('reviewer') must return 'reviewer'."
    )
    # Plain 'guardian' is not in STAGE_CAPABILITIES (only compound forms are);
    # returns None. The lifecycle.py fix handles this via `or agent_type` fallback.
    result = lease_role_for_stage("guardian")
    # Accept None or "guardian" — the fix works with either via the `or` fallback
    assert result in (None, "guardian"), (
        f"lease_role_for_stage('guardian') returned {result!r} — "
        "expected None or 'guardian'. The lifecycle.py fix uses `or agent_type` "
        "to handle the None case."
    )


# ===========================================================================
# Case (i): Decision ID appears in this module's docstring
# ===========================================================================


def test_i_decision_id_in_module_docstring() -> None:
    """The literal DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001 must
    appear in this test module's __doc__ so reviewers can trace the anchor.
    """
    import tests.runtime.test_harness_agent_id_sole_identity_authority as _this_module

    decision_id = "DEC-CLAUDEX-HARNESS-AGENT-ID-SOLE-IDENTITY-AUTHORITY-001"
    assert _this_module.__doc__ is not None, (
        "Module docstring is None — the @decision annotation was removed."
    )
    assert decision_id in _this_module.__doc__, (
        f"Decision ID {decision_id!r} not found in module docstring. "
        "The @decision annotation must be present for traceability."
    )

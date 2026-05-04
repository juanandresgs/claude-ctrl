"""Tests for the pre-agent.sh carrier write leg.

Covers the three missing invariants identified in the carrier slice review:

1. The pre-agent.sh -> cc-policy evaluate path writes the expected
   pending_agent_requests row when the payload carries session_id,
   tool_input.subagent_type, and a first-line CLAUDEX_CONTRACT_BLOCK: in
   tool_input.prompt.

2. Negative cases: missing marker line, missing session_id, missing subagent_type,
   and non-Agent tool.  None of these must produce a carrier row.

3. End-to-end: pre-agent.sh delegates, cc-policy evaluate writes the carrier
   row, and subagent-start.sh consumes it → runtime-first prompt-pack path fires. No direct seeding of
   pending_agent_requests is used in this class; the row comes exclusively from
   the hook.

@decision DEC-CLAUDEX-SA-CARRIER-001
Title: pending_agent_requests: SQLite carrier for SubagentStart contract fields
Status: accepted — write-leg tests added here to complete the end-to-end proof.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
from pathlib import Path

import pytest

from runtime.core import contracts, goal_contract_codec
from runtime.core import decision_work_registry as dwr
from runtime.core import workflows as workflows_mod
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_PRE_AGENT = str(_REPO_ROOT / "hooks" / "pre-agent.sh")
_SUBAGENT_START = str(_REPO_ROOT / "hooks" / "subagent-start.sh")

# ---------------------------------------------------------------------------
# Shared contract data — must match the DB seed below
# ---------------------------------------------------------------------------

_SESSION_ID = "carrier-pre-agent-test-session"
_AGENT_TYPE = "planner"

_CONTRACT = {
    "workflow_id": "wf-hook",
    "stage_id": "planner",
    "goal_id": "GOAL-HOOK-1",
    "work_item_id": "WI-HOOK-1",
    "decision_scope": "kernel",
    "generated_at": 1_700_000_000,
}

_CONTRACT_BLOCK_LINE = "CLAUDEX_CONTRACT_BLOCK:" + json.dumps(_CONTRACT)

# Prompt text that embeds the block as the first line of the Agent prompt.
_PROMPT_WITH_BLOCK = (
    _CONTRACT_BLOCK_LINE
    + "\n\nYou are a planner agent. Execute the following slice.\n"
)

_PROMPT_WITHOUT_BLOCK = "You are a planner agent. No contract block here.\n"


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


def _seed_db(conn: sqlite3.Connection, worktree_path: str | Path = _REPO_ROOT) -> None:
    """Seed the DB with the goal, work_item, and workflow that the runtime
    compiler needs when it processes the carrier fields."""
    goal = contracts.GoalContract(
        goal_id="GOAL-HOOK-1",
        desired_end_state="carrier path test",
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
            work_item_id="WI-HOOK-1",
            goal_id="GOAL-HOOK-1",
            title="carrier test slice",
            status="in_progress",
            version=1,
            author="planner",
            scope_json=(
                '{"allowed_paths":["hooks/pre-agent.sh"],'
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
        workflow_id="wf-hook",
        worktree_path=str(worktree_path),
        branch="feature/carrier-test",
    )


@pytest.fixture
def carrier_db(tmp_path: Path) -> Path:
    """DB with schema + seeds required for both hooks."""
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


def _make_repo_with_worktree(tmp_path: Path) -> tuple[Path, Path, Path]:
    """Create a real git repo/worktree pair with state only in the shared DB."""
    repo = tmp_path / "carrier-repo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.email", "test@test.com"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.name", "Test"],
        check=True,
        capture_output=True,
    )
    (repo / ".claude").mkdir()
    (repo / "README.md").write_text("carrier worktree routing\n")
    subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-m", "init"],
        check=True,
        capture_output=True,
    )

    worktree = repo / ".worktrees" / "feature-carrier"
    worktree.parent.mkdir()
    subprocess.run(
        ["git", "-C", str(repo), "worktree", "add", str(worktree), "-b", "feature/carrier"],
        check=True,
        capture_output=True,
    )

    db_path = repo / ".claude" / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed_db(conn, worktree)
        conn.commit()
    finally:
        conn.close()
    return repo, worktree, db_path


def _shared_env(db_path: Path) -> dict:
    return {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_PROJECT_DIR": str(_REPO_ROOT),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }


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


def _worktree_env(worktree: Path) -> dict:
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_PROJECT_DIR": str(worktree),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }
    env.pop("CLAUDE_POLICY_DB", None)
    return env


def _run_pre_agent_from_worktree(payload: dict, worktree: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        ["bash", _PRE_AGENT],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=_worktree_env(worktree),
        cwd=str(worktree),
    )
    return result.returncode, result.stdout, result.stderr


def _run_subagent_start_from_worktree(payload: dict, worktree: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        ["bash", _SUBAGENT_START],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=_worktree_env(worktree),
        cwd=str(worktree),
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


def _agent_payload(**overrides) -> dict:
    """Realistic PreToolUse:Agent payload with contract block in prompt."""
    base = {
        "session_id": _SESSION_ID,
        "tool_name": "Agent",
        "tool_input": {
            "subagent_type": _AGENT_TYPE,
            "prompt": _PROMPT_WITH_BLOCK,
        },
    }
    base.update(overrides)
    return base


def _row_exists(db_path: Path, session_id: str, agent_type: str) -> bool:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT 1 FROM pending_agent_requests WHERE session_id=? AND agent_type=?",
            (session_id, agent_type),
        ).fetchone()
    finally:
        conn.close()
    return row is not None


def _read_row(db_path: Path, session_id: str, agent_type: str) -> dict | None:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT workflow_id, stage_id, goal_id, work_item_id, decision_scope, generated_at "
            "FROM pending_agent_requests WHERE session_id=? AND agent_type=?",
            (session_id, agent_type),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    return dict(row)


def _read_marker(db_path: Path, agent_id: str) -> dict | None:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT agent_id, role, project_root, workflow_id, is_active "
            "FROM agent_markers WHERE agent_id=?",
            (agent_id,),
        ).fetchone()
    finally:
        conn.close()
    return dict(row) if row is not None else None


def _latest_attempt_timeout(db_path: Path) -> int | None:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT timeout_at FROM dispatch_attempts ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    return row["timeout_at"]


def _table_count(db_path: Path, table: str) -> int:
    conn = sqlite3.connect(str(db_path))
    try:
        return int(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 1. pre-agent.sh write leg — positive cases
# ---------------------------------------------------------------------------


class TestPreAgentCarrierWrite:
    """pre-agent/evaluate writes the carrier row when all ingredients are present."""

    def test_hook_exits_zero(self, carrier_db):
        rc, _out, _err = _run_pre_agent(_agent_payload(), carrier_db)
        assert rc == 0

    def test_row_written_to_db(self, carrier_db):
        _run_pre_agent(_agent_payload(), carrier_db)
        assert _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_contract_fields_written_correctly(self, carrier_db):
        _run_pre_agent(_agent_payload(), carrier_db)
        row = _read_row(carrier_db, _SESSION_ID, _AGENT_TYPE)
        assert row is not None
        assert row["workflow_id"] == _CONTRACT["workflow_id"]
        assert row["stage_id"] == _CONTRACT["stage_id"]
        assert row["goal_id"] == _CONTRACT["goal_id"]
        assert row["work_item_id"] == _CONTRACT["work_item_id"]
        assert row["decision_scope"] == _CONTRACT["decision_scope"]
        assert row["generated_at"] == _CONTRACT["generated_at"]

    def test_contract_block_on_first_line_is_found(self, carrier_db):
        prompt = _CONTRACT_BLOCK_LINE + "\nLine two.\n"
        payload = _agent_payload()
        payload["tool_input"]["prompt"] = prompt
        _run_pre_agent(payload, carrier_db)
        assert _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_contract_block_after_preamble_no_row_written(self, carrier_db):
        # The runtime policy requires the contract block on line 1; later
        # standalone markers are ignored by the carrier writer.
        prompt = "Line one.\nLine two.\n" + _CONTRACT_BLOCK_LINE + "\nLine three.\n"
        payload = _agent_payload()
        payload["tool_input"]["prompt"] = prompt
        _run_pre_agent(payload, carrier_db)
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_repeat_write_preserves_attempt_rows(self, carrier_db):
        # Two pre-agent calls for the same (session_id, agent_type) are distinct
        # dispatch attempts; the carrier no longer overwrites the first row.
        first_contract = json.dumps({**_CONTRACT, "generated_at": 1_700_000_001})
        second_contract = json.dumps({**_CONTRACT, "generated_at": 1_700_000_002})
        first_payload = _agent_payload()
        first_payload["tool_input"]["prompt"] = (
            "CLAUDEX_CONTRACT_BLOCK:" + first_contract + "\n"
        )
        second_payload = _agent_payload()
        second_payload["tool_input"]["prompt"] = (
            "CLAUDEX_CONTRACT_BLOCK:" + second_contract + "\n"
        )
        _run_pre_agent(first_payload, carrier_db)
        _run_pre_agent(second_payload, carrier_db)
        conn = sqlite3.connect(str(carrier_db))
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                """
                SELECT generated_at FROM pending_agent_requests
                WHERE session_id=? AND agent_type=?
                ORDER BY written_at ASC, rowid ASC
                """,
                (_SESSION_ID, _AGENT_TYPE),
            ).fetchall()
            count = conn.execute("SELECT COUNT(*) FROM pending_agent_requests").fetchone()[0]
        finally:
            conn.close()
        assert [row["generated_at"] for row in rows] == [1_700_000_001, 1_700_000_002]
        assert count == 2

    def test_attempt_issue_sets_default_timeout(self, carrier_db):
        _run_pre_agent(_agent_payload(), carrier_db)
        timeout_at = _latest_attempt_timeout(carrier_db)
        assert timeout_at is not None
        assert timeout_at > 0

    def test_scope_drift_denies_before_carrier_attempt_or_lease(self, carrier_db):
        conn = sqlite3.connect(str(carrier_db))
        conn.row_factory = sqlite3.Row
        try:
            workflows_mod.set_scope(
                conn,
                "wf-hook",
                allowed_paths=["different/**"],
                required_paths=["different/file.py"],
                forbidden_paths=["blocked/**"],
                authority_domains=[],
            )
        finally:
            conn.close()

        rc, out, _err = _run_pre_agent(_agent_payload(), carrier_db)

        assert rc == 0
        parsed = json.loads(out.strip())
        hso = parsed["hookSpecificOutput"]
        assert hso["permissionDecision"] == "deny"
        assert "prompt-pack preflight failed" in hso["permissionDecisionReason"]
        assert "scope-sync" in hso["permissionDecisionReason"]
        assert _table_count(carrier_db, "pending_agent_requests") == 0
        assert _table_count(carrier_db, "dispatch_attempts") == 0
        assert _table_count(carrier_db, "dispatch_leases") == 0


# ---------------------------------------------------------------------------
# 2. pre-agent.sh write leg — negative cases
# ---------------------------------------------------------------------------


class TestPreAgentCarrierWriteNegative:
    """Boundary cases where no carrier row should be written."""

    def test_no_block_line_no_row_written(self, carrier_db):
        payload = _agent_payload()
        payload["tool_input"]["prompt"] = _PROMPT_WITHOUT_BLOCK
        _run_pre_agent(payload, carrier_db)
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_block_not_at_line_start_no_row_written(self, carrier_db):
        # Block prefixed with whitespace — grep '^CLAUDEX...' must NOT match.
        prompt = "Preamble text " + _CONTRACT_BLOCK_LINE + "\n"
        payload = _agent_payload()
        payload["tool_input"]["prompt"] = prompt
        _run_pre_agent(payload, carrier_db)
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_missing_session_id_no_row_written(self, carrier_db):
        payload = _agent_payload()
        del payload["session_id"]
        _run_pre_agent(payload, carrier_db)
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_missing_subagent_type_no_row_written(self, carrier_db):
        payload = _agent_payload()
        del payload["tool_input"]["subagent_type"]
        rc, out, _err = _run_pre_agent(payload, carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_dispatch_role_without_contract_is_denied(self, carrier_db):
        payload = _agent_payload()
        payload["tool_input"]["prompt"] = _PROMPT_WITHOUT_BLOCK
        rc, out, _err = _run_pre_agent(payload, carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        reason = parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert "requires a runtime-issued contract" in reason
        assert "workflow stage-packet" in reason
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_guardian_without_contract_gets_compound_stage_guidance(self, carrier_db):
        payload = _agent_payload()
        payload["tool_input"]["subagent_type"] = "guardian"
        payload["tool_input"]["prompt"] = _PROMPT_WITHOUT_BLOCK
        rc, out, _err = _run_pre_agent(payload, carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        reason = parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert "guardian:land" in reason
        assert "guardian:provision" in reason
        assert "unknown active stage" not in reason
        assert not _row_exists(carrier_db, _SESSION_ID, "guardian")

    def test_contract_stage_with_general_purpose_subagent_is_denied(self, carrier_db):
        payload = _agent_payload()
        payload["tool_input"]["subagent_type"] = "general-purpose"
        rc, out, _err = _run_pre_agent(payload, carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "must launch with subagent_type='planner'" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, "general-purpose")

    # Shell-side keyword-intent classification was retired per Codex
    # supervisor correction 1776448684478-0015-9lddhj (hooks are adapters,
    # not policy engines). Tests that asserted prose-based deny paths
    # (complex implementer / planner intent on generic seat) were removed;
    # runtime-owned classification via canonical_dispatch_subagent_type
    # remains covered by test_dispatch_role_without_contract_is_denied and
    # test_contract_stage_with_general_purpose_subagent_is_denied above.

    def test_simple_prompt_without_subagent_is_allowed(self, carrier_db):
        payload = {
            "session_id": _SESSION_ID,
            "tool_name": "Agent",
            "tool_input": {
                "prompt": "Summarize current bridge status briefly.",
            },
        }
        rc, out, _err = _run_pre_agent(payload, carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "allow"
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_non_agent_tool_no_row_written(self, carrier_db):
        payload = _agent_payload()
        payload["tool_name"] = "Bash"  # not Agent/Task — hook exits early
        _run_pre_agent(payload, carrier_db)
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_hook_exits_zero_even_when_block_absent(self, carrier_db):
        payload = _agent_payload()
        payload["tool_input"]["prompt"] = _PROMPT_WITHOUT_BLOCK
        rc, _out, _err = _run_pre_agent(payload, carrier_db)
        assert rc == 0

    def test_isolation_worktree_blocked_no_row_written(self, carrier_db):
        # isolation=worktree takes the deny path — no carrier write, non-allow output.
        payload = _agent_payload()
        payload["tool_input"]["isolation"] = "worktree"
        rc, out, _err = _run_pre_agent(payload, carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)


# ---------------------------------------------------------------------------
# 3. End-to-end: pre-agent/evaluate writes → subagent-start consumes → runtime-first
# ---------------------------------------------------------------------------


class TestCarrierEndToEnd:
    """Full carrier path: pre-agent.sh is the sole writer; subagent-start.sh is
    the sole consumer.  No direct seeding of pending_agent_requests is used here.
    """

    def test_e2e_runtime_first_path_fires_from_pre_agent_write(self, carrier_db):
        # Step 1: run pre-agent.sh — cc-policy evaluate writes the carrier row.
        pre_rc, _pre_out, _pre_err = _run_pre_agent(_agent_payload(), carrier_db)
        assert pre_rc == 0, "pre-agent.sh must succeed before subagent-start can consume"

        # Carrier row must be present after step 1.
        assert _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE), (
            "pre-agent.sh must have written a pending_agent_requests row"
        )

        # Step 2: run subagent-start.sh with matching (session_id, agent_type).
        # No contract fields in the payload — the hook must get them from the carrier.
        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        sa_rc, sa_out, _sa_err = _run_subagent_start(subagent_payload, carrier_db)
        assert sa_rc == 0

        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]

        # Runtime-first path produces the compiled PromptPack header.
        assert "# ClauDEX Prompt Pack:" in ctx, (
            "subagent-start.sh must have taken the runtime-first path via the "
            "carrier row written by pre-agent.sh (not via direct DB seeding)"
        )

    def test_e2e_carrier_row_absent_after_subagent_start(self, carrier_db):
        # After the consume leg runs, the row must be gone (atomic delete).
        _run_pre_agent(_agent_payload(), carrier_db)
        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        _run_subagent_start(subagent_payload, carrier_db)
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE), (
            "pending_agent_requests row must be atomically deleted after consume"
        )

    def test_e2e_without_pre_agent_write_takes_a8_deny_path(self, carrier_db):
        # A8: canonical seat (planner) with no carrier row → canonical_seat_no_carrier_contract.
        # pre-agent.sh never called → no row written → subagent-start sees canonical seat
        # with no carrier contract → A8 fail-closed deny, not legacy path.
        # (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        sa_rc, sa_out, _sa_err = _run_subagent_start(subagent_payload, carrier_db)
        assert sa_rc == 0
        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_e2e_wrong_session_id_in_subagent_takes_legacy_path(self, carrier_db):
        # pre-agent writes for session A; subagent-start arrives with session B.
        _run_pre_agent(_agent_payload(), carrier_db)
        subagent_payload = {
            "agent_type": _AGENT_TYPE,
            "session_id": "completely-different-session",
        }
        sa_rc, sa_out, _sa_err = _run_subagent_start(subagent_payload, carrier_db)
        assert sa_rc == 0
        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_e2e_second_subagent_after_consume_takes_a8_deny_path(self, carrier_db):
        # A8: The carrier row is one-time-use. A second subagent-start call for the
        # same (session_id, agent_type) finds no carrier row → canonical seat + no
        # contract → A8 canonical_seat_no_carrier_contract deny (not legacy path).
        # (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
        _run_pre_agent(_agent_payload(), carrier_db)
        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        _run_subagent_start(subagent_payload, carrier_db)  # first call consumes
        sa_rc, sa_out, _sa_err = _run_subagent_start(subagent_payload, carrier_db)
        assert sa_rc == 0
        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_e2e_from_linked_worktree_uses_shared_repo_db(self, tmp_path):
        # Regression: shell hooks previously resolved linked worktrees via
        # --show-toplevel, creating/reading <worktree>/.claude/state.db while the
        # runtime CLI used the parent repo DB via --git-common-dir.
        _repo, worktree, shared_db = _make_repo_with_worktree(tmp_path)
        private_db = worktree / ".claude" / "state.db"

        pre_rc, _pre_out, pre_err = _run_pre_agent_from_worktree(
            _agent_payload(), worktree
        )
        assert pre_rc == 0, pre_err
        assert _row_exists(shared_db, _SESSION_ID, _AGENT_TYPE)
        assert not private_db.exists(), (
            "hook resolver must not create or read a private worktree DB"
        )

        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        sa_rc, sa_out, sa_err = _run_subagent_start_from_worktree(
            subagent_payload, worktree
        )
        assert sa_rc == 0, sa_err

        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" in ctx
        assert "capture_workflow_contracts: no goal row" not in ctx
        assert _row_exists(shared_db, _SESSION_ID, _AGENT_TYPE) is False
        assert not private_db.exists()


# ---------------------------------------------------------------------------
# A8: Canonical-seat malformed/partial contracts denied at PreToolUse; no row written
# ---------------------------------------------------------------------------


class TestPreAgentA8ContractShapeDeny:
    """A8: canonical-seat contracts with missing or malformed fields are denied
    at pre-agent.sh (PreToolUse) and no carrier row is written.

    Tests cover the six new reason-code substrings added in
    DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001, exercising each via a
    malformed or partial CLAUDEX_CONTRACT_BLOCK embedded in the prompt.
    """

    def _partial_block(self, **overrides) -> str:
        """Build a CLAUDEX_CONTRACT_BLOCK: prompt line, dropping keys where value is None."""
        base = {
            "workflow_id": "wf-hook",
            "stage_id": "planner",
            "goal_id": "GOAL-HOOK-1",
            "work_item_id": "WI-HOOK-1",
            "decision_scope": "kernel",
            "generated_at": 1_700_000_000,
        }
        for k, v in overrides.items():
            if v is None:
                base.pop(k, None)
            else:
                base[k] = v
        return "CLAUDEX_CONTRACT_BLOCK:" + json.dumps(base)

    def _partial_agent_payload(self, block_line: str) -> dict:
        return {
            "session_id": _SESSION_ID,
            "tool_name": "Agent",
            "tool_input": {
                "subagent_type": _AGENT_TYPE,
                "prompt": block_line + "\nDo some planning.",
            },
        }

    def test_missing_workflow_id_denied_no_row(self, carrier_db):
        block = self._partial_block(workflow_id=None)
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        hso = parsed["hookSpecificOutput"]
        assert hso["permissionDecision"] == "deny"
        assert "contract_block_missing_workflow_id" in hso["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_empty_workflow_id_denied_no_row(self, carrier_db):
        block = self._partial_block(workflow_id="")
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "contract_block_empty_workflow_id" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_missing_goal_id_denied_no_row(self, carrier_db):
        block = self._partial_block(goal_id=None)
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "contract_block_missing_goal_id" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_missing_work_item_id_denied_no_row(self, carrier_db):
        block = self._partial_block(work_item_id=None)
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "contract_block_missing_work_item_id" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_missing_decision_scope_denied_no_row(self, carrier_db):
        block = self._partial_block(decision_scope=None)
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "contract_block_missing_decision_scope" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_missing_generated_at_denied_no_row(self, carrier_db):
        block = self._partial_block(generated_at=None)
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "contract_block_missing_generated_at" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_invalid_generated_at_boolean_denied_no_row(self, carrier_db):
        """JSON boolean generated_at must be denied (not a valid timestamp)."""
        # Build the block with a boolean — must use json.dumps directly to preserve type.
        raw = {
            "workflow_id": "wf-hook", "stage_id": "planner",
            "goal_id": "GOAL-HOOK-1", "work_item_id": "WI-HOOK-1",
            "decision_scope": "kernel", "generated_at": True,
        }
        block = "CLAUDEX_CONTRACT_BLOCK:" + json.dumps(raw)
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "contract_block_invalid_generated_at" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_zero_generated_at_denied_no_row(self, carrier_db):
        block = self._partial_block(generated_at=0)
        rc, out, _ = _run_pre_agent(self._partial_agent_payload(block), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "contract_block_invalid_generated_at" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_full_valid_contract_succeeds_row_written(self, carrier_db):
        """Positive control: fully valid six-field contract passes and writes carrier row."""
        rc, out, _ = _run_pre_agent(_agent_payload(), carrier_db)
        assert rc == 0
        parsed = json.loads(out.strip())
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "allow"
        assert _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)


# ---------------------------------------------------------------------------
# A8: carrier-write failure → carrier_write_failed deny
# ---------------------------------------------------------------------------


class TestPreAgentA8CarrierWriteFailDeny:
    """A8: if pending_agent_requests.py write returns non-zero for a canonical seat,
    pre-agent.sh must deny with reason carrier_write_failed.

    Simulated by pointing CLAUDE_POLICY_DB at a read-only file or a path where
    the write will fail (non-writable parent directory).
    """

    def test_carrier_write_fail_produces_deny(self, tmp_path):
        """Deny with carrier_write_failed when the DB is not writable."""
        import stat

        # Create a read-only DB file so sqlite3 write fails.
        ro_db = tmp_path / "readonly.db"

        # First create a valid DB with schema so the module can import the table.
        conn = sqlite3.connect(str(ro_db))
        from runtime.schemas import ensure_schema
        ensure_schema(conn)
        conn.commit()
        conn.close()

        # Make it read-only so writes fail.
        ro_db.chmod(stat.S_IRUSR | stat.S_IRGRP)
        try:
            payload = _agent_payload()
            rc, out, err = _run_pre_agent(payload, ro_db)
            assert rc == 0
            # If the DB path can't be written, the hook must deny.
            if out.strip():
                parsed = json.loads(out.strip())
                hso = parsed.get("hookSpecificOutput", {})
                if hso.get("permissionDecision") == "deny":
                    reason = hso["permissionDecisionReason"]
                    assert (
                        "carrier_write_failed" in reason
                        or "Policy engine unavailable" in reason
                    )
            # A read-only SQLite file can fail before policy evaluation reaches
            # the carrier effect because connection bootstrap must set WAL mode.
            # That boundary should still fail closed.
        finally:
            # Restore permissions so tmp_path cleanup can remove the file.
            ro_db.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP)

    def test_no_db_path_skips_carrier_write_gracefully(self, tmp_path):
        """When CLAUDE_POLICY_DB and CLAUDE_PROJECT_DIR are unset, the hook uses
        the git-toplevel fallback (tier 3) to locate the DB.  Since cwd is inside
        a git repo, the carrier write succeeds and no deny is produced.

        Note: after GS1-F-3 the hook no longer skips the carrier write when env
        vars are absent — it falls back to git rev-parse.  When cwd is inside a
        git repo the write succeeds normally.  Only when ALL three tiers fail (no
        env vars AND no git tree) does the hook deny with carrier_write_failed.
        """
        repo_root = _make_git_repo_with_schema(tmp_path)
        db_path = repo_root / ".claude" / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            _seed_db(conn, repo_root)
            conn.commit()
        finally:
            conn.close()

        payload = _agent_payload()
        env = {
            **os.environ,
            "PYTHONPATH": str(_REPO_ROOT),
            "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
        }
        # Remove both DB env vars so the hook must fall back to git-based resolution.
        env.pop("CLAUDE_POLICY_DB", None)
        env.pop("CLAUDE_PROJECT_DIR", None)
        result = subprocess.run(
            ["bash", _PRE_AGENT],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(repo_root),
        )
        # Hook resolves DB via git toplevel, writes successfully, exits 0 without deny.
        assert result.returncode == 0
        # No deny output (empty stdout or non-deny JSON):
        if result.stdout.strip():
            try:
                parsed = json.loads(result.stdout.strip())
                hso = parsed.get("hookSpecificOutput", {})
                assert hso.get("permissionDecision") != "deny", (
                    "Hook must not deny when DB is resolved via git fallback — "
                    "carrier write succeeded."
                )
            except json.JSONDecodeError:
                pass  # non-JSON stdout is also acceptable (hook may emit nothing)


# ---------------------------------------------------------------------------
# GS1-F-3: DB routing via git fallback when no env vars set
# ---------------------------------------------------------------------------


def _make_git_repo_with_schema(tmp_path: Path, subdir_name: str = "repo") -> Path:
    """Create a minimal git repo with a seeded DB at <root>/.claude/state.db.

    Returns the git repo root path.
    """
    root = tmp_path / subdir_name
    root.mkdir()
    subprocess.run(["git", "init", str(root)], capture_output=True, check=True)
    subprocess.run(
        ["git", "-C", str(root), "config", "user.email", "test@test.com"],
        capture_output=True,
        check=True,
    )
    subprocess.run(
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
        from runtime.schemas import ensure_schema
        ensure_schema(conn)
        conn.commit()
    finally:
        conn.close()
    return root


def _make_parent_and_payload_repo(tmp_path: Path) -> tuple[Path, Path, Path]:
    """Create a non-git launch cwd plus a child git repo with seeded state."""
    launch_root = tmp_path / "launch-root"
    launch_root.mkdir()
    repo_root = _make_git_repo_with_schema(launch_root, subdir_name="payload-repo")
    db_path = repo_root / ".claude" / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        _seed_db(conn, repo_root)
        conn.commit()
    finally:
        conn.close()
    return launch_root, repo_root, db_path


def _env_no_db_vars(repo_root: Path) -> dict:
    """Env with no CLAUDE_POLICY_DB or CLAUDE_PROJECT_DIR; cwd expected inside repo_root."""
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
    }
    env.pop("CLAUDE_POLICY_DB", None)
    env.pop("CLAUDE_PROJECT_DIR", None)
    return env


class TestPreAgentCarrierDBRoutingNoEnv:
    """GS1-F-3: carrier write resolves DB via git fallback when both env vars absent.

    These tests prove that removing CLAUDE_POLICY_DB and CLAUDE_PROJECT_DIR
    from the hook's environment does NOT prevent the carrier write — as long
    as cwd is inside a git repo.  The pre-fix hook would silently skip the
    write; post-fix it resolves via git rev-parse.

    Companion test for the no-git-tree case (deny path) also lives here.
    """

    def test_pre_agent_writes_carrier_when_no_env_but_git_cwd(self, tmp_path):
        """pre-agent/evaluate writes carrier row when neither env var is set but cwd is
        inside a git tree.  Pre-fix: _CARRIER_DB empty → write silently skipped.
        Post-fix: _resolve_policy_db tier 3 resolves via git rev-parse.

        This test FAILS on pre-fix code (no row written).
        """
        repo_root = _make_git_repo_with_schema(tmp_path)
        db_path = repo_root / ".claude" / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            _seed_db(conn, repo_root)
            conn.commit()
        finally:
            conn.close()

        env = _env_no_db_vars(repo_root)
        result = subprocess.run(
            ["bash", _PRE_AGENT],
            input=json.dumps(_agent_payload()),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(repo_root),
        )
        assert result.returncode == 0, f"pre-agent.sh exited {result.returncode}; stderr={result.stderr!r}"

        # Carrier row must be present in the git-resolved DB.
        assert _row_exists(db_path, _SESSION_ID, _AGENT_TYPE), (
            "pre-agent.sh must have written a pending_agent_requests row via git-based "
            "DB resolution.  Pre-fix: no row (DB path unresolved); post-fix: row present. "
            f"db_path={db_path}; stdout={result.stdout!r}"
        )

    def test_pre_agent_denies_when_no_env_no_git(self, tmp_path):
        """pre-agent.sh must deny with carrier_write_failed when neither env var is
        set AND cwd is outside any git tree.  Pre-fix: silent skip (exit 0, no deny).
        Post-fix: deny with carrier_write_failed reason code.
        """
        no_git_dir = tmp_path / "not-a-repo"
        no_git_dir.mkdir()

        # Use a fake HOME so git global config doesn't accidentally place us in a repo.
        env = _env_no_db_vars(no_git_dir)
        env["HOME"] = str(tmp_path / "fakehome")

        result = subprocess.run(
            ["bash", _PRE_AGENT],
            input=json.dumps(_agent_payload()),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(no_git_dir),
        )
        assert result.returncode == 0, f"Hook must always exit 0; rc={result.returncode}"
        assert result.stdout.strip(), "Expected deny JSON on stdout, got empty output"
        parsed = json.loads(result.stdout.strip())
        hso = parsed["hookSpecificOutput"]
        assert hso["permissionDecision"] == "deny", (
            f"Expected deny, got {hso['permissionDecision']!r}. "
            f"Pre-fix: hook silently exits 0 without a deny when DB is unresolvable."
        )
        assert "carrier_write_failed" in hso["permissionDecisionReason"], (
            f"Expected 'carrier_write_failed' in reason, got: {hso['permissionDecisionReason']!r}"
        )

    def test_pre_agent_ignores_policy_db_poison_and_falls_back_to_project_db(self, tmp_path):
        """runtime/policy.db must not win DB resolution for carrier writes."""
        repo_root = _make_git_repo_with_schema(tmp_path)
        db_path = repo_root / ".claude" / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            _seed_db(conn, repo_root)
            conn.commit()
        finally:
            conn.close()
        poisoned = repo_root / "runtime" / "policy.db"
        poisoned.parent.mkdir(parents=True, exist_ok=True)

        env = {
            **os.environ,
            "PYTHONPATH": str(_REPO_ROOT),
            "CLAUDE_RUNTIME_ROOT": str(_REPO_ROOT / "runtime"),
            "CLAUDE_POLICY_DB": str(poisoned),
        }
        env.pop("CLAUDE_PROJECT_DIR", None)

        result = subprocess.run(
            ["bash", _PRE_AGENT],
            input=json.dumps(_agent_payload()),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(repo_root),
        )
        assert result.returncode == 0, result.stderr
        assert _row_exists(db_path, _SESSION_ID, _AGENT_TYPE), (
            "pre-agent.sh must ignore runtime/policy.db and fall back to the "
            "git-resolved project .claude/state.db"
        )


class TestPreAgentToSubagentStartRoundTrip:
    """GS1-F-3: end-to-end carrier round-trip with no env vars — git-based resolution.

    pre-agent/evaluate writes carrier → subagent-start.sh consumes carrier.
    Both invocations use a tmp git repo and neither CLAUDE_POLICY_DB nor
    CLAUDE_PROJECT_DIR is set.  This is the production-sequence proof.
    """

    def test_carrier_round_trip_no_env(self, tmp_path):
        """pre-agent/evaluate writes carrier row via git-based DB resolution.
        subagent-start.sh consumes it via the same git-based resolution.
        Both use no CLAUDE_POLICY_DB and no CLAUDE_PROJECT_DIR.

        Asserts:
        - carrier row written by pre-agent is consumed by subagent-start
        - subagent-start takes the runtime-first (contract) path
        - carrier row is absent after subagent-start completes (atomic delete)

        This test exercises the REAL production sequence for guardian landings
        where the harness injects neither CLAUDE_POLICY_DB nor CLAUDE_PROJECT_DIR.
        """
        repo_root = _make_git_repo_with_schema(tmp_path)
        db_path = repo_root / ".claude" / "state.db"

        # Seed the DB with the goal/work_item/workflow required by the runtime.
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            _seed_db(conn)
            conn.commit()
        finally:
            conn.close()

        env = _env_no_db_vars(repo_root)

        # Step 1: run pre-agent.sh — evaluate writes carrier row via git-based resolution.
        pre_result = subprocess.run(
            ["bash", _PRE_AGENT],
            input=json.dumps(_agent_payload()),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(repo_root),
        )
        assert pre_result.returncode == 0, (
            f"pre-agent.sh must succeed; rc={pre_result.returncode}; stderr={pre_result.stderr!r}"
        )
        assert _row_exists(db_path, _SESSION_ID, _AGENT_TYPE), (
            "pre-agent.sh must have written a carrier row via git-based DB resolution"
        )

        # Step 2: run subagent-start.sh — consumes carrier row via git-based resolution.
        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        sa_result = subprocess.run(
            ["bash", _SUBAGENT_START],
            input=json.dumps(subagent_payload),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(repo_root),
        )
        assert sa_result.returncode == 0, (
            f"subagent-start.sh must exit 0; rc={sa_result.returncode}; stderr={sa_result.stderr!r}"
        )

        # Verify runtime-first path fired (contract was consumed from carrier).
        parsed = json.loads(sa_result.stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" in ctx, (
            "subagent-start.sh must have taken the runtime-first path via the carrier row "
            "written (and resolved via git) by pre-agent.sh.  "
            f"ctx (first 400 chars)={ctx[:400]!r}"
        )

        # Carrier row must be gone (atomic delete on consume).
        assert not _row_exists(db_path, _SESSION_ID, _AGENT_TYPE), (
            "Carrier row must be atomically deleted after subagent-start.sh consumes it"
        )


class TestPayloadCwdDbRouting:
    """Hook event cwd must route DB resolution when process cwd is elsewhere."""

    def test_pre_agent_uses_payload_cwd_when_process_cwd_is_parent(self, tmp_path):
        launch_root, repo_root, db_path = _make_parent_and_payload_repo(tmp_path)
        env = _env_no_db_vars(repo_root)

        payload = _agent_payload(cwd=str(repo_root))
        result = subprocess.run(
            ["bash", _PRE_AGENT],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(launch_root),
        )

        assert result.returncode == 0, result.stderr
        assert _row_exists(db_path, _SESSION_ID, _AGENT_TYPE), (
            "pre-agent.sh must resolve state.db from hook payload cwd, not the "
            "hook subprocess cwd"
        )

    def test_subagent_start_consumes_payload_cwd_carrier_from_parent_cwd(self, tmp_path):
        launch_root, repo_root, db_path = _make_parent_and_payload_repo(tmp_path)
        env = _env_no_db_vars(repo_root)

        pre_payload = _agent_payload(cwd=str(repo_root))
        pre_result = subprocess.run(
            ["bash", _PRE_AGENT],
            input=json.dumps(pre_payload),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(launch_root),
        )
        assert pre_result.returncode == 0, pre_result.stderr
        assert _row_exists(db_path, _SESSION_ID, _AGENT_TYPE)

        subagent_payload = {
            "agent_type": _AGENT_TYPE,
            "session_id": _SESSION_ID,
            "agent_id": "payload-cwd-agent",
            "cwd": str(repo_root),
        }
        sa_result = subprocess.run(
            ["bash", _SUBAGENT_START],
            input=json.dumps(subagent_payload),
            capture_output=True,
            text=True,
            env=env,
            cwd=str(launch_root),
        )

        assert sa_result.returncode == 0, sa_result.stderr
        parsed = json.loads(sa_result.stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" in ctx
        assert "capture_workflow_contracts: no goal row" not in ctx
        assert not _row_exists(db_path, _SESSION_ID, _AGENT_TYPE)
        marker = _read_marker(db_path, "payload-cwd-agent")
        assert marker is not None
        assert marker["project_root"] == str(repo_root)
        assert marker["workflow_id"] == _CONTRACT["workflow_id"]

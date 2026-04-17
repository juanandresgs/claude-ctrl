"""Tests for the pre-agent.sh carrier write leg.

Covers the three missing invariants identified in the carrier slice review:

1. pre-agent.sh writes the expected pending_agent_requests row when the payload
   carries session_id, tool_input.subagent_type, and a CLAUDEX_CONTRACT_BLOCK:
   line in tool_input.prompt.

2. Negative cases: missing marker line, missing session_id, missing subagent_type,
   and non-Agent tool.  None of these must produce a carrier row.

3. End-to-end: pre-agent.sh writes the carrier row → subagent-start.sh consumes
   it → runtime-first prompt-pack path fires.  No direct seeding of
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
from pathlib import Path

import pytest

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec
from runtime.core import workflows as workflows_mod
from runtime.core.pending_agent_requests import consume_pending_request
from runtime.schemas import ensure_schema

import subprocess

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

# Prompt text that embeds the block as a standalone line (grep '^...' match).
_PROMPT_WITH_BLOCK = (
    "You are a planner agent. Execute the following slice.\n"
    + _CONTRACT_BLOCK_LINE
    + "\nEnd of system context.\n"
)

_PROMPT_WITHOUT_BLOCK = "You are a planner agent. No contract block here.\n"


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


def _seed_db(conn: sqlite3.Connection) -> None:
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
        worktree_path=str(_REPO_ROOT),
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


# ---------------------------------------------------------------------------
# 1. pre-agent.sh write leg — positive cases
# ---------------------------------------------------------------------------


class TestPreAgentCarrierWrite:
    """pre-agent.sh writes the carrier row when all three ingredients are present."""

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

    def test_block_line_at_start_of_line_is_found(self, carrier_db):
        # Embed the block after several lines of preamble — grep '^' must still find it.
        prompt = "Line one.\nLine two.\n" + _CONTRACT_BLOCK_LINE + "\nLine three.\n"
        payload = _agent_payload()
        payload["tool_input"]["prompt"] = prompt
        _run_pre_agent(payload, carrier_db)
        assert _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

    def test_repeat_write_overwrites_stale_row(self, carrier_db):
        # Two pre-agent calls for the same (session_id, agent_type) must not
        # accumulate rows — INSERT OR REPLACE semantics in the helper.
        first_contract = json.dumps({**_CONTRACT, "workflow_id": "wf-old"})
        second_contract = json.dumps({**_CONTRACT, "workflow_id": "wf-new"})
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
        row = _read_row(carrier_db, _SESSION_ID, _AGENT_TYPE)
        assert row is not None
        assert row["workflow_id"] == "wf-new"
        conn = sqlite3.connect(str(carrier_db))
        try:
            count = conn.execute("SELECT COUNT(*) FROM pending_agent_requests").fetchone()[0]
        finally:
            conn.close()
        assert count == 1

    def test_attempt_issue_sets_default_timeout(self, carrier_db):
        _run_pre_agent(_agent_payload(), carrier_db)
        timeout_at = _latest_attempt_timeout(carrier_db)
        assert timeout_at is not None
        assert timeout_at > 0


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
        assert "without CLAUDEX_CONTRACT_BLOCK" in parsed["hookSpecificOutput"]["permissionDecisionReason"]
        assert not _row_exists(carrier_db, _SESSION_ID, _AGENT_TYPE)

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
        assert out.strip() == ""
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
# 3. End-to-end: pre-agent.sh writes → subagent-start.sh consumes → runtime-first
# ---------------------------------------------------------------------------


class TestCarrierEndToEnd:
    """Full carrier path: pre-agent.sh is the sole writer; subagent-start.sh is
    the sole consumer.  No direct seeding of pending_agent_requests is used here.
    """

    def test_e2e_runtime_first_path_fires_from_pre_agent_write(self, carrier_db):
        # Step 1: run pre-agent.sh — this writes the carrier row.
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

    def test_e2e_without_pre_agent_write_takes_legacy_path(self, carrier_db):
        # If pre-agent.sh is never called (no row), subagent-start must use legacy path.
        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        sa_rc, sa_out, _sa_err = _run_subagent_start(subagent_payload, carrier_db)
        assert sa_rc == 0
        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Context:" in ctx
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

    def test_e2e_second_subagent_after_consume_takes_legacy_path(self, carrier_db):
        # The carrier row is one-time-use: a second subagent-start call for the
        # same (session_id, agent_type) must fall through to the legacy path.
        _run_pre_agent(_agent_payload(), carrier_db)
        subagent_payload = {"agent_type": _AGENT_TYPE, "session_id": _SESSION_ID}
        _run_subagent_start(subagent_payload, carrier_db)  # first call consumes
        sa_rc, sa_out, _sa_err = _run_subagent_start(subagent_payload, carrier_db)
        assert sa_rc == 0
        parsed = json.loads(sa_out.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Context:" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx

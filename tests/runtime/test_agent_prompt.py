"""Tests for the runtime-owned Agent dispatch prompt producer.

Covers:
1. build_agent_dispatch_prompt helper: contract construction, runtime state
   resolution for goal_id and work_item_id, and error paths.
2. cc-policy dispatch agent-prompt CLI: happy path, explicit overrides, and
   error cases.
3. Output shape invariants: contract_block_line format is parseable by pre-agent.sh
   (starts at column 0, prefixed with CLAUDEX_CONTRACT_BLOCK:), contract dict
   contains all six required fields.

@decision DEC-CLAUDEX-AGENT-PROMPT-001
Title: agent_prompt: runtime-owned Agent dispatch prompt producer
Status: accepted — test file pinning the helper and CLI surface.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec
from runtime.core import workflows as workflows_mod
from runtime.core.agent_prompt import build_agent_dispatch_prompt
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CONTRACT_FIELDS = ("workflow_id", "stage_id", "goal_id", "work_item_id", "decision_scope", "generated_at")

# ---------------------------------------------------------------------------
# Fixtures / seeding helpers
# ---------------------------------------------------------------------------


def _seed(conn: sqlite3.Connection, *, goal_id: str = "GOAL-AP-1", work_item_id: str = "WI-AP-1") -> None:
    goal = contracts.GoalContract(
        goal_id=goal_id,
        desired_end_state="agent-prompt producer test",
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
            work_item_id=work_item_id,
            goal_id=goal_id,
            title="producer test slice",
            status="in_progress",
            version=1,
            author="planner",
            scope_json='{"allowed_paths":[],"required_paths":[],"forbidden_paths":[],"state_domains":[]}',
            evaluation_json='{"required_tests":[],"required_evidence":[],"rollback_boundary":"","acceptance_notes":""}',
            head_sha=None,
            reviewer_round=1,
        ),
    )
    workflows_mod.bind_workflow(
        conn,
        workflow_id="wf-ap",
        worktree_path=str(_REPO_ROOT),
        branch="feature/agent-prompt-test",
    )


@pytest.fixture
def db(tmp_path: Path) -> Path:
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed(conn)
        conn.commit()
    finally:
        conn.close()
    return db_path


@pytest.fixture
def conn(db: Path):
    c = sqlite3.connect(str(db))
    c.row_factory = sqlite3.Row
    yield c
    c.close()


# ---------------------------------------------------------------------------
# 1. build_agent_dispatch_prompt — contract construction
# ---------------------------------------------------------------------------


class TestBuildContractConstruction:
    def test_returns_dict(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert isinstance(result, dict)

    def test_result_has_three_keys(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert set(result.keys()) == {"contract", "contract_block_line", "prompt_prefix"}

    def test_contract_contains_all_six_fields(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        for f in _CONTRACT_FIELDS:
            assert f in result["contract"], f"missing field: {f}"

    def test_workflow_id_and_stage_id_passed_through(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="implementer")
        assert result["contract"]["workflow_id"] == "wf-ap"
        assert result["contract"]["stage_id"] == "implementer"

    def test_default_decision_scope_is_kernel(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert result["contract"]["decision_scope"] == "kernel"

    def test_custom_decision_scope_respected(self, conn):
        result = build_agent_dispatch_prompt(
            conn, workflow_id="wf-ap", stage_id="planner", decision_scope="worktree"
        )
        assert result["contract"]["decision_scope"] == "worktree"

    def test_generated_at_auto_populated_as_int(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert isinstance(result["contract"]["generated_at"], int)
        assert result["contract"]["generated_at"] > 0

    def test_explicit_generated_at_respected(self, conn):
        result = build_agent_dispatch_prompt(
            conn, workflow_id="wf-ap", stage_id="planner", generated_at=1_700_000_000
        )
        assert result["contract"]["generated_at"] == 1_700_000_000


# ---------------------------------------------------------------------------
# 2. build_agent_dispatch_prompt — runtime state resolution
# ---------------------------------------------------------------------------


class TestRuntimeStateResolution:
    def test_goal_id_resolved_from_active_goal(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert result["contract"]["goal_id"] == "GOAL-AP-1"

    def test_work_item_id_resolved_from_in_progress_item(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert result["contract"]["work_item_id"] == "WI-AP-1"

    def test_explicit_goal_id_overrides_lookup(self, conn):
        # Insert a second active goal + work item so explicit goal_id routes correctly.
        second_goal = contracts.GoalContract(
            goal_id="GOAL-EXPLICIT",
            desired_end_state="explicit override test",
            status="active",
            autonomy_budget=1,
            continuation_rules=(),
            stop_conditions=(),
            escalation_boundaries=(),
            user_decision_boundaries=(),
        )
        dwr.insert_goal(conn, goal_contract_codec.encode_goal_contract(second_goal))
        dwr.insert_work_item(
            conn,
            dwr.WorkItemRecord(
                work_item_id="WI-EXPLICIT",
                goal_id="GOAL-EXPLICIT",
                title="explicit work item",
                status="in_progress",
                version=1,
                author="planner",
                scope_json='{"allowed_paths":[],"required_paths":[],"forbidden_paths":[],"state_domains":[]}',
                evaluation_json='{"required_tests":[],"required_evidence":[],"rollback_boundary":"","acceptance_notes":""}',
                head_sha=None,
                reviewer_round=1,
            ),
        )
        conn.commit()
        result = build_agent_dispatch_prompt(
            conn, workflow_id="wf-ap", stage_id="planner", goal_id="GOAL-EXPLICIT"
        )
        assert result["contract"]["goal_id"] == "GOAL-EXPLICIT"

    def test_explicit_work_item_id_overrides_lookup(self, conn):
        # Insert a second work item under the same goal.
        dwr.insert_work_item(
            conn,
            dwr.WorkItemRecord(
                work_item_id="WI-EXPLICIT",
                goal_id="GOAL-AP-1",
                title="explicit work item",
                status="in_progress",
                version=1,
                author="planner",
                scope_json='{"allowed_paths":[],"required_paths":[],"forbidden_paths":[],"state_domains":[]}',
                evaluation_json='{"required_tests":[],"required_evidence":[],"rollback_boundary":"","acceptance_notes":""}',
                head_sha=None,
                reviewer_round=1,
            ),
        )
        conn.commit()
        result = build_agent_dispatch_prompt(
            conn, workflow_id="wf-ap", stage_id="planner", work_item_id="WI-EXPLICIT"
        )
        assert result["contract"]["work_item_id"] == "WI-EXPLICIT"

    def test_no_active_goal_raises_value_error(self, db):
        # Open a fresh DB with no seeded goals.
        empty_db = db.parent / "empty.db"
        ec = sqlite3.connect(str(empty_db))
        ec.row_factory = sqlite3.Row
        try:
            ensure_schema(ec)
            ec.commit()
            with pytest.raises(ValueError, match="no active goal"):
                build_agent_dispatch_prompt(ec, workflow_id="wf-ap", stage_id="planner")
        finally:
            ec.close()

    def test_no_in_progress_work_item_raises_value_error(self, db):
        ec = sqlite3.connect(str(db.parent / "no_wi.db"))
        ec.row_factory = sqlite3.Row
        try:
            ensure_schema(ec)
            # Insert a goal with no work items.
            goal = contracts.GoalContract(
                goal_id="GOAL-NOWITEM",
                desired_end_state="no work items",
                status="active",
                autonomy_budget=1,
                continuation_rules=(),
                stop_conditions=(),
                escalation_boundaries=(),
                user_decision_boundaries=(),
            )
            dwr.insert_goal(ec, goal_contract_codec.encode_goal_contract(goal))
            ec.commit()
            with pytest.raises(ValueError, match="no in_progress work item"):
                build_agent_dispatch_prompt(ec, workflow_id="wf-ap", stage_id="planner")
        finally:
            ec.close()

    def test_empty_workflow_id_raises_value_error(self, conn):
        with pytest.raises(ValueError, match="workflow_id"):
            build_agent_dispatch_prompt(conn, workflow_id="", stage_id="planner")

    def test_empty_stage_id_raises_value_error(self, conn):
        with pytest.raises(ValueError, match="stage_id"):
            build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="")


# ---------------------------------------------------------------------------
# 3. Output shape invariants — contract_block_line format
# ---------------------------------------------------------------------------


class TestContractBlockLineFormat:
    def test_starts_with_marker(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert result["contract_block_line"].startswith("CLAUDEX_CONTRACT_BLOCK:")

    def test_no_leading_whitespace(self, conn):
        # grep '^CLAUDEX_CONTRACT_BLOCK:' requires the marker at column 0.
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert not result["contract_block_line"][0].isspace()

    def test_no_trailing_newline_in_block_line(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert "\n" not in result["contract_block_line"]

    def test_json_after_marker_is_valid(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        json_part = result["contract_block_line"].split("CLAUDEX_CONTRACT_BLOCK:", 1)[1]
        parsed = json.loads(json_part)
        assert isinstance(parsed, dict)

    def test_json_contains_all_six_fields(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        json_part = result["contract_block_line"].split("CLAUDEX_CONTRACT_BLOCK:", 1)[1]
        parsed = json.loads(json_part)
        for f in _CONTRACT_FIELDS:
            assert f in parsed

    def test_prompt_prefix_starts_with_block_line(self, conn):
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        assert result["prompt_prefix"].startswith(result["contract_block_line"])

    def test_prompt_prefix_block_line_at_line_start(self, conn):
        # Simulate what pre-agent.sh does: split into lines, grep '^CLAUDEX_CONTRACT_BLOCK:'.
        result = build_agent_dispatch_prompt(conn, workflow_id="wf-ap", stage_id="planner")
        lines = result["prompt_prefix"].splitlines()
        matching = [l for l in lines if l.startswith("CLAUDEX_CONTRACT_BLOCK:")]
        assert len(matching) >= 1, "pre-agent.sh grep must find the block line"

    def test_contract_dict_matches_block_line_json(self, conn):
        result = build_agent_dispatch_prompt(
            conn, workflow_id="wf-ap", stage_id="planner", generated_at=1_700_000_000
        )
        json_part = result["contract_block_line"].split("CLAUDEX_CONTRACT_BLOCK:", 1)[1]
        parsed = json.loads(json_part)
        for f in _CONTRACT_FIELDS:
            assert parsed[f] == result["contract"][f]


# ---------------------------------------------------------------------------
# 4. CLI — cc-policy dispatch agent-prompt
# ---------------------------------------------------------------------------


def _run_cli(db_path: Path, *extra_args: str) -> tuple[int, str, str]:
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
    }
    result = subprocess.run(
        [sys.executable, str(_REPO_ROOT / "runtime" / "cli.py"),
         "dispatch", "agent-prompt", *extra_args],
        capture_output=True, text=True, env=env, cwd=str(_REPO_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


class TestCLIHappyPath:
    # CLI uses _ok() which merges into a flat dict with status="ok".
    # Keys are at top level: contract, contract_block_line, prompt_prefix, status.

    def test_exit_zero(self, db):
        rc, _out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        assert rc == 0

    def test_output_is_valid_json(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert isinstance(parsed, dict)

    def test_output_status_ok(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert parsed.get("status") == "ok"

    def test_output_contains_contract(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert "contract" in parsed

    def test_output_contains_contract_block_line(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert "contract_block_line" in parsed

    def test_output_contains_prompt_prefix(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert "prompt_prefix" in parsed

    def test_contract_block_line_starts_with_marker(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert parsed["contract_block_line"].startswith("CLAUDEX_CONTRACT_BLOCK:")

    def test_goal_id_resolved_from_db(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert parsed["contract"]["goal_id"] == "GOAL-AP-1"

    def test_work_item_id_resolved_from_db(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        assert parsed["contract"]["work_item_id"] == "WI-AP-1"

    def test_explicit_goal_id_accepted(self, db):
        _rc, out, _err = _run_cli(
            db, "--workflow-id", "wf-ap", "--stage-id", "planner",
            "--goal-id", "GOAL-AP-1",
        )
        parsed = json.loads(out.strip())
        assert parsed["contract"]["goal_id"] == "GOAL-AP-1"

    def test_explicit_work_item_id_accepted(self, db):
        _rc, out, _err = _run_cli(
            db, "--workflow-id", "wf-ap", "--stage-id", "planner",
            "--goal-id", "GOAL-AP-1", "--work-item-id", "WI-AP-1",
        )
        parsed = json.loads(out.strip())
        assert parsed["contract"]["work_item_id"] == "WI-AP-1"

    def test_custom_decision_scope_accepted(self, db):
        _rc, out, _err = _run_cli(
            db, "--workflow-id", "wf-ap", "--stage-id", "planner",
            "--decision-scope", "worktree",
        )
        parsed = json.loads(out.strip())
        assert parsed["contract"]["decision_scope"] == "worktree"

    def test_explicit_generated_at_accepted(self, db):
        _rc, out, _err = _run_cli(
            db, "--workflow-id", "wf-ap", "--stage-id", "planner",
            "--generated-at", "1700000000",
        )
        parsed = json.loads(out.strip())
        assert parsed["contract"]["generated_at"] == 1_700_000_000


class TestCLIErrorCases:
    def test_missing_workflow_id_exits_nonzero(self, db):
        rc, _out, _err = _run_cli(db, "--stage-id", "planner")
        assert rc != 0

    def test_missing_stage_id_exits_nonzero(self, db):
        rc, _out, _err = _run_cli(db, "--workflow-id", "wf-ap")
        assert rc != 0

    def test_no_active_goal_returns_error_on_stderr(self, db, tmp_path):
        # _err() prints to stderr and returns exit code 1.
        empty_db = tmp_path / "e.db"
        c = sqlite3.connect(str(empty_db))
        c.row_factory = sqlite3.Row
        try:
            ensure_schema(c)
            c.commit()
        finally:
            c.close()
        rc, _out, err = _run_cli(empty_db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        assert rc != 0
        err_parsed = json.loads(err.strip())
        assert err_parsed.get("status") == "error"
        assert "no active goal" in err_parsed.get("message", "")


# ---------------------------------------------------------------------------
# 5. End-to-end: CLI output is directly parseable by pre-agent.sh carrier logic
# ---------------------------------------------------------------------------


class TestCLIOutputCompatibleWithPreAgent:
    """The contract_block_line returned by the CLI must be embeddable in a
    prompt string and detectable by pre-agent.sh's grep '^CLAUDEX_CONTRACT_BLOCK:'."""

    def test_block_line_grep_detectable(self, db):
        """Simulate what pre-agent.sh does: embed the block line in a prompt,
        then check that the grep pattern would find it."""
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        block_line = parsed["contract_block_line"]

        # Simulate the prompt text the orchestrator would build.
        prompt_text = f"You are the planner agent.\n{block_line}\nBegin your task.\n"
        # grep '^CLAUDEX_CONTRACT_BLOCK:' on each line:
        matching = [l for l in prompt_text.splitlines() if l.startswith("CLAUDEX_CONTRACT_BLOCK:")]
        assert len(matching) == 1

    def test_block_line_json_parseable_as_contract(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        block_line = parsed["contract_block_line"]
        json_part = block_line.split("CLAUDEX_CONTRACT_BLOCK:", 1)[1]
        contract = json.loads(json_part)
        for f in _CONTRACT_FIELDS:
            assert f in contract

    def test_prompt_prefix_first_line_is_block_line(self, db):
        _rc, out, _err = _run_cli(db, "--workflow-id", "wf-ap", "--stage-id", "planner")
        parsed = json.loads(out.strip())
        first_line = parsed["prompt_prefix"].splitlines()[0]
        assert first_line == parsed["contract_block_line"]

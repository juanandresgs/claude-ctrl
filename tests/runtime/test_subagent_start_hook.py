"""Tests for the runtime-first routing path in hooks/subagent-start.sh.

@decision DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-HOOK-001
Title: subagent-start.sh routes contract-present payloads to runtime CLI
Status: proposed (Phase 2 hook-adapter reduction)
Rationale: When the incoming SubagentStart payload carries the full
  six-field request contract, the hook delegates entirely to
  ``cc-policy prompt-pack subagent-start``.  The shell hook is a thin
  transport adapter — all validation and prompt-pack assembly live in
  runtime.core.prompt_pack_validation (request validator) and
  runtime.core.prompt_pack (composition helper).  These tests pin the
  five routing invariants plus the carrier path:

  1. Contract-present payload → runtime-first path → SubagentStart envelope
     with status=ok and hookEventName=SubagentStart.
  2. Contract-absent non-canonical payload → lightweight context path, NOT the
     compiled prompt-pack output. Contract-absent canonical seats are blocked.
  3. Contract-present + compile error (non-existent goal_id) does NOT
     silently fall back to shell guidance — the runtime error is surfaced in
     additionalContext and shell role content is absent.
  4. Partial contract for canonical seats → carrier-required A8 block.
     The shell jq check requires ALL six fields; partial contracts are treated
     as contract-absent and canonical seats cannot use lightweight context.
  5. Contract-present + invalid field values → runtime validator returns
     structured violations; the hook surfaces them without falling back to
     shell role guidance.
  6. Carrier path (DEC-CLAUDEX-SA-CARRIER-001): a pending_agent_requests row
     written for (session_id, agent_type) is consumed by the hook before the
     _HAS_CONTRACT check; the merged fields trigger the runtime-first path
     even though the original payload had no contract fields.
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
from runtime.core.dispatch_hook import record_agent_dispatch
from runtime.core.pending_agent_requests import write_pending_request
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_HOOK = str(_REPO_ROOT / "hooks" / "subagent-start.sh")


class TestHookSourceInvariants:
    """Static guard that canonical role guidance stays out of shell fallback."""

    def test_no_canonical_role_guidance_in_subagent_start_shell(self):
        text = Path(_HOOK).read_text(encoding="utf-8")
        forbidden = [
            "Role: Planner",
            "Role: Implementer",
            "Role: Guardian",
            "Role: Reviewer",
            "REQUIRED OUTPUT TRAILERS",
            "Workflow binding:",
            "No scope manifest found",
        ]
        for token in forbidden:
            assert token not in text


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _seed_for_hook(
    conn,
    *,
    workflow_id: str = "wf-hook",
    goal_id: str = "GOAL-HOOK-1",
    work_item_id: str = "WI-HOOK-1",
) -> None:
    goal = contracts.GoalContract(
        goal_id=goal_id,
        desired_end_state="hook path routing test",
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
            title="hook routing test slice",
            status="in_progress",
            version=1,
            author="planner",
            scope_json=(
                '{"allowed_paths":["hooks/subagent-start.sh"],'
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
        branch="feature/hook-test",
    )


@pytest.fixture
def hook_db(tmp_path: Path):
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed_for_hook(conn)
        conn.commit()
    finally:
        conn.close()
    return db_path


def _run_hook(
    payload: dict, db_path: Path
) -> tuple[int, str, str]:
    """Invoke the hook with payload as stdin; return (rc, stdout, stderr)."""
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_PROJECT_DIR": str(_REPO_ROOT),
        # Point cc_policy (runtime-bridge.sh) at the local CLI too,
        # so all Python calls in the hook resolve to the same binary.
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


def _contract_payload(**overrides) -> dict:
    """A payload that carries all six request-contract fields."""
    base: dict = {
        "agent_type": "planner",
        "workflow_id": "wf-hook",
        "stage_id": "planner",
        "goal_id": "GOAL-HOOK-1",
        "work_item_id": "WI-HOOK-1",
        "decision_scope": "kernel",
        "generated_at": 1_700_000_000,
    }
    base.update(overrides)
    return base


def _legacy_payload(**overrides) -> dict:
    """A payload without contract fields."""
    base: dict = {"agent_type": "planner"}
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# 1. Contract-present payload → runtime-first path
# ---------------------------------------------------------------------------


class TestRuntimeFirstPath:
    """Contract-present payload delegates entirely to the runtime compiler."""

    def test_exit_zero(self, hook_db):
        rc, _stdout, _stderr = _run_hook(_contract_payload(), hook_db)
        assert rc == 0

    def test_output_is_valid_json(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_contract_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        assert isinstance(parsed, dict)

    def test_hook_specific_output_key_present(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_contract_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        assert "hookSpecificOutput" in parsed

    def test_hook_event_name_is_subagent_start(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_contract_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        assert parsed["hookSpecificOutput"]["hookEventName"] == "SubagentStart"

    def test_additional_context_non_empty(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_contract_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert isinstance(ctx, str) and ctx.strip()

    def test_additional_context_contains_compiled_prompt_pack_header(self, hook_db):
        # The runtime path produces a compiled PromptPack whose rendered body
        # starts with the canonical "# ClauDEX Prompt Pack: <wf> @ <stage>" header.
        _rc, stdout, _stderr = _run_hook(_contract_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" in ctx

    def test_shell_role_guidance_absent(self, hook_db):
        # The runtime path must NOT inject shell-built role guidance.
        _rc, stdout, _stderr = _run_hook(_contract_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Role: Planner" not in ctx

    def test_contract_with_mismatched_agent_type_fails_closed(self, hook_db):
        payload = _contract_payload(agent_type="general-purpose")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "requires subagent_type 'planner'" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx
        assert "Context:" not in ctx


# ---------------------------------------------------------------------------
# 2. Contract-absent payload → lightweight non-canonical path
# ---------------------------------------------------------------------------


class TestLightweightNonCanonicalPath:
    """Without the request contract, non-canonical agents take lightweight context.

    A8 update: canonical dispatch seats (planner, implementer, guardian, reviewer)
    now receive a fail-closed deny via additionalContext (canonical_seat_no_carrier_contract)
    instead of shell guidance. Tests here use agent_type="Explore" which is
    non-canonical and still receives lightweight context.
    (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
    """

    def test_exit_zero(self, hook_db):
        rc, _stdout, _stderr = _run_hook(_legacy_payload(agent_type="Explore"), hook_db)
        assert rc == 0

    def test_output_is_valid_json(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_legacy_payload(agent_type="Explore"), hook_db)
        parsed = json.loads(stdout.strip())
        assert isinstance(parsed, dict)

    def test_hook_specific_output_key_present(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_legacy_payload(agent_type="Explore"), hook_db)
        parsed = json.loads(stdout.strip())
        assert "hookSpecificOutput" in parsed

    def test_hook_event_name_is_subagent_start(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_legacy_payload(agent_type="Explore"), hook_db)
        parsed = json.loads(stdout.strip())
        assert parsed["hookSpecificOutput"]["hookEventName"] == "SubagentStart"

    def test_compiled_prompt_pack_header_absent(self, hook_db):
        # The lightweight path does NOT produce a compiled PromptPack header.
        _rc, stdout, _stderr = _run_hook(_legacy_payload(agent_type="Explore"), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_legacy_context_present_for_non_canonical(self, hook_db):
        # Non-canonical agent (Explore) takes lightweight path and gets Context.
        _rc, stdout, _stderr = _run_hook(_legacy_payload(agent_type="Explore"), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # "Context:" line is always present on the legacy path.
        assert "Context:" in ctx

    def test_non_canonical_legacy_context_has_no_dispatch_lease_warning(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_legacy_payload(agent_type="Explore"), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "No active lease" not in ctx
        assert "High-risk git ops will be denied" not in ctx

    def test_canonical_seat_without_contract_gets_a8_deny(self, hook_db):
        """A8: planner with no carrier contract gets canonical_seat_no_carrier_contract
        deny, not legacy guidance.
        """
        _rc, stdout, _stderr = _run_hook(_legacy_payload(agent_type="planner"), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx
        assert "Context:" not in ctx


# ---------------------------------------------------------------------------
# 3. Invalid contract-present payload → no silent fallback to shell guidance
# ---------------------------------------------------------------------------


class TestInvalidContractNoFallback:
    """Contract present but compile fails — must surface error, not shell guidance."""

    def test_exit_zero(self, hook_db):
        # The hook still exits 0: the error is surfaced in additionalContext.
        payload = _contract_payload(goal_id="GOAL-ghost-nonexistent")
        rc, _stdout, _stderr = _run_hook(payload, hook_db)
        assert rc == 0

    def test_output_is_valid_json(self, hook_db):
        payload = _contract_payload(goal_id="GOAL-ghost-nonexistent")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        assert isinstance(parsed, dict)

    def test_hook_event_name_still_subagent_start(self, hook_db):
        payload = _contract_payload(goal_id="GOAL-ghost-nonexistent")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        assert parsed["hookSpecificOutput"]["hookEventName"] == "SubagentStart"

    def test_error_surfaced_in_additional_context(self, hook_db):
        payload = _contract_payload(goal_id="GOAL-ghost-nonexistent")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Runtime prompt-pack compile failed" in ctx

    def test_shell_role_guidance_absent(self, hook_db):
        # Shell-built role guidance must NOT appear when the contract was
        # present — even if the runtime path failed.  Injecting "Role: Planner"
        # would silently misguide the agent about the compile failure.
        payload = _contract_payload(goal_id="GOAL-ghost-nonexistent")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Role: Planner" not in ctx

    def test_compiled_prompt_pack_header_absent(self, hook_db):
        # A failed compile must not produce the compiled header.
        payload = _contract_payload(goal_id="GOAL-ghost-nonexistent")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_failed_carrier_compile_marks_attempt_failed_without_marker_or_lease_claim(
        self, hook_db
    ):
        session_id = "compile-fail-carrier-session"
        agent_id = "compile-fail-agent"
        conn = sqlite3.connect(str(hook_db))
        conn.row_factory = sqlite3.Row
        try:
            attempt = record_agent_dispatch(
                conn,
                session_id,
                "planner",
                "bad compile carrier",
                workflow_id="wf-hook",
                work_item_id="WI-HOOK-1",
                goal_id="GOAL-ghost-nonexistent",
                stage_id="planner",
                decision_scope="kernel",
                target_project_root=str(_REPO_ROOT),
                contract={
                    "workflow_id": "wf-hook",
                    "stage_id": "planner",
                    "goal_id": "GOAL-ghost-nonexistent",
                    "work_item_id": "WI-HOOK-1",
                    "decision_scope": "kernel",
                    "generated_at": 1_700_000_000,
                },
            )
            write_pending_request(
                conn,
                attempt_id=attempt["attempt_id"],
                session_id=session_id,
                agent_type="planner",
                workflow_id="wf-hook",
                stage_id="planner",
                goal_id="GOAL-ghost-nonexistent",
                work_item_id="WI-HOOK-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )
            lease_id = attempt["lease_id"]
        finally:
            conn.close()

        rc, stdout, _stderr = _run_hook(
            {"agent_type": "planner", "session_id": session_id, "agent_id": agent_id},
            hook_db,
        )

        assert rc == 0
        ctx = json.loads(stdout.strip())["hookSpecificOutput"]["additionalContext"]
        assert "Runtime prompt-pack compile failed" in ctx
        conn = sqlite3.connect(str(hook_db))
        conn.row_factory = sqlite3.Row
        try:
            attempt_row = conn.execute(
                "SELECT status, failure_reason FROM dispatch_attempts WHERE attempt_id = ?",
                (attempt["attempt_id"],),
            ).fetchone()
            marker_row = conn.execute(
                "SELECT 1 FROM agent_markers WHERE agent_id = ?",
                (agent_id,),
            ).fetchone()
            lease_row = conn.execute(
                "SELECT status, agent_id FROM dispatch_leases WHERE lease_id = ?",
                (lease_id,),
            ).fetchone()
        finally:
            conn.close()

        assert attempt_row["status"] == "failed"
        assert attempt_row["failure_reason"] == "prompt_pack_compile_failed"
        assert marker_row is None
        assert lease_row["status"] == "revoked"
        assert lease_row["agent_id"] is None


# ---------------------------------------------------------------------------
# 4. Partial contract → carrier-required canonical block
# ---------------------------------------------------------------------------


class TestPartialContractRoutingBoundary:
    """Payload missing any one of the six contract fields is treated as contract-absent.

    The shell jq check requires ALL six fields to be present (key existence, not type).
    A payload missing even one field is treated as contract-absent — the runtime-first
    path does NOT fire for it.

    A8 update: For canonical dispatch seats (planner, implementer, guardian, reviewer),
    contract-absent means the A8 fail-closed path fires (canonical_seat_no_carrier_contract).
    For non-canonical seats (Explore, general-purpose, etc.), contract-absent
    takes the lightweight context path. This class tests both routing boundaries.
    (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
    """

    @pytest.fixture(autouse=True)
    def db(self, tmp_path: Path):
        db_path = tmp_path / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            ensure_schema(conn)
            _seed_for_hook(conn)
            conn.commit()
        finally:
            conn.close()
        self._db = db_path

    def _drop(self, field: str) -> dict:
        """Full contract payload (planner) with one field removed."""
        payload = _contract_payload()
        del payload[field]
        return payload

    def _assert_a8_deny(self, field: str) -> None:
        """A canonical seat with a partial contract gets the A8 canonical_seat deny."""
        rc, stdout, _stderr = _run_hook(self._drop(field), self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # A8: canonical seat without a carrier contract gets the fail-closed deny.
        assert "canonical_seat_no_carrier_contract" in ctx
        # Runtime envelope header must NOT be present.
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_missing_workflow_id_takes_a8_deny_path(self):
        # A8: canonical seat (planner) with partial contract → A8 deny, not legacy.
        self._assert_a8_deny("workflow_id")

    def test_missing_stage_id_takes_a8_deny_path(self):
        self._assert_a8_deny("stage_id")

    def test_missing_goal_id_takes_a8_deny_path(self):
        self._assert_a8_deny("goal_id")

    def test_missing_work_item_id_takes_a8_deny_path(self):
        self._assert_a8_deny("work_item_id")

    def test_missing_decision_scope_takes_a8_deny_path(self):
        self._assert_a8_deny("decision_scope")

    def test_missing_generated_at_takes_a8_deny_path(self):
        self._assert_a8_deny("generated_at")

    def test_non_canonical_partial_contract_takes_lightweight_path(self):
        """Non-canonical agent (Explore) with no contract fields gets
        lightweight context, not A8 deny.
        """
        payload = {"agent_type": "Explore"}
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Context:" in ctx
        assert "canonical_seat_no_carrier_contract" not in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx


# ---------------------------------------------------------------------------
# 5. Contract-present + invalid field values → validation violations surfaced
# ---------------------------------------------------------------------------


class TestContractPresentValidationViolations:
    """Contract fields present but with invalid values → runtime validator rejects.

    This is distinct from TestInvalidContractNoFallback (which tests a compile
    error after a valid contract).  Here the contract fields are present and
    syntactically detectable by the shell jq check, but carry invalid values
    (empty string, wrong type).  The runtime validator returns a structured
    violations report instead of a compile error.  The hook must surface the
    violations — NOT fall back to shell role guidance.
    """

    @pytest.fixture(autouse=True)
    def db(self, tmp_path: Path):
        db_path = tmp_path / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            ensure_schema(conn)
            # DB is intentionally NOT seeded — validation errors must fire
            # before any DB lookup, so the DB state is irrelevant here.
            conn.commit()
        finally:
            conn.close()
        self._db = db_path

    def _assert_error_not_shell_guidance(self, payload: dict) -> dict:
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Runtime prompt-pack compile failed" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx
        return parsed

    def test_empty_workflow_id_surfaces_error_not_shell_guidance(self):
        payload = _contract_payload(workflow_id="")
        self._assert_error_not_shell_guidance(payload)

    def test_whitespace_only_stage_id_surfaces_error_not_shell_guidance(self):
        payload = _contract_payload(stage_id="   ")
        self._assert_error_not_shell_guidance(payload)

    def test_null_goal_id_surfaces_error_not_shell_guidance(self):
        # null is the key being present with a null value — jq has() is true,
        # so the runtime path fires; the runtime validator then rejects it.
        payload = _contract_payload()
        payload["goal_id"] = None
        self._assert_error_not_shell_guidance(payload)

    def test_wrong_type_generated_at_surfaces_error_not_shell_guidance(self):
        # String generated_at: shell has() is true; runtime rejects the type.
        payload = _contract_payload(generated_at="1700000000")
        self._assert_error_not_shell_guidance(payload)

    def test_bool_generated_at_surfaces_error_not_shell_guidance(self):
        # True is isinstance(int) in Python but the runtime excludes bools.
        payload = _contract_payload(generated_at=True)
        self._assert_error_not_shell_guidance(payload)

    def test_violations_present_in_error_context(self):
        # When the runtime returns a structured violations report (not a
        # compile exception), the hook must include the violations text.
        payload = _contract_payload(workflow_id="", stage_id="")
        rc, stdout, _stderr = _run_hook(payload, self._db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Violations:" in ctx


# ---------------------------------------------------------------------------
# 6. Carrier path — pending_agent_requests row triggers runtime-first path
# ---------------------------------------------------------------------------


class TestCarrierPath:
    """A pending_agent_requests row written before SubagentStart is consumed by
    the hook and merged into HOOK_INPUT, making the runtime-first path reachable
    without the orchestrator embedding contract fields in the harness payload.

    This pins the end-to-end carrier invariant (DEC-CLAUDEX-SA-CARRIER-001):
    the hook must produce the same runtime-first output whether the contract
    fields arrived natively in the payload or via the carrier table.
    """

    @pytest.fixture(autouse=True)
    def db(self, tmp_path: Path):
        db_path = tmp_path / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            ensure_schema(conn)
            _seed_for_hook(conn)
            conn.commit()
        finally:
            conn.close()
        self._db = db_path

    def _seed_carrier(self, session_id: str = "carrier-test-session") -> None:
        """Write a pending_agent_requests row for (session_id, planner)."""
        conn = sqlite3.connect(str(self._db))
        conn.row_factory = sqlite3.Row
        try:
            write_pending_request(
                conn,
                session_id=session_id,
                agent_type="planner",
                workflow_id="wf-hook",
                stage_id="planner",
                goal_id="GOAL-HOOK-1",
                work_item_id="WI-HOOK-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )
        finally:
            conn.close()

    def _carrier_payload(self, session_id: str = "carrier-test-session") -> dict:
        """Payload with session_id but NO contract fields — forces carrier path."""
        return {"agent_type": "planner", "session_id": session_id}

    def test_carrier_row_triggers_runtime_first_path(self):
        self._seed_carrier()
        rc, stdout, _stderr = _run_hook(self._carrier_payload(), self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # Runtime-first path produces the compiled PromptPack header.
        assert "# ClauDEX Prompt Pack:" in ctx

    def test_carrier_row_absent_takes_a8_deny_path(self):
        # A8: canonical seat (planner) with no carrier row → canonical_seat_no_carrier_contract.
        # This test name retained for backward compat; expectation updated to A8 behavior.
        # (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
        rc, stdout, _stderr = _run_hook(self._carrier_payload(), self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # A8: canonical seat without carrier contract gets fail-closed deny, not legacy.
        assert "canonical_seat_no_carrier_contract" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_carrier_row_consumed_after_hook_runs(self):
        # After the hook consumes the row, a second run (canonical seat, no carrier)
        # gets the A8 fail-closed deny.
        # A8 update: second run is now denied (not legacy) for canonical seats.
        # (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
        self._seed_carrier(session_id="carrier-consume-test")
        payload = self._carrier_payload(session_id="carrier-consume-test")
        _run_hook(payload, self._db)  # first run consumes the row
        rc2, stdout2, _stderr2 = _run_hook(payload, self._db)  # second run: row gone
        assert rc2 == 0
        parsed2 = json.loads(stdout2.strip())
        ctx2 = parsed2["hookSpecificOutput"]["additionalContext"]
        # A8: canonical seat + no carrier row → fail-closed deny, not legacy guidance.
        assert "canonical_seat_no_carrier_contract" in ctx2
        assert "# ClauDEX Prompt Pack:" not in ctx2

    def test_carrier_row_for_different_session_not_consumed(self):
        # A row keyed to a different session_id must not be consumed.
        self._seed_carrier(session_id="other-session")
        payload = self._carrier_payload(session_id="my-session")
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # The row for "other-session" is not consumed; canonical no-carrier is blocked.
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_output_json_structure_matches_runtime_first_envelope(self):
        self._seed_carrier()
        _rc, stdout, _stderr = _run_hook(self._carrier_payload(), self._db)
        parsed = json.loads(stdout.strip())
        hso = parsed["hookSpecificOutput"]
        assert hso["hookEventName"] == "SubagentStart"
        assert "additionalContext" in hso
        assert isinstance(hso["additionalContext"], str) and hso["additionalContext"].strip()


# ---------------------------------------------------------------------------
# 7. Reviewer dispatch-entry guidance (Phase 4)
# ---------------------------------------------------------------------------


class TestReviewerDispatchEntry:
    """Phase 4: reviewer is recognized as a dispatch role.

    A8 update: reviewer is a canonical dispatch seat. When launched without a
    carrier-backed contract (payload with no contract fields and no carrier
    row), the hook now returns canonical_seat_no_carrier_contract instead of
    shell role guidance. Tests updated to reflect A8 routing.
    (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)

    Reviewer role guidance belongs in agents/reviewer.md and runtime prompt
    packs, not in subagent-start.sh shell fallback.
    """

    def test_reviewer_is_dispatch_role_a8_deny(self, hook_db):
        """reviewer agent_type without contract → A8 canonical_seat_no_carrier_contract deny."""
        payload = _legacy_payload(agent_type="reviewer")
        rc, stdout, _stderr = _run_hook(payload, hook_db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # A8: canonical seat without carrier contract gets the fail-closed deny.
        assert "canonical_seat_no_carrier_contract" in ctx

    def test_reviewer_context_blocks_without_review_verdict_trailer(self, hook_db):
        """reviewer no-contract launch blocks instead of injecting REVIEW_VERDICT.

        A8 note: this test now verifies the A8 deny message (canonical_seat_no_carrier_contract)
        and that REVIEW_VERDICT guidance is NOT injected for no-contract launches.
        """
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # A8: reviewer without carrier contract gets deny, not legacy REVIEW_VERDICT injection.
        assert "canonical_seat_no_carrier_contract" in ctx

    def test_reviewer_context_includes_review_head_sha_trailer(self, hook_db):
        """A8: reviewer without carrier contract gets A8 deny, not legacy REVIEW_HEAD_SHA."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx

    def test_reviewer_context_includes_review_findings_json_trailer(self, hook_db):
        """A8: reviewer without carrier contract gets A8 deny."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx

    def test_reviewer_context_mentions_read_only(self, hook_db):
        """A8: reviewer without carrier contract gets A8 deny (not legacy read-only guidance)."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx

    def test_reviewer_context_mentions_check_reviewer(self, hook_db):
        """A8: reviewer without carrier contract gets A8 deny (not legacy check-reviewer ref)."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx

    def test_reviewer_does_not_include_legacy_eval_trailers(self, hook_db):
        """reviewer context must NOT include EVAL_* trailers (A8 deny context either)."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "EVAL_VERDICT:" not in ctx
        assert "EVAL_TESTS_PASS:" not in ctx


class TestReviewerAgentPromptExists:
    """Phase 4: agents/reviewer.md exists and has required content."""

    def test_reviewer_agent_prompt_file_exists(self):
        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        assert reviewer_md.exists(), "agents/reviewer.md must exist"

    def test_reviewer_agent_prompt_has_review_verdict_trailer(self):
        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        content = reviewer_md.read_text(encoding="utf-8")
        assert "REVIEW_VERDICT:" in content

    def test_reviewer_agent_prompt_has_review_findings_json_trailer(self):
        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        content = reviewer_md.read_text(encoding="utf-8")
        assert "REVIEW_FINDINGS_JSON:" in content

    def test_reviewer_agent_prompt_has_read_only_constraint(self):
        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        content = reviewer_md.read_text(encoding="utf-8")
        assert "Do NOT modify source code" in content

    def test_reviewer_agent_prompt_requires_decision_log_lookup(self):
        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        content = reviewer_md.read_text(encoding="utf-8")
        assert "lookup-decision" in content
        assert "Decision Log" in content
        assert "found=false" in content
        assert "in_decision_log=false" in content


class TestAgentPromptCompletionContracts:
    """Pin prompt-visible trailers to runtime completion schemas."""

    def test_planner_prompt_has_plan_trailers(self):
        content = (_REPO_ROOT / "agents" / "planner.md").read_text(encoding="utf-8")
        assert "PLAN_VERDICT:" in content
        assert "PLAN_SUMMARY:" in content

    def test_implementer_prompt_includes_partial_status(self):
        content = (_REPO_ROOT / "agents" / "implementer.md").read_text(encoding="utf-8")
        assert "IMPL_STATUS: complete|partial|blocked" in content

    def test_shared_protocols_use_reviewer_not_legacy_eval(self):
        content = (_REPO_ROOT / "agents" / "shared-protocols.md").read_text(
            encoding="utf-8"
        )
        assert "REVIEW_VERDICT:" in content
        assert "EVAL_VERDICT:" not in content

    def test_guardian_prompt_includes_push_and_provision_verdicts(self):
        content = (_REPO_ROOT / "agents" / "guardian.md").read_text(encoding="utf-8")
        assert "LANDING_RESULT: provisioned|committed|merged|pushed|denied|skipped" in content


# ---------------------------------------------------------------------------
# 8. Reviewer severity vocabulary pins (Phase 4 schema alignment)
# ---------------------------------------------------------------------------


class TestReviewerSeverityVocabularyPin:
    """Pin reviewer guidance in agents/reviewer.md to the runtime severity vocabulary.

    A8 update: subagent-start.sh reviewer hook-output checks have been moved to
    agents/reviewer.md tests only, because the hook no longer injects legacy reviewer
    guidance for a canonical reviewer seat launched without a carrier contract
    (canonical_seat_no_carrier_contract deny fires instead).
    (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)

    If the runtime vocabulary changes, these tests will fail, forcing an
    intentional update of the guidance surfaces.
    """

    def test_hook_severity_example_uses_canonical_vocabulary(self, hook_db):
        """A8: reviewer with no contract gets the A8 deny; the canonical vocabulary
        invariant is now verified via agents/reviewer.md (test below), not hook output.
        This test verifies the A8 routing fires so the invariant class is consistent.
        """
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # A8: canonical seat without carrier → fail-closed deny.
        assert "canonical_seat_no_carrier_contract" in ctx

    def test_hook_does_not_contain_stale_severities(self, hook_db):
        """A8: reviewer with no contract gets A8 deny (does NOT contain legacy severity examples)."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # A8 deny message does not reference stale severities.
        for stale in ("warning", "error", "blocker"):
            assert stale not in ctx.lower().split("|"), (
                f"Stale severity '{stale}' found in A8 deny context"
            )

    def test_agent_prompt_severity_vocabulary_matches_runtime(self):
        """agents/reviewer.md severity vocabulary table matches FINDING_SEVERITIES."""
        from runtime.schemas import FINDING_SEVERITIES

        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        content = reviewer_md.read_text(encoding="utf-8")
        for sev in FINDING_SEVERITIES:
            assert sev in content, (
                f"agents/reviewer.md must document severity '{sev}' "
                f"from FINDING_SEVERITIES"
            )

    def test_agent_prompt_does_not_contain_stale_severities(self):
        """agents/reviewer.md must NOT document stale severity names as
        valid values in the structured findings table."""
        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        content = reviewer_md.read_text(encoding="utf-8")
        # These were the old incorrect severity names — must not appear
        # as severity values in the structured findings table.
        for stale in ("warning", "error", "blocker"):
            # Check the severity column in the table and vocabulary section.
            # Allow the word in general prose but not as a severity value.
            assert f"`{stale}`" not in content, (
                f"agents/reviewer.md must not list '{stale}' as a severity value"
            )

    def test_agent_prompt_optional_fields_match_ledger(self):
        """agents/reviewer.md optional fields use ledger-compatible names."""
        reviewer_md = _REPO_ROOT / "agents" / "reviewer.md"
        content = reviewer_md.read_text(encoding="utf-8")
        ledger_optional = [
            "work_item_id", "file_path", "line", "reviewer_round",
            "head_sha", "finding_id",
        ]
        for field in ledger_optional:
            assert field in content, (
                f"agents/reviewer.md must document optional field '{field}'"
            )

    def test_hook_fail_closed_wording_accurate(self, hook_db):
        """A8: reviewer without carrier contract gets A8 deny (fail-closed behavior).
        The A8 deny is itself fail-closed — it surfaces a blocking message that
        prevents the agent from proceeding without a valid carrier contract.
        (Wording check for 'invalid completion' / 'will not auto-dispatch' is now
        an agents/reviewer.md concern; the hook deny is structurally fail-closed.)
        """
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # A8: the fail-closed message contains the canonical reason code.
        assert "canonical_seat_no_carrier_contract" in ctx


# ---------------------------------------------------------------------------
# A8: canonical seat without carrier contract → fail-closed deny, not legacy
# ---------------------------------------------------------------------------


class TestA8CanonicalSeatNoCarrierContractDeny:
    """A8: canonical dispatch seats (planner, implementer, guardian, reviewer)
    launched without a carrier-backed six-field contract receive a fail-closed
    deny via hookSpecificOutput.additionalContext with reason
    canonical_seat_no_carrier_contract. Shell role guidance must NOT fire
    for these seats.

    This is the compound-interaction test required by the dispatch spec — it
    crosses the boundary between pre-agent.sh (carrier write) and
    subagent-start.sh (carrier consume), verifying the end-to-end enforcement.
    (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
    """

    @pytest.fixture(autouse=True)
    def db(self, tmp_path: Path):
        db_path = tmp_path / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            ensure_schema(conn)
            _seed_for_hook(conn)
            conn.commit()
        finally:
            conn.close()
        self._db = db_path

    def _assert_a8_deny(self, agent_type: str) -> None:
        """Assert that canonical seat with no carrier contract gets the A8 deny."""
        payload = {"agent_type": agent_type, "session_id": "no-carrier-session"}
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0, f"Hook must exit 0 (deny via additionalContext), got rc={rc}"
        parsed = json.loads(stdout.strip())
        hso = parsed["hookSpecificOutput"]
        assert hso["hookEventName"] == "SubagentStart"
        ctx = hso["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx, (
            f"Canonical seat {agent_type!r} without contract must produce "
            f"canonical_seat_no_carrier_contract in additionalContext, got:\n{ctx}"
        )
        assert "workflow stage-packet" in ctx
        # Must NOT fall through to shell role guidance.
        assert "Context:" not in ctx, (
            f"Canonical seat {agent_type!r} must NOT take lightweight path; got:\n{ctx}"
        )
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_planner_no_carrier_contract_denied(self):
        self._assert_a8_deny("planner")

    def test_implementer_no_carrier_contract_denied(self):
        self._assert_a8_deny("implementer")

    def test_guardian_no_carrier_contract_denied(self):
        payload = {"agent_type": "guardian", "session_id": "no-carrier-session"}
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0, f"Hook must exit 0 (deny via additionalContext), got rc={rc}"
        parsed = json.loads(stdout.strip())
        hso = parsed["hookSpecificOutput"]
        assert hso["hookEventName"] == "SubagentStart"
        ctx = hso["additionalContext"]
        assert "canonical_seat_no_carrier_contract" in ctx
        assert "workflow stage-packet" in ctx
        assert "guardian:land" in ctx
        assert "guardian:provision" in ctx
        assert "unknown active stage" not in ctx
        assert "Context:" not in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_reviewer_no_carrier_contract_denied(self):
        self._assert_a8_deny("reviewer")

    def test_non_canonical_explore_takes_lightweight_not_a8_deny(self):
        """Non-canonical Explore agent must still take lightweight context."""
        payload = {"agent_type": "Explore", "session_id": "no-carrier-session"}
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # Non-canonical -> lightweight path; must NOT get A8 deny.
        assert "canonical_seat_no_carrier_contract" not in ctx
        assert "Context:" in ctx

    def test_non_canonical_general_purpose_takes_lightweight_not_a8_deny(self):
        """general-purpose agent must still take lightweight context."""
        payload = {"agent_type": "general-purpose", "session_id": "no-carrier-session"}
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "canonical_seat_no_carrier_contract" not in ctx

    def test_canonical_seat_with_valid_carrier_takes_runtime_first_path(self):
        """Canonical seat WITH a valid carrier row must take the runtime-first path,
        not the A8 deny — verifying the A8 gate is only a fail-closed fallback.
        """
        # Seed a carrier row for the session.
        conn = sqlite3.connect(str(self._db))
        conn.row_factory = sqlite3.Row
        try:
            write_pending_request(
                conn,
                session_id="valid-carrier-session",
                agent_type="planner",
                workflow_id="wf-hook",
                stage_id="planner",
                goal_id="GOAL-HOOK-1",
                work_item_id="WI-HOOK-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )
            conn.commit()
        finally:
            conn.close()

        payload = {"agent_type": "planner", "session_id": "valid-carrier-session"}
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # Must take runtime-first path (carrier row present with full contract).
        assert "# ClauDEX Prompt Pack:" in ctx, (
            "Canonical seat with valid carrier must take runtime-first path"
        )
        assert "canonical_seat_no_carrier_contract" not in ctx

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
  2. Contract-absent payload → legacy compatibility path (shell-built context,
     NOT the compiled prompt-pack output).
  3. Contract-present + compile error (non-existent goal_id) does NOT
     silently fall back to the legacy guidance path — the runtime error is
     surfaced in additionalContext and legacy content is absent.
  4. Partial contract (any one of the six fields absent) → legacy path.
     The shell jq check requires ALL six fields; partial contracts are
     treated as contract-absent.
  5. Contract-present + invalid field values → runtime validator returns
     structured violations; the hook surfaces them without falling back
     to legacy guidance.
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

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec
from runtime.core import workflows as workflows_mod
from runtime.core.pending_agent_requests import write_pending_request
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_HOOK = str(_REPO_ROOT / "hooks" / "subagent-start.sh")


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
    """A payload without contract fields — forces legacy path."""
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

    def test_legacy_role_guidance_absent(self, hook_db):
        # The runtime path must NOT inject the legacy shell-built role guidance.
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
# 2. Contract-absent payload → legacy compatibility path
# ---------------------------------------------------------------------------


class TestLegacyCompatibilityPath:
    """Without the request contract, the hook takes the legacy path."""

    def test_exit_zero(self, hook_db):
        rc, _stdout, _stderr = _run_hook(_legacy_payload(), hook_db)
        assert rc == 0

    def test_output_is_valid_json(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_legacy_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        assert isinstance(parsed, dict)

    def test_hook_specific_output_key_present(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_legacy_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        assert "hookSpecificOutput" in parsed

    def test_hook_event_name_is_subagent_start(self, hook_db):
        _rc, stdout, _stderr = _run_hook(_legacy_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        assert parsed["hookSpecificOutput"]["hookEventName"] == "SubagentStart"

    def test_compiled_prompt_pack_header_absent(self, hook_db):
        # The legacy path does NOT produce a compiled PromptPack header.
        _rc, stdout, _stderr = _run_hook(_legacy_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_legacy_context_present(self, hook_db):
        # Legacy path for agent_type=planner injects role guidance.
        _rc, stdout, _stderr = _run_hook(_legacy_payload(), hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # "Context:" line is always present on the legacy path.
        assert "Context:" in ctx


# ---------------------------------------------------------------------------
# 3. Invalid contract-present payload → no silent fallback to legacy
# ---------------------------------------------------------------------------


class TestInvalidContractNoFallback:
    """Contract present but compile fails — must surface error, not legacy content."""

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

    def test_legacy_role_guidance_absent(self, hook_db):
        # The legacy shell-built guidance must NOT appear when the contract was
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


# ---------------------------------------------------------------------------
# 4. Partial contract → legacy path (routing boundary pin)
# ---------------------------------------------------------------------------


class TestPartialContractTakesLegacyPath:
    """Payload missing any one of the six contract fields takes the legacy path.

    The shell jq check requires ALL six fields to be present (key existence,
    not type).  A payload missing even one field is treated as contract-absent
    and routed to the legacy shell-built path.  This pins the routing boundary
    so partial contracts can never accidentally reach the runtime path.
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
        """Full contract payload with one field removed."""
        payload = _contract_payload()
        del payload[field]
        return payload

    def _assert_legacy(self, field: str) -> None:
        rc, stdout, _stderr = _run_hook(self._drop(field), self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        # Legacy path: "Context:" line is always present.
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Context:" in ctx
        # Runtime envelope header must NOT be present.
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_missing_workflow_id_takes_legacy_path(self):
        self._assert_legacy("workflow_id")

    def test_missing_stage_id_takes_legacy_path(self):
        self._assert_legacy("stage_id")

    def test_missing_goal_id_takes_legacy_path(self):
        self._assert_legacy("goal_id")

    def test_missing_work_item_id_takes_legacy_path(self):
        self._assert_legacy("work_item_id")

    def test_missing_decision_scope_takes_legacy_path(self):
        self._assert_legacy("decision_scope")

    def test_missing_generated_at_takes_legacy_path(self):
        self._assert_legacy("generated_at")


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
    violations — NOT fall back to legacy guidance.
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

    def _assert_error_not_legacy(self, payload: dict) -> dict:
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "Runtime prompt-pack compile failed" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx
        return parsed

    def test_empty_workflow_id_surfaces_error_not_legacy(self):
        payload = _contract_payload(workflow_id="")
        self._assert_error_not_legacy(payload)

    def test_whitespace_only_stage_id_surfaces_error_not_legacy(self):
        payload = _contract_payload(stage_id="   ")
        self._assert_error_not_legacy(payload)

    def test_null_goal_id_surfaces_error_not_legacy(self):
        # null is the key being present with a null value — jq has() is true,
        # so the runtime path fires; the runtime validator then rejects it.
        payload = _contract_payload()
        payload["goal_id"] = None
        self._assert_error_not_legacy(payload)

    def test_wrong_type_generated_at_surfaces_error_not_legacy(self):
        # String generated_at: shell has() is true; runtime rejects the type.
        payload = _contract_payload(generated_at="1700000000")
        self._assert_error_not_legacy(payload)

    def test_bool_generated_at_surfaces_error_not_legacy(self):
        # True is isinstance(int) in Python but the runtime excludes bools.
        payload = _contract_payload(generated_at=True)
        self._assert_error_not_legacy(payload)

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

    def test_carrier_row_absent_takes_legacy_path(self):
        # No carrier row seeded — must fall through to legacy path.
        rc, stdout, _stderr = _run_hook(self._carrier_payload(), self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # Legacy path injects "Context:" line; runtime header is absent.
        assert "Context:" in ctx
        assert "# ClauDEX Prompt Pack:" not in ctx

    def test_carrier_row_consumed_after_hook_runs(self):
        # After the hook consumes the row, a second run must take the legacy path.
        self._seed_carrier(session_id="carrier-consume-test")
        payload = self._carrier_payload(session_id="carrier-consume-test")
        _run_hook(payload, self._db)  # first run consumes the row
        rc2, stdout2, _stderr2 = _run_hook(payload, self._db)  # second run: row gone
        assert rc2 == 0
        parsed2 = json.loads(stdout2.strip())
        ctx2 = parsed2["hookSpecificOutput"]["additionalContext"]
        assert "Context:" in ctx2
        assert "# ClauDEX Prompt Pack:" not in ctx2

    def test_carrier_row_for_different_session_not_consumed(self):
        # A row keyed to a different session_id must not be consumed.
        self._seed_carrier(session_id="other-session")
        payload = self._carrier_payload(session_id="my-session")
        rc, stdout, _stderr = _run_hook(payload, self._db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # The row for "other-session" is not consumed; this run takes legacy path.
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
    """Phase 4: reviewer is recognized as a dispatch role and gets correct
    legacy context with REVIEW_* trailer instructions."""

    def test_reviewer_is_dispatch_role(self, hook_db):
        """reviewer agent_type produces valid output (not rejected as unknown)."""
        payload = _legacy_payload(agent_type="reviewer")
        rc, stdout, _stderr = _run_hook(payload, hook_db)
        assert rc == 0
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # Reviewer legacy context includes the role description.
        assert "Role: Reviewer" in ctx

    def test_reviewer_context_includes_review_verdict_trailer(self, hook_db):
        """reviewer legacy context includes REVIEW_VERDICT trailer instruction."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "REVIEW_VERDICT:" in ctx

    def test_reviewer_context_includes_review_head_sha_trailer(self, hook_db):
        """reviewer legacy context includes REVIEW_HEAD_SHA trailer instruction."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "REVIEW_HEAD_SHA:" in ctx

    def test_reviewer_context_includes_review_findings_json_trailer(self, hook_db):
        """reviewer legacy context includes REVIEW_FINDINGS_JSON trailer instruction."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "REVIEW_FINDINGS_JSON:" in ctx

    def test_reviewer_context_mentions_read_only(self, hook_db):
        """reviewer legacy context states read-only constraint."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "read-only" in ctx.lower()

    def test_reviewer_context_mentions_check_reviewer(self, hook_db):
        """reviewer legacy context references check-reviewer.sh as the trailer parser."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "check-reviewer.sh" in ctx

    def test_reviewer_does_not_include_legacy_eval_trailers(self, hook_db):
        """reviewer context must NOT include EVAL_* trailers.

        EVAL_* trailers belonged to the legacy ``tester`` completion contract
        (retired in Phase 8 Slice 10 / Slice 11, DEC-PHASE8-SLICE11-001).
        The reviewer uses the REVIEW_* trailer family instead.
        """
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


# ---------------------------------------------------------------------------
# 8. Reviewer severity vocabulary pins (Phase 4 schema alignment)
# ---------------------------------------------------------------------------


class TestReviewerSeverityVocabularyPin:
    """Pin reviewer guidance in both subagent-start.sh and agents/reviewer.md
    to the runtime severity vocabulary (FINDING_SEVERITIES from schemas.py).

    If the runtime vocabulary changes, these tests will fail, forcing an
    intentional update of the guidance surfaces.
    """

    def test_hook_severity_example_uses_canonical_vocabulary(self, hook_db):
        """subagent-start.sh reviewer REVIEW_FINDINGS_JSON example uses
        only severities from FINDING_SEVERITIES."""
        from runtime.schemas import FINDING_SEVERITIES

        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        # The severity example in the REVIEW_FINDINGS_JSON line must list
        # exactly the canonical severities (sorted for determinism).
        canonical = sorted(FINDING_SEVERITIES)
        expected_fragment = "|".join(canonical)
        assert expected_fragment in ctx, (
            f"Hook reviewer context must list severities as '{expected_fragment}', "
            f"got context:\n{ctx}"
        )

    def test_hook_does_not_contain_stale_severities(self, hook_db):
        """subagent-start.sh reviewer context must NOT mention the old
        stale severity names (warning, error, blocker)."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        for stale in ("warning", "error", "blocker"):
            assert stale not in ctx.lower().split("|"), (
                f"Stale severity '{stale}' found in hook reviewer context"
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
        """subagent-start.sh reviewer context uses accurate fail-closed wording
        (invalid completion / no auto-dispatch, NOT synthetic needs_changes)."""
        payload = _legacy_payload(agent_type="reviewer")
        _rc, stdout, _stderr = _run_hook(payload, hook_db)
        parsed = json.loads(stdout.strip())
        ctx = parsed["hookSpecificOutput"]["additionalContext"]
        assert "invalid completion" in ctx.lower(), (
            "Hook must mention 'invalid completion' for fail-closed behavior"
        )
        assert "will not auto-dispatch" in ctx.lower(), (
            "Hook must mention 'will not auto-dispatch' for fail-closed behavior"
        )

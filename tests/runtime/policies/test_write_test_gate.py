"""Tests for write_test_gate policy.

@decision DEC-PE-W5-TEST-002
Title: write_test_gate tests verify escalating strike logic via pure function calls
Status: accepted
Rationale: write_test_gate reads test_state from PolicyContext and manages
  strike counts via flat-file state under project_root. Tests inject a
  hand-crafted context and a temp directory to isolate state. No DB I/O.

Production sequence:
  Claude Write/Edit -> pre-write.sh -> cc-policy evaluate ->
  PolicyRegistry.evaluate() -> _policy_fn(request) -> deny|feedback|None
"""

from __future__ import annotations

import tempfile

from runtime.core.policies.write_test_gate import check_test_gate_pretool as _policy_fn
from runtime.core.policy_engine import PolicyContext, PolicyRegistry, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(
    test_state=None,
    project_root: str = "/proj",
) -> PolicyContext:
    return PolicyContext(
        actor_role="implementer",
        actor_id="agent-1",
        workflow_id="wf-1",
        worktree_path=project_root,
        branch="feature/test",
        project_root=project_root,
        is_meta_repo=False,
        lease=None,
        scope=None,
        eval_state=None,
        test_state=test_state,
        binding=None,
        dispatch_phase=None,
    )


def _write_req(
    file_path: str,
    project_root: str = "/proj",
    test_state=None,
) -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": file_path, "content": "x = 1\n"},
        context=_make_context(test_state=test_state, project_root=project_root),
        cwd=project_root,
    )


# ---------------------------------------------------------------------------
# Skip conditions
# ---------------------------------------------------------------------------


def test_no_file_path_returns_none():
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={},
        context=_make_context(),
        cwd="/proj",
    )
    assert _policy_fn(req) is None


def test_non_source_file_skipped():
    """Non-source files are never gated."""
    assert _policy_fn(_write_req("/proj/README.md")) is None
    assert _policy_fn(_write_req("/proj/config.json")) is None


def test_test_file_always_allowed():
    """Test files are exempt so fixes can proceed even when tests fail."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fail_state = {"found": True, "status": "fail", "fail_count": 3, "updated_at": 9999999999}
        assert _policy_fn(_write_req(f"{tmpdir}/test_foo.py", tmpdir, fail_state)) is None
        assert _policy_fn(_write_req(f"{tmpdir}/foo_test.py", tmpdir, fail_state)) is None
        assert _policy_fn(_write_req(f"{tmpdir}/tests/bar.py", tmpdir, fail_state)) is None


def test_meta_infra_skipped():
    """Files under .claude/ are meta-infrastructure — exempt."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fail_state = {"found": True, "status": "fail", "fail_count": 1, "updated_at": 9999999999}
        req = _write_req(f"{tmpdir}/.claude/hooks/hook.sh", tmpdir, fail_state)
        assert _policy_fn(req) is None


# ---------------------------------------------------------------------------
# No test state — allow
# ---------------------------------------------------------------------------


def test_no_test_state_allows():
    """No test data yet — allow (cold start)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        req = _write_req(f"{tmpdir}/app.py", tmpdir, test_state=None)
        result = _policy_fn(req)
        assert result is None


def test_test_state_not_found_allows():
    """test_state.found = False → allow."""
    with tempfile.TemporaryDirectory() as tmpdir:
        state = {"found": False, "status": "unknown", "fail_count": 0, "updated_at": 0}
        req = _write_req(f"{tmpdir}/app.py", tmpdir, state)
        result = _policy_fn(req)
        assert result is None


# ---------------------------------------------------------------------------
# Tests passing — allow + reset strikes
# ---------------------------------------------------------------------------


def test_passing_tests_allow():
    with tempfile.TemporaryDirectory() as tmpdir:
        import time

        state = {
            "found": True,
            "status": "pass",
            "fail_count": 0,
            "updated_at": int(time.time()),
        }
        req = _write_req(f"{tmpdir}/app.py", tmpdir, state)
        result = _policy_fn(req)
        assert result is None


def test_pass_complete_allows():
    with tempfile.TemporaryDirectory() as tmpdir:
        import time

        state = {
            "found": True,
            "status": "pass_complete",
            "fail_count": 0,
            "updated_at": int(time.time()),
        }
        req = _write_req(f"{tmpdir}/app.py", tmpdir, state)
        result = _policy_fn(req)
        assert result is None


def test_passing_resets_strikes(tmp_path):
    """Passing tests clear any existing strikes file."""
    import time

    strikes_file = tmp_path / ".claude" / ".test-gate-strikes"
    strikes_file.parent.mkdir(parents=True)
    strikes_file.write_text("2|1000000")

    state = {
        "found": True,
        "status": "pass",
        "fail_count": 0,
        "updated_at": int(time.time()),
    }
    req = _write_req(f"{tmp_path}/app.py", str(tmp_path), state)
    _policy_fn(req)
    assert not strikes_file.exists()


# ---------------------------------------------------------------------------
# Stale test state — allow
# ---------------------------------------------------------------------------


def test_stale_test_state_allows():
    """Test results older than 600s are ignored."""
    state = {
        "found": True,
        "status": "fail",
        "fail_count": 5,
        "updated_at": 1000,  # very old epoch
    }
    with tempfile.TemporaryDirectory() as tmpdir:
        req = _write_req(f"{tmpdir}/app.py", tmpdir, state)
        result = _policy_fn(req)
        assert result is None


# ---------------------------------------------------------------------------
# Failing tests — escalating strike system
# ---------------------------------------------------------------------------


def test_first_failure_strike1_feedback(tmp_path):
    """First write with failing tests: advisory feedback, not a deny."""
    import time

    state = {
        "found": True,
        "status": "fail",
        "fail_count": 3,
        "updated_at": int(time.time()),
    }
    req = _write_req(f"{tmp_path}/app.py", str(tmp_path), state)
    result = _policy_fn(req)
    assert result is not None
    assert result.action == "feedback"
    assert result.policy_name == "test_gate_pretool"


def test_second_failure_strike2_deny(tmp_path):
    """Second consecutive write with failing tests: deny."""
    import time

    # Write an existing strikes file to simulate strike 1 already happened
    strikes_file = tmp_path / ".claude" / ".test-gate-strikes"
    strikes_file.parent.mkdir(parents=True)
    strikes_file.write_text(f"1|{int(time.time())}")

    state = {
        "found": True,
        "status": "fail",
        "fail_count": 3,
        "updated_at": int(time.time()),
    }
    req = _write_req(f"{tmp_path}/app.py", str(tmp_path), state)
    result = _policy_fn(req)
    assert result is not None
    assert result.action == "deny"
    assert result.policy_name == "test_gate_pretool"


def test_strike_count_increments(tmp_path):
    """Strike count in file is incremented after each failing write."""
    import time

    state = {
        "found": True,
        "status": "fail",
        "fail_count": 1,
        "updated_at": int(time.time()),
    }
    req = _write_req(f"{tmp_path}/app.py", str(tmp_path), state)
    _policy_fn(req)

    strikes_file = tmp_path / ".claude" / ".test-gate-strikes"
    assert strikes_file.exists()
    count = int(strikes_file.read_text().split("|")[0])
    assert count == 1


# ---------------------------------------------------------------------------
# Compound integration — registry path
# ---------------------------------------------------------------------------


def test_registry_test_gate_deny_on_second_strike(tmp_path):
    """Integration: full registry evaluate() denies after 2 failing writes.

    Production sequence: Claude Write -> pre-write.sh -> cc-policy evaluate ->
    PolicyRegistry.evaluate() -> _policy_fn -> deny on strike 2.
    """
    import time

    reg = PolicyRegistry()
    reg.register(
        "test_gate_pretool",
        _policy_fn,
        event_types=["Write", "Edit"],
        priority=650,
    )

    strikes_file = tmp_path / ".claude" / ".test-gate-strikes"
    strikes_file.parent.mkdir(parents=True)
    strikes_file.write_text(f"1|{int(time.time())}")

    state = {
        "found": True,
        "status": "fail",
        "fail_count": 2,
        "updated_at": int(time.time()),
    }
    req = _write_req(f"{tmp_path}/app.py", str(tmp_path), state)
    decision = reg.evaluate(req)
    assert decision.action == "deny"
    assert decision.policy_name == "test_gate_pretool"

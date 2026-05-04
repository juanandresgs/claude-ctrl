"""Tests for write_mock_gate policy.

@decision DEC-PE-W5-TEST-003
Title: write_mock_gate tests verify mock detection logic via pure function calls
Status: accepted
Rationale: write_mock_gate is a pure function of tool_input content — no DB I/O.
  Tests inject hand-crafted PolicyRequest with content and policy_strikes state.
  The compound test
  exercises the full PolicyRegistry path to prove integration wiring is correct.

Production sequence:
  Claude Write/Edit (test file) -> pre-write.sh -> cc-policy evaluate ->
  PolicyRegistry.evaluate() -> mock_gate(request) -> deny|feedback|None
"""

from __future__ import annotations

from runtime.core.policies.write_mock_gate import mock_gate

from runtime.core.policy_engine import PolicyContext, PolicyRegistry, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(project_root: str = "/proj") -> PolicyContext:
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
        test_state=None,
        binding=None,
        dispatch_phase=None,
        policy_strikes={},
    )


def _write_req(
    file_path: str,
    content: str,
    project_root: str = "/proj",
    policy_strikes: dict | None = None,
) -> PolicyRequest:
    ctx = _make_context(project_root=project_root)
    if policy_strikes is not None:
        ctx.policy_strikes = policy_strikes
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": file_path, "content": content},
        context=ctx,
        cwd=project_root,
    )


def _edit_req(
    file_path: str,
    new_string: str,
    project_root: str = "/proj",
    policy_strikes: dict | None = None,
) -> PolicyRequest:
    ctx = _make_context(project_root=project_root)
    if policy_strikes is not None:
        ctx.policy_strikes = policy_strikes
    return PolicyRequest(
        event_type="Edit",
        tool_name="Edit",
        tool_input={"file_path": file_path, "new_string": new_string},
        context=ctx,
        cwd=project_root,
    )


# ---------------------------------------------------------------------------
# Skip conditions — non-test files always pass
# ---------------------------------------------------------------------------


def test_no_file_path_returns_none():
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={},
        context=_make_context(),
        cwd="/proj",
    )
    assert mock_gate(req) is None


def test_non_test_source_file_skipped():
    """Source files that are not tests are never inspected for mocks."""
    content = "from unittest.mock import MagicMock\nx = MagicMock()\n"
    assert mock_gate(_write_req("/proj/app.py", content)) is None
    assert mock_gate(_write_req("/proj/service.ts", content)) is None


def test_empty_content_skipped():
    assert mock_gate(_write_req("/proj/tests/test_foo.py", "")) is None


# ---------------------------------------------------------------------------
# @mock-exempt annotation — always allow
# ---------------------------------------------------------------------------


def test_mock_exempt_annotation_bypasses_check():
    """@mock-exempt annotation skips all detection."""
    content = (
        "# @mock-exempt: testing boundary injection\n"
        "from unittest.mock import MagicMock\n"
        "mock = MagicMock()\n"
    )
    assert mock_gate(_write_req("/proj/tests/test_boundary.py", content)) is None


# ---------------------------------------------------------------------------
# External boundary mocks — allow
# ---------------------------------------------------------------------------


def test_external_http_mock_allowed():
    """Mocking requests (HTTP boundary) is always permitted."""
    content = (
        "import pytest\n"
        "from unittest.mock import patch\n"
        "\n"
        "@patch('requests.get')\n"
        "def test_fetch(mock_get):\n"
        "    mock_get.return_value.json.return_value = {}\n"
    )
    assert mock_gate(_write_req("/proj/tests/test_api.py", content)) is None


def test_external_db_mock_allowed():
    """Mocking sqlalchemy (DB boundary) is always permitted."""
    content = (
        "from unittest.mock import patch\n"
        "\n"
        "@patch('sqlalchemy.create_engine')\n"
        "def test_db(mock_engine):\n"
        "    pass\n"
    )
    assert mock_gate(_write_req("/proj/tests/test_db.py", content)) is None


def test_external_test_library_allowed():
    """pytest-httpx, responses, respx etc. are always allowed."""
    content = (
        "import respx\n"
        "import httpx\n"
        "\n"
        "def test_client(respx_mock):\n"
        "    respx_mock.get('https://api.example.com/').mock(return_value=httpx.Response(200))\n"
    )
    assert mock_gate(_write_req("/proj/tests/test_client.py", content)) is None


# ---------------------------------------------------------------------------
# Internal mocks — escalating strike system
# ---------------------------------------------------------------------------


def test_internal_magicmock_first_strike_feedback(tmp_path):
    """First internal mock: advisory feedback only."""
    content = (
        "from unittest.mock import MagicMock\n"
        "\n"
        "def test_something():\n"
        "    svc = MagicMock()\n"
        "    svc.process.return_value = 42\n"
        "    assert svc.process() == 42\n"
    )
    result = mock_gate(_write_req(f"{tmp_path}/tests/test_foo.py", content, str(tmp_path)))
    assert result is not None
    assert result.action == "feedback"
    assert result.policy_name == "mock_gate"


def test_internal_patch_internal_module_first_strike_feedback(tmp_path):
    """Patching an internal module gives feedback on first strike."""
    content = (
        "from unittest.mock import patch\n"
        "\n"
        "@patch('myapp.services.payment.process')\n"
        "def test_checkout(mock_process):\n"
        "    mock_process.return_value = True\n"
    )
    result = mock_gate(_write_req(f"{tmp_path}/tests/test_checkout.py", content, str(tmp_path)))
    assert result is not None
    assert result.action == "feedback"


def test_internal_mock_second_strike_deny(tmp_path):
    """Second internal mock: deny."""
    strikes = {"mock_gate:internal_mock": {"count": 1}}
    content = (
        "from unittest.mock import MagicMock\n"
        "\n"
        "def test_something():\n"
        "    svc = MagicMock()\n"
        "    assert svc.do_thing() is not None\n"
    )
    result = mock_gate(
        _write_req(
            f"{tmp_path}/tests/test_foo.py",
            content,
            str(tmp_path),
            policy_strikes=strikes,
        )
    )
    assert result is not None
    assert result.action == "deny"
    assert result.policy_name == "mock_gate"


def test_strike_count_increments_on_internal_mock(tmp_path):
    """Strike effect is emitted after each internal mock detection."""
    content = "from unittest.mock import MagicMock\ndef test_x():\n    m = MagicMock()\n"
    result = mock_gate(_write_req(f"{tmp_path}/tests/test_x.py", content, str(tmp_path)))

    assert result is not None
    strikes = result.effects["policy_strikes"]
    assert strikes[0]["policy_name"] == "mock_gate"
    assert strikes[0]["scope_key"] == "internal_mock"
    assert strikes[0]["count"] == 1
    assert not (tmp_path / ".claude" / ".mock-gate-strikes").exists()


# ---------------------------------------------------------------------------
# JS/TS mock detection
# ---------------------------------------------------------------------------


def test_jest_mock_internal_first_strike_feedback(tmp_path):
    """jest.mock() on an internal module gives feedback on first strike."""
    content = (
        "import { foo } from '../services/foo';\n"
        "\n"
        "jest.mock('../services/foo');\n"
        "\n"
        "test('foo works', () => {\n"
        "    expect(foo()).toBeDefined();\n"
        "});\n"
    )
    result = mock_gate(_write_req(f"{tmp_path}/tests/foo.test.ts", content, str(tmp_path)))
    assert result is not None
    assert result.action == "feedback"


def test_vitest_mock_external_allowed(tmp_path):
    """vi.mock() on an external library (axios) is allowed."""
    content = (
        "import { vi } from 'vitest';\n\nvi.mock('axios');\n\ntest('fetch works', () => {});\n"
    )
    result = mock_gate(_write_req(f"{tmp_path}/tests/foo.spec.ts", content, str(tmp_path)))
    # External mock target — should be None or feedback but NOT deny
    assert result is None or result.action != "deny"


# ---------------------------------------------------------------------------
# Edit tool — checks new_string
# ---------------------------------------------------------------------------


def test_edit_adding_internal_mock_first_strike_feedback(tmp_path):
    """Edit tool: new_string with internal mock gets feedback on first strike."""
    new_string = "from unittest.mock import MagicMock\ndef test_new():\n    svc = MagicMock()\n"
    result = mock_gate(_edit_req(f"{tmp_path}/tests/test_x.py", new_string, str(tmp_path)))
    assert result is not None
    assert result.action == "feedback"


# ---------------------------------------------------------------------------
# Compound integration — registry path
# ---------------------------------------------------------------------------


def test_registry_mock_gate_deny_on_second_strike(tmp_path):
    """Integration: full registry evaluate() denies internal mock on strike 2.

    Production sequence: Claude Write (test file) -> pre-write.sh ->
    cc-policy evaluate -> PolicyRegistry.evaluate() -> mock_gate -> deny.
    """
    reg = PolicyRegistry()
    reg.register("mock_gate", mock_gate, event_types=["Write", "Edit"], priority=750)

    content = (
        "from unittest.mock import MagicMock\n"
        "def test_something():\n"
        "    svc = MagicMock()\n"
        "    assert svc.method() is not None\n"
    )
    req = _write_req(
        f"{tmp_path}/tests/test_foo.py",
        content,
        str(tmp_path),
        policy_strikes={"mock_gate:internal_mock": {"count": 1}},
    )
    decision = reg.evaluate(req)
    assert decision.action == "deny"
    assert decision.policy_name == "mock_gate"
    assert decision.effects["policy_strikes"][0]["count"] == 2


def test_registry_mock_gate_allows_external_mocks():
    """Integration: external boundary mock passes through registry."""
    reg = PolicyRegistry()
    reg.register("mock_gate", mock_gate, event_types=["Write", "Edit"], priority=750)

    content = (
        "from unittest.mock import patch\n"
        "\n"
        "@patch('requests.post')\n"
        "def test_post(mock_post):\n"
        "    mock_post.return_value.status_code = 200\n"
    )
    req = _write_req("/proj/tests/test_api.py", content)
    decision = reg.evaluate(req)
    assert decision.action == "allow"

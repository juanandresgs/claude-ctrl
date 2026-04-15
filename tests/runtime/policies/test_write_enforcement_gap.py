"""Tests for enforcement_gap policy.

@decision DEC-PE-W2-TEST-003
Title: enforcement_gap tests write real .enforcement-gaps files in temp directories
Status: accepted
Rationale: enforcement_gap reads a flat file from disk. The correct test
  approach is to write a real file in a temp directory and point project_root
  at it — not mock Path.read_text. This exercises the actual file-read path
  and the pipe-delimited parse logic in production conditions.

Production sequence:
  Claude Write/Edit -> pre-write.sh -> cc-policy evaluate ->
  enforcement_gap(request) -> deny if gap count > 1.
"""

from __future__ import annotations

import os
import tempfile

from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.write_enforcement_gap import enforcement_gap
from runtime.core.policy_engine import PolicyContext, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(project_root: str, actor_role: str = "implementer") -> PolicyContext:
    return PolicyContext(
        actor_role=actor_role,
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
        capabilities=capabilities_for(actor_role),
    )


def _req(file_path: str, project_root: str) -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": file_path},
        context=_make_context(project_root),
        cwd=project_root,
    )


def _write_gaps_file(project_root: str, content: str) -> None:
    claude_dir = os.path.join(project_root, ".claude")
    os.makedirs(claude_dir, exist_ok=True)
    with open(os.path.join(claude_dir, ".enforcement-gaps"), "w") as f:
        f.write(content)


# ---------------------------------------------------------------------------
# Skip cases
# ---------------------------------------------------------------------------


def test_no_file_path_returns_none():
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={},
            context=_make_context(tmpdir),
            cwd=tmpdir,
        )
        assert enforcement_gap(req) is None


def test_non_source_file_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(tmpdir, "unsupported|json|none|2024|5|\n")
        assert enforcement_gap(_req("/proj/config.json", tmpdir)) is None


def test_skippable_path_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(tmpdir, "unsupported|py|none|2024|5|\n")
        assert enforcement_gap(_req("/proj/vendor/util.py", tmpdir)) is None


def test_no_gaps_file_returns_none():
    with tempfile.TemporaryDirectory() as tmpdir:
        # No .enforcement-gaps file exists
        assert enforcement_gap(_req("/proj/app.py", tmpdir)) is None


def test_no_matching_extension():
    with tempfile.TemporaryDirectory() as tmpdir:
        # Gap is for .ts, but file is .py
        _write_gaps_file(tmpdir, "unsupported|ts|none|2024|5|\n")
        assert enforcement_gap(_req(os.path.join(tmpdir, "app.py"), tmpdir)) is None


def test_count_one_not_denied():
    """Count == 1 is the first encounter — transient, not blocked."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(tmpdir, "unsupported|py|none|2024|1|\n")
        assert enforcement_gap(_req(os.path.join(tmpdir, "app.py"), tmpdir)) is None


# ---------------------------------------------------------------------------
# Deny cases
# ---------------------------------------------------------------------------


def test_unsupported_gap_count_gt_1_denied():
    """unsupported gap with count=2 must be denied."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(tmpdir, "unsupported|py|none|2024-01-01|2|\n")
        result = enforcement_gap(_req(os.path.join(tmpdir, "app.py"), tmpdir))
        assert result is not None
        assert result.action == "deny"
        assert "no linter profile" in result.reason
        assert "2 times" in result.reason
        assert result.policy_name == "enforcement_gap"


def test_missing_dep_gap_count_gt_1_denied():
    """missing_dep gap with count=3 must be denied, including tool name."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(tmpdir, "missing_dep|ts|eslint|2024-01-01|3|\n")
        result = enforcement_gap(_req(os.path.join(tmpdir, "component.ts"), tmpdir))
        assert result is not None
        assert result.action == "deny"
        assert "eslint" in result.reason
        assert "not installed" in result.reason
        assert "3 times" in result.reason
        assert result.policy_name == "enforcement_gap"


def test_unsupported_takes_precedence_over_missing_dep():
    """When both gap types are present, unsupported fires first (loop order)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(
            tmpdir,
            "unsupported|py|none|2024-01-01|2|\nmissing_dep|py|flake8|2024-01-01|5|\n",
        )
        result = enforcement_gap(_req(os.path.join(tmpdir, "app.py"), tmpdir))
        assert result is not None
        assert "no linter profile" in result.reason


def test_high_count_message_includes_count():
    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(tmpdir, "missing_dep|go|golangci-lint|2024-01-01|10|\n")
        result = enforcement_gap(_req(os.path.join(tmpdir, "main.go"), tmpdir))
        assert result is not None
        assert "10 times" in result.reason


# ---------------------------------------------------------------------------
# Compound integration test
# ---------------------------------------------------------------------------


def test_registry_enforcement_gap_fires_after_who():
    """Integration: enforcement_gap (250) runs after write_who (200) in the registry.

    When WHO passes (implementer), enforcement_gap must still fire for persistent gaps.
    """
    from runtime.core.policies.write_enforcement_gap import enforcement_gap as eg
    from runtime.core.policies.write_who import write_who as ww
    from runtime.core.policy_engine import PolicyRegistry

    with tempfile.TemporaryDirectory() as tmpdir:
        _write_gaps_file(tmpdir, "unsupported|py|none|2024-01-01|5|\n")

        reg = PolicyRegistry()
        reg.register("write_who", ww, event_types=["Write", "Edit"], priority=200)
        reg.register("enforcement_gap", eg, event_types=["Write", "Edit"], priority=250)

        ctx = _make_context(tmpdir)
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "app.py")},
            context=ctx,
            cwd=tmpdir,
        )
        decision = reg.evaluate(req)
        assert decision.action == "deny"
        assert decision.policy_name == "enforcement_gap"

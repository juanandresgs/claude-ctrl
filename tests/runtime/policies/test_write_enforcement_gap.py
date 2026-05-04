"""Tests for enforcement_gap policy.

@decision DEC-PE-W2-TEST-003
Title: enforcement_gap tests structured DB context
Status: accepted
Rationale: enforcement_gap consumes PolicyContext.enforcement_gaps populated
  by build_context from SQLite. Tests inject structured rows instead of
  creating project-local flatfiles.

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


def _gap(gap_type: str, ext: str, tool: str, count: int) -> dict:
    return {
        "project_root": "/proj",
        "gap_type": gap_type,
        "ext": ext,
        "tool": tool,
        "encounter_count": count,
        "status": "open",
    }


def _make_context(
    project_root: str,
    actor_role: str = "implementer",
    enforcement_gaps: tuple[dict, ...] = (),
) -> PolicyContext:
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
        enforcement_gaps=enforcement_gaps,
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
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": "/proj/config.json"},
            context=_make_context(tmpdir, enforcement_gaps=(_gap("unsupported", "json", "none", 5),)),
            cwd=tmpdir,
        )
        assert enforcement_gap(req) is None


def test_skippable_path_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": "/proj/vendor/util.py"},
            context=_make_context(tmpdir, enforcement_gaps=(_gap("unsupported", "py", "none", 5),)),
            cwd=tmpdir,
        )
        assert enforcement_gap(req) is None


def test_no_gaps_rows_returns_none():
    with tempfile.TemporaryDirectory() as tmpdir:
        assert enforcement_gap(_req("/proj/app.py", tmpdir)) is None


def test_no_matching_extension():
    with tempfile.TemporaryDirectory() as tmpdir:
        # Gap is for .ts, but file is .py
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "app.py")},
            context=_make_context(tmpdir, enforcement_gaps=(_gap("unsupported", "ts", "none", 5),)),
            cwd=tmpdir,
        )
        assert enforcement_gap(req) is None


def test_count_one_not_denied():
    """Count == 1 is the first encounter — transient, not blocked."""
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "app.py")},
            context=_make_context(tmpdir, enforcement_gaps=(_gap("unsupported", "py", "none", 1),)),
            cwd=tmpdir,
        )
        assert enforcement_gap(req) is None


# ---------------------------------------------------------------------------
# Deny cases
# ---------------------------------------------------------------------------


def test_unsupported_gap_count_gt_1_denied():
    """unsupported gap with count=2 must be denied."""
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "app.py")},
            context=_make_context(tmpdir, enforcement_gaps=(_gap("unsupported", "py", "none", 2),)),
            cwd=tmpdir,
        )
        result = enforcement_gap(req)
        assert result is not None
        assert result.action == "deny"
        assert "no linter profile" in result.reason
        assert "2 times" in result.reason
        assert result.policy_name == "enforcement_gap"


def test_missing_dep_gap_count_gt_1_denied():
    """missing_dep gap with count=3 must be denied, including tool name."""
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "component.ts")},
            context=_make_context(tmpdir, enforcement_gaps=(_gap("missing_dep", "ts", "eslint", 3),)),
            cwd=tmpdir,
        )
        result = enforcement_gap(req)
        assert result is not None
        assert result.action == "deny"
        assert "eslint" in result.reason
        assert "not installed" in result.reason
        assert "3 times" in result.reason
        assert result.policy_name == "enforcement_gap"


def test_unsupported_takes_precedence_over_missing_dep():
    """When both gap types are present, unsupported fires first (loop order)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "app.py")},
            context=_make_context(
                tmpdir,
                enforcement_gaps=(
                    _gap("unsupported", "py", "none", 2),
                    _gap("missing_dep", "py", "flake8", 5),
                ),
            ),
            cwd=tmpdir,
        )
        result = enforcement_gap(req)
        assert result is not None
        assert "no linter profile" in result.reason


def test_high_count_message_includes_count():
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "main.go")},
            context=_make_context(tmpdir, enforcement_gaps=(_gap("missing_dep", "go", "golangci-lint", 10),)),
            cwd=tmpdir,
        )
        result = enforcement_gap(req)
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
        reg = PolicyRegistry()
        reg.register("write_who", ww, event_types=["Write", "Edit"], priority=200)
        reg.register("enforcement_gap", eg, event_types=["Write", "Edit"], priority=250)

        ctx = _make_context(tmpdir, enforcement_gaps=(_gap("unsupported", "py", "none", 5),))
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

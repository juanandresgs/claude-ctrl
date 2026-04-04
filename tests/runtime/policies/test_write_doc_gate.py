"""Tests for write_doc_gate policy.

@decision DEC-PE-W5-TEST-001
Title: write_doc_gate tests exercise header + @decision enforcement as pure functions
Status: accepted
Rationale: The policy is a direct port of doc-gate.sh. All tests use
  hand-crafted PolicyContext and PolicyRequest — no subprocess, no DB I/O.
  The compound test exercises the full PolicyRegistry path to prove
  integration wiring is correct.

Production sequence:
  Claude Write/Edit -> pre-write.sh -> cc-policy evaluate ->
  PolicyRegistry.evaluate() -> doc_gate(request) -> deny|feedback|None
"""

from __future__ import annotations

from runtime.core.policies.write_doc_gate import doc_gate

from runtime.core.policy_engine import PolicyContext, PolicyRegistry, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(
    project_root: str = "/proj",
    is_meta_repo: bool = False,
    actor_role: str = "implementer",
) -> PolicyContext:
    return PolicyContext(
        actor_role=actor_role,
        actor_id="agent-1",
        workflow_id="wf-1",
        worktree_path=project_root,
        branch="feature/test",
        project_root=project_root,
        is_meta_repo=is_meta_repo,
        lease=None,
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
    )


def _write_req(
    file_path: str,
    content: str,
    project_root: str = "/proj",
    is_meta_repo: bool = False,
) -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": file_path, "content": content},
        context=_make_context(project_root=project_root, is_meta_repo=is_meta_repo),
        cwd=project_root,
    )


def _edit_req(
    file_path: str,
    new_string: str = "x = 1",
    project_root: str = "/proj",
) -> PolicyRequest:
    return PolicyRequest(
        event_type="Edit",
        tool_name="Edit",
        tool_input={"file_path": file_path, "new_string": new_string},
        context=_make_context(project_root=project_root),
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
    assert doc_gate(req) is None


def test_non_source_file_skipped():
    """Markdown, JSON, YAML are not source files — no opinion."""
    assert doc_gate(_write_req("/proj/README.md", "# Hello")) is None
    assert doc_gate(_write_req("/proj/config.json", "{}")) is None
    assert doc_gate(_write_req("/proj/data.yaml", "key: value")) is None


def test_meta_infra_skipped():
    """Files under .claude/ are meta-infrastructure — exempt."""
    content = '"""No header but exempt."""\nx = 1\n'
    assert doc_gate(_write_req("/proj/.claude/hooks/myhook.sh", content)) is None


def test_skippable_path_skipped():
    assert doc_gate(_write_req("/proj/vendor/util.py", "x = 1")) is None
    assert doc_gate(_write_req("/proj/node_modules/main.js", "var x = 1;")) is None


def test_empty_content_skipped():
    assert doc_gate(_write_req("/proj/app.py", "")) is None


# ---------------------------------------------------------------------------
# Write — no header: deny
# ---------------------------------------------------------------------------


def test_write_missing_python_header_deny():
    """Python file with no doc string — deny."""
    content = "import os\n\ndef foo(): pass\n"
    result = doc_gate(_write_req("/proj/app.py", content))
    assert result is not None
    assert result.action == "deny"
    assert "documentation header" in result.reason.lower()
    assert result.policy_name == "doc_gate"


def test_write_missing_shell_header_deny():
    """Shell file with shebang only (no doc comment) — deny."""
    content = "#!/usr/bin/env bash\nset -euo pipefail\necho hello\n"
    result = doc_gate(_write_req("/proj/deploy.sh", content))
    assert result is not None
    assert result.action == "deny"


def test_write_missing_ts_header_deny():
    """TypeScript file with no doc comment — deny."""
    content = "import { foo } from './bar';\nconst x = 1;\n"
    result = doc_gate(_write_req("/proj/app.ts", content))
    assert result is not None
    assert result.action == "deny"


# ---------------------------------------------------------------------------
# Write — has header, short file: allow
# ---------------------------------------------------------------------------


def test_write_python_with_header_allowed():
    content = '"""Module description."""\nimport os\ndef foo():\n    pass\n'
    result = doc_gate(_write_req("/proj/app.py", content))
    assert result is None


def test_write_shell_with_header_allowed():
    content = "#!/usr/bin/env bash\n# Script description.\nset -euo pipefail\n"
    result = doc_gate(_write_req("/proj/deploy.sh", content))
    assert result is None


# ---------------------------------------------------------------------------
# Write — 50+ lines without @decision: deny
# ---------------------------------------------------------------------------


def test_write_50_lines_no_decision_deny():
    """50-line Python file with header but no @decision annotation — deny."""
    lines = ['"""Module header."""\n'] + ["x = 1\n"] * 49  # 50 lines total
    content = "".join(lines)
    result = doc_gate(_write_req("/proj/big_module.py", content))
    assert result is not None
    assert result.action == "deny"
    assert "@decision" in result.reason.lower()


def test_write_50_lines_with_decision_allowed():
    """50-line Python file with @decision annotation — allow."""
    lines = (
        ['"""Module header."""\n'] + ["# @decision DEC-TEST-001\n"] + ["x = 1\n"] * 48  # 50 total
    )
    content = "".join(lines)
    result = doc_gate(_write_req("/proj/big_module.py", content))
    assert result is None


def test_write_49_lines_no_decision_allowed():
    """Under-50 lines with header but no @decision — allow (threshold not met)."""
    lines = ['"""Module header."""\n'] + ["x = 1\n"] * 48  # 49 lines
    content = "".join(lines)
    result = doc_gate(_write_req("/proj/app.py", content))
    assert result is None


# ---------------------------------------------------------------------------
# Write — markdown in project root (advisory)
# ---------------------------------------------------------------------------


def test_new_md_in_project_root_gives_feedback():
    """Creating a non-operational markdown file in project root → feedback."""
    result = doc_gate(_write_req("/proj/NOTES.md", "# Notes", project_root="/proj"))
    # advisory (feedback) or None depending on whether file exists (not on disk)
    # The policy returns feedback for new non-operational markdown
    assert result is not None
    assert result.action == "feedback"


def test_operational_md_in_project_root_allowed():
    """CLAUDE.md and MASTER_PLAN.md are operational — no feedback."""
    assert doc_gate(_write_req("/proj/CLAUDE.md", "# Claude", project_root="/proj")) is None
    assert doc_gate(_write_req("/proj/MASTER_PLAN.md", "# Plan", project_root="/proj")) is None


# ---------------------------------------------------------------------------
# Edit — no header check (file exists, advise only)
# ---------------------------------------------------------------------------


def test_edit_no_file_path_returns_none():
    req = PolicyRequest(
        event_type="Edit",
        tool_name="Edit",
        tool_input={},
        context=_make_context(),
        cwd="/proj",
    )
    assert doc_gate(req) is None


def test_edit_non_source_file_skipped():
    req = _edit_req("/proj/README.md")
    assert doc_gate(req) is None


# ---------------------------------------------------------------------------
# Compound integration — registry path
# ---------------------------------------------------------------------------


def test_registry_doc_gate_denies_headerless_python():
    """Integration: full registry evaluate() denies a headerless Python Write.

    Production sequence: Claude Write -> pre-write.sh -> cc-policy evaluate ->
    PolicyRegistry.evaluate() -> doc_gate -> deny.
    """
    reg = PolicyRegistry()
    reg.register("doc_gate", doc_gate, event_types=["Write", "Edit"], priority=700)

    content = "import os\ndef main(): pass\n"
    req = _write_req("/proj/main.py", content)
    decision = reg.evaluate(req)
    assert decision.action == "deny"
    assert decision.policy_name == "doc_gate"


def test_registry_doc_gate_allows_documented_python():
    """Integration: fully documented Python file passes through registry."""
    reg = PolicyRegistry()
    reg.register("doc_gate", doc_gate, event_types=["Write", "Edit"], priority=700)

    content = '"""Fully documented module."""\ndef main():\n    pass\n'
    req = _write_req("/proj/main.py", content)
    decision = reg.evaluate(req)
    assert decision.action == "allow"


def test_registry_doc_gate_denies_large_file_no_decision():
    """Integration: 50+ line Python with header but no @decision → deny."""
    reg = PolicyRegistry()
    reg.register("doc_gate", doc_gate, event_types=["Write", "Edit"], priority=700)

    lines = ['"""Module header."""\n'] + ["x = 1\n"] * 49
    content = "".join(lines)
    req = _write_req("/proj/big.py", content)
    decision = reg.evaluate(req)
    assert decision.action == "deny"
    assert "@decision" in decision.reason.lower()

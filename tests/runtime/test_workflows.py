"""Unit tests for runtime.core.workflows.

@decision DEC-TEST-WF-001
Title: Workflow unit tests exercise the real domain sequence end-to-end
Status: accepted
Rationale: Tests cover the production sequence: bind_workflow → set_scope →
  check_scope_compliance, which mirrors what subagent-start.sh and guard.sh
  invoke at runtime. Mocks are avoided — all tests use a real in-memory SQLite
  connection with ensure_schema() applied, matching the production DB state.
  The compound interaction test (test_full_workflow_lifecycle) exercises the
  complete flow across all functions as they would execute in production.
"""

from __future__ import annotations

import json
import sqlite3
import time

import pytest

from runtime.schemas import ensure_schema
from runtime.core.workflows import (
    bind_workflow,
    check_scope_compliance,
    get_binding,
    get_scope,
    list_bindings,
    set_scope,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# Schema checks (Check 1 & 2 of Evaluation Contract)
# ---------------------------------------------------------------------------


def test_workflow_bindings_table_exists(conn):
    """Check 1: workflow_bindings table has expected columns."""
    cols = {
        row[1]
        for row in conn.execute("PRAGMA table_info(workflow_bindings)").fetchall()
    }
    required = {
        "workflow_id", "worktree_path", "branch", "base_branch",
        "ticket", "initiative", "created_at", "updated_at",
    }
    assert required <= cols, f"Missing columns: {required - cols}"


def test_workflow_scope_table_exists(conn):
    """Check 2: workflow_scope table has expected columns."""
    cols = {
        row[1]
        for row in conn.execute("PRAGMA table_info(workflow_scope)").fetchall()
    }
    required = {
        "workflow_id", "allowed_paths", "required_paths",
        "forbidden_paths", "authority_domains", "updated_at",
    }
    assert required <= cols, f"Missing columns: {required - cols}"


# ---------------------------------------------------------------------------
# bind_workflow / get_binding
# ---------------------------------------------------------------------------


def test_bind_workflow_creates_record(conn):
    bind_workflow(conn, "wf-abc", "/path/to/wt", "feature/abc")
    b = get_binding(conn, "wf-abc")
    assert b is not None
    assert b["workflow_id"] == "wf-abc"
    assert b["worktree_path"] == "/path/to/wt"
    assert b["branch"] == "feature/abc"
    assert b["base_branch"] == "main"
    assert b["ticket"] is None
    assert b["initiative"] is None


def test_bind_workflow_with_optional_fields(conn):
    bind_workflow(
        conn, "wf-xyz", "/some/path", "feature/xyz",
        base_branch="develop", ticket="TKT-021", initiative="INIT-004",
    )
    b = get_binding(conn, "wf-xyz")
    assert b["base_branch"] == "develop"
    assert b["ticket"] == "TKT-021"
    assert b["initiative"] == "INIT-004"


def test_bind_workflow_upserts_on_conflict(conn):
    bind_workflow(conn, "wf-up", "/old/path", "feature/up")
    time.sleep(0.01)  # ensure updated_at advances
    bind_workflow(conn, "wf-up", "/new/path", "feature/up-v2", ticket="TKT-099")
    b = get_binding(conn, "wf-up")
    assert b["worktree_path"] == "/new/path"
    assert b["branch"] == "feature/up-v2"
    assert b["ticket"] == "TKT-099"


def test_get_binding_returns_none_for_unknown(conn):
    assert get_binding(conn, "no-such-workflow") is None


def test_list_bindings_empty(conn):
    assert list_bindings(conn) == []


def test_list_bindings_returns_all(conn):
    bind_workflow(conn, "wf-1", "/p1", "b1")
    bind_workflow(conn, "wf-2", "/p2", "b2")
    items = list_bindings(conn)
    assert len(items) == 2
    ids = {i["workflow_id"] for i in items}
    assert ids == {"wf-1", "wf-2"}


# ---------------------------------------------------------------------------
# Check 10: roundtrip
# ---------------------------------------------------------------------------


def test_bind_roundtrip(conn):
    """Check 10: bind then get returns matching fields."""
    bind_workflow(
        conn, "tkt-021", "/worktrees/impl", "feature/tkt-021",
        ticket="TKT-021",
    )
    b = get_binding(conn, "tkt-021")
    assert b["workflow_id"] == "tkt-021"
    assert b["worktree_path"] == "/worktrees/impl"
    assert b["branch"] == "feature/tkt-021"
    assert b["ticket"] == "TKT-021"


# ---------------------------------------------------------------------------
# set_scope / get_scope
# ---------------------------------------------------------------------------


def test_set_scope_requires_binding(conn):
    """set_scope raises ValueError when workflow_id has no binding."""
    with pytest.raises(ValueError, match="not found in workflow_bindings"):
        set_scope(conn, "ghost-wf", ["runtime/*.py"], [], [], [])


def test_set_scope_and_get_scope_roundtrip(conn):
    """Check 16: scope-set writes, scope-get reads back matching."""
    bind_workflow(conn, "wf-s", "/p", "b")
    set_scope(
        conn, "wf-s",
        allowed_paths=["runtime/*.py", "hooks/*.sh"],
        required_paths=["runtime/core/workflows.py"],
        forbidden_paths=["settings.json"],
        authority_domains=["runtime"],
    )
    s = get_scope(conn, "wf-s")
    assert s is not None
    assert s["allowed_paths"] == ["runtime/*.py", "hooks/*.sh"]
    assert s["required_paths"] == ["runtime/core/workflows.py"]
    assert s["forbidden_paths"] == ["settings.json"]
    assert s["authority_domains"] == ["runtime"]


def test_get_scope_returns_none_when_missing(conn):
    bind_workflow(conn, "wf-noscope", "/p", "b")
    assert get_scope(conn, "wf-noscope") is None


def test_set_scope_upserts(conn):
    bind_workflow(conn, "wf-upsert-scope", "/p", "b")
    set_scope(conn, "wf-upsert-scope", ["a/*.py"], [], [], [])
    set_scope(conn, "wf-upsert-scope", ["b/*.sh"], [], [], [])
    s = get_scope(conn, "wf-upsert-scope")
    assert s["allowed_paths"] == ["b/*.sh"]


# ---------------------------------------------------------------------------
# check_scope_compliance — Check 11
# ---------------------------------------------------------------------------


def test_compliance_allowed_match(conn):
    """Check 11a: file matching allowed_paths is compliant."""
    bind_workflow(conn, "wf-c1", "/p", "b")
    set_scope(conn, "wf-c1", allowed_paths=["runtime/*.py", "hooks/*.sh"],
              required_paths=[], forbidden_paths=[], authority_domains=[])
    result = check_scope_compliance(conn, "wf-c1", ["runtime/cli.py"])
    assert result["compliant"] is True
    assert result["violations"] == []
    assert "runtime/cli.py" in result["in_scope"]


def test_compliance_file_outside_allowed(conn):
    """Check 11b: file not matching allowed_paths is a violation."""
    bind_workflow(conn, "wf-c2", "/p", "b")
    set_scope(conn, "wf-c2", allowed_paths=["runtime/*.py"],
              required_paths=[], forbidden_paths=[], authority_domains=[])
    result = check_scope_compliance(conn, "wf-c2", ["hooks/guard.sh"])
    assert result["compliant"] is False
    assert any("hooks/guard.sh" in v for v in result["violations"])


def test_compliance_forbidden_takes_precedence(conn):
    """Check 11c: file matching both allowed and forbidden → violation."""
    bind_workflow(conn, "wf-c3", "/p", "b")
    set_scope(
        conn, "wf-c3",
        allowed_paths=["*.json"],  # would allow settings.json
        required_paths=[],
        forbidden_paths=["settings.json"],  # but forbidden takes precedence
        authority_domains=[],
    )
    result = check_scope_compliance(conn, "wf-c3", ["settings.json"])
    assert result["compliant"] is False
    assert any("FORBIDDEN" in v for v in result["violations"])


def test_compliance_no_scope_returns_compliant(conn):
    """No scope → all files accepted (guard.sh enforces hard deny separately)."""
    bind_workflow(conn, "wf-noscope2", "/p", "b")
    result = check_scope_compliance(conn, "wf-noscope2", ["any/file.py"])
    assert result["compliant"] is True
    assert result["violations"] == []


def test_compliance_mixed_results(conn):
    """Files can partially pass — in_scope and violations are both populated."""
    bind_workflow(conn, "wf-mixed", "/p", "b")
    set_scope(conn, "wf-mixed", allowed_paths=["runtime/*.py"],
              required_paths=[], forbidden_paths=[], authority_domains=[])
    result = check_scope_compliance(conn, "wf-mixed", [
        "runtime/cli.py",      # allowed
        "hooks/guard.sh",      # not allowed
    ])
    assert result["compliant"] is False
    assert "runtime/cli.py" in result["in_scope"]
    assert any("hooks/guard.sh" in v for v in result["violations"])


def test_compliance_empty_allowed_accepts_everything(conn):
    """Empty allowed_paths with no forbidden means no restrictions."""
    bind_workflow(conn, "wf-empty-allowed", "/p", "b")
    set_scope(conn, "wf-empty-allowed", allowed_paths=[],
              required_paths=[], forbidden_paths=[], authority_domains=[])
    result = check_scope_compliance(conn, "wf-empty-allowed", ["anything/file.py"])
    assert result["compliant"] is True


# ---------------------------------------------------------------------------
# Branch-name / workflow-id mismatch scenario (CRITICAL enforcement)
# ---------------------------------------------------------------------------


def test_scope_for_different_workflow_id_does_not_satisfy_binding(conn):
    """Pre-load scope for 'feature-foo', bind with 'feature-bar' → scope absent for bar.

    This mirrors the branch-name/workflow_id consistency enforcement:
    guard.sh reads both binding and scope for the SAME workflow_id. If scope
    was loaded for a different workflow_id, the check fails.
    """
    # Planner pre-loads scope for feature-foo
    bind_workflow(conn, "feature-foo", "/wt/foo", "feature/foo")
    set_scope(conn, "feature-foo",
              allowed_paths=["runtime/*.py"], required_paths=[],
              forbidden_paths=[], authority_domains=[])

    # Implementer's branch is actually feature-bar — bind_workflow is called
    bind_workflow(conn, "feature-bar", "/wt/bar", "feature/bar")

    # scope-get for feature-bar must return None (not feature-foo's scope)
    assert get_scope(conn, "feature-bar") is None

    # scope-check for feature-bar with no scope returns compliant=True BUT
    # guard.sh Check 12 will independently deny when scope is absent
    result = check_scope_compliance(conn, "feature-bar", ["runtime/cli.py"])
    assert result["compliant"] is True  # domain layer permissive
    assert "note" in result             # but advisory note present


# ---------------------------------------------------------------------------
# Compound interaction test — full production sequence
# ---------------------------------------------------------------------------


def test_full_workflow_lifecycle(conn):
    """Compound: bind → set_scope → check_scope_compliance → list_bindings.

    This exercises the real production sequence:
    1. subagent-start.sh calls bind_workflow when implementer spawns
    2. Planner calls set_scope to register the scope manifest
    3. check-implementer.sh and guard.sh call check_scope_compliance
    4. list_bindings is the audit trail

    This test must cross all internal component boundaries.
    """
    # 1. Bind (simulates subagent-start.sh)
    bind_workflow(
        conn, "feature-tkt-021", "/worktrees/tkt-021", "feature/tkt-021",
        ticket="TKT-021", initiative="INIT-004",
    )
    b = get_binding(conn, "feature-tkt-021")
    assert b is not None
    assert b["ticket"] == "TKT-021"

    # 2. Set scope (simulates planner scope ingestion)
    set_scope(
        conn, "feature-tkt-021",
        allowed_paths=["runtime/*.py", "runtime/core/*.py", "hooks/*.sh",
                       "tests/runtime/*.py", "tests/scenarios/*.sh", "CLAUDE.md"],
        required_paths=["runtime/core/workflows.py"],
        forbidden_paths=["settings.json", "agents/*.md", "MASTER_PLAN.md"],
        authority_domains=["runtime", "hooks"],
    )
    s = get_scope(conn, "feature-tkt-021")
    assert s is not None
    assert "runtime/*.py" in s["allowed_paths"]
    assert "settings.json" in s["forbidden_paths"]

    # 3. Check compliance — all allowed
    result = check_scope_compliance(
        conn, "feature-tkt-021",
        ["runtime/cli.py", "runtime/core/workflows.py", "hooks/guard.sh"],
    )
    assert result["compliant"] is True
    assert result["violations"] == []

    # 4. Check compliance — forbidden file
    result2 = check_scope_compliance(
        conn, "feature-tkt-021", ["settings.json"],
    )
    assert result2["compliant"] is False
    assert any("FORBIDDEN" in v for v in result2["violations"])

    # 5. Check compliance — agents file (forbidden glob)
    result3 = check_scope_compliance(
        conn, "feature-tkt-021", ["agents/implementer.md"],
    )
    assert result3["compliant"] is False

    # 6. list_bindings shows the binding
    bindings = list_bindings(conn)
    assert any(b["workflow_id"] == "feature-tkt-021" for b in bindings)

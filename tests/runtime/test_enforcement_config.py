"""Unit tests for runtime.core.enforcement_config.

Tests the enforcement_config table domain module using an in-memory SQLite
database seeded via ensure_schema(). Covers the get/set_/list_all round-trips,
the WHO gate, scope precedence semantics, and the seeded global defaults.

@decision DEC-CONFIG-AUTHORITY-001
Title: Policy engine is the canonical authority for enforcement toggles
Status: accepted
Rationale: enforcement_config replaces the scattered toggle authorities
  (settings.json, codex state.json). These tests confirm the single-authority
  invariant: only guardian may write, all readers go through the same get()
  with scope precedence (workflow > project > global > None).

@decision DEC-REGULAR-STOP-REVIEW-001
Title: Regular Stop review gate toggled via enforcement_config, not state.json
Status: accepted
Rationale: Tests confirm review_gate_regular_stop is seeded true globally,
  overridable per-project and per-workflow, and guarded by the WHO gate.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core import enforcement_config as ec
from runtime.core.db import connect_memory
from runtime.core.enforcement_config import PermissionError as ECPermissionError
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# 1. Seeded global defaults
# ---------------------------------------------------------------------------


def test_get_global_default_returns_seeded_value(conn):
    """ensure_schema() seeds review_gate_regular_stop=true in the global scope."""
    value = ec.get(conn, "review_gate_regular_stop")
    assert value == "true", (
        f"Expected seeded default 'true', got {value!r}. "
        "Check ensure_schema() _defaults list in runtime/schemas.py."
    )


def test_get_unknown_key_returns_none(conn):
    """A key that has never been written must return None — not False or empty string."""
    value = ec.get(conn, "nonexistent_key_xyz")
    assert value is None


# ---------------------------------------------------------------------------
# 2. WHO gate: set_() permission enforcement
# ---------------------------------------------------------------------------


def test_set_as_guardian_writes_value(conn):
    """Guardian role may write enforcement_config; value is readable back."""
    ec.set_(conn, "review_gate_regular_stop", "false", actor_role="guardian")
    value = ec.get(conn, "review_gate_regular_stop")
    assert value == "false"


def test_set_as_implementer_raises_permission_error(conn):
    """Implementer role must not be allowed to write enforcement_config."""
    with pytest.raises(ECPermissionError):
        ec.set_(conn, "review_gate_regular_stop", "false", actor_role="implementer")


def test_set_as_orchestrator_raises_permission_error(conn):
    """Empty actor_role (orchestrator) must not be allowed to write enforcement_config."""
    with pytest.raises(ECPermissionError):
        ec.set_(conn, "review_gate_regular_stop", "false", actor_role="")


# ---------------------------------------------------------------------------
# 3. Scope precedence: workflow overrides project overrides global
# ---------------------------------------------------------------------------


def test_workflow_scope_overrides_project_overrides_global(conn):
    """Scope precedence: workflow= beats project= beats global."""
    # Write at all three scopes with distinct values.
    ec.set_(conn, "review_gate_provider", "codex", scope="global", actor_role="guardian")
    ec.set_(
        conn, "review_gate_provider", "gemini", scope="project=/my/project", actor_role="guardian"
    )
    ec.set_(conn, "review_gate_provider", "openai", scope="workflow=wf-123", actor_role="guardian")

    # No scope qualifiers → global
    assert ec.get(conn, "review_gate_provider") == "codex"

    # Project scope provided → project wins over global
    assert ec.get(conn, "review_gate_provider", project_root="/my/project") == "gemini"

    # Workflow scope provided → workflow wins over project
    assert (
        ec.get(conn, "review_gate_provider", workflow_id="wf-123", project_root="/my/project")
        == "openai"
    )

    # Workflow present but key only set at project level → project value returned
    assert (
        ec.get(conn, "review_gate_provider", workflow_id="other-wf", project_root="/my/project")
        == "gemini"
    )


# ---------------------------------------------------------------------------
# 4. list_all round-trip
# ---------------------------------------------------------------------------


def test_list_all_returns_seeded_rows(conn):
    """list_all() returns at least the two seeded defaults from ensure_schema()."""
    rows = ec.list_all(conn)
    keys = {r["key"] for r in rows}
    assert "review_gate_regular_stop" in keys
    assert "review_gate_provider" in keys


def test_list_all_scope_filter(conn):
    """list_all(scope='global') returns only global-scoped rows."""
    ec.set_(conn, "my_key", "val", scope="project=/foo", actor_role="guardian")
    global_rows = ec.list_all(conn, scope="global")
    for row in global_rows:
        assert row["scope"] == "global", f"Expected scope=global, got {row['scope']!r}"

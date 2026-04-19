"""Single-authority invariant tests for scope-list parser consolidation.

Asserts that all four policy modules that consume workflow_scope.forbidden_paths
/ allowed_paths reference the SAME parse_scope_list object from
runtime.core.policy_utils — not local redefinitions. A failure here means a
maintainer re-introduced a local copy, breaking the single-authority contract.

@decision DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001
Title: parse_scope_list is the sole canonical parser for workflow_scope JSON-TEXT
Status: accepted
Rationale: See runtime/core/policy_utils.py DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001.
  This test makes the constraint mechanically enforceable — any local redefinition
  causes immediate CI failure rather than silent drift.

Production sequence exercised:
  cc-policy evaluate -> PolicyEngine.evaluate() -> policy.check(request) ->
  _parse_scope_list(scope.get("forbidden_paths")) -> canonical parse_scope_list()

Tests:
  1. Identity invariant: each module's _parse_scope_list IS canonical (not a copy).
  2. Behavioral proof: each module's _parse_scope_list produces the same output as
     the canonical for a representative scope-row value.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from runtime.core import policy_utils
from runtime.core.policies import (
    bash_cross_branch_restore_ban,
    bash_shell_copy_ban,
    write_plan_guard,
    write_who,
)

_CANONICAL = policy_utils.parse_scope_list
_ALL_MODULES = (
    write_plan_guard,
    write_who,
    bash_cross_branch_restore_ban,
    bash_shell_copy_ban,
)


# ---------------------------------------------------------------------------
# Identity invariant
# ---------------------------------------------------------------------------


def test_all_policy_callers_reference_canonical_parser():
    """Each migrated module's _parse_scope_list IS the canonical parse_scope_list.

    Object identity (``is``) not equality (``==``) — a locally-defined function
    with identical body would pass ``==`` but fail ``is``.
    """
    for mod in _ALL_MODULES:
        assert mod._parse_scope_list is _CANONICAL, (
            f"{mod.__name__}._parse_scope_list is NOT runtime.core.policy_utils."
            "parse_scope_list — a local redefinition was detected. Remove the "
            "local copy and import from policy_utils (DEC-DISCIPLINE-SCOPE-PARSER-"
            "SINGLE-AUTH-001)."
        )


# ---------------------------------------------------------------------------
# Behavioral proof: all modules produce canonical output for real scope rows
# ---------------------------------------------------------------------------


def test_behavioral_parity_json_encoded_list():
    """Each module's _parse_scope_list decodes a JSON-encoded list correctly.

    This is the production format: workflow_scope.forbidden_paths is stored as
    a JSON-TEXT column (e.g. '["runtime/**", "hooks/**"]').
    """
    raw = json.dumps(["runtime/**", "hooks/**", "agents/*.md"])
    expected = _CANONICAL(raw)
    for mod in _ALL_MODULES:
        result = mod._parse_scope_list(raw)
        assert result == expected, (
            f"{mod.__name__}._parse_scope_list produced {result!r}, "
            f"expected {expected!r} for input {raw!r}"
        )


def test_behavioral_parity_plain_list():
    """Each module's _parse_scope_list handles a native list input correctly."""
    raw = ["runtime/**", "hooks/**"]
    expected = _CANONICAL(raw)
    for mod in _ALL_MODULES:
        result = mod._parse_scope_list(raw)
        assert result == expected, (
            f"{mod.__name__}._parse_scope_list produced {result!r}, "
            f"expected {expected!r} for input {raw!r}"
        )


def test_behavioral_parity_empty_and_none():
    """Each module's _parse_scope_list handles empty/None inputs identically."""
    for raw in (None, "", "[]", [], "not-json"):
        expected = _CANONICAL(raw)
        for mod in _ALL_MODULES:
            result = mod._parse_scope_list(raw)
            assert result == expected, (
                f"{mod.__name__}._parse_scope_list({raw!r}) = {result!r}, "
                f"expected {expected!r}"
            )

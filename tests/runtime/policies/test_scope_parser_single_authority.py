"""Single-authority invariant tests for scope-list parser consolidation.

Asserts that EVERY policy module under runtime.core.policies that exposes
_parse_scope_list references the SAME parse_scope_list object from
runtime.core.policy_utils — not a local redefinition. A failure here means a
maintainer re-introduced a local copy, breaking the single-authority contract.

Slice 11 enforced this over a hardcoded 4-module tuple. Slice 12 replaces
that tuple with pkgutil.iter_modules discovery so that any NEW policy module
carrying a local _parse_scope_list copy is caught automatically without
needing to update this file.

@decision DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-002
Title: discovery-based invariant over runtime.core.policies.*
Status: accepted
Rationale: slice 11 enforced single-authority on 4 enumerated modules; slice
  12 expands coverage to every current and future _parse_scope_list consumer
  under runtime.core.policies via pkgutil.iter_modules so that adding a new
  policy module cannot silently re-open the drift window. Adding a new
  policy module with a local _parse_scope_list will now cause CI failure
  without any manual update to this file.
  Extends: DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001 (policy_utils.py)

Production sequence exercised:
  cc-policy evaluate -> PolicyEngine.evaluate() -> policy.check(request) ->
  _parse_scope_list(scope.get("forbidden_paths")) -> canonical parse_scope_list()

Tests:
  1. Discovery-based identity invariant: every module's _parse_scope_list IS
     canonical (not a copy). Lower-bound guard ensures >= 4 callers found.
  2. Behavioral proof: discovered modules' _parse_scope_list produces the same
     output as the canonical for representative scope-row values.
  3. Negative teeth test: proves the is-identity check FAILS when a module
     exposes a divergent _parse_scope_list — the invariant has real teeth.
"""

from __future__ import annotations

import importlib
import json
import pkgutil
import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

import runtime.core.policies as _policies_pkg
from runtime.core import policy_utils

_CANONICAL = policy_utils.parse_scope_list


# ---------------------------------------------------------------------------
# Discovery helper
# ---------------------------------------------------------------------------


def _iter_policy_modules():
    """Yield every non-private submodule of runtime.core.policies.

    Skips names starting with '_' (covers __init__ and any future
    _private.py helpers). Does NOT recurse into subpackages (current
    layout is flat).

    Import failures propagate loudly — a policy module that fails to
    import is itself a defect this test surface should catch.
    """
    for info in pkgutil.iter_modules(_policies_pkg.__path__):
        if info.name.startswith("_"):
            continue
        yield importlib.import_module(f"runtime.core.policies.{info.name}")


def _scope_parser_modules():
    """Return modules under runtime.core.policies that expose _parse_scope_list."""
    return [m for m in _iter_policy_modules() if hasattr(m, "_parse_scope_list")]


# ---------------------------------------------------------------------------
# Identity invariant (discovery-based, replaces slice-11 hardcoded tuple)
# ---------------------------------------------------------------------------


def test_all_policy_callers_reference_canonical_parser():
    """Every module's _parse_scope_list IS the canonical parse_scope_list.

    Object identity (``is``) not equality (``==``) — a locally-defined
    function with an identical body would pass ``==`` but fail ``is``.

    Lower-bound guard (>= 4): ensures the discovery did not collapse to a
    vacuous no-op if all callers are renamed/removed without updating this
    test. The bound must be updated in the same PR as any legitimate removal.

    Replaces the slice-11 hardcoded 4-module tuple. Discovery is done via
    pkgutil.iter_modules over runtime.core.policies.__path__ so any future
    policy module that carries a local _parse_scope_list is caught without
    editing this file.
    """
    matches = _scope_parser_modules()
    assert len(matches) >= 4, (
        f"Discovery found only {len(matches)} _parse_scope_list consumer(s): "
        f"{[m.__name__ for m in matches]}. Expected >= 4. "
        "If callers were legitimately removed, update this lower bound "
        "(DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-002)."
    )
    for mod in matches:
        assert mod._parse_scope_list is _CANONICAL, (
            f"{mod.__name__}._parse_scope_list has diverged from the canonical "
            "runtime.core.policy_utils.parse_scope_list — a local redefinition "
            "was detected. Remove the local copy and import from policy_utils "
            "(DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-002)."
        )


# ---------------------------------------------------------------------------
# Negative teeth test
# ---------------------------------------------------------------------------


def test_negative_divergent_local_redefinition_would_fail():
    """The is-identity invariant must reject a divergent local _parse_scope_list.

    Constructs an in-memory fake module (NOT inserted into sys.modules, NOT
    placed under runtime.core.policies) that exposes a distinct local
    _parse_scope_list function. Passes it directly to the assertion logic
    and asserts that the identity check raises AssertionError.

    This proves the invariant has teeth: a module with a locally-defined
    copy — even one with an identical body — would cause CI failure.
    """
    fake_mod = types.ModuleType("fake_policy_local_copy_slice12")

    def _local_divergent_parser(value):  # different object, not canonical
        return []

    fake_mod._parse_scope_list = _local_divergent_parser

    # The production invariant assertion must fail on the fake module.
    with pytest.raises(AssertionError):
        assert fake_mod._parse_scope_list is _CANONICAL, (
            "fake_policy has a divergent _parse_scope_list"
        )


# ---------------------------------------------------------------------------
# Behavioral proof: all discovered modules produce canonical output
# ---------------------------------------------------------------------------


def test_behavioral_parity_json_encoded_list():
    """Each module's _parse_scope_list decodes a JSON-encoded list correctly.

    This is the production format: workflow_scope.forbidden_paths is stored
    as a JSON-TEXT column (e.g. '["runtime/**", "hooks/**"]').
    """
    raw = json.dumps(["runtime/**", "hooks/**", "agents/*.md"])
    expected = _CANONICAL(raw)
    for mod in _scope_parser_modules():
        result = mod._parse_scope_list(raw)
        assert result == expected, (
            f"{mod.__name__}._parse_scope_list produced {result!r}, "
            f"expected {expected!r} for input {raw!r}"
        )


def test_behavioral_parity_plain_list():
    """Each module's _parse_scope_list handles a native list input correctly."""
    raw = ["runtime/**", "hooks/**"]
    expected = _CANONICAL(raw)
    for mod in _scope_parser_modules():
        result = mod._parse_scope_list(raw)
        assert result == expected, (
            f"{mod.__name__}._parse_scope_list produced {result!r}, "
            f"expected {expected!r} for input {raw!r}"
        )


def test_behavioral_parity_empty_and_none():
    """Each module's _parse_scope_list handles empty/None inputs identically."""
    for raw in (None, "", "[]", [], "not-json"):
        expected = _CANONICAL(raw)
        for mod in _scope_parser_modules():
            result = mod._parse_scope_list(raw)
            assert result == expected, (
                f"{mod.__name__}._parse_scope_list({raw!r}) = {result!r}, "
                f"expected {expected!r}"
            )

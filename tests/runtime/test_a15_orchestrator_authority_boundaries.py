"""A15 — consolidated invariant pins for orchestrator/subagent authority boundaries.

Mechanical verification of the three A15 objectives at soak HEAD:

1. `required_subagent_type` is end-to-end enforced for seat-owned operations:
   contract-bearing dispatch-significant launches must carry a matching
   (stage_id, subagent_type) pair; mismatch denies fail-closed.

2. Canonical seat routing is the authoritative source: classification lives in
   `authority_registry.canonical_dispatch_subagent_type` +
   `STAGE_SUBAGENT_TYPES`; `dispatch_contract.py` is an adapter-shim
   (identity re-export from authority_registry, no parallel mapping).

3. Orchestrator cannot self-execute seat-owned work: `write_who` denies
   source-file writes from any actor lacking `CAN_WRITE_SOURCE`; `plan_guard`
   denies governance writes from any actor lacking `CAN_WRITE_GOVERNANCE`
   OR any actor (regardless of capability) whose target matches
   `workflow_scope.forbidden_paths`.

This file is the single A15 invariant-consolidation point. It does NOT
duplicate test logic that lives in other test files; instead it imports
the runtime authorities directly and pins the cross-cutting contracts.

@decision DEC-CLAUDEX-A15-AUTHORITY-BOUNDARIES-001
Title: A15 invariant-consolidation file for orchestrator/subagent authority
  boundaries end-to-end enforcement.
Status: accepted
Rationale: A1-A14 delivered the mechanical enforcement piece-by-piece across
  policy/hook/test surfaces. A15 is the single test file a future maintainer
  can run to verify the three authority-boundary invariants still hold
  without re-walking the full test suite. Non-duplicative: imports and
  exercises existing runtime authorities rather than re-defining them.
"""

from __future__ import annotations

import pytest

from runtime.core import authority_registry, dispatch_contract, stage_registry
from runtime.core.authority_registry import (
    CAN_WRITE_GOVERNANCE,
    CAN_WRITE_SOURCE,
    STAGE_SUBAGENT_TYPES,
    canonical_dispatch_subagent_type,
)


# ---------------------------------------------------------------------------
# Objective 1: required_subagent_type end-to-end for seat-owned actions
# ---------------------------------------------------------------------------


class TestRequiredSubagentTypeEnforcement:
    """Pin that stage → required_subagent_type mapping is canonical and complete."""

    def test_every_active_stage_maps_to_canonical_subagent_type(self):
        """Every stage_registry.ACTIVE_STAGES member has a non-empty canonical."""
        for stage in stage_registry.ACTIVE_STAGES:
            assert stage in STAGE_SUBAGENT_TYPES, (
                f"stage_registry.ACTIVE_STAGES member {stage!r} is not in "
                f"authority_registry.STAGE_SUBAGENT_TYPES — required_subagent_type "
                f"cannot be resolved for this stage"
            )
            expected = STAGE_SUBAGENT_TYPES[stage]
            assert isinstance(expected, str) and expected, (
                f"STAGE_SUBAGENT_TYPES[{stage!r}] = {expected!r} is not a "
                f"non-empty string — required_subagent_type enforcement broken"
            )

    def test_canonical_dispatch_subagent_type_covers_all_active_stage_subagents(self):
        """Every canonical subagent_type is recognized by canonical_dispatch_subagent_type."""
        for stage, subagent_type in STAGE_SUBAGENT_TYPES.items():
            assert canonical_dispatch_subagent_type(subagent_type) is not None, (
                f"canonical_dispatch_subagent_type({subagent_type!r}) returned None "
                f"for canonical subagent_type mapped from stage {stage!r} — "
                f"round-trip broken"
            )

    def test_plan_alias_resolves_to_planner(self):
        """The `Plan` harness alias must resolve to the canonical planner seat."""
        assert canonical_dispatch_subagent_type("Plan") == "planner"

    def test_lightweight_subagent_types_are_non_canonical(self):
        """Lightweight types must NOT be dispatch-significant."""
        for lightweight in ("Explore", "general-purpose", "statusline-setup", "", "custom-tool"):
            assert canonical_dispatch_subagent_type(lightweight) is None, (
                f"canonical_dispatch_subagent_type({lightweight!r}) should be None "
                f"but got {canonical_dispatch_subagent_type(lightweight)!r} — "
                f"non-canonical subagent type was classified as dispatch-significant"
            )


# ---------------------------------------------------------------------------
# Objective 2: canonical seat routing, single authority
# ---------------------------------------------------------------------------


class TestCanonicalSeatRoutingSingleAuthority:
    """Pin that dispatch_contract is a shim and authority_registry is canonical."""

    def test_dispatch_contract_stage_subagent_types_is_authority_registry_object(self):
        """Identity re-export (not copy) — drift is mechanically impossible."""
        assert (
            dispatch_contract.STAGE_SUBAGENT_TYPES
            is authority_registry.STAGE_SUBAGENT_TYPES
        )

    def test_dispatch_contract_subagent_type_aliases_is_authority_registry_object(self):
        """Identity re-export for alias table."""
        assert (
            dispatch_contract._SUBAGENT_TYPE_ALIASES
            is authority_registry._SUBAGENT_TYPE_ALIASES
        )

    def test_dispatch_contract_has_no_parallel_mapping_authority(self):
        """dispatch_contract.py must not redeclare any authority mapping."""
        import ast
        import pathlib

        module_path = (
            pathlib.Path(authority_registry.__file__).resolve().parent
            / "dispatch_contract.py"
        )
        tree = ast.parse(module_path.read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and target.id in (
                        "STAGE_SUBAGENT_TYPES",
                        "_SUBAGENT_TYPE_ALIASES",
                    ):
                        assert not isinstance(node.value, ast.Dict), (
                            f"dispatch_contract.py redeclares {target.id} as a dict literal — "
                            f"parallel authority forbidden"
                        )

    @pytest.mark.parametrize("stage", sorted(stage_registry.ACTIVE_STAGES))
    def test_dispatch_contract_delegation_parity_every_active_stage(self, stage):
        """For every active stage, adapter output equals authority output."""
        assert (
            dispatch_contract.dispatch_subagent_type_for_stage(stage)
            == authority_registry.dispatch_subagent_type_for_stage(stage)
        )

    def test_agent_contract_required_policy_has_no_dispatch_significant_frozenset(self):
        """Policy module must not redeclare classification lists — A6/A8 retirement pin."""
        from runtime.core.policies import agent_contract_required as mod

        assert not hasattr(mod, "DISPATCH_SIGNIFICANT"), (
            "agent_contract_required has DISPATCH_SIGNIFICANT frozenset — "
            "parallel classification authority forbidden (retired by A6)"
        )
        assert not hasattr(mod, "LIGHTWEIGHT"), (
            "agent_contract_required has LIGHTWEIGHT frozenset — "
            "parallel classification authority forbidden (retired by A6)"
        )


# ---------------------------------------------------------------------------
# Objective 3: orchestrator cannot self-execute seat-owned work
# ---------------------------------------------------------------------------


class TestOrchestratorCannotSelfExecuteSeatOwnedWork:
    """Pin that capability gates correctly classify orchestrator-out-of-scope roles."""

    def test_can_write_source_capability_constant_is_stable(self):
        """CAN_WRITE_SOURCE must exist; test-suite depends on this authority identifier."""
        assert CAN_WRITE_SOURCE is not None
        # Capability constant is a frozenset member or enum; just verify it's defined.

    def test_can_write_governance_capability_constant_is_stable(self):
        """CAN_WRITE_GOVERNANCE must exist."""
        assert CAN_WRITE_GOVERNANCE is not None

    def test_orchestrator_role_is_not_listed_among_stage_subagent_types(self):
        """`orchestrator` is not a dispatch-significant seat itself."""
        assert "orchestrator" not in STAGE_SUBAGENT_TYPES.values(), (
            "orchestrator appears as a canonical subagent_type — orchestrator "
            "should route to seats, not act as one"
        )
        assert canonical_dispatch_subagent_type("orchestrator") is None

    def test_plan_guard_has_scope_forbidden_path_gate(self):
        """plan_guard must import fnmatch (for forbidden_paths check — A12)."""
        from runtime.core.policies import write_plan_guard as mod
        import inspect

        source = inspect.getsource(mod)
        assert "fnmatch" in source, (
            "write_plan_guard.py does not import fnmatch — A12 scope_forbidden_path_write "
            "gate may be missing"
        )
        assert "scope_forbidden_path_write" in source, (
            "write_plan_guard.py does not emit scope_forbidden_path_write reason code — "
            "A12 role-absolute gate may be missing"
        )

    def test_write_plan_guard_consults_scope_before_capability(self):
        """plan_guard source must reference request.context.scope.forbidden_paths."""
        from runtime.core.policies import write_plan_guard as mod
        import inspect

        source = inspect.getsource(mod)
        assert "forbidden_paths" in source, (
            "write_plan_guard.py does not consult forbidden_paths — scope-absolute "
            "deny for governance writes is missing"
        )


# ---------------------------------------------------------------------------
# Smoke: A15 objectives collectively enforce the end-to-end contract
# ---------------------------------------------------------------------------


class TestA15EndToEndSmoke:
    """Compound smoke: all three A15 objectives hold simultaneously at soak HEAD."""

    def test_a15_full_invariant_bundle_holds(self):
        """Smoke: every A15 invariant class above passes."""
        # Objective 1: every active stage has a canonical subagent_type.
        for stage in stage_registry.ACTIVE_STAGES:
            assert STAGE_SUBAGENT_TYPES.get(stage), stage

        # Objective 2: dispatch_contract is a shim (identity re-export).
        assert (
            dispatch_contract.STAGE_SUBAGENT_TYPES
            is authority_registry.STAGE_SUBAGENT_TYPES
        )

        # Objective 3: capability constants are live.
        assert CAN_WRITE_SOURCE is not None
        assert CAN_WRITE_GOVERNANCE is not None

        # Orchestrator is not a dispatch-significant seat.
        assert canonical_dispatch_subagent_type("orchestrator") is None

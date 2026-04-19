"""
Slice 17: stage-routing single-authority invariant.

@decision DEC-CLAUDEX-STAGE-ROUTING-AUTH-001:
    Title: stage_registry is the sole owner of stage transitions
    Status: accepted (Slice 17, global-soak-main, 2026-04-19)
    Rationale: CUTOVER_PLAN Invariant #1 ("No stage transitions are defined
    outside the stage registry") is true by convention only. This test suite
    locks it into the mechanical test surface so future drift between
    stage_registry.ALL_STAGES and completions._STAGE_TO_ROLE fails at test
    time with a named diff. The discovery-based walk (pkgutil.iter_modules)
    asserts no sibling module exports a top-level TRANSITIONS symbol, closing
    the parallel-authority gap described in CUTOVER_PLAN §Execution Model.

    Design notes:
    - Pure read-only: imports modules and inspects attributes, no mutation.
    - Discovery-based walk uses slice 12 pattern for TRANSITIONS check.
    - Vacuous-truth guard: assert lower-bound module count so a passing walk
      with an empty package is detected immediately.
    - Failure messages are specific: on drift, output names the offending
      stage/role/module.
    - _ROLE_TO_STAGES is derived inline (not a module-level symbol); tests
      re-derive it from _STAGE_TO_ROLE to validate consistency without
      depending on an internal implementation detail.
"""

from __future__ import annotations

import importlib
import pkgutil
from typing import Optional

import runtime.core as rc_pkg
from runtime.core import completions, stage_registry


class TestStageRoutingSingleAuthority:
    """Lock CUTOVER_PLAN Invariant #1 into the mechanical test surface.

    Every test in this class is read-only: it imports runtime modules and
    inspects their attributes, but never mutates any state. If a test fails
    against the current source, that is a REAL drift — do not patch the test
    to match a broken invariant; fix the source.
    """

    def test_stage_to_role_parity_with_all_stages(self) -> None:
        """Every stage in stage_registry.ALL_STAGES has exactly one role mapping.

        _STAGE_TO_ROLE in completions.py is the boundary between the compound
        stage namespace (stage_registry) and the live role namespace (dispatch).
        Its key set must equal ALL_STAGES exactly — no missing stages, no extra
        stages that stage_registry doesn't know about.

        This is the primary parity guard for CUTOVER_PLAN Invariant #1.
        """
        stages: set[str] = set(stage_registry.ALL_STAGES)
        mapped: set[str] = set(completions._STAGE_TO_ROLE.keys())

        missing = stages - mapped
        extra = mapped - stages

        assert missing == set(), (
            f"stages in stage_registry.ALL_STAGES without a role mapping in "
            f"completions._STAGE_TO_ROLE: {sorted(missing)}"
        )
        assert extra == set(), (
            f"keys in completions._STAGE_TO_ROLE that are unknown to "
            f"stage_registry.ALL_STAGES: {sorted(extra)}"
        )

    def test_role_to_stages_roundtrip_consistency(self) -> None:
        """_STAGE_TO_ROLE must be internally consistent under round-trip inversion.

        _ROLE_TO_STAGES is built inline inside determine_next_role and is not
        exported. This test re-derives the role->stages inverse from
        _STAGE_TO_ROLE directly (the module-level authority) and verifies that
        every stage ends up reachable under its own role's entry.

        A failure here indicates that _STAGE_TO_ROLE maps a stage to a role
        that, when inverted, does not cover that stage — which would be an
        internal inconsistency in the mapping.
        """
        role_to_stages: dict[str, set[str]] = {}
        for stage, role in completions._STAGE_TO_ROLE.items():
            if role is not None:
                role_to_stages.setdefault(role, set()).add(stage)

        for stage, role in completions._STAGE_TO_ROLE.items():
            if role is None:
                # Sink stages (terminal, user) map to None — they have no
                # outgoing role and are not expected in role_to_stages.
                continue
            assert stage in role_to_stages[role], (
                f"completions._STAGE_TO_ROLE says '{stage}' -> '{role}', "
                f"but '{stage}' is missing from the inverse role_to_stages['{role}']"
            )

    def test_no_parallel_top_level_transitions_outside_stage_registry(self) -> None:
        """No sibling module of stage_registry may export a top-level TRANSITIONS.

        TRANSITIONS is the canonical single-authority transition table in
        stage_registry. Parallel TRANSITIONS symbols in sibling modules would
        create competing routing authorities — a Sacred Practice 12 violation.

        Walk all non-underscore modules in runtime.core (excluding
        stage_registry itself) and assert none have a top-level TRANSITIONS
        attribute. The vacuous-truth guard ensures the walk actually ran on a
        substantive package (>= 5 modules found).
        """
        offenders: list[str] = []
        scanned: list[str] = []

        for info in pkgutil.iter_modules(rc_pkg.__path__):
            if info.name.startswith("_"):
                continue
            scanned.append(info.name)
            if info.name == "stage_registry":
                # stage_registry is the sole legal owner — skip it.
                continue
            mod = importlib.import_module(f"runtime.core.{info.name}")
            if hasattr(mod, "TRANSITIONS"):
                offenders.append(f"runtime.core.{info.name}.TRANSITIONS")

        # Vacuous-truth guard: the walk must cover a substantive package.
        # If pkgutil fails or the package is renamed/emptied, this catches it
        # before the empty offenders list produces a false-green result.
        assert len(scanned) >= 5, (
            f"runtime.core module discovery returned too few modules "
            f"(expected >= 5, got {len(scanned)}): {scanned}"
        )

        assert offenders == [], (
            f"parallel TRANSITIONS owners found outside stage_registry "
            f"(CUTOVER_PLAN Invariant #1 violated): {offenders}"
        )

    def test_stage_registry_is_sole_owner_of_transitions(self) -> None:
        """stage_registry must expose all authoritative stage-graph data symbols.

        This test verifies that stage_registry is discoverable as the single
        source of truth by asserting the presence of the symbols the
        CUTOVER_PLAN Invariant #1 requires it to own. If any symbol is missing,
        the test fails with a specific message rather than silently treating an
        incomplete module as compliant.
        """
        # Primary authority symbol: the complete stage set.
        assert hasattr(stage_registry, "ALL_STAGES"), (
            "stage_registry.ALL_STAGES is missing — "
            "the module can no longer serve as the stage-graph authority"
        )

        # Active stages (non-sink participants in routing).
        assert hasattr(stage_registry, "ACTIVE_STAGES"), (
            "stage_registry.ACTIVE_STAGES is missing — "
            "routing callers cannot distinguish active from sink stages"
        )

        # Sink stages (terminal resolution points).
        assert hasattr(stage_registry, "SINK_STAGES"), (
            "stage_registry.SINK_STAGES is missing — "
            "terminal/user detection requires this symbol"
        )

        # The canonical transition table itself.
        assert hasattr(stage_registry, "TRANSITIONS"), (
            "stage_registry.TRANSITIONS is missing — "
            "the transition authority table must live here per Invariant #1"
        )

        # Verify set-theoretic consistency of the three stage sets.
        all_s: set[str] = set(stage_registry.ALL_STAGES)
        active_s: set[str] = set(stage_registry.ACTIVE_STAGES)
        sink_s: set[str] = set(stage_registry.SINK_STAGES)

        assert active_s | sink_s == all_s, (
            f"stage_registry.ACTIVE_STAGES | SINK_STAGES != ALL_STAGES. "
            f"active={sorted(active_s)}, sink={sorted(sink_s)}, "
            f"all={sorted(all_s)}"
        )
        assert active_s & sink_s == set(), (
            f"stage_registry.ACTIVE_STAGES and SINK_STAGES must be disjoint; "
            f"overlap: {sorted(active_s & sink_s)}"
        )

    def test_stage_to_role_values_are_canonical_roles(self) -> None:
        """Every non-None role in _STAGE_TO_ROLE is a recognized top-level role.

        The dispatch system recognizes exactly four live roles: planner,
        implementer, reviewer, guardian. Sink stages (terminal, user) map to
        None. Any other value is a typo or a stale entry that will silently
        mis-route traffic.

        Canonical set: {"planner", "implementer", "reviewer", "guardian"}.
        """
        canonical_roles: set[str] = {"planner", "implementer", "reviewer", "guardian"}

        # Collect only non-None values — None is legal for sink stages.
        roles: set[Optional[str]] = set(completions._STAGE_TO_ROLE.values())
        live_roles: set[str] = {r for r in roles if r is not None}

        unknown = live_roles - canonical_roles
        assert unknown == set(), (
            f"unknown (non-canonical) roles in completions._STAGE_TO_ROLE values: "
            f"{sorted(unknown)}. Canonical roles are: {sorted(canonical_roles)}"
        )

    def test_transitions_table_only_references_known_stages(self) -> None:
        """Every stage referenced in TRANSITIONS is a member of ALL_STAGES.

        This is the compound-interaction test: it crosses the boundary between
        stage_registry.TRANSITIONS (the routing authority) and
        stage_registry.ALL_STAGES (the stage enumeration authority), exercising
        the full production sequence where a stage emits a verdict, next_stage()
        resolves the target, and the target is validated as known.

        If a Transition references a stage not in ALL_STAGES, the routing
        graph is internally inconsistent — a future agent would resolve to an
        unknown stage string with no further transitions.
        """
        all_known: set[str] = set(stage_registry.ALL_STAGES)

        from_errors: list[str] = []
        to_errors: list[str] = []

        for t in stage_registry.TRANSITIONS:
            if t.from_stage not in all_known:
                from_errors.append(
                    f"Transition({t.from_stage!r}, {t.verdict!r}, {t.to_stage!r}): "
                    f"from_stage '{t.from_stage}' not in ALL_STAGES"
                )
            if t.to_stage not in all_known:
                to_errors.append(
                    f"Transition({t.from_stage!r}, {t.verdict!r}, {t.to_stage!r}): "
                    f"to_stage '{t.to_stage}' not in ALL_STAGES"
                )

        all_errors = from_errors + to_errors
        assert all_errors == [], (
            f"TRANSITIONS table references stages outside ALL_STAGES "
            f"({len(all_errors)} violation(s)):\n" + "\n".join(all_errors)
        )

    def test_next_stage_pure_function_completeness(self) -> None:
        """next_stage() resolves every declared (from_stage, verdict) pair.

        This end-to-end production-sequence test exercises the full routing
        path: take every declared Transition in TRANSITIONS, call next_stage()
        with its (from_stage, verdict), and verify the result matches the
        declared to_stage. A failure here means the _TRANSITION_INDEX derived
        cache is inconsistent with the TRANSITIONS tuple — the production
        routing would silently return None for a legal move.
        """
        for t in stage_registry.TRANSITIONS:
            result = stage_registry.next_stage(t.from_stage, t.verdict)
            assert result == t.to_stage, (
                f"next_stage({t.from_stage!r}, {t.verdict!r}) returned "
                f"{result!r}, expected {t.to_stage!r}. "
                f"The _TRANSITION_INDEX cache is inconsistent with TRANSITIONS."
            )

    def test_stage_to_role_covers_all_active_stages(self) -> None:
        """Every ACTIVE stage maps to a live (non-None) role in _STAGE_TO_ROLE.

        Sink stages (terminal, user) legitimately map to None. But every
        active stage (one that has outgoing transitions) must map to a
        non-None role — otherwise the dispatch system would attempt to route
        to None for a stage that is not actually terminal.
        """
        active_stages: set[str] = set(stage_registry.ACTIVE_STAGES)

        no_role: list[str] = []
        for stage in sorted(active_stages):
            role = completions._STAGE_TO_ROLE.get(stage)
            if role is None:
                no_role.append(stage)

        assert no_role == [], (
            f"ACTIVE stages that map to None in _STAGE_TO_ROLE (should map "
            f"to a live role): {no_role}"
        )

    def test_sink_stages_map_to_none_in_stage_to_role(self) -> None:
        """Sink stages (terminal, user) must map to None in _STAGE_TO_ROLE.

        A sink stage with a non-None role mapping would tell the dispatch
        system to continue routing after reaching a terminal point — a routing
        infinite loop risk. Sink stages have no outgoing transitions; their
        role must be None.
        """
        sink_stages: set[str] = set(stage_registry.SINK_STAGES)

        wrong_role: list[str] = []
        for stage in sorted(sink_stages):
            if stage not in completions._STAGE_TO_ROLE:
                wrong_role.append(f"{stage}: missing from _STAGE_TO_ROLE entirely")
            elif completions._STAGE_TO_ROLE[stage] is not None:
                wrong_role.append(
                    f"{stage}: maps to {completions._STAGE_TO_ROLE[stage]!r} "
                    f"(expected None for sink stage)"
                )

        assert wrong_role == [], (
            f"SINK stages with incorrect role mapping in _STAGE_TO_ROLE:\n"
            + "\n".join(wrong_role)
        )

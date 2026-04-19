"""Slice 23: role-schema verdict-vocabulary parity invariant.

@decision DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001:
    Title: completions.ROLE_SCHEMAS[role]["valid_verdicts"] must equal the
    authoritative stage_registry vocabulary for that role's stage(s)
    Status: proposed (Slice 23, global-soak-main, 2026-04-19)
    Rationale: Slice 17 pinned ALL_STAGES <-> _STAGE_TO_ROLE key parity.
    test_stage_registry.py pins TRANSITIONS.verdict in allowed_verdicts(from_stage).
    Neither surface pins the consumer side: validate_payload() consults
    ROLE_SCHEMAS[role]["valid_verdicts"], and for implementer + guardian that
    field is a hand-written literal frozenset, not bound to stage_registry.
    This test closes the last hop in the registry -> consumer parity chain
    so a verdict added to stage_registry without a parallel update to
    ROLE_SCHEMAS (or vice versa) fails at collection time with a named
    symmetric-difference diagnostic. Extends slice 17 invariant coverage.
    Shadow-only discipline: stdlib imports plus runtime.core.completions and
    runtime.core.stage_registry. No SQLite, no filesystem, no subprocess,
    no mocks.
    Adjacent authorities:
      - runtime/core/stage_registry.py: producer of per-stage verdict
        vocabularies (PLANNER_VERDICTS, IMPLEMENTER_VERDICTS,
        REVIEWER_VERDICTS, GUARDIAN_PROVISION_VERDICTS, GUARDIAN_LAND_VERDICTS)
      - runtime/core/completions.py: consumer at validate_payload() via
        ROLE_SCHEMAS[role]["valid_verdicts"]
      - tests/runtime/test_completions.py:123-125 (planner identity pin)
      - tests/runtime/test_completions.py:975 (reviewer identity pin)
      - tests/runtime/test_stage_routing_single_authority.py (slice 17)

Mechanical invariants enforced:
  1. completions planner verdicts == stage_registry.PLANNER_VERDICTS
  2. completions reviewer verdicts == stage_registry.REVIEWER_VERDICTS
  3. completions implementer verdicts == stage_registry.IMPLEMENTER_VERDICTS
     (primary gap pin: implementer is a hand-written literal in completions.py)
  4. completions guardian verdicts == GUARDIAN_PROVISION_VERDICTS |
                                      GUARDIAN_LAND_VERDICTS
     (primary gap pin: guardian is a hand-written literal union in completions.py)
  5. ROLE_SCHEMAS.keys() == {r for r in _STAGE_TO_ROLE.values() if r is not None}
     (no role has a schema without a live routing mapping and vice versa)
  6. valid_verdicts is a frozenset for every role in ROLE_SCHEMAS
     (locks the shape so a future list/tuple/set bypass does not slip through)
  7. Vacuous-truth guard: all five authoritative stage_registry vocabulary
     constants are non-empty frozensets
     (without this, cases 1-4 could silently pass on frozenset() == frozenset())
"""

from runtime.core import completions, stage_registry


def _symmetric_diff_diagnostic(actual: frozenset, expected: frozenset) -> str:
    """Produce a named diff message on set inequality.

    DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001: used by every parity
    assertion to produce a named diagnostic on failure so the drift direction
    is immediately visible without reading raw set repr output.
    """
    missing = expected - actual
    extra = actual - expected
    return (
        f"Verdict parity drift detected: "
        f"missing_from_completions={sorted(missing)}, "
        f"extra_in_completions={sorted(extra)}"
    )


class TestRoleSchemaVerdictVocabularyParity:
    """Set-equality invariants between completions.ROLE_SCHEMAS verdict
    vocabularies and the authoritative stage_registry vocabulary constants.

    DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001: every test in this class
    is a mechanical enforcement of one hop in the registry -> consumer
    parity chain. A future author who edits either surface without the other
    will see a named symmetric-difference diagnostic in the failure message.

    Runtime discipline: no fixtures, no DB, no filesystem, no subprocess,
    no mocks. All assertions are pure in-process set comparisons.
    """

    # ------------------------------------------------------------------
    # Case 7: Vacuous-truth guard (run first conceptually; the fixture
    # ordering does not matter but the diagnostic importance is highest)
    # ------------------------------------------------------------------

    def test_vacuous_truth_guard_on_stage_registry_vocabularies(self):
        """DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001: every authoritative
        vocabulary constant in stage_registry must be a non-empty frozenset.

        Without this guard, cases 1-4 could silently pass on
        frozenset() == frozenset() if a future refactor emptied the upstream
        vocabulary. Each assertion names the constant that is empty so the
        failure message identifies the specific gap.
        """
        assert len(stage_registry.PLANNER_VERDICTS) >= 1, (
            "stage_registry.PLANNER_VERDICTS is empty — vacuous-truth guard tripped"
        )
        assert len(stage_registry.IMPLEMENTER_VERDICTS) >= 1, (
            "stage_registry.IMPLEMENTER_VERDICTS is empty — vacuous-truth guard tripped"
        )
        assert len(stage_registry.REVIEWER_VERDICTS) >= 1, (
            "stage_registry.REVIEWER_VERDICTS is empty — vacuous-truth guard tripped"
        )
        assert len(stage_registry.GUARDIAN_PROVISION_VERDICTS) >= 1, (
            "stage_registry.GUARDIAN_PROVISION_VERDICTS is empty — vacuous-truth guard tripped"
        )
        assert len(stage_registry.GUARDIAN_LAND_VERDICTS) >= 1, (
            "stage_registry.GUARDIAN_LAND_VERDICTS is empty — vacuous-truth guard tripped"
        )

    # ------------------------------------------------------------------
    # Case 6: frozenset shape invariant
    # ------------------------------------------------------------------

    def test_valid_verdicts_is_frozenset_for_every_role(self):
        """DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001: valid_verdicts must be
        a frozenset for every role in ROLE_SCHEMAS.

        Locks the shape so a future hand-edit that changes a literal to a
        tuple, list, or mutable set does not bypass immutability. Python set
        equality would still pass for cases 1-4, but this test fails first
        with a named diagnostic that identifies the offending role.
        """
        for role, schema in completions.ROLE_SCHEMAS.items():
            vv = schema["valid_verdicts"]
            assert isinstance(vv, frozenset), (
                f"ROLE_SCHEMAS[{role!r}]['valid_verdicts'] is {type(vv).__name__!r}, "
                f"expected frozenset — immutability contract violated"
            )

    # ------------------------------------------------------------------
    # Case 5: ROLE_SCHEMAS key coverage == live routing roles
    # ------------------------------------------------------------------

    def test_role_schemas_keys_equal_live_roles_from_stage_to_role(self):
        """DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001: ROLE_SCHEMAS keys must
        equal the set of non-None live roles in completions._STAGE_TO_ROLE.

        This pins that no role gets a completions schema without a live routing
        mapping (_STAGE_TO_ROLE entry), and no mapped role lacks a schema.
        A future slice that adds a new role to _STAGE_TO_ROLE without a matching
        ROLE_SCHEMAS entry (or vice versa) fails here with a named diagnostic.
        """
        schema_roles = set(completions.ROLE_SCHEMAS.keys())
        # _STAGE_TO_ROLE maps compound stage names to live role names;
        # None entries are terminal/sink stages with no role.
        live_roles = {
            role
            for role in completions._STAGE_TO_ROLE.values()
            if role is not None
        }
        missing_from_schemas = live_roles - schema_roles
        extra_in_schemas = schema_roles - live_roles
        assert schema_roles == live_roles, (
            f"ROLE_SCHEMAS key coverage mismatch: "
            f"live_roles_without_schema={sorted(missing_from_schemas)}, "
            f"schema_roles_without_routing={sorted(extra_in_schemas)}"
        )

    # ------------------------------------------------------------------
    # Cases 1-4: per-role set-equality parity assertions
    # ------------------------------------------------------------------

    def test_planner_role_schema_equals_stage_registry(self):
        """DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001 — planner parity.

        Planner's valid_verdicts is already identity-bound to
        stage_registry.PLANNER_VERDICTS (pinned by test_completions.py:123-124).
        This set-equality companion asserts the same invariant in the parity
        suite so the full role set is uniformly covered here.
        """
        completions_planner = frozenset(
            completions.ROLE_SCHEMAS["planner"]["valid_verdicts"]
        )
        expected = frozenset(stage_registry.PLANNER_VERDICTS)
        assert completions_planner == expected, _symmetric_diff_diagnostic(
            completions_planner, expected
        )

    def test_implementer_role_schema_equals_stage_registry(self):
        """DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001 — implementer parity.

        PRIMARY GAP PIN: implementer verdicts at completions.py:86 are a
        hand-written frozenset literal not bound to stage_registry.
        This test closes the gap: any future edit to either surface without
        the other will fail here with a named symmetric-difference diagnostic
        identifying the missing or extra verdicts.

        Authoritative source: stage_registry.IMPLEMENTER_VERDICTS
        Consumer: completions.ROLE_SCHEMAS["implementer"]["valid_verdicts"]
        """
        completions_implementer = frozenset(
            completions.ROLE_SCHEMAS["implementer"]["valid_verdicts"]
        )
        expected = frozenset(stage_registry.IMPLEMENTER_VERDICTS)
        assert completions_implementer == expected, _symmetric_diff_diagnostic(
            completions_implementer, expected
        )

    def test_reviewer_role_schema_equals_stage_registry(self):
        """DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001 — reviewer parity.

        Reviewer's valid_verdicts is already identity-bound to
        stage_registry.REVIEWER_VERDICTS (pinned by test_completions.py:975).
        This set-equality companion asserts the same invariant in the parity
        suite so the full role set is uniformly covered here.
        """
        completions_reviewer = frozenset(
            completions.ROLE_SCHEMAS["reviewer"]["valid_verdicts"]
        )
        expected = frozenset(stage_registry.REVIEWER_VERDICTS)
        assert completions_reviewer == expected, _symmetric_diff_diagnostic(
            completions_reviewer, expected
        )

    def test_guardian_role_schema_equals_union_of_guardian_stages(self):
        """DEC-CLAUDEX-ROLE-SCHEMA-VERDICT-PARITY-001 — guardian parity.

        PRIMARY GAP PIN: guardian verdicts at completions.py:81 are a
        hand-written frozenset literal combining provision + land vocabularies.
        Guardian maps to two compound stages in stage_registry; the invariant
        is that the completions literal equals the union of both authoritative
        sets.

        Authoritative sources:
          - stage_registry.GUARDIAN_PROVISION_VERDICTS (provision mode)
          - stage_registry.GUARDIAN_LAND_VERDICTS (land mode)
        Consumer: completions.ROLE_SCHEMAS["guardian"]["valid_verdicts"]

        Any future verdict added to either stage_registry guardian set that
        is not mirrored in the completions literal — or vice versa — fails
        this test with a named symmetric-difference diagnostic.
        """
        completions_guardian = frozenset(
            completions.ROLE_SCHEMAS["guardian"]["valid_verdicts"]
        )
        provision = frozenset(stage_registry.GUARDIAN_PROVISION_VERDICTS)
        land = frozenset(stage_registry.GUARDIAN_LAND_VERDICTS)
        expected = provision | land
        assert completions_guardian == expected, _symmetric_diff_diagnostic(
            completions_guardian, expected
        )

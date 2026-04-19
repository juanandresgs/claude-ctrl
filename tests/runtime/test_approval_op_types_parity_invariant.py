"""APPROVAL_OP_TYPES producer/consumer parity invariant.

DEC-CLAUDEX-APPROVAL-OP-TYPES-PARITY-001

@decision DEC-CLAUDEX-APPROVAL-OP-TYPES-PARITY-001
Title: APPROVAL_OP_TYPES producer/consumer parity invariant
Status: accepted
Rationale:
    `runtime.schemas.APPROVAL_OP_TYPES` is the single canonical frozenset of
    approval-token op_types guarding destructive/history-rewrite/admin-recovery
    git operations. Four independent consumers exist:
      C1 — domain re-export (approvals.VALID_OP_TYPES)
      C2 — policy resolver emitter (_resolve_op_type image)
      C3 — CLI grant-side choices= (ap_grant.op_type argparse action)
      C4 — CLI check-side choices= (ap_check.op_type argparse action) [LIVE GAP]
    There was no cross-consumer parity assertion before this slice. A schema
    addition that is unreachable from the policy gate compiles, grants, and is
    silently ungated — directly threatening unauthorized-history-rewrite safety.
    This file mechanically pins every consumer-to-producer relationship with
    named symmetric-diff diagnostics so drift is loud at pytest time, not silent
    at runtime. The live C4 gap (ap_check missing choices=) is anchored as an
    xfail(strict=True) anti-regression guard: when a future slice closes the
    gap, the suite catches it and forces the implementer to convert the xfail
    to a hard assertion.

Authority surfaces under test (all read-only imports, no mutation):
    - runtime.schemas.APPROVAL_OP_TYPES  (schemas.py:799-810)
    - runtime.core.approvals.VALID_OP_TYPES  (approvals.py:35)
    - runtime.core.policies.bash_approval_gate._resolve_op_type  (bash_approval_gate.py:45-71)
    - runtime.core.leases.classify_git_op  (leases.py:233-350)
    - runtime.cli.build_parser  (cli.py:3897)

Slice: 27 (global-soak-main / claudex-global-soak-main)
Workflow: global-soak-main
"""

import pytest

from runtime import schemas
from runtime.core import approvals
from runtime.core.leases import classify_git_op
from runtime.core.policies.bash_approval_gate import _resolve_op_type

# ---------------------------------------------------------------------------
# Pinned anchor constants — the authoritative ground truth for this file.
# If schemas.py drifts, test_expected_matches_schema_authority catches it.
# ---------------------------------------------------------------------------

#: The full canonical vocabulary of approval-token op_types as expected by
#: this slice at baseline HEAD 915fa4d3.
EXPECTED_APPROVAL_OP_TYPES: frozenset = frozenset(
    {
        "rebase",
        "reset",
        "force_push",
        "destructive_cleanup",
        "non_ff_merge",
        "admin_recovery",
    }
)

#: Subset of EXPECTED_APPROVAL_OP_TYPES that bash_approval_gate._resolve_op_type()
#: is expected to emit for at least one canonical git command. force_push and
#: destructive_cleanup are handled earlier in the hook priority chain
#: (bash_force_push priority=500, bash_destructive_git priority=600) — they
#: never reach _resolve_op_type, so they are HARD_DENIED, not policy-reachable.
POLICY_REACHABLE_OP_TYPES: frozenset = frozenset(
    {
        "rebase",
        "reset",
        "non_ff_merge",
        "admin_recovery",
    }
)

#: Op-types that are grantable (in EXPECTED_APPROVAL_OP_TYPES) but whose
#: approval gate fires via a higher-priority hook before bash_approval_gate
#: ever runs. These MUST NOT appear in the image of _resolve_op_type.
HARD_DENIED_OP_TYPES: frozenset = frozenset(
    {
        "force_push",
        "destructive_cleanup",
    }
)

#: Canonical git commands — one representative per POLICY_REACHABLE op_type,
#: plus an extra admin_recovery variant (reset --merge) tested in the
#: admin_recovery pin case.  Dict key is the op_type string expected from
#: _resolve_op_type; value is the command string.
#:
#: Intentionally minimal — do NOT add commands outside the four
#: policy-reachable triggers (planner forbidden_shortcuts §Implementation rules).
CANONICAL_GIT_COMMANDS: dict = {
    "rebase": "git rebase main",
    "reset": "git reset HEAD~1",
    "non_ff_merge": "git merge --no-ff feature/bar",
    "admin_recovery": "git merge --abort",
}

# ---------------------------------------------------------------------------
# Case 1 — Schema anchor
# ---------------------------------------------------------------------------


def test_expected_matches_schema_authority() -> None:
    """EXPECTED_APPROVAL_OP_TYPES must equal schemas.APPROVAL_OP_TYPES.

    Catches: drift between this file's anchor and the live schema constant.
    Diagnostic: named symmetric difference so the reader sees exactly which
    members diverged.
    """
    live = schemas.APPROVAL_OP_TYPES
    diff = EXPECTED_APPROVAL_OP_TYPES.symmetric_difference(live)
    assert not diff, (
        f"EXPECTED_APPROVAL_OP_TYPES ≠ schemas.APPROVAL_OP_TYPES "
        f"symmetric_difference={sorted(diff)!r}. "
        f"expected={sorted(EXPECTED_APPROVAL_OP_TYPES)!r} "
        f"live={sorted(live)!r}"
    )


# ---------------------------------------------------------------------------
# Case 2 — Domain re-export identity
# ---------------------------------------------------------------------------


def test_domain_reexport_equals_schema() -> None:
    """approvals.VALID_OP_TYPES must be set-equal to schemas.APPROVAL_OP_TYPES.

    Guards C1 against a future local-literal refactor that makes VALID_OP_TYPES
    a filtered subset or a separately maintained copy.
    """
    diff = approvals.VALID_OP_TYPES.symmetric_difference(schemas.APPROVAL_OP_TYPES)
    assert not diff, (
        f"approvals.VALID_OP_TYPES ≠ schemas.APPROVAL_OP_TYPES "
        f"symmetric_difference={sorted(diff)!r}. "
        f"VALID_OP_TYPES={sorted(approvals.VALID_OP_TYPES)!r} "
        f"APPROVAL_OP_TYPES={sorted(schemas.APPROVAL_OP_TYPES)!r}"
    )


# ---------------------------------------------------------------------------
# Case 3 — Non-empty frozenset type
# ---------------------------------------------------------------------------


def test_vocabulary_is_nonempty_frozenset() -> None:
    """schemas.APPROVAL_OP_TYPES must be a non-empty frozenset.

    Guards against accidental replacement with an empty set, a list, or None.
    """
    value = schemas.APPROVAL_OP_TYPES
    assert isinstance(value, frozenset), (
        f"APPROVAL_OP_TYPES must be a frozenset, got {type(value).__name__}"
    )
    assert len(value) > 0, "APPROVAL_OP_TYPES must not be empty"


# ---------------------------------------------------------------------------
# Case 4 — Partition exhaustiveness
# ---------------------------------------------------------------------------


def test_partition_is_exhaustive() -> None:
    """POLICY_REACHABLE ∪ HARD_DENIED == EXPECTED and their intersection is empty.

    Ensures the two-partition model is coherent: every op_type is either
    policy-reachable (flows through bash_approval_gate) or hard-denied
    (intercepted by a higher-priority hook). No op_type may be in both buckets.
    """
    union = POLICY_REACHABLE_OP_TYPES | HARD_DENIED_OP_TYPES
    diff = union.symmetric_difference(EXPECTED_APPROVAL_OP_TYPES)
    assert not diff, (
        f"POLICY_REACHABLE ∪ HARD_DENIED ≠ EXPECTED_APPROVAL_OP_TYPES "
        f"symmetric_difference={sorted(diff)!r}"
    )
    intersection = POLICY_REACHABLE_OP_TYPES & HARD_DENIED_OP_TYPES
    assert not intersection, (
        f"POLICY_REACHABLE ∩ HARD_DENIED must be empty, got {sorted(intersection)!r}"
    )


# ---------------------------------------------------------------------------
# Case 5 — CANONICAL_GIT_COMMANDS covers exactly POLICY_REACHABLE_OP_TYPES
# ---------------------------------------------------------------------------


def test_every_policy_reachable_op_type_has_canonical_command() -> None:
    """CANONICAL_GIT_COMMANDS keys must equal POLICY_REACHABLE_OP_TYPES.

    Ensures the test corpus covers every policy-reachable op_type and no
    extra op_types were accidentally added to the corpus.
    """
    corpus_keys = frozenset(CANONICAL_GIT_COMMANDS.keys())
    diff = corpus_keys.symmetric_difference(POLICY_REACHABLE_OP_TYPES)
    assert not diff, (
        f"CANONICAL_GIT_COMMANDS keys ≠ POLICY_REACHABLE_OP_TYPES "
        f"symmetric_difference={sorted(diff)!r}"
    )


# ---------------------------------------------------------------------------
# Case 6 — Policy resolver emits every policy-reachable op_type
# ---------------------------------------------------------------------------


def test_resolver_emits_every_policy_reachable_op_type() -> None:
    """_resolve_op_type(cmd) must return the expected op_type for each canonical command.

    Both the per-command result and the aggregate image are asserted with
    symmetric-diff diagnostics.
    """
    emitted: set = set()
    failures: list = []

    for expected_op_type, command in CANONICAL_GIT_COMMANDS.items():
        result = _resolve_op_type(command)
        emitted.add(result)
        if result != expected_op_type:
            failures.append(
                f"  {command!r}: expected {expected_op_type!r}, got {result!r}"
            )

    assert not failures, (
        "Per-command _resolve_op_type mismatches:\n" + "\n".join(failures)
    )

    # Aggregate image must equal POLICY_REACHABLE_OP_TYPES
    image = frozenset(emitted)
    diff = image.symmetric_difference(POLICY_REACHABLE_OP_TYPES)
    assert not diff, (
        f"Image of _resolve_op_type over CANONICAL_GIT_COMMANDS ≠ POLICY_REACHABLE_OP_TYPES "
        f"symmetric_difference={sorted(diff)!r} "
        f"image={sorted(image)!r}"
    )


# ---------------------------------------------------------------------------
# Case 7 — No orphan emissions (image ⊆ APPROVAL_OP_TYPES)
# ---------------------------------------------------------------------------


def test_resolver_image_subset_of_schema() -> None:
    """Every non-None value from _resolve_op_type must be in APPROVAL_OP_TYPES.

    Guards C2 against a future policy resolver emitting a new string not yet
    registered in the schema frozenset.
    """
    image = frozenset(
        result
        for command in CANONICAL_GIT_COMMANDS.values()
        if (result := _resolve_op_type(command)) is not None
    )
    diff = image.symmetric_difference(POLICY_REACHABLE_OP_TYPES)
    orphans = image - schemas.APPROVAL_OP_TYPES
    assert not orphans, (
        f"_resolve_op_type emitted op_types not in schemas.APPROVAL_OP_TYPES: "
        f"{sorted(orphans)!r}. APPROVAL_OP_TYPES={sorted(schemas.APPROVAL_OP_TYPES)!r}"
    )
    # Also re-confirm image equals POLICY_REACHABLE_OP_TYPES (belt-and-suspenders)
    assert not diff, (
        f"Image ≠ POLICY_REACHABLE_OP_TYPES symmetric_difference={sorted(diff)!r}"
    )


# ---------------------------------------------------------------------------
# Case 8 — Gate-wiring: every canonical command classifies as gated op_class
# ---------------------------------------------------------------------------


def test_every_policy_reachable_command_classifies_as_gated_op_class() -> None:
    """classify_git_op(cmd) must return 'high_risk' or 'admin_recovery' for every
    canonical command in CANONICAL_GIT_COMMANDS.

    bash_approval_gate.check() short-circuits unless op_class ∈ {'high_risk',
    'admin_recovery'} (bash_approval_gate.py:114-116). This test proves that the
    approval gate would actually fire for each canonical command — otherwise an
    op_type could be grantable but silently ungated at runtime.
    """
    gated_classes = {"high_risk", "admin_recovery"}
    failures: list = []

    for op_type, command in CANONICAL_GIT_COMMANDS.items():
        op_class = classify_git_op(command)
        if op_class not in gated_classes:
            failures.append(
                f"  {command!r} (op_type={op_type!r}): "
                f"classify_git_op returned {op_class!r}, expected one of {sorted(gated_classes)!r}"
            )

    assert not failures, (
        "Commands that should trigger the approval gate do not classify as gated:\n"
        + "\n".join(failures)
    )


# ---------------------------------------------------------------------------
# Case 9 — admin_recovery pin for merge --abort and reset --merge
# ---------------------------------------------------------------------------


def test_admin_recovery_commands_classify_as_admin_recovery() -> None:
    """Both canonical admin_recovery commands must classify as 'admin_recovery'.

    Pins the DEC-LEASE-002 classification for git merge --abort (in-progress
    merge recovery) and git reset --merge (backed-out merge recovery). These
    are the only two commands that resolve to 'admin_recovery' op_type; they
    must also classify at the lease level as 'admin_recovery' so both the
    approval-gate and the eval-readiness bypass (admin_recovery exempts Check 10)
    apply correctly.
    """
    merge_abort = "git merge --abort"
    reset_merge = "git reset --merge"

    assert classify_git_op(merge_abort) == "admin_recovery", (
        f"classify_git_op({merge_abort!r}) returned "
        f"{classify_git_op(merge_abort)!r}, expected 'admin_recovery'"
    )
    assert classify_git_op(reset_merge) == "admin_recovery", (
        f"classify_git_op({reset_merge!r}) returned "
        f"{classify_git_op(reset_merge)!r}, expected 'admin_recovery'"
    )


# ---------------------------------------------------------------------------
# Case 10 — Non-gated commands do not emit an op_type
# ---------------------------------------------------------------------------


def test_non_gated_commands_do_not_emit_op_type() -> None:
    """_resolve_op_type must return None for routine, non-gated git commands.

    Guards against a regression where routine commands are opportunistically
    classified as requiring approval tokens.
    """
    non_gated = [
        "git status",
        "git commit -m 'msg'",
        "git push origin main",
        "git fetch",
        "git log",
    ]
    failures: list = []
    for command in non_gated:
        result = _resolve_op_type(command)
        if result is not None:
            failures.append(f"  {command!r}: expected None, got {result!r}")

    assert not failures, (
        "_resolve_op_type returned a non-None value for non-gated commands:\n"
        + "\n".join(failures)
    )


# ---------------------------------------------------------------------------
# Case 11 — CLI grant-side choices= is sourced from APPROVAL_OP_TYPES
# ---------------------------------------------------------------------------


def test_cli_grant_parser_accepts_every_op_type() -> None:
    """The argparse 'approval grant' subparser's op_type action must have choices
    equal to schemas.APPROVAL_OP_TYPES.

    Guards C3 against a future edit that hard-codes a subset of op_types as CLI
    choices, silently breaking the grant flow for any newly added schema member.
    Uses build_parser() in-process — no subprocess invocation.
    """
    from runtime.cli import build_parser

    parser = build_parser()

    # Walk: domain=approval → action=grant → positional op_type
    approval_parser = parser._subparsers._group_actions[0].choices.get("approval")
    assert approval_parser is not None, "Could not find 'approval' subparser"

    grant_parser = approval_parser._subparsers._group_actions[0].choices.get("grant")
    assert grant_parser is not None, "Could not find 'approval grant' subparser"

    op_type_action = None
    for action in grant_parser._actions:
        if action.dest == "op_type":
            op_type_action = action
            break

    assert op_type_action is not None, (
        "Could not find op_type positional action in 'approval grant' subparser"
    )
    assert op_type_action.choices is not None, (
        "approval grant op_type has no choices= — expected choices sourced from APPROVAL_OP_TYPES"
    )

    grant_choices = frozenset(op_type_action.choices)
    diff = grant_choices.symmetric_difference(schemas.APPROVAL_OP_TYPES)
    assert not diff, (
        f"CLI 'approval grant' op_type choices ≠ schemas.APPROVAL_OP_TYPES "
        f"symmetric_difference={sorted(diff)!r} "
        f"grant_choices={sorted(grant_choices)!r} "
        f"APPROVAL_OP_TYPES={sorted(schemas.APPROVAL_OP_TYPES)!r}"
    )


# ---------------------------------------------------------------------------
# Case 12 — CLI check-side asymmetry anchor (deployable anti-regression)
# ---------------------------------------------------------------------------


@pytest.mark.xfail(
    strict=True,
    reason=(
        "live asymmetry at runtime/cli.py:5055 — ap_check op_type has no choices= "
        "(deployable anti-regression anchor: DEC-CLAUDEX-APPROVAL-OP-TYPES-PARITY-001). "
        "When a future slice adds choices= to ap_check, this xfail becomes XPASS and "
        "strict=True fails the suite — forcing the implementer to remove the xfail and "
        "convert to a hard assertion."
    ),
)
def test_cli_check_parser_symmetry() -> None:
    """The 'approval check' op_type action must have choices== APPROVAL_OP_TYPES.

    Currently ap_check has NO choices= (runtime/cli.py:5055), so this test is
    expected to fail (xfail). The assertion is written as if the gap is closed so
    that when a future slice adds choices=, the test flips from XFAIL to XPASS and
    strict=True causes the suite to report the change loudly. The future implementer
    must then remove @pytest.mark.xfail and verify the assertion passes as a hard case.
    """
    from runtime.cli import build_parser

    parser = build_parser()

    approval_parser = parser._subparsers._group_actions[0].choices.get("approval")
    assert approval_parser is not None, "Could not find 'approval' subparser"

    check_parser = approval_parser._subparsers._group_actions[0].choices.get("check")
    assert check_parser is not None, "Could not find 'approval check' subparser"

    op_type_action = None
    for action in check_parser._actions:
        if action.dest == "op_type":
            op_type_action = action
            break

    assert op_type_action is not None, (
        "Could not find op_type positional action in 'approval check' subparser"
    )
    # This assertion currently fails because op_type_action.choices is None.
    # That is intentional — this is the deployable anti-regression anchor.
    assert op_type_action.choices is not None, (
        "approval check op_type has no choices= — gap not yet closed"
    )
    check_choices = frozenset(op_type_action.choices)
    diff = check_choices.symmetric_difference(schemas.APPROVAL_OP_TYPES)
    assert not diff, (
        f"CLI 'approval check' op_type choices ≠ schemas.APPROVAL_OP_TYPES "
        f"symmetric_difference={sorted(diff)!r}"
    )


# ---------------------------------------------------------------------------
# Case 13 — Non-git invocation returns None
# ---------------------------------------------------------------------------


def test_resolver_returns_none_for_non_git_invocation() -> None:
    """_resolve_op_type must return None for non-git command strings.

    Guards against a regression where non-git commands accidentally trigger
    the approval-gate path.
    """
    result = _resolve_op_type("ls -la")
    assert result is None, (
        f"_resolve_op_type('ls -la') returned {result!r}, expected None"
    )


# ---------------------------------------------------------------------------
# Case 14 — DEC traceability
# ---------------------------------------------------------------------------


def test_decision_id_appears_in_module_docstring() -> None:
    """This module's docstring must contain DEC-CLAUDEX-APPROVAL-OP-TYPES-PARITY-001.

    Enforces decision-log provenance: if the decision key is absent from the
    docstring, the trace is broken and Future Implementers cannot locate the
    rationale.
    """
    import tests.runtime.test_approval_op_types_parity_invariant as this_module

    docstring = this_module.__doc__ or ""
    marker = "DEC-CLAUDEX-APPROVAL-OP-TYPES-PARITY-001"
    assert marker in docstring, (
        f"Module docstring does not contain decision key {marker!r}. "
        f"Docstring prefix: {docstring[:120]!r}"
    )

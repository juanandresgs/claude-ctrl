"""Invariant tests: migrated policy gates stay capability-based.

These tests mechanically pin the Phase 3 contract: policy authorization
decisions key off explicit capability constants via `context.capabilities`
(or `capabilities_for()`), NOT raw role-name string comparisons like
`actor_role == "implementer"`.

Each test inspects the AST of a narrow production file to verify the gate
pattern. This prevents regression to role-name folklore without relying on
fragile whole-repo string scans.

@decision DEC-PE-CAP-INVARIANT-001
@title Invariant tests for capability-gated policy authorization
@status accepted
@rationale Phase 3 migrated five policy surfaces from raw role-name checks to
  capability-based authorization via authority_registry constants. Without
  mechanical pins, a future edit could silently reintroduce actor_role string
  comparisons. AST inspection of the narrow policy files catches this class of
  drift at test time.
"""

from __future__ import annotations

import ast
import inspect
import textwrap

import pytest

from runtime.core.policies import bash_git_who
from runtime.core.policies import bash_worktree_creation
from runtime.core.policies import write_plan_guard
from runtime.core.policies import write_who
from runtime.core import enforcement_config


# ---------------------------------------------------------------------------
# AST helpers
# ---------------------------------------------------------------------------


def _parse_module(module) -> ast.Module:
    """Parse a module's source into an AST tree."""
    return ast.parse(inspect.getsource(module))


def _find_string_comparisons_with(tree: ast.Module, target: str) -> list[str]:
    """Find Compare nodes that compare something against a string literal
    containing ``target``.

    Returns a list of human-readable descriptions for each match.
    """
    matches: list[str] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Compare):
            continue
        # Check all comparators (the right-hand sides of chained comparisons).
        for comparator in node.comparators:
            if isinstance(comparator, ast.Constant) and isinstance(
                comparator.value, str
            ):
                if target in comparator.value:
                    matches.append(
                        f"line {node.lineno}: string comparison with {comparator.value!r}"
                    )
        # Also check the left side.
        if isinstance(node.left, ast.Constant) and isinstance(
            node.left.value, str
        ):
            if target in node.left.value:
                matches.append(
                    f"line {node.lineno}: string comparison with {node.left.value!r}"
                )
    return matches


def _find_capability_in_checks(tree: ast.Module, cap_name: str) -> list[int]:
    """Find ``<cap_name> in ...`` membership checks (ast.Compare with ``In``).

    Returns a list of line numbers where the pattern appears.
    """
    lines: list[int] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Compare):
            continue
        # Look for `CAP in request.context.capabilities` pattern.
        # The left side should be a Name or Attribute referencing the cap constant.
        left = node.left
        left_name = ""
        if isinstance(left, ast.Name):
            left_name = left.id
        elif isinstance(left, ast.Attribute):
            left_name = left.attr

        if left_name != cap_name:
            continue

        for op in node.ops:
            if isinstance(op, (ast.In, ast.NotIn)):
                lines.append(node.lineno)
    return lines


def _find_imports_of(tree: ast.Module, names: set[str]) -> set[str]:
    """Return the subset of ``names`` that appear in ImportFrom nodes."""
    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                if alias.name in names:
                    found.add(alias.name)
    return found


def _find_calls_to(tree: ast.Module, func_name: str) -> list[int]:
    """Find Call nodes where the function name matches ``func_name``.

    Works for both simple ``func_name(...)`` and ``module.func_name(...)`` patterns.
    """
    lines: list[int] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = ""
        if isinstance(func, ast.Name):
            name = func.id
        elif isinstance(func, ast.Attribute):
            name = func.attr
        if name == func_name:
            lines.append(node.lineno)
    return lines


# ---------------------------------------------------------------------------
# write_who.py: CAN_WRITE_SOURCE gate
# ---------------------------------------------------------------------------


class TestWriteWhoCapabilityGate:
    """Pin: write_who uses CAN_WRITE_SOURCE, not role-name strings."""

    @pytest.fixture(autouse=True)
    def _parse(self):
        self.tree = _parse_module(write_who)

    def test_imports_can_write_source(self):
        imported = _find_imports_of(self.tree, {"CAN_WRITE_SOURCE"})
        assert "CAN_WRITE_SOURCE" in imported

    def test_uses_capability_in_check(self):
        lines = _find_capability_in_checks(self.tree, "CAN_WRITE_SOURCE")
        assert len(lines) >= 1, (
            "write_who must use `CAN_WRITE_SOURCE in ...` for authorization"
        )

    def test_no_implementer_string_comparison(self):
        matches = _find_string_comparisons_with(self.tree, "implementer")
        assert matches == [], (
            f"write_who must not compare against 'implementer' string: {matches}"
        )

    def test_no_actor_role_equality_gate(self):
        """No == or != comparison where actor_role is compared to a role string."""
        matches = _find_string_comparisons_with(self.tree, "orchestrator")
        # "orchestrator" appears only in the deny reason message (a Constant
        # inside an f-string or string concat), not in a Compare node for gating.
        # The helper only catches Compare nodes, so the deny-message string
        # does not appear here.
        for m in matches:
            assert "comparison" not in m or "deny" in m.lower(), (
                f"write_who should not gate on 'orchestrator' string: {m}"
            )


# ---------------------------------------------------------------------------
# write_plan_guard.py: CAN_WRITE_GOVERNANCE gate
# ---------------------------------------------------------------------------


class TestPlanGuardCapabilityGate:
    """Pin: plan_guard uses CAN_WRITE_GOVERNANCE, not role-name strings."""

    @pytest.fixture(autouse=True)
    def _parse(self):
        self.tree = _parse_module(write_plan_guard)

    def test_imports_can_write_governance(self):
        imported = _find_imports_of(self.tree, {"CAN_WRITE_GOVERNANCE"})
        assert "CAN_WRITE_GOVERNANCE" in imported

    def test_uses_capability_in_check(self):
        lines = _find_capability_in_checks(self.tree, "CAN_WRITE_GOVERNANCE")
        assert len(lines) >= 1, (
            "plan_guard must use `CAN_WRITE_GOVERNANCE in ...` for authorization"
        )

    def test_no_planner_string_comparison(self):
        matches = _find_string_comparisons_with(self.tree, "planner")
        assert matches == [], (
            f"plan_guard must not compare against 'planner' string: {matches}"
        )

    def test_no_plan_alias_string_comparison(self):
        """The capitalized 'Plan' alias must not appear as a comparison target."""
        matches = _find_string_comparisons_with(self.tree, "Plan")
        # Filter out any that are inside string constants used in deny messages.
        # We only care about Compare nodes where "Plan" is the comparison value.
        gate_matches = [
            m for m in matches
            if "CLAUDE_PLAN_MIGRATION" not in m  # env var check, not role gate
        ]
        assert gate_matches == [], (
            f"plan_guard must not compare against 'Plan' alias string: {gate_matches}"
        )


# ---------------------------------------------------------------------------
# bash_worktree_creation.py: CAN_PROVISION_WORKTREE gate
# ---------------------------------------------------------------------------


class TestWorktreeCreationCapabilityGate:
    """Pin: bash_worktree_creation uses CAN_PROVISION_WORKTREE, not role strings."""

    @pytest.fixture(autouse=True)
    def _parse(self):
        self.tree = _parse_module(bash_worktree_creation)

    def test_imports_can_provision_worktree(self):
        imported = _find_imports_of(self.tree, {"CAN_PROVISION_WORKTREE"})
        assert "CAN_PROVISION_WORKTREE" in imported

    def test_uses_capability_in_check(self):
        lines = _find_capability_in_checks(self.tree, "CAN_PROVISION_WORKTREE")
        assert len(lines) >= 1, (
            "bash_worktree_creation must use `CAN_PROVISION_WORKTREE in ...` "
            "for authorization"
        )

    def test_no_guardian_string_comparison(self):
        matches = _find_string_comparisons_with(self.tree, "guardian")
        assert matches == [], (
            f"bash_worktree_creation must not compare against 'guardian' string: {matches}"
        )

    def test_no_guardian_provision_string_comparison(self):
        matches = _find_string_comparisons_with(self.tree, "guardian:provision")
        assert matches == [], (
            f"bash_worktree_creation must not compare against "
            f"'guardian:provision' string: {matches}"
        )


# ---------------------------------------------------------------------------
# bash_git_who.py: READ_ONLY_REVIEW gate
# ---------------------------------------------------------------------------


class TestGitWhoReadOnlyGate:
    """Pin: bash_git_who enforces reviewer read-only via READ_ONLY_REVIEW
    capability, not role-name strings. The gate fires before lease allowed_ops."""

    @pytest.fixture(autouse=True)
    def _parse(self):
        self.tree = _parse_module(bash_git_who)

    def test_imports_read_only_review(self):
        imported = _find_imports_of(self.tree, {"READ_ONLY_REVIEW"})
        assert "READ_ONLY_REVIEW" in imported

    def test_uses_capability_in_check(self):
        lines = _find_capability_in_checks(self.tree, "READ_ONLY_REVIEW")
        assert len(lines) >= 1, (
            "bash_git_who must use `READ_ONLY_REVIEW in ...` for reviewer gate"
        )

    def test_no_reviewer_string_comparison(self):
        matches = _find_string_comparisons_with(self.tree, "reviewer")
        assert matches == [], (
            f"bash_git_who must not compare against 'reviewer' string: {matches}"
        )

    def test_capability_gate_precedes_lease_check(self):
        """The READ_ONLY_REVIEW ``in`` check must appear before the first
        reference to ``request.context.lease`` (attribute access), ensuring
        the capability gate fires before lease allowed_ops evaluation."""
        cap_lines = _find_capability_in_checks(self.tree, "READ_ONLY_REVIEW")
        assert cap_lines, "READ_ONLY_REVIEW in-check not found"

        # Find first attribute access to .lease on any node
        lease_lines: list[int] = []
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Attribute) and node.attr == "lease":
                lease_lines.append(node.lineno)

        assert lease_lines, "No .lease attribute access found in bash_git_who"
        assert min(cap_lines) < min(lease_lines), (
            f"READ_ONLY_REVIEW gate (line {min(cap_lines)}) must precede "
            f"first lease access (line {min(lease_lines)})"
        )


# ---------------------------------------------------------------------------
# enforcement_config.py: CAN_SET_CONTROL_CONFIG gate
# ---------------------------------------------------------------------------


class TestEnforcementConfigCapabilityGate:
    """Pin: enforcement_config uses CAN_SET_CONTROL_CONFIG / capabilities_for(),
    not raw guardian/planner role-name branches (except the documented
    review_gate_regular_stop empty-actor exception)."""

    @pytest.fixture(autouse=True)
    def _parse(self):
        self.tree = _parse_module(enforcement_config)

    def test_imports_can_set_control_config(self):
        imported = _find_imports_of(
            self.tree, {"CAN_SET_CONTROL_CONFIG", "capabilities_for"}
        )
        assert "CAN_SET_CONTROL_CONFIG" in imported

    def test_imports_capabilities_for(self):
        imported = _find_imports_of(
            self.tree, {"CAN_SET_CONTROL_CONFIG", "capabilities_for"}
        )
        assert "capabilities_for" in imported

    def test_calls_capabilities_for(self):
        lines = _find_calls_to(self.tree, "capabilities_for")
        assert len(lines) >= 1, (
            "enforcement_config must call capabilities_for() for WHO resolution"
        )

    def test_uses_capability_not_in_check(self):
        """The set_ function uses `CAN_SET_CONTROL_CONFIG not in capabilities_for(...)`
        — a NotIn membership test."""
        lines = _find_capability_in_checks(self.tree, "CAN_SET_CONTROL_CONFIG")
        assert len(lines) >= 1, (
            "enforcement_config must use `CAN_SET_CONTROL_CONFIG [not] in ...` "
            "for write authorization"
        )

    def test_no_planner_string_comparison(self):
        matches = _find_string_comparisons_with(self.tree, "planner")
        assert matches == [], (
            f"enforcement_config must not compare against 'planner' string: {matches}"
        )

    def test_no_guardian_string_comparison(self):
        matches = _find_string_comparisons_with(self.tree, "guardian")
        assert matches == [], (
            f"enforcement_config must not compare against 'guardian' string: {matches}"
        )

    def test_review_gate_exception_is_string_key_not_role_gate(self):
        """The only string comparison allowed is `key == "review_gate_regular_stop"`
        — a key-name check, not a role-name authorization gate."""
        # Find all string comparisons in the module
        all_comparisons: list[str] = []
        for node in ast.walk(self.tree):
            if not isinstance(node, ast.Compare):
                continue
            for comparator in node.comparators:
                if isinstance(comparator, ast.Constant) and isinstance(
                    comparator.value, str
                ):
                    all_comparisons.append(comparator.value)
            if isinstance(node.left, ast.Constant) and isinstance(
                node.left.value, str
            ):
                all_comparisons.append(node.left.value)

        # Filter to only role-like strings (lowercase, no underscores —
        # things that look like stage names rather than config keys or scopes).
        role_like = {
            "planner", "implementer", "guardian", "reviewer", "tester",
            "orchestrator", "guardian:provision", "guardian:land", "Plan",
        }
        role_comparisons = [s for s in all_comparisons if s in role_like]
        assert role_comparisons == [], (
            f"enforcement_config compares against role-like strings: {role_comparisons}"
        )


# ---------------------------------------------------------------------------
# Cross-cutting: no policy imports actor_role comparison helpers
# ---------------------------------------------------------------------------


class TestNoPolicyImportsRoleCheckHelpers:
    """Pin: none of the migrated policies import or define ad-hoc role-check
    helpers that could re-introduce role-name folklore."""

    MODULES = [write_who, write_plan_guard, bash_worktree_creation, bash_git_who]
    FORBIDDEN_PATTERNS = {"is_implementer", "is_planner", "is_guardian", "is_reviewer"}

    def test_no_role_check_function_definitions(self):
        """No migrated policy defines a function matching is_<role>."""
        for module in self.MODULES:
            tree = _parse_module(module)
            for node in ast.walk(tree):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    assert node.name not in self.FORBIDDEN_PATTERNS, (
                        f"{module.__name__} defines forbidden role-check "
                        f"helper: {node.name}"
                    )

    def test_no_role_check_imports(self):
        """No migrated policy imports a function matching is_<role>."""
        for module in self.MODULES:
            tree = _parse_module(module)
            imported = _find_imports_of(tree, self.FORBIDDEN_PATTERNS)
            assert imported == set(), (
                f"{module.__name__} imports forbidden role-check helpers: {imported}"
            )

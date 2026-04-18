"""Tests for plan_guard scope_forbidden_path_write enforcement (Slice A4).

Covers INV-A4-1 through INV-A4-10: all behavioural invariants for the
forbidden_paths early-deny block inserted into plan_guard() between the
CLAUDE_PLAN_MIGRATION=1 check and the CAN_WRITE_GOVERNANCE capability gate.

@decision DEC-CLAUDEX-WRITE-PLAN-GUARD-FORBIDDEN-PATHS-TEST-005
Title: test_write_scope_forbidden exercises role-absolute forbidden_paths denial
Status: accepted
Rationale: The forbidden_paths block in plan_guard() is role-absolute: even a
  planner (CAN_WRITE_GOVERNANCE) is denied if the path matches a forbidden
  glob. Tests must exercise the full range of inputs — governance files,
  non-governance (constitution-level) files, malformed scope rows, scope=None,
  CLAUDE_PLAN_MIGRATION=1 bypass, and fnmatch glob semantics — to prove the
  block's invariants hold across the production call path. No subprocess calls
  or disk I/O; all fixtures are in-memory PolicyContext / PolicyRequest objects.

Production sequence:
  Claude Write/Edit -> pre-write.sh -> cc-policy evaluate ->
  plan_guard(request) -> [forbidden check] -> deny iff path matches forbidden
  glob in workflow_scope.forbidden_paths (regardless of role capability).
"""

from __future__ import annotations

import dataclasses
import json

import pytest

from runtime.core.authority_registry import CAN_WRITE_GOVERNANCE, capabilities_for
from runtime.core.policies.write_plan_guard import _parse_scope_list, plan_guard
from runtime.core.policy_engine import PolicyContext, PolicyDecision, PolicyRequest

# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

_PROJECT_ROOT = "/proj"


def _make_scope(forbidden: list[str] | None = None, workflow_id: str = "wf-test") -> dict:
    """Build a minimal scope dict, encoding forbidden_paths as JSON-TEXT as the
    DB does. Passing forbidden=None omits the key; passing [] stores an empty JSON array.
    """
    scope: dict = {"workflow_id": workflow_id}
    if forbidden is not None:
        scope["forbidden_paths"] = json.dumps(forbidden)
    return scope


def _make_context(
    actor_role: str = "planner",
    scope: dict | None = None,
    project_root: str = _PROJECT_ROOT,
) -> PolicyContext:
    return PolicyContext(
        actor_role=actor_role,
        actor_id="agent-a4",
        workflow_id="wf-test",
        worktree_path=project_root,
        branch="feature/a4",
        project_root=project_root,
        is_meta_repo=False,
        lease=None,
        scope=scope,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
        capabilities=capabilities_for(actor_role),
    )


def _req(
    file_path: str,
    role: str = "planner",
    scope: dict | None = None,
    project_root: str = _PROJECT_ROOT,
) -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": file_path},
        context=_make_context(actor_role=role, scope=scope, project_root=project_root),
        cwd=project_root,
    )


# ---------------------------------------------------------------------------
# Helper unit tests
# ---------------------------------------------------------------------------


class TestParseScopeList:
    """Unit tests for _parse_scope_list — the JSON-TEXT decoder."""

    def test_list_input_passthrough(self):
        assert _parse_scope_list(["a", "b"]) == ["a", "b"]

    def test_json_string_decoded(self):
        assert _parse_scope_list('["a","b"]') == ["a", "b"]

    def test_empty_list_returns_empty(self):
        assert _parse_scope_list([]) == []

    def test_empty_json_string_returns_empty(self):
        assert _parse_scope_list("[]") == []

    def test_none_returns_empty(self):
        assert _parse_scope_list(None) == []

    def test_malformed_json_returns_empty(self):
        assert _parse_scope_list("not-json") == []

    def test_json_dict_returns_empty(self):
        """Non-list JSON top-level value → empty."""
        assert _parse_scope_list('{"a":1}') == []

    def test_list_with_non_strings_filtered(self):
        """Non-string elements in a list are excluded."""
        assert _parse_scope_list(["ok", 42, None, "also-ok"]) == ["ok", "also-ok"]

    def test_integer_returns_empty(self):
        assert _parse_scope_list(42) == []


# ---------------------------------------------------------------------------
# INV-A4 policy-level tests
# ---------------------------------------------------------------------------


class TestScopeForbiddenPathsWriteGate:
    """Behavioural invariants for plan_guard's scope_forbidden_path_write block."""

    # -----------------------------------------------------------------------
    # INV-A4-5: scope=None → fall through (no regression on pre-scope workflows)
    # -----------------------------------------------------------------------

    def test_scope_none_planner_allowed(self):
        """INV-A4-5: When scope is None, planner still passes (fallthrough to cap gate)."""
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=None))
        assert result is None

    def test_scope_none_implementer_denied_by_cap_gate(self):
        """INV-A4-5: scope=None does not suppress the later CAN_WRITE_GOVERNANCE gate.

        Implementer is still denied for governance markdown — just by the
        capability gate, not the forbidden check.
        """
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="implementer", scope=None))
        assert result is not None
        assert result.action == "deny"
        assert "scope_forbidden_path_write" not in result.reason

    # -----------------------------------------------------------------------
    # INV-A4-6: forbidden_paths=[] or missing → fall through
    # -----------------------------------------------------------------------

    def test_empty_forbidden_paths_planner_allowed(self):
        """INV-A4-6: forbidden_paths=[] → no forbidden-check denial."""
        scope = _make_scope(forbidden=[])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is None

    def test_missing_forbidden_paths_key_planner_allowed(self):
        """INV-A4-6: scope dict without forbidden_paths key → fallthrough."""
        scope = {"workflow_id": "wf-test"}  # No forbidden_paths key
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is None

    def test_malformed_json_forbidden_paths_planner_allowed(self):
        """INV-A4-6: malformed JSON in forbidden_paths → treated as empty → planner allowed."""
        scope = {"workflow_id": "wf-test", "forbidden_paths": "NOT_JSON"}
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is None

    # -----------------------------------------------------------------------
    # INV-A4-1: planner→forbidden-governance → deny (role-absolute)
    # -----------------------------------------------------------------------

    def test_planner_denied_for_forbidden_governance_file(self):
        """INV-A4-1: Planner (CAN_WRITE_GOVERNANCE) is denied when path matches forbidden glob."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "plan_guard"

    def test_implementer_denied_for_forbidden_governance_file(self):
        """INV-A4-1/4: Implementer is also denied — same block, role-absolute."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="implementer", scope=scope))
        assert result is not None
        assert result.action == "deny"

    # -----------------------------------------------------------------------
    # INV-A4-2: stable exact substring `scope_forbidden_path_write`
    # -----------------------------------------------------------------------

    def test_deny_reason_contains_stable_substring(self):
        """INV-A4-2: reason must contain `scope_forbidden_path_write` exactly once."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is not None
        assert result.reason.count("scope_forbidden_path_write") == 1

    def test_deny_reason_names_file_and_pattern(self):
        """INV-A4-2 / usability: reason must include the file path and the pattern."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is not None
        assert "/proj/MASTER_PLAN.md" in result.reason
        assert "MASTER_PLAN.md" in result.reason

    def test_deny_reason_names_workflow_id(self):
        """INV-A4-2: reason must include the workflow_id."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"], workflow_id="wf-slice-a4")
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is not None
        assert "wf-slice-a4" in result.reason

    # -----------------------------------------------------------------------
    # INV-A4-3: allowed path (in allowed_paths, NOT in forbidden) → None
    # -----------------------------------------------------------------------

    def test_planner_allowed_for_non_forbidden_governance_file(self):
        """INV-A4-3: Planner writing a governance file not in forbidden_paths → allowed."""
        scope = _make_scope(forbidden=["some-other-file.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is None

    # -----------------------------------------------------------------------
    # INV-A4-7: CLAUDE_PLAN_MIGRATION=1 still overrides (fires before forbidden check)
    # -----------------------------------------------------------------------

    def test_plan_migration_env_bypasses_forbidden_check(self, monkeypatch):
        """INV-A4-7: CLAUDE_PLAN_MIGRATION=1 fires before forbidden check → planner allowed."""
        monkeypatch.setenv("CLAUDE_PLAN_MIGRATION", "1")
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is None

    def test_plan_migration_env_bypasses_forbidden_for_implementer(self, monkeypatch):
        """INV-A4-7: CLAUDE_PLAN_MIGRATION=1 also bypasses forbidden check for implementer."""
        monkeypatch.setenv("CLAUDE_PLAN_MIGRATION", "1")
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="implementer", scope=scope))
        assert result is None

    # -----------------------------------------------------------------------
    # INV-A4-8: Enforcement is context-driven (no role-string hardcoding)
    # -----------------------------------------------------------------------

    def test_unknown_role_with_governance_capability_still_denied_when_forbidden(self):
        """INV-A4-8: Even an injected CAN_WRITE_GOVERNANCE cap cannot bypass forbidden check."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        ctx = dataclasses.replace(
            _make_context(actor_role="unknown_role", scope=scope),
            capabilities=frozenset({CAN_WRITE_GOVERNANCE}),
        )
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": "/proj/MASTER_PLAN.md"},
            context=ctx,
            cwd=_PROJECT_ROOT,
        )
        result = plan_guard(req)
        assert result is not None
        assert result.action == "deny"
        assert "scope_forbidden_path_write" in result.reason

    # -----------------------------------------------------------------------
    # INV-A4-9: fnmatch glob semantics
    # -----------------------------------------------------------------------

    def test_bare_filename_pattern_matches_root_level_file(self):
        """INV-A4-9: bare pattern 'MASTER_PLAN.md' matches repo-root file."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is not None
        assert result.action == "deny"

    def test_bare_filename_does_not_match_nested_file(self):
        """INV-A4-9: bare pattern 'MASTER_PLAN.md' does NOT match subdir/MASTER_PLAN.md
        because fnmatch does not cross directory separators for bare patterns.
        """
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        # Write to a nested path with the same filename — should NOT match bare pattern
        result = plan_guard(_req("/proj/docs/MASTER_PLAN.md", role="planner", scope=scope))
        # docs/MASTER_PLAN.md is governance markdown but does NOT match 'MASTER_PLAN.md'
        # via fnmatch (which treats the full normalized string). fnmatch("docs/MASTER_PLAN.md",
        # "MASTER_PLAN.md") → False. Planner should be allowed.
        assert result is None

    def test_glob_pattern_matches_nested_file(self):
        """INV-A4-9: glob pattern 'runtime/core/*.py' matches nested constitution files.

        Uses runtime/core/policy_engine.py which is a verified constitution-level
        file (present in constitution_registry.CONCRETE_PATHS). The forbidden
        check fires only after the file is classified as constitution-level, so
        the target file MUST be either governance markdown or constitution-level.
        """
        # runtime/core/policy_engine.py IS in constitution_registry.CONCRETE_PATHS
        scope = _make_scope(forbidden=["runtime/core/*.py"])
        result = plan_guard(
            _req("/proj/runtime/core/policy_engine.py", role="planner", scope=scope)
        )
        assert result is not None
        assert result.action == "deny"
        assert "scope_forbidden_path_write" in result.reason

    def test_wildcard_pattern_matches_all_markdown(self):
        """INV-A4-9: wildcard '*.md' matches any root-level markdown file."""
        scope = _make_scope(forbidden=["*.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is not None
        assert result.action == "deny"

    # -----------------------------------------------------------------------
    # INV-A4-10: Priority unchanged (300); policy_name correct
    # -----------------------------------------------------------------------

    def test_policy_name_is_plan_guard(self):
        """INV-A4-10: policy_name must be 'plan_guard' (not a new name)."""
        scope = _make_scope(forbidden=["MASTER_PLAN.md"])
        result = plan_guard(_req("/proj/MASTER_PLAN.md", role="planner", scope=scope))
        assert result is not None
        assert result.policy_name == "plan_guard"

    # -----------------------------------------------------------------------
    # Compound integration test — exercises full production sequence boundary
    # -----------------------------------------------------------------------

    def test_registry_scope_forbidden_fires_before_capability_gate(self):
        """Compound: scope_forbidden denies planner via plan_guard registered at priority 300.

        Exercises the real production sequence:
          PolicyRegistry.evaluate() -> plan_guard() -> [forbidden check] -> deny
          before CAN_WRITE_GOVERNANCE gate is reached.

        State transitions: governance file classified -> migration env absent ->
        scope present -> forbidden match -> PolicyDecision(action=deny) returned
        to registry -> registry returns that decision (action != None).
        """
        from runtime.core.policy_engine import PolicyRegistry

        reg = PolicyRegistry()
        reg.register("plan_guard", plan_guard, event_types=["Write", "Edit"], priority=300)

        scope = _make_scope(forbidden=["MASTER_PLAN.md"])

        # Planner with CAN_WRITE_GOVERNANCE + forbidden scope → denied
        planner_req = _req("/proj/MASTER_PLAN.md", role="planner", scope=scope)
        decision = reg.evaluate(planner_req)
        assert decision.action == "deny"
        assert decision.policy_name == "plan_guard"
        assert "scope_forbidden_path_write" in decision.reason

        # Same planner, no scope → allowed (fallthrough to cap gate)
        planner_no_scope = _req("/proj/MASTER_PLAN.md", role="planner", scope=None)
        assert reg.evaluate(planner_no_scope).action == "allow"

        # Implementer, scope with different forbidden list → denied by cap gate (not forbidden)
        scope_no_master = _make_scope(forbidden=["some-other.md"])
        impl_req = _req("/proj/MASTER_PLAN.md", role="implementer", scope=scope_no_master)
        impl_decision = reg.evaluate(impl_req)
        assert impl_decision.action == "deny"
        assert "scope_forbidden_path_write" not in impl_decision.reason

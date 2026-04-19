"""Unit tests for write_who scope-forbidden-path enforcement (Slice 8).

Tests the DEC-DISCIPLINE-WRITE-SCOPE-FORBIDDEN-001 extension to write_who:
  when a CAN_WRITE_SOURCE actor (implementer) attempts to write a path that
  matches context.scope.forbidden_paths, the write is denied with reason-code
  'scope_forbidden_path_write'.

This test file proves:
  1. Implementer writes to forbidden paths are denied when scope is seated.
  2. Implementer writes to allowed/non-forbidden paths pass through.
  3. No scope → prior behavior preserved (existing allow/deny unchanged).
  4. Non-implementer writes still use the existing role-label deny reason.
  5. Worktree-absolute path resolution works correctly.
  6. The new branch does not fire for non-source or skippable paths.

Production sequence:
  Claude Write/Edit → pre-write.sh → cc-policy evaluate →
  write_who(request) → [scope check] → deny iff path matches forbidden
  glob in workflow_scope.forbidden_paths AND actor has CAN_WRITE_SOURCE.

@decision DEC-DISCIPLINE-WRITE-SCOPE-FORBIDDEN-001
Title: test_write_who_scope tests are the regression gate for scope-forbidden
  write enforcement in write_who.
Status: accepted
Rationale: Seven test classes cover: deny on forbidden glob match (direct and
  wildcard), allow on allowed paths, allow when no scope, non-regression for
  role-deny path, non-source file skip, worktree path resolution, and a
  compound integration test through the write_who function with the full
  forbidden_paths logic.
"""

from __future__ import annotations

import dataclasses
import json

import pytest

from runtime.core.authority_registry import CAN_WRITE_SOURCE, capabilities_for
from runtime.core.policies.write_who import write_who
from runtime.core.policy_engine import PolicyContext, PolicyDecision, PolicyRequest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_PROJECT_ROOT = "/proj"
_WORKTREE_PATH = "/proj/.worktrees/global-soak-main"


def _make_scope(
    forbidden: list[str] | None = None,
    allowed: list[str] | None = None,
    workflow_id: str = "global-soak-main",
) -> dict:
    """Build a minimal scope dict matching the DB JSON-TEXT encoding."""
    scope: dict = {"workflow_id": workflow_id}
    if forbidden is not None:
        scope["forbidden_paths"] = json.dumps(forbidden)
    if allowed is not None:
        scope["allowed_paths"] = json.dumps(allowed)
    return scope


def _make_context(
    actor_role: str = "implementer",
    scope: dict | None = None,
    project_root: str = _PROJECT_ROOT,
    worktree_path: str = _WORKTREE_PATH,
) -> PolicyContext:
    return PolicyContext(
        actor_role=actor_role,
        actor_id="agent-slice8",
        workflow_id="global-soak-main",
        worktree_path=worktree_path,
        branch="global-soak-main",
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
    role: str = "implementer",
    scope: dict | None = None,
    project_root: str = _PROJECT_ROOT,
    worktree_path: str = _WORKTREE_PATH,
    event_type: str = "Write",
) -> PolicyRequest:
    ctx = _make_context(
        actor_role=role,
        scope=scope,
        project_root=project_root,
        worktree_path=worktree_path,
    )
    return PolicyRequest(
        event_type=event_type,
        tool_name="Write",
        tool_input={"file_path": file_path},
        context=ctx,
        cwd=worktree_path,
    )


# Baseline scope for slice 8
_SLICE8_SCOPE = _make_scope(
    forbidden=[
        "CLAUDE.md",
        "hooks/**",
        "scripts/**",
        "settings.json",
        "ClauDEX/**",
        "agents/**",
        "docs/**",
        "plugins/**",
        "runtime/core/policies/bash_stash_ban.py",
    ],
    allowed=[
        "runtime/core/policies/bash_cross_branch_restore_ban.py",
        "runtime/core/policies/__init__.py",
        "runtime/core/policies/write_who.py",
        "tests/runtime/policies/test_bash_cross_branch_restore_ban.py",
        "tests/runtime/policies/test_write_who_scope.py",
        "tmp/**",
    ],
)


# ---------------------------------------------------------------------------
# Class 1: Deny — forbidden path (exact and glob)
# ---------------------------------------------------------------------------


class TestDeniesWriteWhenPathMatchesForbiddenGlob:
    """Implementer writes to forbidden source-file paths must be denied when scope is seated.

    Note: write_who enforces only on source files (is_source_file() check fires first).
    Non-source files (.md, .json) are skipped by write_who before reaching the scope
    check — this is by design (write_who is a source-file WHO guard, not a universal
    forbidden-path guard). The scope-forbidden check fires only when all prior skip
    conditions pass. Tests use .py and .sh files (which are source files per
    is_source_file()) for forbidden-path assertions.
    """

    def test_denies_write_python_file_matching_forbidden_exact(self):
        """Implementer writes bash_stash_ban.py (forbidden exact path) → deny."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"
        assert "scope_forbidden_path_write" in result.reason
        assert "bash_stash_ban.py" in result.reason

    def test_denies_write_shell_file_matching_forbidden_wildcard(self):
        """Write to hooks/pre-tool.sh with forbidden hooks/** → deny.

        .sh is a source extension (is_source_file returns True), so the
        scope check fires for shell scripts under hooks/.
        """
        result = write_who(
            _req(f"{_PROJECT_ROOT}/hooks/pre-tool.sh", scope=_SLICE8_SCOPE)
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"
        assert "scope_forbidden_path_write" in result.reason

    def test_denies_write_scripts_shell_file_when_forbidden(self):
        """Write to scripts/statusline.sh with scripts/** forbidden → deny."""
        result = write_who(
            _req(f"{_PROJECT_ROOT}/scripts/statusline.sh", scope=_SLICE8_SCOPE)
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"
        assert "scope_forbidden_path_write" in result.reason

    def test_non_source_file_skipped_before_scope_check(self):
        """CLAUDE.md (.md) is not a source file → write_who returns None (skip before scope).

        This documents the boundary: write_who's scope-forbidden check fires only for
        source files. Markdown files are not gated here; they are gated by plan_guard.
        """
        result = write_who(_req(f"{_PROJECT_ROOT}/CLAUDE.md", scope=_SLICE8_SCOPE))
        assert result is None  # .md is not a source file → skipped

    def test_deny_reason_contains_workflow_id(self):
        """Deny reason must include workflow_id from scope."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is not None
        assert "global-soak-main" in result.reason

    def test_denies_edit_event_for_forbidden_source_file(self):
        """Edit events are also denied for forbidden source files."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
                scope=_SLICE8_SCOPE,
                event_type="Edit",
            )
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"


# ---------------------------------------------------------------------------
# Class 2: Allow — path is in allowed_paths (not in forbidden_paths)
# ---------------------------------------------------------------------------


class TestAllowsWriteWhenPathInAllowedPaths:
    """Implementer writes to paths that are in allowed_paths (not in forbidden) must pass."""

    def test_allows_write_to_allowed_policy_file(self):
        """write_who.py is in allowed_paths, not in forbidden_paths → allow."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/write_who.py",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is None

    def test_allows_write_to_new_policy_file(self):
        """bash_cross_branch_restore_ban.py is in allowed_paths → allow."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_cross_branch_restore_ban.py",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is None

    def test_allows_write_to_init_py(self):
        """__init__.py is in allowed_paths → allow."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/__init__.py",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is None

    def test_allows_write_to_new_test_file(self):
        """test_bash_cross_branch_restore_ban.py is in allowed_paths → allow."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/tests/runtime/policies/test_bash_cross_branch_restore_ban.py",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is None


# ---------------------------------------------------------------------------
# Class 3: Allow — no scope seated → preserve prior behavior
# ---------------------------------------------------------------------------


class TestMissingScopePreservesPriorBehavior:
    """When context.scope is None, the new scope check must be skipped entirely.

    CAN_WRITE_SOURCE actors must continue to get None (allow) from write_who
    when scope is not seated (protects ad-hoc implementer sessions).
    """

    def test_implementer_allowed_when_scope_none(self):
        """CAN_WRITE_SOURCE actor, scope=None, source file → allow (None)."""
        result = write_who(_req(f"{_PROJECT_ROOT}/runtime/foo.py", scope=None))
        assert result is None

    def test_implementer_allowed_when_scope_none_for_source_file(self):
        """Implementer, scope=None, source file that would normally be forbidden → allow.

        This is the conservative exemption: ad-hoc sessions should not be broken by
        missing scope rows. bash_stash_ban.py would be forbidden in slice 8 scope,
        but without scope it passes through (conservative: no-op outside ClauDEX workflows).
        """
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
                scope=None,
            )
        )
        assert result is None  # No scope → skip forbidden check → allow

    def test_implementer_allowed_for_python_source_when_scope_none(self):
        """Python source file, scope=None, implementer → allow."""
        result = write_who(_req(f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py", scope=None))
        assert result is None


# ---------------------------------------------------------------------------
# Class 4: Non-implementer still denied on source (non-regression)
# ---------------------------------------------------------------------------


class TestNonImplementerStillDenied:
    """Existing role-deny path must remain unchanged after scope extension."""

    def test_orchestrator_denied_on_source_with_scope(self):
        """Orchestrator writes source file → denied with role-label reason (non-regression)."""
        result = write_who(
            _req(f"{_PROJECT_ROOT}/runtime/foo.py", role="", scope=_SLICE8_SCOPE)
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"
        assert "scope_forbidden_path_write" not in result.reason  # Role deny, not scope deny
        assert "orchestrator" in result.reason

    def test_planner_denied_on_source_with_scope(self):
        """Planner lacks CAN_WRITE_SOURCE → denied on source file."""
        result = write_who(
            _req(f"{_PROJECT_ROOT}/runtime/foo.py", role="planner", scope=_SLICE8_SCOPE)
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"
        assert "scope_forbidden_path_write" not in result.reason

    def test_orchestrator_denied_on_source_without_scope(self):
        """Orchestrator (no scope) → denied with role reason (original behavior)."""
        result = write_who(
            _req(f"{_PROJECT_ROOT}/runtime/foo.py", role="", scope=None)
        )
        assert result is not None
        assert result.action == "deny"
        assert "orchestrator" in result.reason
        assert result.policy_name == "write_who"


# ---------------------------------------------------------------------------
# Class 5: Non-source file skips scope check
# ---------------------------------------------------------------------------


class TestNonSourceFileSkipsScopeCheck:
    """Non-source files must skip the scope check (existing skip conditions fire first)."""

    def test_json_file_skipped(self):
        """JSON files are not source files → write_who returns None even if forbidden."""
        scope = _make_scope(forbidden=["config.json"])
        result = write_who(_req(f"{_PROJECT_ROOT}/config.json", scope=scope))
        assert result is None

    def test_markdown_file_skipped(self):
        """Markdown files are not source files → skipped before scope check."""
        scope = _make_scope(forbidden=["README.md"])
        result = write_who(_req(f"{_PROJECT_ROOT}/README.md", scope=scope))
        assert result is None

    def test_tmp_python_skippable_path(self):
        """tmp/scratch.py: is_skippable_path returns False for tmp/ paths (not in pattern),
        but tmp files may or may not be source — document behavior."""
        # tmp/scratch.py has .py extension → is_source_file=True
        # is_skippable_path: tmp/ is not in the skippable pattern list → False
        # With scope, check forbidden: tmp/** is in allowed, not forbidden
        scope = _SLICE8_SCOPE
        result = write_who(_req(f"{_PROJECT_ROOT}/tmp/scratch.py", scope=scope))
        # Not in forbidden_paths → allow
        assert result is None


# ---------------------------------------------------------------------------
# Class 6: Worktree-relative path resolution
# ---------------------------------------------------------------------------


class TestWorktreeRelativePathResolution:
    """Write target as absolute worktree path → forbidden glob (repo-relative) must match."""

    def test_worktree_absolute_path_resolves_to_forbidden(self):
        """Absolute path under worktree root → repo-relative → denied if forbidden."""
        # CLAUDE.md is in forbidden_paths
        # Absolute path: /proj/.worktrees/global-soak-main/CLAUDE.md
        worktree_abs_path = f"{_WORKTREE_PATH}/CLAUDE.md"
        result = write_who(
            _req(
                worktree_abs_path,
                scope=_SLICE8_SCOPE,
                worktree_path=_WORKTREE_PATH,
            )
        )
        # CLAUDE.md is not a source file (.md) → write_who skips before scope check
        assert result is None  # .md not a source file

    def test_worktree_absolute_python_path_resolves_to_forbidden(self):
        """Absolute worktree path for a forbidden .py file → deny."""
        # bash_stash_ban.py is in forbidden_paths
        worktree_abs_path = f"{_WORKTREE_PATH}/runtime/core/policies/bash_stash_ban.py"
        result = write_who(
            _req(
                worktree_abs_path,
                scope=_SLICE8_SCOPE,
                worktree_path=_WORKTREE_PATH,
            )
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"
        assert "scope_forbidden_path_write" in result.reason

    def test_project_root_absolute_python_path_resolves_to_forbidden(self):
        """Absolute path under project_root for a forbidden .py file → deny."""
        # The project_root fallback: /proj/runtime/core/policies/bash_stash_ban.py
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
                scope=_SLICE8_SCOPE,
                project_root=_PROJECT_ROOT,
                worktree_path=_WORKTREE_PATH,
            )
        )
        assert result is not None
        assert result.action == "deny"
        assert "scope_forbidden_path_write" in result.reason


# ---------------------------------------------------------------------------
# Class 7: Compound integration — write_who with scope through full function path
# ---------------------------------------------------------------------------


class TestCompoundIntegrationWriteWhoScope:
    """Compound-interaction test: verify the full write_who production sequence
    with scope-forbidden enforcement.

    Production sequence:
      Claude Write/Edit → cc-policy evaluate → write_who() → scope check →
      deny iff implementer writes a forbidden path.

    This test crosses: capabilities_for() → CAN_WRITE_SOURCE gate →
    scope._check_scope_forbidden() → _to_repo_relative() → fnmatch.
    """

    def test_full_production_sequence_deny(self):
        """Full sequence: implementer + scope + forbidden path → deny.

        Verifies the interaction between:
          1. capabilities_for('implementer') includes CAN_WRITE_SOURCE
          2. scope is seated (forbidden_paths present)
          3. write_who executes scope check
          4. deny returned with correct reason-code and policy_name
        """
        caps = capabilities_for("implementer")
        assert CAN_WRITE_SOURCE in caps, (
            "capabilities_for('implementer') must include CAN_WRITE_SOURCE"
        )

        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
                role="implementer",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is not None
        assert result.action == "deny"
        assert result.policy_name == "write_who"
        assert "scope_forbidden_path_write" in result.reason
        assert "global-soak-main" in result.reason

    def test_full_production_sequence_allow(self):
        """Full sequence: implementer + scope + allowed path → allow (None)."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/write_who.py",
                role="implementer",
                scope=_SLICE8_SCOPE,
            )
        )
        assert result is None

    def test_full_production_sequence_no_scope(self):
        """Full sequence: implementer + no scope + source path → allow (None)."""
        result = write_who(
            _req(
                f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
                role="implementer",
                scope=None,
            )
        )
        assert result is None  # No scope → skip forbidden check → allow

    def test_registry_integration_deny_forbidden_for_implementer(self):
        """Full registry: write_who denies implementer writing forbidden .py file."""
        from runtime.core.policies.write_who import write_who as ww
        from runtime.core.policy_engine import PolicyRegistry

        reg = PolicyRegistry()
        reg.register("write_who", ww, event_types=["Write", "Edit"], priority=200)

        req = _req(
            f"{_PROJECT_ROOT}/runtime/core/policies/bash_stash_ban.py",
            role="implementer",
            scope=_SLICE8_SCOPE,
        )
        decision = reg.evaluate(req)
        assert decision.action == "deny"
        assert decision.policy_name == "write_who"
        assert "scope_forbidden_path_write" in decision.reason

    def test_registry_integration_allow_non_forbidden_for_implementer(self):
        """Full registry: write_who allows implementer writing non-forbidden .py file."""
        from runtime.core.policies.write_who import write_who as ww
        from runtime.core.policy_engine import PolicyRegistry

        reg = PolicyRegistry()
        reg.register("write_who", ww, event_types=["Write", "Edit"], priority=200)

        req = _req(
            f"{_PROJECT_ROOT}/runtime/core/policies/write_who.py",
            role="implementer",
            scope=_SLICE8_SCOPE,
        )
        decision = reg.evaluate(req)
        assert decision.action == "allow"

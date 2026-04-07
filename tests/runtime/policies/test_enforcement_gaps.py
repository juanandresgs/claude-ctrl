"""Tests for the 5 enforcement-gap fixes.

@decision DEC-PE-EGAP-001
Title: Enforcement gap test suite covers 5 security-critical bypass paths
Status: accepted
Rationale: Each gap test is structured as a failing-spec-first test: it verifies
  the production code denies what it must deny and allows what it should allow.
  The compound-interaction test (test_lease_role_mismatch_denied_end_to_end)
  exercises the real production sequence across build_context + bash_git_who,
  confirming role-blind lease inheritance is closed at both layers.

  Gap 1: bash_git_who regex expansion — worktree remove, branch -d, rebase, reset, tag
  Gap 2: build_context role-blind lease fallback closed + bash_git_who belt-and-suspenders check
  Gap 3: auto-review.sh heredoc crash (bash-level test in test_auto_review_heredoc.sh)
  Gap 4: fail-closed safety wrapper (bash-level test in test_hook_safety.sh)
  Gap 5: bash_worktree_nesting policy — deny worktree add from inside .worktrees/
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Optional

from runtime.core.policy_engine import PolicyContext, PolicyDecision, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _future() -> int:
    return int(time.time()) + 3600


def _make_lease(
    *,
    allowed_ops=None,
    blocked_ops=None,
    expires_at=None,
    role="implementer",
    workflow_id="feature-test",
) -> dict:
    return {
        "workflow_id": workflow_id,
        "role": role,
        "expires_at": expires_at if expires_at is not None else _future(),
        "allowed_ops_json": json.dumps(allowed_ops or ["routine_local"]),
        "blocked_ops_json": json.dumps(blocked_ops or []),
    }


def _make_guardian_lease(**kw) -> dict:
    return _make_lease(
        role="guardian",
        allowed_ops=["routine_local", "high_risk", "admin_recovery"],
        **kw,
    )


# ---------------------------------------------------------------------------
# GAP 1: bash_git_who expanded regex
# Commands that previously bypassed WHO enforcement must now be caught.
# ---------------------------------------------------------------------------


class TestGap1ExpandedRegex:
    """Gap 1: _GIT_OP_RE must gate all Guardian-only git operations.

    Previously only commit/merge/push were matched. worktree remove,
    branch -d, rebase, reset, and tag all bypassed the lease check entirely.
    """

    def _check(self, command: str, lease=None) -> Optional[PolicyDecision]:
        from runtime.core.policies.bash_git_who import check

        ctx = make_context(lease=lease)
        req = make_request(command, context=ctx)
        return check(req)

    # --- Commands that must now be denied when no lease ---

    def test_worktree_remove_denied_no_lease(self):
        decision = self._check("git worktree remove .worktrees/feature-x")
        assert decision is not None, "git worktree remove must be caught by _GIT_OP_RE"
        assert decision.action == "deny"
        assert decision.policy_name == "bash_git_who"

    def test_worktree_prune_denied_no_lease(self):
        decision = self._check("git worktree prune")
        assert decision is not None, "git worktree prune must be caught by _GIT_OP_RE"
        assert decision.action == "deny"

    def test_branch_delete_lowercase_d_denied_no_lease(self):
        decision = self._check("git branch -d feature/old")
        assert decision is not None, "git branch -d must be caught by _GIT_OP_RE"
        assert decision.action == "deny"

    def test_branch_delete_uppercase_D_denied_no_lease(self):
        decision = self._check("git branch -D feature/stale")
        assert decision is not None, "git branch -D must be caught by _GIT_OP_RE"
        assert decision.action == "deny"

    def test_rebase_denied_no_lease(self):
        decision = self._check("git rebase main")
        assert decision is not None, "git rebase must be caught by _GIT_OP_RE"
        assert decision.action == "deny"

    def test_reset_hard_denied_no_lease(self):
        decision = self._check("git reset --hard HEAD~1")
        assert decision is not None, "git reset must be caught by _GIT_OP_RE"
        assert decision.action == "deny"

    def test_tag_denied_no_lease(self):
        decision = self._check("git tag v1.0.0")
        assert decision is not None, "git tag must be caught by _GIT_OP_RE"
        assert decision.action == "deny"

    # --- Safe commands that must NOT be newly blocked ---

    def test_git_status_still_allowed(self):
        decision = self._check("git status")
        assert decision is None, "git status must not be blocked"

    def test_git_log_still_allowed(self):
        decision = self._check("git log --oneline")
        assert decision is None, "git log must not be blocked"

    def test_git_diff_still_allowed(self):
        decision = self._check("git diff HEAD")
        assert decision is None, "git diff must not be blocked"

    def test_git_fetch_still_allowed(self):
        # fetch is read-only and must not trigger WHO enforcement
        decision = self._check("git fetch origin")
        assert decision is None, "git fetch must not be blocked"

    # --- With valid lease, high_risk ops that match are allowed when permitted ---

    def test_rebase_allowed_with_guardian_lease(self):
        """Guardian lease with high_risk in allowed_ops must permit rebase.

        The belt-and-suspenders role check requires the context actor_role to
        match the lease role. Use actor_role_override="guardian" here.
        """
        from runtime.core.policies.bash_git_who import check

        lease = _make_guardian_lease()
        ctx = make_context(lease=lease, actor_role_override="guardian")
        req = make_request("git rebase main", context=ctx)
        decision = check(req)
        # rebase is high_risk; guardian lease includes high_risk → should pass WHO
        assert decision is None, "rebase with guardian lease allowing high_risk must pass"

    def test_reset_allowed_with_guardian_lease(self):
        """Guardian actor with guardian lease must be allowed to reset."""
        from runtime.core.policies.bash_git_who import check

        lease = _make_guardian_lease()
        ctx = make_context(lease=lease, actor_role_override="guardian")
        req = make_request("git reset --hard HEAD~1", context=ctx)
        decision = check(req)
        assert decision is None, "reset with guardian lease allowing high_risk must pass"

    def test_rebase_denied_with_implementer_lease(self):
        """Implementer lease (routine_local only) must block rebase (high_risk)."""
        lease = _make_lease(role="implementer", allowed_ops=["routine_local"])
        decision = self._check("git rebase main", lease=lease)
        assert decision is not None
        assert decision.action == "deny"


# ---------------------------------------------------------------------------
# GAP 2: Role-blind lease resolution in build_context + belt-and-suspenders in bash_git_who
# ---------------------------------------------------------------------------


class TestGap2RoleBlindLease:
    """Gap 2: build_context must not hand a guardian lease to the orchestrator.

    The belt-and-suspenders check in bash_git_who must also deny when the
    actor_role does not match the lease's role.
    """

    def test_role_mismatch_denied_by_bash_git_who(self):
        """bash_git_who belt-and-suspenders: orchestrator (no role) must not use guardian lease."""
        from runtime.core.policies.bash_git_who import check

        guardian_lease = _make_guardian_lease()
        # actor_role is "" (orchestrator) but lease.role is "guardian"
        ctx = make_context(lease=guardian_lease, actor_role_override="")
        req = make_request("git commit -m 'test'", context=ctx)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "lease role" in decision.reason.lower() or "role" in decision.reason.lower()

    def test_role_match_not_denied_by_bash_git_who(self):
        """When actor_role matches lease.role, the role check must not fire."""
        from runtime.core.policies.bash_git_who import check

        guardian_lease = _make_guardian_lease()
        # actor_role is "guardian" and lease.role is "guardian" — should pass role check
        ctx = make_context(lease=guardian_lease, actor_role_override="guardian")
        req = make_request("git commit -m 'landing'", context=ctx)
        decision = check(req)
        # Role check passes; op_class for commit is routine_local, guardian allows that
        assert decision is None, "guardian with matching role must pass role check"

    def test_implementer_role_matches_implementer_lease(self):
        """Implementer role + implementer lease must pass role check."""
        from runtime.core.policies.bash_git_who import check

        lease = _make_lease(role="implementer", allowed_ops=["routine_local"])
        ctx = make_context(lease=lease, actor_role_override="implementer")
        req = make_request("git commit -m 'feat: add thing'", context=ctx)
        decision = check(req)
        assert decision is None

    def test_build_context_role_aware_lease_resolution(self):
        """build_context with actor_role set must only pick up leases matching that role.

        This tests the policy_engine.build_context() path directly via SQLite.
        An implementer-role request must NOT inherit a guardian lease from the same worktree.
        """
        # Use an in-memory DB so this test is fully hermetic
        import sqlite3 as _sqlite3

        from runtime.core.policy_engine import build_context
        from runtime.schemas import ensure_schema

        conn = _sqlite3.connect(":memory:")
        conn.row_factory = _sqlite3.Row
        ensure_schema(conn)

        # Issue a guardian lease for the worktree
        now = int(time.time())
        conn.execute(
            """INSERT INTO dispatch_leases
               (lease_id, role, worktree_path, status, issued_at, expires_at,
                allowed_ops_json, blocked_ops_json, requires_eval)
               VALUES (?, ?, ?, 'active', ?, ?, ?, ?, 0)""",
            (
                "guardian-lease-1",
                "guardian",
                "/project/.worktrees/feature-test",
                now,
                now + 3600,
                json.dumps(["routine_local", "high_risk", "admin_recovery"]),
                json.dumps([]),
            ),
        )
        conn.commit()

        # build_context called with actor_role="implementer" must NOT pick up guardian lease
        ctx = build_context(
            conn,
            cwd="/project/.worktrees/feature-test",
            actor_role="implementer",
            actor_id="",
            project_root="/project",
        )
        # The implementer actor must not get the guardian lease
        if ctx.lease is not None:
            assert ctx.lease.get("role") != "guardian", (
                "build_context handed implementer actor a guardian lease — role-blind gap not fixed"
            )

    def test_build_context_empty_actor_role_does_not_inherit_lease(self):
        """build_context with no actor_role (orchestrator) must not pick up any role-specific lease.

        This is the defensive else-branch: when actor_role is empty, the worktree-path
        fallback must NOT inherit a guardian (or any role-holding) lease.
        """
        from runtime.core.policy_engine import build_context
        from runtime.schemas import ensure_schema

        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)

        now = int(time.time())
        conn.execute(
            """INSERT INTO dispatch_leases
               (lease_id, role, worktree_path, status, issued_at, expires_at,
                allowed_ops_json, blocked_ops_json, requires_eval)
               VALUES (?, ?, ?, 'active', ?, ?, ?, ?, 0)""",
            (
                "guardian-lease-2",
                "guardian",
                "/project/.worktrees/feature-test",
                now,
                now + 3600,
                json.dumps(["routine_local", "high_risk", "admin_recovery"]),
                json.dumps([]),
            ),
        )
        conn.commit()

        # actor_role="" (orchestrator) — must not inherit guardian lease via worktree fallback
        ctx = build_context(
            conn,
            cwd="/project/.worktrees/feature-test",
            actor_role="",
            actor_id="",
            project_root="/project",
        )
        # Orchestrator should get no lease (the guard filters it out)
        assert ctx.lease is None, (
            "Empty actor_role (orchestrator) inherited a role-specific lease — Gap 2 not fixed"
        )


# ---------------------------------------------------------------------------
# GAP 5: bash_worktree_nesting policy
# ---------------------------------------------------------------------------


class TestGap5WorktreeNesting:
    """Gap 5: Prevent creation of worktrees from inside an existing worktree.

    git worktree add from inside .worktrees/ leads to nested paths that become
    orphaned when the outer worktree is cleaned up.
    """

    def _check_nesting(self, command: str, cwd: str) -> Optional[PolicyDecision]:
        from runtime.core.policies.bash_worktree_nesting import check

        ctx = make_context()
        req = PolicyRequest(
            event_type="PreToolUse",
            tool_name="Bash",
            tool_input={"command": command},
            context=ctx,
            cwd=cwd,
        )
        return check(req)

    def test_worktree_add_from_inside_worktree_denied(self):
        """git worktree add from .worktrees/ CWD must be denied."""
        decision = self._check_nesting(
            "git worktree add .worktrees/child -b feature/child",
            cwd="/project/.worktrees/feature-x",
        )
        assert decision is not None, "worktree add from inside worktree must be denied"
        assert decision.action == "deny"
        assert decision.policy_name == "bash_worktree_nesting"
        assert ".worktrees" in decision.reason

    def test_worktree_add_from_project_root_allowed(self):
        """git worktree add from project root must be allowed."""
        decision = self._check_nesting(
            "git worktree add .worktrees/feature-y -b feature/y",
            cwd="/project",
        )
        assert decision is None, "worktree add from project root must not be blocked"

    def test_nested_target_path_denied(self):
        """Target path with double .worktrees/ must be denied."""
        decision = self._check_nesting(
            "git worktree add .worktrees/outer/.worktrees/inner -b feature/inner",
            cwd="/project",
        )
        assert decision is not None, "nested target path must be denied"
        assert decision.action == "deny"

    def test_worktree_list_not_blocked(self):
        """git worktree list must not be blocked by nesting policy."""
        decision = self._check_nesting("git worktree list", cwd="/project/.worktrees/feature-x")
        assert decision is None, "git worktree list must not be blocked"

    def test_non_worktree_command_not_blocked(self):
        """Unrelated commands must pass through."""
        decision = self._check_nesting("git commit -m 'test'", cwd="/project/.worktrees/feature-x")
        assert decision is None, "non-worktree-add commands must not be blocked by nesting policy"

    def test_worktree_add_absolute_path_outside_worktrees_allowed(self):
        """git worktree add with path that has no .worktrees/ nesting is allowed."""
        decision = self._check_nesting(
            "git worktree add /tmp/scratch -b feature/scratch",
            cwd="/project",
        )
        assert decision is None

    def test_nesting_policy_registered(self):
        """bash_worktree_nesting must appear in the default registry."""
        from runtime.core.policy_engine import default_registry

        registry = default_registry()
        names = [p.name for p in registry.list_policies()]
        assert "bash_worktree_nesting" in names, (
            "bash_worktree_nesting not found in default_registry — not registered in __init__.py"
        )


# ---------------------------------------------------------------------------
# GAP 2 compound-interaction test: end-to-end production sequence
# This exercises the real production sequence: hook payload → build_context → bash_git_who
# ---------------------------------------------------------------------------


class TestGap2EndToEnd:
    """Compound-interaction test: role-blind lease must be closed across the
    full production sequence (build_context → bash_git_who).

    This simulates the real production path:
      1. Hook payload arrives with actor_role="" (orchestrator)
      2. build_context resolves context (must NOT hand orchestrator a guardian lease)
      3. bash_git_who evaluates the context (belt-and-suspenders: also checks role)
    """

    def test_orchestrator_cannot_use_guardian_lease_end_to_end(self):
        """Full production sequence: empty actor_role + guardian lease = deny for git ops."""
        from runtime.core.policies.bash_git_who import check
        from runtime.core.policy_engine import build_context
        from runtime.schemas import ensure_schema

        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)

        now = int(time.time())
        conn.execute(
            """INSERT INTO dispatch_leases
               (lease_id, role, worktree_path, status, issued_at, expires_at,
                allowed_ops_json, blocked_ops_json, requires_eval)
               VALUES (?, ?, ?, 'active', ?, ?, ?, ?, 0)""",
            (
                "guardian-lease-e2e",
                "guardian",
                "/project/.worktrees/feature-test",
                now,
                now + 3600,
                json.dumps(["routine_local", "high_risk", "admin_recovery"]),
                json.dumps([]),
            ),
        )
        conn.commit()

        ctx = build_context(
            conn,
            cwd="/project/.worktrees/feature-test",
            actor_role="",  # orchestrator
            actor_id="",
            project_root="/project",
        )

        req = PolicyRequest(
            event_type="PreToolUse",
            tool_name="Bash",
            tool_input={"command": "git commit -m 'orchestrator bypass attempt'"},
            context=ctx,
            cwd="/project/.worktrees/feature-test",
        )

        decision = check(req)
        # With Gap 2 fixed, orchestrator gets no lease → denied for no-lease reason
        # OR denied for role-mismatch (belt-and-suspenders) depending on which layer catches it
        assert decision is not None, (
            "Orchestrator with no actor_role must not be allowed to run git commit "
            "even when a guardian lease exists for the same worktree"
        )
        assert decision.action == "deny"


# ---------------------------------------------------------------------------
# Helper: make_context with actor_role_override support
# We need to patch make_context to support actor_role_override for Gap 2 tests
# ---------------------------------------------------------------------------


def make_context(
    *,
    is_meta_repo=False,
    project_root="/project",
    workflow_id="feature-test",
    lease=None,
    scope=None,
    eval_state=None,
    test_state=None,
    binding=None,
    branch="feature/test",
    actor_role_override=None,
) -> PolicyContext:
    """Extended make_context that supports actor_role_override for Gap 2 testing."""
    role = actor_role_override if actor_role_override is not None else "implementer"
    return PolicyContext(
        actor_role=role,
        actor_id="agent-test",
        workflow_id=workflow_id,
        worktree_path="/project/.worktrees/feature-test",
        branch=branch,
        project_root=project_root,
        is_meta_repo=is_meta_repo,
        lease=lease,
        scope=scope,
        eval_state=eval_state,
        test_state=test_state,
        binding=binding,
        dispatch_phase=None,
    )


def make_request(
    command, *, context=None, cwd="/project/.worktrees/feature-test", event_type="PreToolUse"
) -> PolicyRequest:
    if context is None:
        context = make_context()
    return PolicyRequest(
        event_type=event_type,
        tool_name="Bash",
        tool_input={"command": command},
        context=context,
        cwd=cwd,
    )

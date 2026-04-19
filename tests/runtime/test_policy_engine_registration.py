"""Tests for policy registry ordering invariants — slice 8 (bash_cross_branch_restore_ban).

Asserts:
  1. bash_cross_branch_restore_ban is registered at priority 630.
  2. Priority ordering: bash_stash_ban(625) < bash_cross_branch_restore_ban(630) < bash_worktree_removal(700).

These are structural invariants that ensure the policy execution ordering
remains correct as the registry grows. Regression guard for slice 8 additions.

@decision DEC-DISCIPLINE-NONSTASH-RESTORE-BAN-001 (registration invariant site)
Title: test_policy_engine_registration verifies priority ordering for slice 8 policies
Status: accepted
Rationale: Priority ordering between bash_stash_ban and bash_cross_branch_restore_ban
  must be preserved so both contamination vectors are evaluated in ascending severity.
  This test file is the mechanical guard against priority drift during future policy
  additions.
"""

from __future__ import annotations

import pytest


def _build_registry():
    from runtime.core.policies import register_all
    from runtime.core.policy_engine import PolicyRegistry

    reg = PolicyRegistry()
    register_all(reg)
    return reg


class TestBashCrossBranchRestoreBanRegistration:
    """Assert bash_cross_branch_restore_ban is registered at the correct priority."""

    def test_registered_at_priority_630(self):
        """bash_cross_branch_restore_ban must be registered at priority 630."""
        reg = _build_registry()
        policies = {p.name: p.priority for p in reg.list_policies()}
        assert "bash_cross_branch_restore_ban" in policies, (
            "bash_cross_branch_restore_ban not in registry — check __init__.py"
        )
        assert policies["bash_cross_branch_restore_ban"] == 630, (
            f"Expected priority 630 but got {policies['bash_cross_branch_restore_ban']}"
        )

    def test_event_types_include_bash_and_pre_tool_use(self):
        """bash_cross_branch_restore_ban must be registered for Bash/PreToolUse events."""
        reg = _build_registry()
        policy_info = next(
            (p for p in reg.list_policies() if p.name == "bash_cross_branch_restore_ban"),
            None,
        )
        assert policy_info is not None
        assert "Bash" in policy_info.event_types or "PreToolUse" in policy_info.event_types, (
            f"Expected Bash or PreToolUse in event_types, got: {policy_info.event_types}"
        )

    def test_enabled_by_default(self):
        """bash_cross_branch_restore_ban must be enabled in the default registry."""
        reg = _build_registry()
        policy_info = next(
            (p for p in reg.list_policies() if p.name == "bash_cross_branch_restore_ban"),
            None,
        )
        assert policy_info is not None
        assert policy_info.enabled, "bash_cross_branch_restore_ban must be enabled"


class TestRegistryOrderingStashThenRestoreThenWorktreeRemoval:
    """Assert priority ordering: bash_stash_ban(625) < bash_cross_branch_restore_ban(630) < bash_worktree_removal(700)."""

    def test_stash_ban_below_restore_ban(self):
        """bash_stash_ban priority must be strictly less than bash_cross_branch_restore_ban."""
        reg = _build_registry()
        policies = {p.name: p.priority for p in reg.list_policies()}
        assert policies["bash_stash_ban"] < policies["bash_cross_branch_restore_ban"], (
            f"bash_stash_ban({policies['bash_stash_ban']}) must be < "
            f"bash_cross_branch_restore_ban({policies['bash_cross_branch_restore_ban']})"
        )

    def test_restore_ban_below_worktree_removal(self):
        """bash_cross_branch_restore_ban priority must be strictly less than bash_worktree_removal."""
        reg = _build_registry()
        policies = {p.name: p.priority for p in reg.list_policies()}
        assert policies["bash_cross_branch_restore_ban"] < policies["bash_worktree_removal"], (
            f"bash_cross_branch_restore_ban({policies['bash_cross_branch_restore_ban']}) must be < "
            f"bash_worktree_removal({policies['bash_worktree_removal']})"
        )

    def test_full_ordering_625_630_700(self):
        """Full ordering invariant: 625 < 630 < 700."""
        reg = _build_registry()
        policies = {p.name: p.priority for p in reg.list_policies()}
        stash = policies.get("bash_stash_ban")
        restore = policies.get("bash_cross_branch_restore_ban")
        worktree = policies.get("bash_worktree_removal")
        assert stash == 625, f"bash_stash_ban priority changed from 625: {stash}"
        assert restore == 630, f"bash_cross_branch_restore_ban priority changed from 630: {restore}"
        assert worktree == 700, f"bash_worktree_removal priority changed from 700: {worktree}"
        assert stash < restore < worktree, (
            f"Priority ordering violated: {stash} < {restore} < {worktree}"
        )

    def test_both_stash_and_restore_ban_present(self):
        """Both slice 6 and slice 8 policies must coexist in the registry."""
        reg = _build_registry()
        names = {p.name for p in reg.list_policies()}
        assert "bash_stash_ban" in names, "bash_stash_ban (slice 6) must be present"
        assert "bash_cross_branch_restore_ban" in names, (
            "bash_cross_branch_restore_ban (slice 8) must be present"
        )

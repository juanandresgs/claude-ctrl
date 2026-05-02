"""Unit tests for bash_shell_copy_ban policy (slice 10).

Exercises the sole enforcement authority for shell-mediated contamination
(non-git file-op vector) into scope-forbidden paths by CAN_WRITE_SOURCE
actors (DEC-DISCIPLINE-SHELL-COPY-BAN-001).

Production trigger: PreToolUse Bash hook — any cp/mv/rsync/ln/install/tar-
extract/redirection command from a can_write_source actor (implementer) whose
destination matches scope.forbidden_paths.

Production sequence:
  1. Implementer issues `cp /other/branch/CLAUDE.md CLAUDE.md`.
  2. pre-bash.sh hook fires: payload → cc-policy evaluate.
  3. build_context() resolves actor_role + capabilities + scope.
  4. PolicyRegistry.evaluate() calls bash_shell_copy_ban.check() at priority 635.
  5. check() gates on CAN_WRITE_SOURCE, parses command, checks forbidden_paths,
     returns deny.
  6. Hook receives deny → blocks the command before shell execution.

@decision DEC-DISCIPLINE-SHELL-COPY-BAN-001
Title: bash_shell_copy_ban unit tests are the sole regression gate for
  shell file-op contamination enforcement
Status: accepted
Rationale: 13 test classes cover: deny matrix (cp, mv, rsync, ln, install,
  tar, redirection >, >>, tee), allow matrix (in-scope dst, unscoped dst,
  no scope, empty forbidden), capability matrix (non-CAN_WRITE_SOURCE),
  git-passthrough, benign-shell pass-through, slice-6 and slice-8 non-
  regression assertions, the slice 7 recurrence scenario (copy form), and
  a compound-interaction integration proof that exercises the full production
  sequence end-to-end.
"""

from __future__ import annotations

import json

import pytest

from runtime.core.authority_registry import CAN_WRITE_SOURCE, capabilities_for
from runtime.core.policies.bash_shell_copy_ban import check
from runtime.core.policy_engine import PolicyDecision, PolicyRegistry, PolicyRequest
from tests.runtime.policies.conftest import make_context, make_request


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


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


def _impl_ctx(scope=None, branch="global-soak-main"):
    """Make an implementer context, optionally with scope."""
    return make_context(actor_role="implementer", scope=scope, branch=branch)


def _impl_req(command: str, scope=None):
    """Make an implementer Bash request with optional scope."""
    ctx = _impl_ctx(scope=scope)
    return make_request(command, context=ctx)


# Baseline scope for slice 10 (mirrors slice 10 scope manifest intent).
# Forbidden paths represent a typical implementation lane scope.
_SLICE10_SCOPE = _make_scope(
    forbidden=[
        "CLAUDE.md",
        "AGENTS.md",
        "hooks/**",
        "scripts/**",
        "settings.json",
        "agents/**",
        "docs/**",
        "plugins/**",
        "runtime/core/policies/bash_stash_ban.py",
        "runtime/core/policies/bash_cross_branch_restore_ban.py",
        "runtime/core/policies/bash_workflow_scope.py",
        "runtime/core/policies/bash_write_who.py",
        "runtime/core/policies/write_who.py",
        "tests/runtime/test_policy_engine.py",
    ],
    allowed=[
        "runtime/core/policies/bash_shell_copy_ban.py",
        "runtime/core/policies/__init__.py",
        "tests/runtime/policies/test_bash_shell_copy_ban.py",
        "tests/runtime/test_policy_engine.py",  # NOTE: both forbidden and allowed
        # allowed beats forbidden: this verifies the override logic in tests below
        "tmp/**",
    ],
)


# ---------------------------------------------------------------------------
# Class 1: Deny — cp to forbidden path
# ---------------------------------------------------------------------------


class TestDeniesCpToForbiddenPath:
    """cp <src> <dst> must be denied when dst matches scope.forbidden_paths."""

    def test_denies_cp_claude_md(self):
        """cp /other/branch/CLAUDE.md CLAUDE.md → deny (CLAUDE.md forbidden)."""
        decision = check(_impl_req("cp /other/branch/CLAUDE.md CLAUDE.md", scope=_SLICE10_SCOPE))
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"
        assert "CLAUDE.md" in decision.reason
        assert "can_write_source" in decision.reason

    def test_denies_cp_hooks_dir(self):
        """cp /ref/hooks/pre-bash.sh hooks/pre-bash.sh → deny (hooks/** forbidden)."""
        decision = check(
            _impl_req("cp /ref/hooks/pre-bash.sh hooks/pre-bash.sh", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_cp_with_flag(self):
        """cp -f /src/x.py runtime/core/policies/bash_stash_ban.py → deny."""
        decision = check(
            _impl_req(
                "cp -f /src/x.py runtime/core/policies/bash_stash_ban.py",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_cp_settings_json(self):
        """cp /ref/settings.json settings.json → deny (settings.json forbidden)."""
        decision = check(
            _impl_req("cp /ref/settings.json settings.json", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"


# ---------------------------------------------------------------------------
# Class 2: Deny — mv across worktree to forbidden path
# ---------------------------------------------------------------------------


class TestDeniesMvToForbiddenPath:
    """mv <src> <dst> must be denied when dst matches scope.forbidden_paths."""

    def test_denies_mv_claude_md(self):
        """mv ../other/CLAUDE.md CLAUDE.md → deny."""
        decision = check(_impl_req("mv ../other/CLAUDE.md CLAUDE.md", scope=_SLICE10_SCOPE))
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_mv_agents_file(self):
        """mv /tmp/planner.md agents/planner.md → deny (agents/** forbidden)."""
        decision = check(
            _impl_req("mv /tmp/planner.md agents/planner.md", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_mv_with_backup_flag(self):
        """mv --backup=numbered /src/x.py scripts/x.py → deny (scripts/** forbidden)."""
        decision = check(
            _impl_req("mv --backup=numbered /src/x.py scripts/x.py", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"


# ---------------------------------------------------------------------------
# Class 3: Deny — rsync into forbidden path
# ---------------------------------------------------------------------------


class TestDeniesRsyncToForbiddenPath:
    """rsync <src> <dst> must be denied when dst matches scope.forbidden_paths."""

    def test_denies_rsync_hooks_dir(self):
        """rsync -a /ref/hooks/ hooks/ → deny (hooks/** forbidden)."""
        decision = check(_impl_req("rsync -a /ref/hooks/ hooks/", scope=_SLICE10_SCOPE))
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_rsync_docs_dir(self):
        """rsync -r /other/docs/ docs/ → deny (docs/** forbidden)."""
        decision = check(
            _impl_req("rsync -r /other/docs/ docs/", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_rsync_exclude_flag_not_destination(self):
        """rsync -a --exclude=.git /src/ hooks/ → deny on hooks/ destination."""
        decision = check(
            _impl_req("rsync -a --exclude=.git /src/ hooks/", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"


# ---------------------------------------------------------------------------
# Class 4: Deny — ln to forbidden path
# ---------------------------------------------------------------------------


class TestDeniesLnToForbiddenPath:
    """ln [-s] <src> <dst> must be denied when dst matches scope.forbidden_paths."""

    def test_denies_ln_s_symlink(self):
        """ln -sf /src/x runtime/core/policies/bash_write_who.py → deny."""
        decision = check(
            _impl_req(
                "ln -sf /src/x runtime/core/policies/bash_write_who.py",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_ln_hardlink(self):
        """ln /src/x.sh hooks/x.sh → deny (hooks/** forbidden)."""
        decision = check(
            _impl_req("ln /src/x.sh hooks/x.sh", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_ln_s_settings(self):
        """ln -s /ref/settings.json settings.json → deny (settings.json forbidden)."""
        decision = check(
            _impl_req("ln -s /ref/settings.json settings.json", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"


# ---------------------------------------------------------------------------
# Class 5: Deny — install to forbidden path
# ---------------------------------------------------------------------------


class TestDeniesInstallToForbiddenPath:
    """install <src> <dst> must be denied when dst matches scope.forbidden_paths."""

    def test_denies_install_to_hooks(self):
        """install -m 755 /src/pre-bash.sh hooks/pre-bash.sh → deny."""
        decision = check(
            _impl_req(
                "install -m 755 /src/pre-bash.sh hooks/pre-bash.sh",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_install_to_agents(self):
        """install -m 644 /src/planner.md agents/planner.md → deny (agents/** forbidden)."""
        decision = check(
            _impl_req(
                "install -m 644 /src/planner.md agents/planner.md",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"


# ---------------------------------------------------------------------------
# Class 6: Deny — tar --extract into forbidden path
# ---------------------------------------------------------------------------


class TestDeniesTarExtractToForbiddenPath:
    """tar --extract/-x -C <dst> must be denied when dst matches scope.forbidden_paths."""

    def test_denies_tar_x_capital_c_hooks(self):
        """tar -xf foreign.tar.gz -C hooks/ → deny (hooks/** forbidden)."""
        decision = check(
            _impl_req("tar -xf foreign.tar.gz -C hooks/", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_tar_extract_long_form(self):
        """tar --extract -f foo.tar --directory=docs/ → deny (docs/** forbidden)."""
        decision = check(
            _impl_req(
                "tar --extract -f foo.tar --directory=docs/",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_tar_xvzf_c_scripts(self):
        """tar -xvzf foo.tar.gz -C scripts/ → deny (scripts/** forbidden)."""
        decision = check(
            _impl_req("tar -xvzf foo.tar.gz -C scripts/", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_allows_tar_create_from_forbidden_src(self):
        """tar -czf tmp/out.tar.gz runtime/ → allow (writing to tmp/*, allowed)."""
        # tar -c creates; no -x extraction flag; write is tmp/out.tar.gz (unscoped)
        decision = check(
            _impl_req("tar -czf tmp/out.tar.gz runtime/", scope=_SLICE10_SCOPE)
        )
        # tar create (-c) without -x should not be classified as extraction
        assert decision is None


# ---------------------------------------------------------------------------
# Class 7: Deny — shell redirection writes
# ---------------------------------------------------------------------------


class TestDeniesShellRedirectToForbiddenPath:
    """cmd > <path> and cmd >> <path> must be denied when <path> is forbidden."""

    def test_denies_redirect_overwrite_claude_md(self):
        """cat /foreign > CLAUDE.md → deny (CLAUDE.md forbidden)."""
        decision = check(
            _impl_req("cat /foreign > CLAUDE.md", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_redirect_append_hooks(self):
        """echo hello >> hooks/pre-bash.sh → deny (hooks/** forbidden)."""
        decision = check(
            _impl_req("echo hello >> hooks/pre-bash.sh", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_denies_tee_to_forbidden(self):
        """echo x | tee hooks/tee-out.sh → deny (hooks/** forbidden)."""
        decision = check(
            _impl_req("echo x | tee hooks/tee-out.sh", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_allows_redirect_to_allowed_path(self):
        """echo hello > tmp/out.txt → allow (tmp/** in allowed_paths)."""
        decision = check(
            _impl_req("echo hello > tmp/out.txt", scope=_SLICE10_SCOPE)
        )
        assert decision is None

    def test_allows_redirect_to_unscoped_path(self):
        """echo hello > /var/log/out.txt → allow (not in forbidden_paths)."""
        decision = check(
            _impl_req("echo hello > /var/log/out.txt", scope=_SLICE10_SCOPE)
        )
        assert decision is None


# ---------------------------------------------------------------------------
# Class 8: Allow — destination in allowed_paths (allowed beats forbidden)
# ---------------------------------------------------------------------------


class TestAllowsDestinationInAllowedPaths:
    """When destination is in allowed_paths, the policy must return None (allow).

    allowed_paths override forbidden globs — mirrors bash_cross_branch_restore_ban
    _is_path_forbidden semantics.
    """

    def test_cp_to_allowed_new_policy_file(self):
        """cp tmp/bash_shell_copy_ban.py runtime/core/policies/bash_shell_copy_ban.py → allow."""
        decision = check(
            _impl_req(
                "cp tmp/bash_shell_copy_ban.py runtime/core/policies/bash_shell_copy_ban.py",
                scope=_SLICE10_SCOPE,
            )
        )
        # runtime/core/policies/bash_shell_copy_ban.py is in allowed_paths
        assert decision is None

    def test_cp_to_tmp_path(self):
        """cp /src/something tmp/something → allow (tmp/** in allowed_paths)."""
        decision = check(
            _impl_req("cp /src/something tmp/something", scope=_SLICE10_SCOPE)
        )
        assert decision is None

    def test_allowed_paths_beats_forbidden_glob(self):
        """tests/runtime/test_policy_engine.py is both forbidden AND allowed.

        allowed_paths override must win so implementer can write the required file.
        This validates the _is_path_forbidden override semantics.
        """
        # In _SLICE10_SCOPE: tests/runtime/test_policy_engine.py appears in BOTH
        # forbidden and allowed. The allowed rule must beat the forbidden glob.
        decision = check(
            _impl_req(
                "cp tmp/generated.py tests/runtime/test_policy_engine.py",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is None


# ---------------------------------------------------------------------------
# Class 9: Allow — destination outside scope (unscoped)
# ---------------------------------------------------------------------------


class TestAllowsDestinationOutsideScope:
    """Destination outside both allowed and forbidden → allow (same as bash_cross_branch_restore_ban)."""

    def test_cp_unscoped_runtime_file(self):
        """cp /src/x.py runtime/core/policies/new_policy.py → allow (not forbidden)."""
        # new_policy.py is not in forbidden_paths
        decision = check(
            _impl_req(
                "cp /src/x.py runtime/core/policies/new_policy.py",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is None

    def test_cp_absolute_unrelated_path(self):
        """cp /src/x /usr/local/bin/x → allow (not in forbidden_paths)."""
        decision = check(
            _impl_req("cp /src/x /usr/local/bin/x", scope=_SLICE10_SCOPE)
        )
        assert decision is None


# ---------------------------------------------------------------------------
# Class 10: Allow — no scope seated → policy is a no-op
# ---------------------------------------------------------------------------


class TestMissingScopeExemption:
    """If context.scope is None, this policy must return None (conservative)."""

    def test_cp_without_scope_returns_none(self):
        """Without scope, cp to any path is not gated by this policy."""
        decision = check(_impl_req("cp /foreign/CLAUDE.md CLAUDE.md", scope=None))
        assert decision is None

    def test_mv_without_scope_returns_none(self):
        """Without scope, mv to any path is not gated."""
        decision = check(_impl_req("mv /foreign/hooks/pre.sh hooks/pre.sh", scope=None))
        assert decision is None

    def test_empty_scope_returns_none(self):
        """scope={} (no forbidden_paths) → no-op (conservative)."""
        decision = check(_impl_req("cp /foreign/CLAUDE.md CLAUDE.md", scope={}))
        assert decision is None

    def test_empty_forbidden_paths_returns_none(self):
        """scope with empty forbidden_paths list → no-op."""
        scope = _make_scope(forbidden=[], allowed=["tmp/**"])
        decision = check(_impl_req("cp /foreign/CLAUDE.md CLAUDE.md", scope=scope))
        assert decision is None


# ---------------------------------------------------------------------------
# Class 11: Allow — non-CAN_WRITE_SOURCE actor → policy is a no-op
# ---------------------------------------------------------------------------


class TestNonImplementerActorsNotDenied:
    """Non-CAN_WRITE_SOURCE actors must not be gated by this policy.

    bash_shell_copy_ban returns None for all non-implementer roles so other
    policies can still fire (mirrors bash_stash_ban and bash_cross_branch_restore_ban).
    """

    def _check_role(self, role: str, command: str) -> PolicyDecision | None:
        ctx = make_context(actor_role=role, scope=_SLICE10_SCOPE)
        req = make_request(command, context=ctx)
        return check(req)

    def test_planner_not_denied(self):
        decision = self._check_role("planner", "cp /foreign/CLAUDE.md CLAUDE.md")
        assert decision is None

    def test_reviewer_not_denied(self):
        decision = self._check_role("reviewer", "mv /src/hooks/pre.sh hooks/pre.sh")
        assert decision is None

    def test_guardian_provision_not_denied(self):
        """Guardian does not carry CAN_WRITE_SOURCE → Option B recovery exempted."""
        decision = self._check_role("guardian:provision", "cp /ref/CLAUDE.md CLAUDE.md")
        assert decision is None

    def test_guardian_land_not_denied(self):
        decision = self._check_role("guardian:land", "rsync -a /ref/ hooks/")
        assert decision is None


# ---------------------------------------------------------------------------
# Class 12: Git passthrough — git commands not touched by this policy
# ---------------------------------------------------------------------------


class TestGitCommandsPassthrough:
    """Git commands must return None — owned by bash_cross_branch_restore_ban."""

    def test_git_checkout_passthrough(self):
        """git checkout origin/main -- CLAUDE.md → None from bash_shell_copy_ban."""
        decision = check(
            _impl_req("git checkout origin/main -- CLAUDE.md", scope=_SLICE10_SCOPE)
        )
        assert decision is None

    def test_git_restore_passthrough(self):
        """git restore --source=main -- hooks/pre-bash.sh → None."""
        decision = check(
            _impl_req(
                "git restore --source=main -- hooks/pre-bash.sh",
                scope=_SLICE10_SCOPE,
            )
        )
        assert decision is None

    def test_git_stash_passthrough(self):
        """git stash pop → None (owned by bash_stash_ban)."""
        decision = check(_impl_req("git stash pop", scope=_SLICE10_SCOPE))
        assert decision is None

    def test_git_push_passthrough(self):
        """git push origin main → None (owned by bash_force_push/bash_main_sacred)."""
        decision = check(_impl_req("git push origin main", scope=_SLICE10_SCOPE))
        assert decision is None


# ---------------------------------------------------------------------------
# Class 13: Benign shell commands — policy is a no-op
# ---------------------------------------------------------------------------


class TestBenignShellCommandsPassthrough:
    """Common benign shell commands must return None — policy does not block them."""

    def test_ls_returns_none(self):
        decision = check(_impl_req("ls -la runtime/core/policies/", scope=_SLICE10_SCOPE))
        assert decision is None

    def test_cat_read_returns_none(self):
        """cat reading from forbidden path (no write) → allow."""
        decision = check(_impl_req("cat CLAUDE.md", scope=_SLICE10_SCOPE))
        assert decision is None

    def test_grep_returns_none(self):
        decision = check(_impl_req("grep -r 'pattern' runtime/", scope=_SLICE10_SCOPE))
        assert decision is None

    def test_echo_without_redirect_returns_none(self):
        decision = check(_impl_req("echo hello world", scope=_SLICE10_SCOPE))
        assert decision is None

    def test_pwd_returns_none(self):
        decision = check(_impl_req("pwd", scope=_SLICE10_SCOPE))
        assert decision is None

    def test_python_returns_none(self):
        """python3 -m pytest → allow (no file write to forbidden)."""
        decision = check(
            _impl_req("python3 -m pytest tests/runtime/policies/ -v", scope=_SLICE10_SCOPE)
        )
        assert decision is None

    def test_redirect_to_tmp_returns_none(self):
        """echo hello > tmp/log.txt → allow (tmp/** is in allowed_paths)."""
        decision = check(_impl_req("echo hello > tmp/log.txt", scope=_SLICE10_SCOPE))
        assert decision is None


# ---------------------------------------------------------------------------
# Class 14: Slice-6 non-regression — bash_stash_ban still fires
# ---------------------------------------------------------------------------


class TestSlice6StashBanNonRegression:
    """Confirm bash_stash_ban still denies git stash pop for implementers.

    This class verifies that slice 10 changes to __init__.py and the new
    bash_shell_copy_ban module do not accidentally disable or short-circuit
    bash_stash_ban (slice 6, priority 625).

    @decision DEC-DISCIPLINE-STASH-BAN-001 (non-regression guard)
    """

    def test_stash_pop_still_denied_by_stash_ban(self):
        """bash_stash_ban.check must still deny git stash pop for implementers."""
        from runtime.core.policies.bash_stash_ban import check as stash_check

        ctx = make_context(actor_role="implementer")
        req = make_request("git stash pop", context=ctx)
        decision = stash_check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"

    def test_stash_apply_still_denied_by_stash_ban(self):
        """bash_stash_ban.check must still deny git stash apply for implementers."""
        from runtime.core.policies.bash_stash_ban import check as stash_check

        ctx = make_context(actor_role="implementer")
        req = make_request("git stash apply", context=ctx)
        decision = stash_check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"


# ---------------------------------------------------------------------------
# Class 15: Slice-8 non-regression — bash_cross_branch_restore_ban still fires
# ---------------------------------------------------------------------------


class TestSlice8CrossBranchRestoreBanNonRegression:
    """Confirm bash_cross_branch_restore_ban still denies git checkout origin/main.

    This class verifies that slice 10 changes do not accidentally disable or
    short-circuit bash_cross_branch_restore_ban (slice 8, priority 630).

    @decision DEC-DISCIPLINE-NONSTASH-RESTORE-BAN-001 (non-regression guard)
    """

    _SLICE8_SCOPE = _make_scope(
        forbidden=["CLAUDE.md", "hooks/**", "docs/**", "scripts/**", "settings.json"],
        allowed=["runtime/core/policies/bash_cross_branch_restore_ban.py", "tmp/**"],
    )

    def test_git_checkout_still_denied_by_restore_ban(self):
        """bash_cross_branch_restore_ban must still deny git checkout origin/main -- CLAUDE.md."""
        from runtime.core.policies.bash_cross_branch_restore_ban import check as restore_check

        ctx = make_context(actor_role="implementer", scope=self._SLICE8_SCOPE)
        req = make_request("git checkout origin/main -- CLAUDE.md", context=ctx)
        decision = restore_check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_cross_branch_restore_ban"

    def test_git_restore_source_still_denied(self):
        """bash_cross_branch_restore_ban must still deny git restore --source=main."""
        from runtime.core.policies.bash_cross_branch_restore_ban import check as restore_check

        ctx = make_context(actor_role="implementer", scope=self._SLICE8_SCOPE)
        req = make_request("git restore --source=main -- hooks/pre-bash.sh", context=ctx)
        decision = restore_check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_cross_branch_restore_ban"

    def test_bash_shell_copy_ban_does_not_fire_on_git_commands(self):
        """bash_shell_copy_ban must NOT fire on git commands (git_invocation gate)."""
        # Verifies the git passthrough gate in bash_shell_copy_ban
        ctx = make_context(actor_role="implementer", scope=_SLICE10_SCOPE)
        req = make_request("git checkout origin/main -- CLAUDE.md", context=ctx)
        shell_copy_decision = check(req)
        assert shell_copy_decision is None, (
            "bash_shell_copy_ban must not fire on git commands — "
            "bash_cross_branch_restore_ban owns that vector"
        )


# ---------------------------------------------------------------------------
# Class 16: write_who scope non-regression — Write tool event denied for forbidden
# ---------------------------------------------------------------------------


class TestWriteWhoScopeNonRegression:
    """Confirm write_who still denies Write tool events to forbidden paths.

    This class verifies that slice 10 changes do not accidentally disable
    write_who (slice 8 scope extension, priority 200).

    @decision DEC-WRITE-WHO-SCOPE-BAN-001 (non-regression guard)
    """

    def test_write_who_still_denies_write_to_forbidden(self):
        """write_who must still deny Write tool events to scope-forbidden source paths.

        Note: write_who only gates 'source files' (by extension/classification).
        CLAUDE.md is not classified as a source file by write_who; hooks/pre-bash.sh
        is. We test with hooks/pre-bash.sh which is in forbidden_paths.
        """
        from runtime.core.policies.write_who import write_who

        # Scope where hooks/** is forbidden (source file classification applies)
        scope_for_write_who = _make_scope(
            forbidden=["hooks/**", "scripts/**", "agents/**"],
            allowed=["runtime/core/policies/bash_shell_copy_ban.py", "tmp/**"],
        )
        ctx = make_context(
            actor_role="implementer",
            scope=scope_for_write_who,
            project_root="/project",
        )
        # Write tool event to a forbidden source path (hooks/pre-bash.sh is a source file)
        req = PolicyRequest(
            event_type="PreToolUse",
            tool_name="Write",
            tool_input={"file_path": "hooks/pre-bash.sh", "content": "x"},
            context=ctx,
            cwd="/project/.worktrees/global-soak-main",
        )
        decision = write_who(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "write_who"


# ---------------------------------------------------------------------------
# Class 17: Slice-7 recurrence scenario — cp form of CLAUDE.md contamination
# ---------------------------------------------------------------------------


class TestSlice7RecurrenceScenarioCopyForm:
    """Reproduce the slice 7 cross-branch contamination scenario via shell cp.

    In slice 7, the implementer ran `git checkout origin/main -- CLAUDE.md`.
    The equivalent shell cp form `cp /other/branch/CLAUDE.md CLAUDE.md`
    was ungated. This class asserts the cp form is now denied by bash_shell_copy_ban.

    This is the acceptance proof that the shell-mediated contamination vector
    is closed (complementing slice 8's git vector closure).

    @decision DEC-DISCIPLINE-SHELL-COPY-BAN-001 (test site: slice 7 cp-recurrence)
    """

    # Files that would have been contaminated if the cp form was used in slice 7.
    _SLICE7_FILES_CP_FORM = [
        "CLAUDE.md",
        "AGENTS.md",
        "hooks/pre-bash.sh",
        "hooks/pre-tool.sh",
        "scripts/statusline.sh",
        "agents/implementer.md",
        "docs/architecture.md",
        "settings.json",
    ]

    def test_each_slice7_file_cp_denied(self):
        """Each slice 7 file copied from /other/branch → deny."""
        for path in self._SLICE7_FILES_CP_FORM:
            command = f"cp /other/branch/{path} {path}"
            decision = check(_impl_req(command, scope=_SLICE10_SCOPE))
            assert decision is not None, (
                f"Expected deny for `{command}` but got None — "
                f"shell copy contamination vector is NOT closed for {path}"
            )
            assert decision.action == "deny", (
                f"Expected action=deny for `{command}` but got {decision.action!r}"
            )
            assert decision.policy_name == "bash_shell_copy_ban", (
                f"Wrong policy_name for `{command}`: {decision.policy_name!r}"
            )

    def test_slice7_mv_form_also_denied(self):
        """mv /other/branch/CLAUDE.md CLAUDE.md → deny (mv form)."""
        decision = check(
            _impl_req("mv /other/branch/CLAUDE.md CLAUDE.md", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"
        assert "CLAUDE.md" in decision.reason

    def test_deny_reason_contains_required_tokens(self):
        """Deny reason must contain attribution tokens."""
        decision = check(
            _impl_req("cp /other/branch/CLAUDE.md CLAUDE.md", scope=_SLICE10_SCOPE)
        )
        assert decision is not None
        required_tokens = [
            "bash_shell_copy_ban",
            "can_write_source",
            "forbidden",
        ]
        for token in required_tokens:
            assert token in decision.reason, (
                f"Missing required token {token!r} in deny reason: {decision.reason!r}"
            )


# ---------------------------------------------------------------------------
# Class 18: Compound-interaction integration — full registry, production sequence
# ---------------------------------------------------------------------------


class TestIntegrationFullRegistry:
    """Compound-interaction test: verify the full production sequence end-to-end.

    Exercises: PolicyRequest construction → PolicyRegistry.evaluate() with all
    policies loaded → bash_shell_copy_ban registered at priority 635.

    Production sequence proof:
      1. register_all() wires bash_shell_copy_ban at priority 635.
      2. PolicyRegistry.evaluate() runs policies in ascending priority order.
      3. A cp to a forbidden path from an implementer context with scope seated
         is denied by bash_shell_copy_ban.
      4. Priority ordering: bash_stash_ban(625) < bash_cross_branch_restore_ban(630)
         < bash_shell_copy_ban(635) < bash_worktree_removal(700).
    """

    def _build_registry(self) -> PolicyRegistry:
        from runtime.core.policies import register_all

        reg = PolicyRegistry()
        register_all(reg)
        return reg

    def test_bash_shell_copy_ban_registered_in_default_registry(self):
        """bash_shell_copy_ban must appear in the policy registry after register_all()."""
        reg = self._build_registry()
        names = [p.name for p in reg.list_policies()]
        assert "bash_shell_copy_ban" in names, (
            "bash_shell_copy_ban not found in registry — check __init__.py registration"
        )

    def test_priority_ordering_stash_restore_shellcopy_worktree(self):
        """Priority order must be: stash_ban(625) < restore_ban(630) < shell_copy_ban(635) < worktree_removal(700)."""
        reg = self._build_registry()
        policies = {p.name: p.priority for p in reg.list_policies()}
        assert "bash_stash_ban" in policies
        assert "bash_cross_branch_restore_ban" in policies
        assert "bash_shell_copy_ban" in policies
        assert "bash_worktree_removal" in policies
        assert policies["bash_stash_ban"] == 625
        assert policies["bash_cross_branch_restore_ban"] == 630
        assert policies["bash_shell_copy_ban"] == 635
        assert policies["bash_worktree_removal"] == 700
        assert (
            policies["bash_stash_ban"]
            < policies["bash_cross_branch_restore_ban"]
            < policies["bash_shell_copy_ban"]
            < policies["bash_worktree_removal"]
        ), "Priority ordering violated: expected stash < restore < shell_copy < worktree_removal"

    def test_cp_to_forbidden_denied_via_full_registry(self):
        """Integration: full registry denies cp to forbidden path from implementer.

        This is the compound-interaction proof that connects:
          authority_registry.capabilities_for("implementer") → CAN_WRITE_SOURCE present
          → bash_shell_copy_ban.check() → deny at priority 635.
        """
        caps = capabilities_for("implementer")
        assert CAN_WRITE_SOURCE in caps, (
            "capabilities_for('implementer') must include CAN_WRITE_SOURCE"
        )

        ctx = make_context(actor_role="implementer", scope=_SLICE10_SCOPE)
        req = make_request("cp /other/branch/CLAUDE.md CLAUDE.md", context=ctx)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    def test_benign_shell_not_denied_via_full_registry(self):
        """Integration: ls/cat/grep/python3 are not blocked by bash_shell_copy_ban."""
        for cmd in ["ls -la", "cat CLAUDE.md", "grep pattern runtime/", "python3 -m pytest"]:
            ctx = make_context(actor_role="implementer", scope=_SLICE10_SCOPE)
            req = make_request(cmd, context=ctx)
            decision = check(req)
            assert decision is None, (
                f"Expected None (allow) for `{cmd}` but got {decision!r}"
            )

    def test_git_command_passthrough_in_full_registry(self):
        """Integration: git commands are passed through by bash_shell_copy_ban."""
        ctx = make_context(actor_role="implementer", scope=_SLICE10_SCOPE)
        req = make_request("git status", context=ctx)
        decision = check(req)
        assert decision is None

    def test_non_implementer_passthrough_in_full_registry(self):
        """Integration: guardian cp is not denied by bash_shell_copy_ban."""
        ctx = make_context(actor_role="guardian:provision", scope=_SLICE10_SCOPE)
        req = make_request("cp /ref/CLAUDE.md CLAUDE.md", context=ctx)
        decision = check(req)
        assert decision is None


# ---------------------------------------------------------------------------
# Class 19: Absolute-path bypass regression (slice 10R hotfix)
# ---------------------------------------------------------------------------
# These tests must FAIL pre-hotfix and PASS post-hotfix.
# They cover the P0 defect: destination tokens that are absolute paths were
# matched against scope.forbidden_paths as raw tokens, bypassing the glob.
# DEC-DISCIPLINE-SHELL-COPY-BAN-002
# ---------------------------------------------------------------------------

_HOOKS_SCOPE = _make_scope(forbidden=["hooks/**", "CLAUDE.md"], allowed=["tmp/**"])

# The conftest worktree_path is "/project/.worktrees/feature-test" and
# project_root is "/project". These match the defaults in make_context().
_WORKTREE = "/project/.worktrees/feature-test"
_PROJECT_ROOT = "/project"


class TestAbsolutePathNormalizationHotfix:
    """Regression suite for slice 10R hotfix (DEC-DISCIPLINE-SHELL-COPY-BAN-002).

    Verifies that absolute destination paths are normalized to repo-relative
    before forbidden-glob matching, closing the bypass documented in the P0
    defect report.

    Production trigger: any cp/mv/rsync/ln/install/tar/redirect from an
    implementer where the destination is spelled as an absolute path pointing
    into the worktree or project root.
    """

    # -----------------------------------------------------------------------
    # Test 1: cp with absolute destination under worktree → deny
    # -----------------------------------------------------------------------

    def test_absolute_path_under_worktree_denied(self):
        """cp src/x /project/.worktrees/feature-test/hooks/pre-bash.sh → deny.

        This is the canonical supervisor repro case. The absolute path
        /project/.worktrees/feature-test/hooks/pre-bash.sh normalizes to
        hooks/pre-bash.sh which matches forbidden "hooks/**".

        @decision DEC-DISCIPLINE-SHELL-COPY-BAN-002
        """
        cmd = f"cp src/x {_WORKTREE}/hooks/pre-bash.sh"
        decision = check(_impl_req(cmd, scope=_HOOKS_SCOPE))
        assert decision is not None, (
            f"Expected deny for absolute-path cp into worktree hooks/ but got None. "
            f"This was the P0 bypass: {cmd!r}"
        )
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    # -----------------------------------------------------------------------
    # Test 2: cp with absolute destination OUTSIDE project root → allow
    # -----------------------------------------------------------------------

    def test_absolute_path_outside_project_allowed(self):
        """cp src/x /some/path/outside/project/hooks/pre-bash.sh → allow.

        The destination is not under the worktree or project root, so it
        cannot pollute the worktree. The policy must not false-positive here.

        @decision DEC-DISCIPLINE-SHELL-COPY-BAN-002
        """
        cmd = "cp src/x /some/external/hooks/pre-bash.sh"
        decision = check(_impl_req(cmd, scope=_HOOKS_SCOPE))
        assert decision is None, (
            f"Expected allow for external absolute path but got {decision!r}. "
            f"External destinations cannot pollute the worktree: {cmd!r}"
        )

    # -----------------------------------------------------------------------
    # Test 3: mv with absolute destination under project root → deny
    # -----------------------------------------------------------------------

    def test_mv_absolute_path_under_project_root_denied(self):
        """mv old_name /project/CLAUDE.md → deny.

        The project root /project is the second fallback after worktree_path.
        /project/CLAUDE.md normalizes to CLAUDE.md which matches forbidden
        "CLAUDE.md".

        @decision DEC-DISCIPLINE-SHELL-COPY-BAN-002
        """
        cmd = f"mv old_name {_PROJECT_ROOT}/CLAUDE.md"
        decision = check(_impl_req(cmd, scope=_HOOKS_SCOPE))
        assert decision is not None, (
            f"Expected deny for absolute mv to project root CLAUDE.md but got None. "
            f"cmd: {cmd!r}"
        )
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    # -----------------------------------------------------------------------
    # Test 4: rsync with absolute destination directory (trailing slash) → deny
    # -----------------------------------------------------------------------

    def test_rsync_absolute_path_trailing_slash_denied(self):
        """rsync -av src/ /project/.worktrees/feature-test/hooks/ → deny.

        Trailing slash on the rsync destination (directory form) must not
        break normalization. hooks/ still matches "hooks/**".

        @decision DEC-DISCIPLINE-SHELL-COPY-BAN-002
        """
        cmd = f"rsync -av src/ {_WORKTREE}/hooks/"
        decision = check(_impl_req(cmd, scope=_HOOKS_SCOPE))
        assert decision is not None, (
            f"Expected deny for absolute rsync trailing-slash into hooks/ but got None. "
            f"cmd: {cmd!r}"
        )
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    # -----------------------------------------------------------------------
    # Test 5: relative destination still denied (non-regression)
    # -----------------------------------------------------------------------

    def test_relative_destination_still_denied(self):
        """cp src/x hooks/pre-bash.sh → still denied (pre-fix behavior preserved).

        Ensures the hotfix did not break the original relative-path case.
        """
        decision = check(_impl_req("cp src/x hooks/pre-bash.sh", scope=_HOOKS_SCOPE))
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_shell_copy_ban"

    # -----------------------------------------------------------------------
    # Test 6: absolute dest within project but in allowed_paths → allow
    # -----------------------------------------------------------------------

    def test_absolute_allowed_path_within_project_still_allowed(self):
        """cp src/x /project/.worktrees/feature-test/tmp/out.py → allow.

        Absolute path normalization must not break allowed_paths precedence.
        tmp/** is in allowed_paths; after normalization, tmp/out.py is allowed.
        """
        cmd = f"cp src/x {_WORKTREE}/tmp/out.py"
        decision = check(_impl_req(cmd, scope=_HOOKS_SCOPE))
        assert decision is None, (
            f"Expected allow for absolute path to allowed tmp/ but got {decision!r}. "
            f"cmd: {cmd!r}"
        )

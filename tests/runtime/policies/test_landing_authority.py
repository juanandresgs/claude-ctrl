"""Tests for guardian-only landing authority (Slice 3, DEC-WHO-LANDING-001).

Proves four invariants:
  1. Implementer cannot land (commit, merge, push)
  2. guardian:provision cannot land
  3. guardian:land CAN land
  4. Bare "guardian" alias no longer silently stands in for landing

@decision DEC-WHO-LANDING-TEST-001
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import time


from runtime.core.landing_authority import classify_landing_scope
from runtime.core.authority_registry import (
    CAN_LAND_GIT,
    CAN_PROVISION_WORKTREE,
    actor_matches_lease_role,
    capabilities_for,
    lease_role_for_stage,
)
from runtime.core.policies.bash_git_who import check
from tests.runtime.policies.conftest import make_context, make_request


def _git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _future_expiry():
    return int(time.time()) + 3600


def _make_lease(*, role="guardian", allowed_ops=None):
    return {
        "role": role,
        "workflow_id": "test-workflow",
        "expires_at": _future_expiry(),
        "allowed_ops_json": json.dumps(
            allowed_ops or ["routine_local", "high_risk", "admin_recovery"]
        ),
        "blocked_ops_json": json.dumps([]),
    }


# ---------------------------------------------------------------------------
# Invariant 1: Implementer cannot land
# ---------------------------------------------------------------------------


class TestImplementerCannotLand:

    def test_implementer_denied_commit(self):
        lease = _make_lease(role="implementer", allowed_ops=["routine_local"])
        ctx = make_context(actor_role="implementer", lease=lease)
        req = make_request("git commit -m 'impl work'", context=ctx)
        d = check(req)
        assert d is not None and d.action == "deny"
        assert "can_land_git" in d.reason.lower()

    def test_implementer_denied_merge(self):
        lease = _make_lease(role="implementer", allowed_ops=["routine_local"])
        ctx = make_context(actor_role="implementer", lease=lease)
        req = make_request("git merge feature/foo", context=ctx)
        d = check(req)
        assert d is not None and d.action == "deny"
        assert "can_land_git" in d.reason.lower()

    def test_implementer_denied_push(self):
        lease = _make_lease(role="implementer", allowed_ops=["routine_local"])
        ctx = make_context(actor_role="implementer", lease=lease)
        req = make_request("git push origin feature/bar", context=ctx)
        d = check(req)
        assert d is not None and d.action == "deny"
        assert "can_land_git" in d.reason.lower()

    def test_implementer_lacks_can_land_git(self):
        assert CAN_LAND_GIT not in capabilities_for("implementer")


# ---------------------------------------------------------------------------
# Invariant 2: guardian:provision cannot land
# ---------------------------------------------------------------------------


class TestGuardianProvisionCannotLand:

    def test_provision_denied_commit(self):
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:provision", lease=lease)
        req = make_request("git commit -m 'provision should not commit'", context=ctx)
        d = check(req)
        assert d is not None and d.action == "deny"
        assert "can_land_git" in d.reason.lower()

    def test_provision_denied_merge(self):
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:provision", lease=lease)
        req = make_request("git merge feature/foo", context=ctx)
        d = check(req)
        assert d is not None and d.action == "deny"
        assert "can_land_git" in d.reason.lower()

    def test_provision_denied_push(self):
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:provision", lease=lease)
        req = make_request("git push origin feature/bar", context=ctx)
        d = check(req)
        assert d is not None and d.action == "deny"
        assert "can_land_git" in d.reason.lower()

    def test_provision_lacks_can_land_git(self):
        assert CAN_LAND_GIT not in capabilities_for("guardian:provision")

    def test_provision_has_provision_worktree(self):
        """guardian:provision retains CAN_PROVISION_WORKTREE."""
        assert CAN_PROVISION_WORKTREE in capabilities_for("guardian:provision")

    def test_provision_allowed_non_landing_high_risk(self):
        """guardian:provision with guardian lease can still do high_risk non-landing ops."""
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:provision", lease=lease)
        req = make_request("git rebase main", context=ctx)
        d = check(req)
        assert d is None, "guardian:provision should be allowed non-landing high_risk ops"


# ---------------------------------------------------------------------------
# Invariant 3: guardian:land CAN land
# ---------------------------------------------------------------------------


class TestGuardianLandCanLand:

    def test_land_allowed_commit(self):
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:land", lease=lease)
        req = make_request("git commit -m 'land the feature'", context=ctx)
        d = check(req)
        assert d is None

    def test_land_allowed_merge(self):
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:land", lease=lease)
        req = make_request("git merge feature/done", context=ctx)
        d = check(req)
        assert d is None

    def test_land_allowed_push(self):
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:land", lease=lease)
        req = make_request("git push origin feature/done", context=ctx)
        d = check(req)
        assert d is None

    def test_land_has_can_land_git(self):
        assert CAN_LAND_GIT in capabilities_for("guardian:land")

    def test_land_merge_abort_still_allowed(self):
        """merge --abort is admin_recovery, not a landing op — CAN_LAND_GIT gate skips it."""
        lease = _make_lease()
        ctx = make_context(actor_role="guardian:land", lease=lease)
        req = make_request("git merge --abort", context=ctx)
        d = check(req)
        assert d is None


class TestRuntimeLandingScopeClassification:
    def _repo_with_feature_worktree(self, tmp_path):
        repo = tmp_path / "repo"
        repo.mkdir()
        _git(repo, "init")
        _git(repo, "config", "user.email", "test@example.com")
        _git(repo, "config", "user.name", "Test User")
        (repo / "README.md").write_text("seed\n", encoding="utf-8")
        _git(repo, "add", "README.md")
        _git(repo, "commit", "-m", "seed")
        feature = tmp_path / "feature"
        _git(repo, "worktree", "add", "-b", "feature/test", str(feature))
        return repo, feature

    def _ctx(self, repo, feature):
        lease = _make_lease()
        lease["worktree_path"] = str(feature)
        lease["workflow_id"] = "wf-test"
        return make_context(
            actor_role="guardian:land",
            project_root=str(repo),
            lease=lease,
            workflow_id="wf-test",
        )

    def test_classifies_feature_commit_governance_sidecar_and_merge(self, tmp_path):
        repo, feature = self._repo_with_feature_worktree(tmp_path)
        ctx = self._ctx(repo, feature)

        feature_scope = classify_landing_scope(
            ctx,
            subcommand="commit",
            target_dir=str(feature),
            paths=["src/adapter.py"],
        )
        governance_scope = classify_landing_scope(
            ctx,
            subcommand="commit",
            target_dir=str(repo),
            paths=["MASTER_PLAN.md", "docs/RESEARCH.md"],
        )
        merge_scope = classify_landing_scope(
            ctx,
            subcommand="merge",
            target_dir=str(repo),
            paths=[],
        )

        assert feature_scope.operation == "feature_commit"
        assert governance_scope.operation == "governance_record"
        assert governance_scope.path_class == "governance_only"
        assert merge_scope.operation == "merge_reviewed_feature"

    def test_base_worktree_non_governance_commit_is_not_landing_sidecar(self, tmp_path):
        repo, feature = self._repo_with_feature_worktree(tmp_path)
        ctx = self._ctx(repo, feature)

        scope = classify_landing_scope(
            ctx,
            subcommand="commit",
            target_dir=str(repo),
            paths=["scripts/landing.sh"],
        )

        assert scope.operation == "not_landing"
        assert scope.path_class == "non_governance"


# ---------------------------------------------------------------------------
# Invariant 4: Bare "guardian" alias no longer silently stands in
# ---------------------------------------------------------------------------


class TestBareGuardianAliasRemoved:

    def test_bare_guardian_empty_capabilities(self):
        caps = capabilities_for("guardian")
        assert caps == frozenset(), (
            "Bare 'guardian' must return empty capabilities after "
            "DEC-WHO-LANDING-ALIAS-001"
        )

    def test_bare_guardian_cannot_land(self):
        """Even with a valid guardian lease, bare 'guardian' actor cannot commit."""
        lease = _make_lease()
        ctx = make_context(actor_role="guardian", lease=lease)
        req = make_request("git commit -m 'should fail'", context=ctx)
        d = check(req)
        assert d is not None and d.action == "deny"
        assert "can_land_git" in d.reason.lower()

    def test_bare_guardian_can_still_do_non_landing_ops(self):
        """Bare 'guardian' with guardian lease can do high_risk non-landing ops
        (role literal match passes belt-and-suspenders, CAN_LAND_GIT gate skips)."""
        lease = _make_lease()
        ctx = make_context(actor_role="guardian", lease=lease)
        req = make_request("git rebase main", context=ctx)
        d = check(req)
        assert d is None


# ---------------------------------------------------------------------------
# Stage↔lease role bridging helpers
# ---------------------------------------------------------------------------


class TestLeaseRoleBridging:

    def test_lease_role_for_guardian_provision(self):
        assert lease_role_for_stage("guardian:provision") == "guardian"

    def test_lease_role_for_guardian_land(self):
        assert lease_role_for_stage("guardian:land") == "guardian"

    def test_lease_role_for_implementer(self):
        assert lease_role_for_stage("implementer") == "implementer"

    def test_lease_role_for_planner(self):
        assert lease_role_for_stage("planner") == "planner"

    def test_lease_role_for_unknown(self):
        assert lease_role_for_stage("unknown_role") is None

    def test_lease_role_for_empty(self):
        assert lease_role_for_stage("") is None

    def test_actor_matches_guardian_provision_to_guardian(self):
        assert actor_matches_lease_role("guardian:provision", "guardian")

    def test_actor_matches_guardian_land_to_guardian(self):
        assert actor_matches_lease_role("guardian:land", "guardian")

    def test_actor_matches_literal_guardian(self):
        assert actor_matches_lease_role("guardian", "guardian")

    def test_implementer_does_not_match_guardian(self):
        assert not actor_matches_lease_role("implementer", "guardian")

    def test_guardian_provision_does_not_match_implementer(self):
        assert not actor_matches_lease_role("guardian:provision", "implementer")

    def test_empty_actor_does_not_match(self):
        assert not actor_matches_lease_role("", "guardian")

    def test_empty_lease_does_not_match(self):
        assert not actor_matches_lease_role("guardian:land", "")

"""Live-path tests for guardian stage canonicalization (DEC-WHO-GUARDIAN-CANONICALIZE-001).

These tests cover the LIVE paths — not synthetic make_context() helpers. Live
dispatch persists bare "guardian" in agent_markers (lifecycle.py) and bare
"guardian" as lease.role (leases.issue_for_dispatch). build_context() must
canonicalize bare guardian to the correct compound stage using dispatch_phase
from completion_records, driven by stage_registry.next_stage() as the sole
routing authority.

Four required invariants (from the Slice 3 correction spec):
  1. live guardian + planner→guardian dispatch phase retains CAN_PROVISION_WORKTREE
  2. live guardian + reviewer→guardian dispatch phase retains CAN_LAND_GIT
  3. live guardian with matching lease can `git worktree add` in provision mode
  4. live guardian with matching lease can `git commit` only in land mode
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from runtime.core import markers as markers_mod
from runtime.core import stage_registry as sr
from runtime.core.authority_registry import (
    CAN_LAND_GIT,
    CAN_PROVISION_WORKTREE,
    canonical_actor_stage,
)
from runtime.core.policy_engine import build_context, PolicyRequest
from runtime.core.policies.bash_git_who import check as bash_git_who_check
from runtime.core.policies.bash_worktree_creation import check as worktree_check
from runtime.core.command_intent import build_bash_command_intent
from runtime.schemas import ensure_schema


# ---------------------------------------------------------------------------
# Pure helper tests — canonical_actor_stage() uses stage_registry.next_stage()
# as the single routing authority, not a duplicate mapping.
# ---------------------------------------------------------------------------


class TestCanonicalActorStage:

    def test_guardian_after_planner_next_work_item_resolves_to_provision(self):
        """planner → guardian via next_work_item routes to guardian:provision."""
        assert canonical_actor_stage("guardian", "planner:next_work_item") == sr.GUARDIAN_PROVISION

    def test_guardian_after_reviewer_ready_for_guardian_resolves_to_land(self):
        """reviewer → guardian via ready_for_guardian routes to guardian:land."""
        assert canonical_actor_stage("guardian", "reviewer:ready_for_guardian") == sr.GUARDIAN_LAND

    def test_guardian_with_no_dispatch_phase_defaults_to_provision(self):
        """No dispatch context → safe default (provision, no landing auth)."""
        assert canonical_actor_stage("guardian", None) == sr.GUARDIAN_PROVISION
        assert canonical_actor_stage("guardian", "") == sr.GUARDIAN_PROVISION

    def test_guardian_with_unknown_verdict_defaults_to_provision(self):
        """Unknown verdict → next_stage returns None → safe default."""
        assert canonical_actor_stage("guardian", "planner:does_not_exist") == sr.GUARDIAN_PROVISION

    def test_non_guardian_roles_pass_through_unchanged(self):
        assert canonical_actor_stage("planner", "anything") == "planner"
        assert canonical_actor_stage("implementer", "anything") == "implementer"
        assert canonical_actor_stage("reviewer", "anything") == "reviewer"
        assert canonical_actor_stage("", "anything") == ""

    def test_guardian_compound_stage_passes_through(self):
        """Already-compound stage IDs (e.g. from tests) pass through unchanged
        because actor_role != "guardian"."""
        assert canonical_actor_stage("guardian:land", "any") == "guardian:land"
        assert canonical_actor_stage("guardian:provision", "any") == "guardian:provision"


# ---------------------------------------------------------------------------
# Live build_context path tests — seeds SQLite state (markers, leases,
# completion_records) the same way the live hook flow does, then runs
# build_context() and asserts the canonicalized actor_role and capabilities.
# ---------------------------------------------------------------------------


@pytest.fixture
def live_db(tmp_path):
    """Create a fresh SQLite policy DB with the full schema applied."""
    db = tmp_path / "state.db"
    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    yield conn
    conn.close()


def _seed_lease(conn, *, workflow_id, worktree_path, role="guardian",
                allowed_ops=None, blocked_ops=None):
    now = int(time.time())
    expires = now + 3600
    conn.execute(
        "INSERT INTO dispatch_leases "
        "(lease_id, role, agent_id, workflow_id, worktree_path, status, "
        " issued_at, expires_at, allowed_ops_json, blocked_ops_json) "
        "VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)",
        (
            f"lease-{workflow_id}",
            role,
            "agent-live",
            workflow_id,
            worktree_path,
            now,
            expires,
            json.dumps(allowed_ops or ["routine_local", "high_risk", "admin_recovery"]),
            json.dumps(blocked_ops or []),
        ),
    )
    conn.commit()


def _seed_completion(conn, *, workflow_id, role, verdict):
    conn.execute(
        "INSERT INTO completion_records "
        "(lease_id, workflow_id, role, verdict, valid, payload_json, missing_fields, created_at) "
        "VALUES (?, ?, ?, ?, 1, '{}', '[]', ?)",
        (f"lease-{workflow_id}", workflow_id, role, verdict, int(time.time())),
    )
    conn.commit()


def _seed_workflow_binding(conn, *, workflow_id, worktree_path, branch):
    now = int(time.time())
    conn.execute(
        "INSERT INTO workflow_bindings "
        "(workflow_id, worktree_path, branch, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (workflow_id, worktree_path, branch, now, now),
    )
    conn.commit()


class TestLiveGuardianCanonicalization:
    """Build the full live state (bare 'guardian' marker, bare 'guardian' lease,
    workflow binding, completion record) and exercise build_context()."""

    def test_live_guardian_with_planner_dispatch_phase_retains_provision_capability(
        self, live_db, tmp_path
    ):
        """Scenario: planner just completed next_work_item → guardian dispatched
        in provision mode. Marker and lease both carry bare 'guardian'."""
        project_root = str(tmp_path)
        workflow_id = "feature-provision-live"

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/x"
        )
        _seed_lease(
            live_db,
            workflow_id=workflow_id,
            worktree_path=project_root,
            role="guardian",
        )
        _seed_completion(
            live_db, workflow_id=workflow_id, role="planner", verdict="next_work_item"
        )

        ctx = build_context(live_db, cwd=project_root, project_root=project_root, actor_role="guardian", actor_id="agent-live")

        assert ctx.actor_role == sr.GUARDIAN_PROVISION
        assert CAN_PROVISION_WORKTREE in ctx.capabilities
        assert CAN_LAND_GIT not in ctx.capabilities
        assert ctx.dispatch_phase == "planner:next_work_item"

    def test_live_guardian_with_reviewer_dispatch_phase_retains_land_capability(
        self, live_db, tmp_path
    ):
        """Scenario: reviewer just completed ready_for_guardian → guardian
        dispatched in land mode."""
        project_root = str(tmp_path)
        workflow_id = "feature-land-live"

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/y"
        )
        _seed_lease(
            live_db,
            workflow_id=workflow_id,
            worktree_path=project_root,
            role="guardian",
        )
        _seed_completion(
            live_db, workflow_id=workflow_id, role="reviewer", verdict="ready_for_guardian"
        )

        ctx = build_context(live_db, cwd=project_root, project_root=project_root, actor_role="guardian", actor_id="agent-live")

        assert ctx.actor_role == sr.GUARDIAN_LAND
        assert CAN_LAND_GIT in ctx.capabilities
        assert CAN_PROVISION_WORKTREE not in ctx.capabilities
        assert ctx.dispatch_phase == "reviewer:ready_for_guardian"

    def test_live_guardian_in_provision_mode_can_worktree_add(self, live_db, tmp_path):
        """End-to-end: live guardian in provision mode is allowed git worktree add."""
        project_root = str(tmp_path)
        workflow_id = "feature-worktree-add"

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/x"
        )
        _seed_lease(
            live_db,
            workflow_id=workflow_id,
            worktree_path=project_root,
            role="guardian",
        )
        _seed_completion(
            live_db, workflow_id=workflow_id, role="planner", verdict="next_work_item"
        )

        ctx = build_context(live_db, cwd=project_root, project_root=project_root, actor_role="guardian", actor_id="agent-live")
        command = "git worktree add .worktrees/feature-x -b feature/x"
        request = PolicyRequest(
            event_type="PreToolUse",
            tool_name="Bash",
            tool_input={"command": command},
            context=ctx,
            cwd=project_root,
            command_intent=build_bash_command_intent(command, cwd=project_root),
        )
        decision = worktree_check(request)
        assert decision is None, (
            f"live guardian in provision mode must be allowed git worktree add; "
            f"got {decision!r}"
        )

    def test_live_guardian_in_land_mode_can_commit(self, live_db, tmp_path):
        """End-to-end: live guardian in land mode is allowed git commit."""
        project_root = str(tmp_path)
        workflow_id = "feature-commit-land"

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/y"
        )
        _seed_lease(
            live_db,
            workflow_id=workflow_id,
            worktree_path=project_root,
            role="guardian",
        )
        _seed_completion(
            live_db, workflow_id=workflow_id, role="reviewer", verdict="ready_for_guardian"
        )

        ctx = build_context(live_db, cwd=project_root, project_root=project_root, actor_role="guardian", actor_id="agent-live")
        command = "git commit -m 'feat: land work'"
        request = PolicyRequest(
            event_type="PreToolUse",
            tool_name="Bash",
            tool_input={"command": command},
            context=ctx,
            cwd=project_root,
            command_intent=build_bash_command_intent(command, cwd=project_root),
        )
        decision = bash_git_who_check(request)
        assert decision is None, (
            f"live guardian in land mode must be allowed git commit; got {decision!r}"
        )

    def test_live_guardian_in_provision_mode_cannot_commit(self, live_db, tmp_path):
        """End-to-end: live guardian in provision mode is DENIED git commit
        by the CAN_LAND_GIT gate (only guardian:land can land)."""
        project_root = str(tmp_path)
        workflow_id = "feature-commit-provision"

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/z"
        )
        _seed_lease(
            live_db,
            workflow_id=workflow_id,
            worktree_path=project_root,
            role="guardian",
        )
        _seed_completion(
            live_db, workflow_id=workflow_id, role="planner", verdict="next_work_item"
        )

        ctx = build_context(live_db, cwd=project_root, project_root=project_root, actor_role="guardian", actor_id="agent-live")
        command = "git commit -m 'should not land'"
        request = PolicyRequest(
            event_type="PreToolUse",
            tool_name="Bash",
            tool_input={"command": command},
            context=ctx,
            cwd=project_root,
            command_intent=build_bash_command_intent(command, cwd=project_root),
        )
        decision = bash_git_who_check(request)
        assert decision is not None
        assert decision.action == "deny"
        assert "can_land_git" in decision.reason.lower()

    def test_live_guardian_with_no_dispatch_phase_defaults_to_provision(
        self, live_db, tmp_path
    ):
        """Scenario: fresh guardian session with no completion history.
        Canonicalization defaults to provision (safe — no landing auth)."""
        project_root = str(tmp_path)
        workflow_id = "feature-no-history"

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/q"
        )
        _seed_lease(
            live_db,
            workflow_id=workflow_id,
            worktree_path=project_root,
            role="guardian",
        )
        # NO completion_records row — dispatch_phase will be None

        ctx = build_context(live_db, cwd=project_root, project_root=project_root, actor_role="guardian", actor_id="agent-live")

        assert ctx.actor_role == sr.GUARDIAN_PROVISION
        assert CAN_PROVISION_WORKTREE in ctx.capabilities
        assert CAN_LAND_GIT not in ctx.capabilities
        assert ctx.dispatch_phase is None


# ---------------------------------------------------------------------------
# DEC-WHO-DISPATCH-PHASE-TIEBREAK-001
#
# build_context()'s latest-completion query must order by (created_at DESC,
# id DESC) — the same tiebreak used by completions.latest(). Without the id
# tiebreak, two completions with identical created_at values resolve
# nondeterministically, which can misgrant guardian landing-vs-provision
# capability. The tests below pin the tiebreak behavior.
# ---------------------------------------------------------------------------


def _seed_completion_at(conn, *, workflow_id, role, verdict, created_at):
    """Seed a completion row at an explicit created_at (for tie construction)."""
    conn.execute(
        "INSERT INTO completion_records "
        "(lease_id, workflow_id, role, verdict, valid, payload_json, missing_fields, created_at) "
        "VALUES (?, ?, ?, ?, 1, '{}', '[]', ?)",
        (f"lease-{workflow_id}", workflow_id, role, verdict, created_at),
    )
    conn.commit()


class TestDispatchPhaseTieOrdering:
    """build_context() must match completions.latest()'s ORDER BY — same
    created_at ties must break by higher id (the later insert wins)."""

    def test_same_second_tie_resolves_by_higher_id_reviewer_wins_when_inserted_last(
        self, live_db, tmp_path
    ):
        """Two completions at the same created_at: planner first, reviewer
        second. The reviewer row has the higher id and must win the tiebreak
        so dispatch_phase == reviewer:ready_for_guardian."""
        project_root = str(tmp_path)
        workflow_id = "feature-tie-reviewer-wins"
        now = int(time.time())

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/t"
        )
        _seed_lease(
            live_db, workflow_id=workflow_id, worktree_path=project_root, role="guardian"
        )

        # Insert planner first, reviewer second — identical created_at.
        _seed_completion_at(
            live_db, workflow_id=workflow_id, role="planner",
            verdict="next_work_item", created_at=now,
        )
        _seed_completion_at(
            live_db, workflow_id=workflow_id, role="reviewer",
            verdict="ready_for_guardian", created_at=now,
        )

        ctx = build_context(
            live_db, cwd=project_root, project_root=project_root,
            actor_role="guardian", actor_id="agent-live",
        )

        assert ctx.dispatch_phase == "reviewer:ready_for_guardian", (
            "Same-second tie must resolve by higher id (later insert wins). "
            "Reviewer was inserted last and must win."
        )
        # Canonicalization must follow — guardian → guardian:land with CAN_LAND_GIT.
        assert ctx.actor_role == sr.GUARDIAN_LAND
        assert CAN_LAND_GIT in ctx.capabilities
        assert CAN_PROVISION_WORKTREE not in ctx.capabilities

    def test_same_second_tie_resolves_by_higher_id_planner_wins_when_inserted_last(
        self, live_db, tmp_path
    ):
        """Reverse insert order: reviewer first, planner second. Planner now
        has the higher id and must win the tiebreak → guardian:provision."""
        project_root = str(tmp_path)
        workflow_id = "feature-tie-planner-wins"
        now = int(time.time())

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/t2"
        )
        _seed_lease(
            live_db, workflow_id=workflow_id, worktree_path=project_root, role="guardian"
        )

        # Insert reviewer first, planner second — identical created_at.
        _seed_completion_at(
            live_db, workflow_id=workflow_id, role="reviewer",
            verdict="ready_for_guardian", created_at=now,
        )
        _seed_completion_at(
            live_db, workflow_id=workflow_id, role="planner",
            verdict="next_work_item", created_at=now,
        )

        ctx = build_context(
            live_db, cwd=project_root, project_root=project_root,
            actor_role="guardian", actor_id="agent-live",
        )

        assert ctx.dispatch_phase == "planner:next_work_item", (
            "Same-second tie must resolve by higher id — planner inserted "
            "last must win."
        )
        # Canonicalization must follow — guardian → guardian:provision,
        # CAN_LAND_GIT must NOT be granted.
        assert ctx.actor_role == sr.GUARDIAN_PROVISION
        assert CAN_PROVISION_WORKTREE in ctx.capabilities
        assert CAN_LAND_GIT not in ctx.capabilities

    def test_build_context_matches_completions_latest_ordering(self, live_db, tmp_path):
        """build_context()'s latest-completion ORDER BY must match
        completions.latest()'s ORDER BY — same tie-breaking behavior, by
        direct comparison. If this regresses, dispatch_phase will disagree
        with the authority module's idea of the latest completion."""
        from runtime.core import completions as completions_mod

        project_root = str(tmp_path)
        workflow_id = "feature-latest-parity"
        now = int(time.time())

        markers_mod.set_active(live_db, "agent-live", "guardian", project_root=project_root)
        _seed_workflow_binding(
            live_db, workflow_id=workflow_id, worktree_path=project_root, branch="feature/p"
        )
        _seed_lease(
            live_db, workflow_id=workflow_id, worktree_path=project_root, role="guardian"
        )
        # Three rows, identical created_at — the highest id must win in both
        # build_context and completions.latest.
        _seed_completion_at(
            live_db, workflow_id=workflow_id, role="planner",
            verdict="next_work_item", created_at=now,
        )
        _seed_completion_at(
            live_db, workflow_id=workflow_id, role="implementer",
            verdict="complete", created_at=now,
        )
        _seed_completion_at(
            live_db, workflow_id=workflow_id, role="reviewer",
            verdict="ready_for_guardian", created_at=now,
        )

        ctx = build_context(
            live_db, cwd=project_root, project_root=project_root,
            actor_role="guardian", actor_id="agent-live",
        )
        latest = completions_mod.latest(live_db, workflow_id=workflow_id)

        assert latest is not None
        assert ctx.dispatch_phase == f"{latest['role']}:{latest['verdict']}", (
            "build_context() and completions.latest() must agree on which "
            "row is 'latest' when created_at values tie."
        )

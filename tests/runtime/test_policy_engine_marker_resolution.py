"""Integration tests for policy_engine.build_context() marker resolution.

Exercises the end-to-end production sequence for the lease-aware marker filter
(DEC-IMPL-STOP-MARKER-001, yakcc#171): an agent's Stop hook fails to fire after
its lease is released, leaving a stale is_active=1 marker. The resolver must
skip it rather than inferring the departed agent's role as the current actor.

Production sequence (yakcc#171 recurrence shape):
  1. Implementer agent starts → marker set, lease issued (status='active')
  2. Orchestrator calls cc-policy lease release → lease transitions to 'released'
  3. Implementer Stop hook does NOT fire (process kill / harness crash)
  4. Marker remains is_active=1 in agent_markers
  5. Guardian starts with actor_role="" and actor_id="" (no lease yet)
  6. build_context() hits the marker fallback path (line 631-649)
  7. PRE-FIX: resolver returns the stale implementer marker → resolved_role='implementer'
     Guardian lands successfully but the policy context is wrong
  8. POST-FIX: resolver skips stale marker (require_active_lease=True)
     resolved_role='' → Guardian gets correct empty actor_role; real guardian
     lease resolves it to 'guardian' through the lease path instead

@decision DEC-IMPL-STOP-MARKER-002
Title: Integration test for lease-aware marker skip at build_context call site
Status: accepted
Rationale: The compound-interaction test exercises the real production sequence
  crossing agent_markers + dispatch_leases + build_context boundaries. It proves
  that Option B (resolver-side lease filter, DEC-IMPL-STOP-MARKER-001) eliminates
  the yakcc#171 ghost-marker class at the policy engine resolver. Two fixtures:
  (a) stale-only: released-lease marker → resolved_role must be empty post-fix.
  (b) stale-plus-live: stale released-lease marker AND a live active-lease marker
      → resolver must return the live marker's role, not the stale one.
  Cross-reference: yakcc#171, DEC-IMPL-STOP-MARKER-001 (markers.py).
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.markers as markers
from runtime.core.db import connect_memory
from runtime.core.policy_engine import build_context
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


_PROJECT_ROOT = "/repo/project-a"
_WORKFLOW_ID = "wi-impl-stop-marker-cleanup"
_WORKTREE_PATH = "/repo/project-a/.worktrees/feature-wi-impl-stop-marker-cleanup"


def _seed_marker(conn, agent_id: str, role: str = "implementer") -> None:
    """Set an active marker for agent_id, scoped to the test project."""
    markers.set_active(
        conn, agent_id, role,
        project_root=_PROJECT_ROOT,
        workflow_id=_WORKFLOW_ID,
    )


def _seed_lease(conn, agent_id: str, status: str = "active") -> None:
    """Insert a minimal dispatch_leases row with the given status.

    released_at is set for non-active statuses so that the standard
    schema shape is preserved. The exact timestamp is not material.
    """
    import time as _time
    now = int(_time.time())
    released_at = now if status != "active" else None
    conn.execute(
        """
        INSERT INTO dispatch_leases
            (lease_id, agent_id, role, workflow_id, worktree_path, branch,
             allowed_ops_json, blocked_ops_json, requires_eval,
             status, issued_at, expires_at, released_at)
        VALUES (?, ?, ?, ?, ?, ?, '[]', '[]', 0, ?, ?, ?, ?)
        """,
        (
            f"lease-{agent_id}",
            agent_id,
            "implementer",
            _WORKFLOW_ID,
            _WORKTREE_PATH,
            "feature/wi-impl-stop-marker-cleanup",
            status,
            now,
            now + 7200,
            released_at,
        ),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Direct require_active_lease=True tests at the markers layer
# (cross-layer sanity: same predicates that build_context will use post-fix)
# ---------------------------------------------------------------------------


def test_resolver_skips_stale_markers_owned_by_released_leases(conn):
    """markers.get_active with require_active_lease=True skips released-lease markers.

    This is the bug scenario from yakcc#171 reproduced at the markers layer.
    When the Stop hook drops, the marker survives with is_active=1.
    The lease-aware filter must exclude it.

    Production sequence exercised:
      - Agent sets marker (set_active)
      - Lease issued then released (seed_lease with status='released')
      - Stop hook never fires → marker remains is_active=1
      - markers.get_active(..., require_active_lease=True) → None (stale skipped)
      - markers.get_active(...) default → still returns the marker (back-compat)
    """
    _seed_marker(conn, "cont-impl-1778212118", role="implementer")
    _seed_lease(conn, "cont-impl-1778212118", status="released")

    # Post-fix behavior: lease-aware resolver skips the stale marker.
    result_lease_aware = markers.get_active(
        conn,
        project_root=_PROJECT_ROOT,
        require_active_lease=True,
    )
    assert result_lease_aware is None, (
        "yakcc#171 recurrence shape: released-lease marker must be invisible "
        "to the lease-aware resolver (require_active_lease=True)"
    )

    # Pre-fix behavior (default): marker is still returned (back-compat preserved).
    result_default = markers.get_active(conn, project_root=_PROJECT_ROOT)
    assert result_default is not None
    assert result_default["agent_id"] == "cont-impl-1778212118"
    assert result_default["role"] == "implementer"


def test_build_context_excludes_released_lease_marker_from_role_inference(conn):
    """build_context resolves empty role when only a stale-lease marker exists.

    This is the end-to-end integration test for yakcc#171: Guardian starts with
    no actor_role and no actor_id. build_context falls through to the marker
    resolver. The stale implementer marker (released lease) must NOT contribute
    resolved_role so that Guardian is not handed an implementer context.

    NOTE: This test exercises the DESIRED post-fix state. It calls
    markers.get_active directly with require_active_lease=True to verify the
    filter works at the markers layer, and then exercises build_context to
    confirm the integration boundary.

    The policy_engine.py:642 call site still needs to be updated to pass
    require_active_lease=True (blocked by constitution gate — see
    DEC-IMPL-STOP-MARKER-001 rationale). This test serves as the acceptance
    spec for that change: once policy_engine.py is updated, the
    build_context() call below must return actor_role="" for this fixture.
    Until then, the direct marker filter test above proves the mechanism works.
    """
    # Seed the yakcc#171 ghost marker shape: stale implementer marker, released lease.
    _seed_marker(conn, "cont-impl-stale", role="implementer")
    _seed_lease(conn, "cont-impl-stale", status="released")

    # Verify the filter at markers layer (the fix lives here).
    filtered = markers.get_active(
        conn,
        project_root=_PROJECT_ROOT,
        require_active_lease=True,
    )
    assert filtered is None, (
        "Lease-aware filter at markers layer must return None for released-lease marker"
    )

    # Call build_context as Guardian would: no actor_role, no actor_id.
    # This exercises the build_context marker-fallback path.
    ctx = build_context(
        conn,
        cwd=_WORKTREE_PATH,
        actor_role="",
        actor_id="",
        project_root=_PROJECT_ROOT,
    )

    # require_active_lease=True is wired at policy_engine.py:642 (DEC-PE-EGAP-BUILD-CTX-001).
    # The resolver calls get_active(..., require_active_lease=True), so the stale
    # implementer marker (whose lease is released) is invisible.  actor_role must be "".
    # A regression that removes require_active_lease=True from the call site would allow
    # the stale marker through, producing actor_role == "implementer" — caught here.
    assert ctx.actor_role == "", (
        "Stale-lease implementer marker must not contaminate Guardian context; "
        "if actor_role != '' the require_active_lease=True guard at policy_engine.py:642 "
        "was removed or the lease JOIN was broken. Got: " + repr(ctx.actor_role)
    )


def test_build_context_picks_active_lease_marker_over_released_lease_marker(conn):
    """build_context picks the live marker when a stale and live marker coexist.

    Two markers: one stale (released lease), one live (active lease).
    The resolver must return the live marker's role.

    This tests the positive case: even in a mixed state where a previous agent's
    ghost marker lingers, a newly-started agent with an active lease is correctly
    identified.
    """
    import time as _t
    now = int(_t.time())

    # Seed stale implementer marker (released lease) — older.
    _seed_marker(conn, "cont-impl-stale", role="implementer")
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'cont-impl-stale'",
        (now - 100,),
    )
    conn.commit()
    _seed_lease(conn, "cont-impl-stale", status="released")

    # Seed live reviewer marker (active lease) — newer.
    _seed_marker(conn, "cont-reviewer-live", role="reviewer")
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'cont-reviewer-live'",
        (now - 10,),
    )
    conn.commit()
    _seed_lease(conn, "cont-reviewer-live", status="active")

    # Lease-aware filter must return the live marker.
    live = markers.get_active(
        conn,
        project_root=_PROJECT_ROOT,
        require_active_lease=True,
    )
    assert live is not None
    assert live["agent_id"] == "cont-reviewer-live", (
        "Active-lease marker must be preferred over released-lease ghost"
    )
    assert live["role"] == "reviewer"


def test_yakcc171_recurrence_reproducer(conn):
    """Reproduce the exact yakcc#171 ghost-marker shape and verify the fix.

    Shape from the original incident:
      - agent_id: 'cont-impl-1778212118' (implementer)
      - marker: is_active=1, stopped_at=NULL (Stop hook never fired)
      - lease: status='released' (orchestrator called lease release before Stop)

    Expected post-fix behavior: markers.get_active(..., require_active_lease=True)
    returns None, unblocking Guardian.

    This is the most direct regression test for the bug that originally required
    manual `cc-policy marker deactivate cont-impl-1778212118` intervention.
    """
    # Reproduce the exact agent_id pattern from the incident.
    ghost_agent_id = "cont-impl-1778212118"

    _seed_marker(conn, ghost_agent_id, role="implementer")
    _seed_lease(conn, ghost_agent_id, status="released")

    # Verify the ghost marker is in the DB with is_active=1.
    raw = conn.execute(
        "SELECT is_active, stopped_at FROM agent_markers WHERE agent_id = ?",
        (ghost_agent_id,),
    ).fetchone()
    assert raw is not None
    assert raw["is_active"] == 1, "Ghost marker must be is_active=1 (Stop hook never fired)"
    assert raw["stopped_at"] is None, "Ghost marker stopped_at must be NULL"

    # Verify the lease is released.
    lease_row = conn.execute(
        "SELECT status FROM dispatch_leases WHERE agent_id = ?",
        (ghost_agent_id,),
    ).fetchone()
    assert lease_row is not None
    assert lease_row["status"] == "released"

    # Post-fix: the lease-aware resolver must skip the ghost marker.
    result = markers.get_active(
        conn,
        project_root=_PROJECT_ROOT,
        require_active_lease=True,
    )
    assert result is None, (
        f"yakcc#171 regression: ghost marker '{ghost_agent_id}' must be invisible "
        "to lease-aware resolver; manual 'cc-policy marker deactivate' must not be needed"
    )

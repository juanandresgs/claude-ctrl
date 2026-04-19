"""Regression suite: compound-stage marker persistence through ensure_schema.

@decision DEC-CONV-002-AMEND-001
Title: _MARKER_ACTIVE_ROLES derives from stage_registry.ACTIVE_STAGES
Status: accepted
Rationale: GS1-F-4 root-cause: ensure_schema() cleanup UPDATE deactivated
  compound-stage roles ('guardian:land', 'guardian:provision') because the
  original DEC-CONV-002 whitelist was hardcoded to 4 base roles. This suite
  pins the corrected behaviour: every ACTIVE_STAGES member survives a
  cleanup round-trip, and only non-dispatch roles are deactivated.

Tests exercising the CLI subprocess path prove the production sequence
  (seat → CLI invocation → ensure_schema cleanup → query) exactly as it
  runs in the global-soak lane.

Production sequence for tests 1-4:
  1. SubagentStart hook calls ``cc-policy dispatch agent-start <role> <id>``
     which writes agent_markers row with is_active=1.
  2. Orchestrator calls ``cc-policy marker get-active`` (or ``context role``).
     Both invoke _get_conn() -> ensure_schema() -> cleanup UPDATE.
  3. If the role is NOT in the whitelist, is_active is flipped to 0.
  4. Subsequent queries return None / empty role.

These tests directly replicate that sequence via subprocess CLI calls
against a hermetic tmp-dir SQLite DB (CLAUDE_POLICY_DB env var).
"""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_REPO_ROOT))

from runtime.core.db import connect_memory  # noqa: E402
from runtime.schemas import ensure_schema, _MARKER_ACTIVE_ROLES  # noqa: E402
from runtime.core import markers  # noqa: E402
from runtime.core.stage_registry import ACTIVE_STAGES  # noqa: E402


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------

_PYTHON = sys.executable


def _run_cli(args: list[str], *, db_path: Path, project_dir: str | None = None) -> tuple[int, dict]:
    """Run ``python3 -m runtime.cli <args>`` with CLAUDE_POLICY_DB set.

    Returns (returncode, parsed_json_or_raw_dict).
    """
    env = {
        "CLAUDE_POLICY_DB": str(db_path),
        "PYTHONPATH": str(_REPO_ROOT),
        "PATH": __import__("os").environ.get("PATH", ""),
    }
    if project_dir is not None:
        env["CLAUDE_PROJECT_DIR"] = project_dir

    result = subprocess.run(
        [_PYTHON, "-m", "runtime.cli"] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        data = {"_raw_stdout": result.stdout, "_raw_stderr": result.stderr}
    return result.returncode, data


def _db_row(db_path: Path, agent_id: str) -> dict | None:
    """Direct read of agent_markers bypassing ensure_schema."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT * FROM agent_markers WHERE agent_id = ?", (agent_id,)
        ).fetchone()
        return dict(row) if row is not None else None
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test 1: compound-stage marker survives a second ensure_schema call
# ---------------------------------------------------------------------------


def test_compound_stage_marker_survives_ensure_schema(tmp_path: Path) -> None:
    """Seat guardian:land via agent-start; trigger ensure_schema via get-active.

    Pre-fix: the get-active invocation calls ensure_schema() which wipes the
    guardian:land row (hardcoded whitelist).
    Post-fix: guardian:land is in _MARKER_ACTIVE_ROLES and survives.

    This test FAILS on the pre-fix tree (confirmed via stash-and-rerun).
    """
    db_path = tmp_path / "test.db"
    agent_id = "gs1-f4-test-agent-land-001"
    project_root = str(tmp_path / "project")

    # Step 1: seat the marker (first CLI invocation → ensure_schema run 1)
    rc, data = _run_cli(
        ["dispatch", "agent-start", "guardian:land", agent_id,
         "--project-root", project_root, "--workflow-id", "wf-gs1-f4"],
        db_path=db_path,
    )
    assert rc == 0, f"agent-start failed: {data}"

    # Confirm row exists and is_active=1 after write (before second schema call)
    row_before = _db_row(db_path, agent_id)
    assert row_before is not None, "agent-start wrote no row"
    assert row_before["is_active"] == 1, (
        f"Expected is_active=1 immediately after agent-start, got {row_before}"
    )

    # Step 2: trigger a second ensure_schema() call via get-active
    # (This is the invocation that wiped the row pre-fix)
    rc2, data2 = _run_cli(
        ["marker", "get-active", "--project-root", project_root,
         "--workflow-id", "wf-gs1-f4"],
        db_path=db_path,
        project_dir=project_root,
    )
    assert rc2 == 0, f"get-active failed: {data2}"

    # Post-fix assertions — marker get-active returns flat JSON directly.
    # Response keys: found, role, agent_id, is_active, status, started_at, ...
    assert data2.get("found") is True, (
        f"Expected found=true after fix; got {data2}. "
        "This test fails on pre-fix tree (guardian:land wiped by ensure_schema cleanup)."
    )
    assert data2.get("role") == "guardian:land", (
        f"Expected role=guardian:land, got: {data2}"
    )
    assert data2.get("agent_id") == agent_id, (
        f"agent_id mismatch: {data2}"
    )
    assert data2.get("is_active") == 1, (
        f"Expected is_active=1: {data2}"
    )


# ---------------------------------------------------------------------------
# Test 2: context role resolves guardian:land after a second ensure_schema call
# ---------------------------------------------------------------------------


def test_context_role_resolves_guardian_land_after_subagent_start(tmp_path: Path) -> None:
    """context role must return guardian:land, not empty, after the fix.

    Pre-fix: second ensure_schema wipes the row → build_context() returns
    empty role. Post-fix: row survives → role resolves to guardian:land.

    This test FAILS on the pre-fix tree.

    Implementation note: project_root must be a real git repo directory so that
    detect_project_root() (called by build_context inside context role) resolves
    it to itself and the scoped get_active() query matches the stored project_root.
    We use _REPO_ROOT (the actual worktree) for this purpose.
    """
    db_path = tmp_path / "test.db"
    agent_id = "gs1-f4-test-agent-context-001"
    # Use repo root so detect_project_root() returns the same path that's stored
    project_root = str(_REPO_ROOT)

    # Seat the marker (first CLI invocation → ensure_schema run 1)
    rc, _ = _run_cli(
        ["dispatch", "agent-start", "guardian:land", agent_id,
         "--project-root", project_root, "--workflow-id", "wf-gs1-f4-ctx"],
        db_path=db_path,
    )
    assert rc == 0

    # Call context role — triggers ensure_schema() again on _get_conn()
    # Pre-fix: the cleanup wipes guardian:land → build_context returns empty role
    # Post-fix: row survives → resolves to guardian:land
    rc2, data2 = _run_cli(
        ["context", "role"],
        db_path=db_path,
        project_dir=project_root,
    )
    assert rc2 == 0, f"context role failed: {data2}"
    # context role returns flat JSON: {role, agent_id, workflow_id, status}
    assert data2.get("role") == "guardian:land", (
        f"Expected role=guardian:land, got {data2.get('role')!r}. "
        "This test fails on pre-fix tree (guardian:land wiped by ensure_schema cleanup)."
    )
    assert data2.get("agent_id") == agent_id, (
        f"agent_id mismatch: expected {agent_id!r}, got {data2.get('agent_id')!r}"
    )


# ---------------------------------------------------------------------------
# Test 3: stale reviewer marker does not hijack guardian:land resolution
# ---------------------------------------------------------------------------


def test_stale_reviewer_marker_does_not_hijack_guardian_land(tmp_path: Path) -> None:
    """GS1-F-1 invariant under the fix: reviewer stale marker must not win.

    Seed a stale reviewer marker (older started_at), then seat a fresh
    guardian:land marker. context role must resolve to guardian:land.

    Implementation note: project_root must be a real git repo directory so that
    detect_project_root() resolves to the same path stored in agent_markers.
    We use _REPO_ROOT (the actual worktree) for this purpose.
    """
    db_path = tmp_path / "test.db"
    # Use repo root so detect_project_root() returns the same path that's stored
    project_root = str(_REPO_ROOT)

    # Seed stale reviewer marker directly (bypasses ensure_schema to simulate
    # a marker that was written earlier and is still is_active=1)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        # Use the raw markers module to write a scoped reviewer marker
        markers.set_active(
            conn, "stale-reviewer-001", "reviewer",
            project_root=project_root, workflow_id="wf-gs1-f4-hijack"
        )
        conn.commit()
    finally:
        conn.close()

    # Sleep >1s to ensure guardian:land has a strictly later epoch-second
    # started_at than the reviewer (get_active orders by started_at DESC)
    time.sleep(1.1)

    # Seat guardian:land via CLI (second DB open → second ensure_schema)
    agent_id = "gs1-f4-guardian-land-fresh"
    rc, _ = _run_cli(
        ["dispatch", "agent-start", "guardian:land", agent_id,
         "--project-root", project_root, "--workflow-id", "wf-gs1-f4-hijack"],
        db_path=db_path,
    )
    assert rc == 0

    # GS1-F-4 primary invariant: guardian:land marker must survive ensure_schema
    # (Pre-fix: this row would be wiped by the cleanup UPDATE in the next CLI call)
    row_after_start = _db_row(db_path, agent_id)
    assert row_after_start is not None and row_after_start["is_active"] == 1, (
        f"guardian:land marker not written or deactivated immediately: {row_after_start}"
    )

    # Resolve context role (third DB open → third ensure_schema)
    rc2, data2 = _run_cli(
        ["context", "role"],
        db_path=db_path,
        project_dir=project_root,
    )
    assert rc2 == 0

    # GS1-F-4 secondary assertion: guardian:land still active after cleanup
    row_after_context = _db_row(db_path, agent_id)
    assert row_after_context is not None and row_after_context["is_active"] == 1, (
        f"guardian:land marker was wiped by ensure_schema cleanup in context role call. "
        f"GS1-F-4 fix regression: {row_after_context}"
    )

    # context role returns flat JSON: {role, agent_id, workflow_id, status}
    # With guardian:land started strictly later than reviewer, it wins get_active
    assert data2.get("role") == "guardian:land", (
        f"reviewer marker hijacked guardian:land: got role={data2.get('role')!r}. "
        f"DB state: guardian:land={row_after_context}"
    )
    assert data2.get("agent_id") == agent_id


# ---------------------------------------------------------------------------
# Test 4: guardian:provision marker also survives ensure_schema cleanup
# ---------------------------------------------------------------------------


def test_guardian_provision_marker_also_survives(tmp_path: Path) -> None:
    """Sister-stage coverage: guardian:provision must survive cleanup.

    Mirrors test 1 for the provision compound stage.
    """
    db_path = tmp_path / "test.db"
    agent_id = "gs1-f4-test-agent-provision-001"
    project_root = str(tmp_path / "project")

    rc, _ = _run_cli(
        ["dispatch", "agent-start", "guardian:provision", agent_id,
         "--project-root", project_root, "--workflow-id", "wf-gs1-f4-prov"],
        db_path=db_path,
    )
    assert rc == 0

    # Trigger ensure_schema again
    rc2, data2 = _run_cli(
        ["marker", "get-active", "--project-root", project_root,
         "--workflow-id", "wf-gs1-f4-prov"],
        db_path=db_path,
        project_dir=project_root,
    )
    assert rc2 == 0
    # marker get-active returns flat JSON: {found, role, agent_id, is_active, ...}
    assert data2.get("found") is True, (
        f"guardian:provision marker wiped by ensure_schema cleanup: {data2}"
    )
    assert data2.get("role") == "guardian:provision"
    assert data2.get("agent_id") == agent_id


# ---------------------------------------------------------------------------
# Test 5: non-dispatch role markers ARE cleaned up (DEC-CONV-002 still holds)
# ---------------------------------------------------------------------------


def test_lightweight_role_marker_still_cleaned() -> None:
    """DEC-CONV-002 invariant: 'Bash' and other non-dispatch roles get wiped.

    Writes a marker with role='Bash' directly to an in-memory DB, then
    calls ensure_schema() a second time to trigger the cleanup. The row
    must be deactivated.
    """
    conn = connect_memory()
    ensure_schema(conn)

    # Write a non-dispatch role marker directly (bypasses shell filter)
    conn.execute(
        "INSERT INTO agent_markers (agent_id, role, started_at, is_active, status) "
        "VALUES (?, ?, ?, 1, 'active')",
        ("bash-ghost-001", "Bash", int(time.time())),
    )
    conn.commit()

    # Confirm it is active before second ensure_schema call
    row_before = conn.execute(
        "SELECT is_active FROM agent_markers WHERE agent_id = 'bash-ghost-001'"
    ).fetchone()
    assert row_before["is_active"] == 1

    # Second ensure_schema call triggers cleanup UPDATE
    ensure_schema(conn)

    row_after = conn.execute(
        "SELECT is_active, status FROM agent_markers WHERE agent_id = 'bash-ghost-001'"
    ).fetchone()
    assert row_after is not None
    assert row_after["is_active"] == 0, (
        "Bash ghost marker was NOT deactivated by ensure_schema cleanup — "
        "DEC-CONV-002 cleanup is broken."
    )
    assert row_after["status"] == "stopped"
    conn.close()


# ---------------------------------------------------------------------------
# Test 6: cleanup whitelist derives from ACTIVE_STAGES (authority-sync invariant)
# ---------------------------------------------------------------------------


def test_cleanup_whitelist_derives_from_active_stages() -> None:
    """Every ACTIVE_STAGES member survives a cleanup round-trip.

    This is the mechanical-difficulty guard per CLAUDE.md 'Architecture
    Preservation': if a future stage is added to ACTIVE_STAGES but the
    whitelist is not updated, this test fails immediately.

    This test exercises the fix introduced by DEC-CONV-002-AMEND-001 — it
    would have caught the pre-fix bug directly.
    """
    # Verify _MARKER_ACTIVE_ROLES is a superset of ACTIVE_STAGES
    missing = frozenset(ACTIVE_STAGES) - _MARKER_ACTIVE_ROLES
    assert not missing, (
        f"ACTIVE_STAGES members not in _MARKER_ACTIVE_ROLES: {missing}. "
        "These roles would be wiped by ensure_schema cleanup — add them to "
        "_MARKER_ACTIVE_ROLES or derive it from ACTIVE_STAGES (DEC-CONV-002-AMEND-001)."
    )

    # Round-trip test: seat each ACTIVE_STAGES role, run ensure_schema, check it survived
    conn = connect_memory()
    ensure_schema(conn)

    now = int(time.time())
    for i, stage in enumerate(sorted(ACTIVE_STAGES)):
        agent_id = f"authority-sync-test-{i:03d}"
        conn.execute(
            "INSERT INTO agent_markers (agent_id, role, started_at, is_active, status) "
            "VALUES (?, ?, ?, 1, 'active')",
            (agent_id, stage, now + i),
        )
    conn.commit()

    # Trigger cleanup
    ensure_schema(conn)

    for i, stage in enumerate(sorted(ACTIVE_STAGES)):
        agent_id = f"authority-sync-test-{i:03d}"
        row = conn.execute(
            "SELECT is_active FROM agent_markers WHERE agent_id = ?", (agent_id,)
        ).fetchone()
        assert row is not None
        assert row["is_active"] == 1, (
            f"Stage {stage!r} (ACTIVE_STAGES member) was deactivated by ensure_schema cleanup. "
            "This means _MARKER_ACTIVE_ROLES is missing this stage. "
            "Fix: ensure _MARKER_ACTIVE_ROLES derives from ACTIVE_STAGES (DEC-CONV-002-AMEND-001)."
        )

    conn.close()

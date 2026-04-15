"""Tests for runtime/core/lifecycle.py

@decision DEC-LIFECYCLE-001
Title: lifecycle.py owns agent start/stop marker transitions
Status: accepted
Rationale: Marker activation and deactivation is a distinct concern from dispatch
  routing. Separating it into lifecycle.py makes both modules independently testable
  and avoids conflating routing logic with agent identity tracking.

@decision DEC-LIFECYCLE-002
Title: CLI dispatch agent-start/agent-stop are the hook-reachable lifecycle entry points
Status: accepted
Rationale: subagent-start.sh and check-*.sh previously called rt_marker_set and
  rt_marker_deactivate through runtime-bridge.sh, which resolves the runtime via
  CLAUDE_RUNTIME_ROOT=$HOME/.claude/runtime. In worktrees (before merge), this path
  points to the installed runtime, not the worktree's runtime — so new subcommands
  added in a feature branch are unreachable. The fix: hooks that call lifecycle
  commands resolve the CLI via $(dirname "$0")/../runtime/cli.py (relative to the
  hook file) so they always reach the in-worktree runtime. The shell-boundary tests
  in this file verify that path by invoking the CLI as a subprocess.

@decision DEC-LIFECYCLE-003
Title: on_stop_by_role / lifecycle on-stop is the single authority for role-matched deactivation
Status: accepted
Rationale: SubagentStop hooks run in a different process from SubagentStart so they
  cannot use the original agent_id. They must query the active marker, match its role
  to the stopping agent_type, and deactivate by the stored agent_id. Duplicating this
  pattern in four check-*.sh hooks creates four places to get it wrong. Centralising
  in on_stop_by_role (called via `cc-policy lifecycle on-stop <agent_type>`) gives
  one implementation, one test surface, and one authority.
"""

import json
import os
import sqlite3
import subprocess
import sys

import pytest

from runtime.core import markers
from runtime.core.lifecycle import on_agent_start, on_agent_stop, on_stop_by_role
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Helpers for CLI subprocess tests
# ---------------------------------------------------------------------------

_PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_CLI = os.path.join(_PROJECT_ROOT, "runtime", "cli.py")


def _cc(*args, db_path, stdin_text=None):
    """Invoke cli.py with the given args; return (returncode, parsed_json)."""
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": _PROJECT_ROOT}
    result = subprocess.run(
        [sys.executable, _CLI, *args],
        input=stdin_text,
        capture_output=True,
        text=True,
        env=env,
    )
    try:
        return result.returncode, json.loads(result.stdout)
    except json.JSONDecodeError:
        return result.returncode, {"_raw": result.stdout, "_err": result.stderr}


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# on_agent_start
# ---------------------------------------------------------------------------


def test_on_agent_start_sets_marker_active(conn):
    on_agent_start(conn, "reviewer", "agent-abc")
    marker = markers.get_active(conn)
    assert marker is not None
    assert marker["agent_id"] == "agent-abc"
    assert marker["role"] == "reviewer"
    assert marker["is_active"] == 1


def test_on_agent_start_implementer(conn):
    on_agent_start(conn, "implementer", "agent-impl-001")
    marker = markers.get_active(conn)
    assert marker["role"] == "implementer"


def test_on_agent_start_overwrites_previous_marker(conn):
    """Second start for same agent_id replaces existing marker."""
    on_agent_start(conn, "implementer", "agent-001")
    on_agent_start(conn, "reviewer", "agent-001")
    marker = markers.get_active(conn)
    assert marker["role"] == "reviewer"
    assert marker["agent_id"] == "agent-001"


# ---------------------------------------------------------------------------
# on_agent_stop
# ---------------------------------------------------------------------------


def test_on_agent_stop_deactivates_marker(conn):
    on_agent_start(conn, "reviewer", "agent-xyz")
    on_agent_stop(conn, "reviewer", "agent-xyz")
    marker = markers.get_active(conn)
    assert marker is None


def test_on_agent_stop_noop_when_no_marker(conn):
    """Deactivating a non-existent marker should not raise."""
    on_agent_stop(conn, "reviewer", "agent-nonexistent")
    # No exception = pass


def test_on_agent_stop_does_not_affect_other_markers(conn):
    """Stopping agent-A should not deactivate agent-B."""
    on_agent_start(conn, "implementer", "agent-A")
    on_agent_start(conn, "reviewer", "agent-B")
    on_agent_stop(conn, "implementer", "agent-A")
    # agent-B (most recently started) should still be active
    marker = markers.get_active(conn)
    assert marker is not None
    assert marker["agent_id"] == "agent-B"


# ---------------------------------------------------------------------------
# Round-trip: start then stop
# ---------------------------------------------------------------------------


def test_start_stop_roundtrip(conn):
    on_agent_start(conn, "guardian", "agent-guardian-001")
    active_before = markers.get_active(conn)
    assert active_before is not None

    on_agent_stop(conn, "guardian", "agent-guardian-001")
    active_after = markers.get_active(conn)
    assert active_after is None


# ---------------------------------------------------------------------------
# Shell-boundary tests: CLI subprocess path (DEC-LIFECYCLE-002)
#
# These tests verify that `dispatch agent-start` and `dispatch agent-stop`
# are reachable through the local CLI path ($(dirname "$0")/../runtime/cli.py)
# exactly as post-task.sh and subagent-start.sh will call it after the fix.
# They cross the boundary between shell resolution and the Python runtime so
# they serve as the compound-interaction proof required by the evaluation contract.
# ---------------------------------------------------------------------------


@pytest.fixture
def db_path(tmp_path):
    """Isolated SQLite DB path for CLI subprocess tests."""
    # Ensure schema exists before use
    db = str(tmp_path / "test.db")
    _cc("schema", "ensure", db_path=db)
    return db


def test_dispatch_agent_start_via_cli(db_path):
    """dispatch agent-start writes an active marker via the local CLI path."""
    rc, data = _cc("dispatch", "agent-start", "implementer", "agent-cli-001", db_path=db_path)
    assert rc == 0, f"non-zero exit: {data}"
    assert data.get("status") == "ok"
    assert data.get("agent_id") == "agent-cli-001"


def test_dispatch_agent_stop_via_cli(db_path):
    """dispatch agent-stop deactivates an active marker via the local CLI path."""
    _cc("dispatch", "agent-start", "reviewer", "agent-cli-002", db_path=db_path)
    rc, data = _cc("dispatch", "agent-stop", "reviewer", "agent-cli-002", db_path=db_path)
    assert rc == 0, f"non-zero exit: {data}"
    assert data.get("status") == "ok"
    assert data.get("agent_id") == "agent-cli-002"


def test_dispatch_agent_start_then_stop_marker_cleared(db_path):
    """Full round-trip: agent-start sets marker active; agent-stop clears it."""
    _cc("dispatch", "agent-start", "implementer", "agent-rt-001", db_path=db_path)

    # Verify marker is active via marker get-active
    rc_get, active = _cc("marker", "get-active", db_path=db_path)
    assert rc_get == 0
    assert active.get("found") is True
    assert active.get("role") == "implementer"

    _cc("dispatch", "agent-stop", "implementer", "agent-rt-001", db_path=db_path)

    rc_get2, after = _cc("marker", "get-active", db_path=db_path)
    assert rc_get2 == 0
    assert after.get("found") is False


def test_dispatch_process_stop_reachable_via_local_cli_path(db_path):
    """Compound-interaction test: dispatch process-stop is reachable through the
    local CLI path (not via cc_policy bridge) and returns hookSpecificOutput.

    This is the shell-boundary proof for Blocker 1: post-task.sh must resolve
    the runtime relative to its own location so worktree-local CLI changes are
    reachable. This test exercises that exact path by calling the CLI directly
    as a subprocess (the same mechanism post-task.sh uses after the fix).
    """
    # Phase 6 Slice 4: planner requires lease+completion. Use implementer
    # (fixed routing → reviewer) for the CLI reachability test.
    payload = json.dumps({"agent_type": "implementer", "project_root": ""})
    rc, data = _cc("dispatch", "process-stop", db_path=db_path, stdin_text=payload)
    assert rc == 0, f"non-zero exit: {data}"
    # Must contain hookSpecificOutput — this is the contract post-task.sh checks
    assert "hookSpecificOutput" in data, f"missing hookSpecificOutput in: {data}"
    hook_out = data["hookSpecificOutput"]
    assert hook_out.get("hookEventName") == "SubagentStop"
    # Phase 5: implementer routes to reviewer
    assert data.get("next_role") == "reviewer"


# ---------------------------------------------------------------------------
# on_stop_by_role unit tests (DEC-LIFECYCLE-003)
# ---------------------------------------------------------------------------


def test_on_stop_by_role_deactivates_matching_role(conn):
    """on_stop_by_role deactivates the active marker when role matches."""
    on_agent_start(conn, "reviewer", "agent-role-001")
    result = on_stop_by_role(conn, "reviewer")
    assert result["found"] is True
    assert result["deactivated"] is True
    assert result["agent_id"] == "agent-role-001"
    assert result["role"] == "reviewer"
    assert markers.get_active(conn) is None


def test_on_stop_by_role_noop_when_no_active_marker(conn):
    """on_stop_by_role returns found=False when no marker is active."""
    result = on_stop_by_role(conn, "implementer")
    assert result["found"] is False
    assert result["deactivated"] is False
    assert result["agent_id"] is None


def test_on_stop_by_role_noop_when_role_mismatch(conn):
    """on_stop_by_role does not deactivate when active role differs from agent_type."""
    on_agent_start(conn, "guardian", "agent-guard-001")
    result = on_stop_by_role(conn, "reviewer")  # wrong role
    assert result["found"] is False
    assert result["deactivated"] is False
    # guardian marker is still active
    active = markers.get_active(conn)
    assert active is not None
    assert active["agent_id"] == "agent-guard-001"


def test_on_stop_by_role_all_four_roles(conn):
    """on_stop_by_role works for every valid agent role."""
    for role in ("implementer", "reviewer", "guardian", "planner"):
        on_agent_start(conn, role, f"agent-{role}")
        result = on_stop_by_role(conn, role)
        assert result["found"] is True, f"role={role} should match"
        assert result["deactivated"] is True
        assert markers.get_active(conn) is None


# ---------------------------------------------------------------------------
# CLI lifecycle on-stop tests (DEC-LIFECYCLE-003 shell boundary)
#
# These cross the CLI subprocess boundary — the same path check-*.sh hooks
# take after the fix. They serve as the compound-interaction proof that the
# lifecycle on-stop command is reachable through the local CLI path.
# ---------------------------------------------------------------------------


def test_lifecycle_on_stop_via_cli_deactivates_marker(db_path):
    """lifecycle on-stop deactivates the matching active marker via CLI subprocess."""
    _cc("dispatch", "agent-start", "implementer", "agent-lc-001", db_path=db_path)

    rc, data = _cc("lifecycle", "on-stop", "implementer", db_path=db_path)
    assert rc == 0, f"non-zero exit: {data}"
    assert data.get("status") == "ok"
    assert data.get("found") is True
    assert data.get("deactivated") is True
    assert data.get("agent_id") == "agent-lc-001"

    # Confirm marker is gone
    rc2, active = _cc("marker", "get-active", db_path=db_path)
    assert rc2 == 0
    assert active.get("found") is False


def test_lifecycle_on_stop_via_cli_noop_when_no_marker(db_path):
    """lifecycle on-stop returns found=False when no active marker exists."""
    rc, data = _cc("lifecycle", "on-stop", "reviewer", db_path=db_path)
    assert rc == 0, f"non-zero exit: {data}"
    assert data.get("found") is False
    assert data.get("deactivated") is False


def test_lifecycle_on_stop_via_cli_noop_role_mismatch(db_path):
    """lifecycle on-stop does not deactivate a marker with a different role."""
    _cc("dispatch", "agent-start", "guardian", "agent-lc-guard", db_path=db_path)

    rc, data = _cc("lifecycle", "on-stop", "reviewer", db_path=db_path)
    assert rc == 0, f"non-zero exit: {data}"
    assert data.get("found") is False
    assert data.get("deactivated") is False

    # guardian marker is still active
    rc2, active = _cc("marker", "get-active", db_path=db_path)
    assert active.get("found") is True
    assert active.get("role") == "guardian"


# ---------------------------------------------------------------------------
# Scoped marker lookup tests (DEC-LIFECYCLE-004 / ENFORCE-RCA-6-ext / #26)
#
# These verify that on_stop_by_role respects project_root and workflow_id
# scoping so that stopping an agent in project A does not silently deactivate
# an unrelated active marker in project B. Before the scoping fix, the
# globally-newest active marker was used unconditionally, enabling cross-
# project contamination and orphan-marker poisoning of role detection.
# ---------------------------------------------------------------------------


def test_on_stop_by_role_scoped_to_project_root(conn):
    """Deactivation scoped by project_root targets only the caller's project.

    Regression guard for ENFORCE-RCA-6-ext / #26: before this fix, a newer
    active marker from project B could be deactivated when the caller in
    project A called on_stop_by_role, OR the caller's own older marker
    could be missed because the globally-newest belonged to project B.
    """
    # Start two tester markers in two different projects
    markers.set_active(conn, "agent-A", "reviewer", project_root="/repo/A", workflow_id=None)
    markers.set_active(conn, "agent-B", "reviewer", project_root="/repo/B", workflow_id=None)

    # Stop tester in project A only — must leave B's marker intact
    result = on_stop_by_role(conn, "reviewer", project_root="/repo/A")
    assert result["found"] is True
    assert result["deactivated"] is True
    assert result["agent_id"] == "agent-A"

    # Project B's marker should still be active
    active_b = markers.get_active(conn, project_root="/repo/B")
    assert active_b is not None
    assert active_b["agent_id"] == "agent-B"


def test_on_stop_by_role_scoped_ignores_stale_other_project(conn):
    """When caller's project has no active marker, scoped lookup returns found=False.

    Even if a GLOBALLY-newer active marker exists in another project, the
    scoped query must not return it. Before the fix, the unscoped query
    would return the foreign marker and either deactivate it (wrong) or
    fail the role match and appear as a no-op (also wrong — masks the real
    state).
    """
    # Active marker exists only in project B, not A
    markers.set_active(
        conn, "agent-B-only", "implementer", project_root="/repo/B", workflow_id=None
    )

    # Call scoped to project A — should NOT find the B marker
    result = on_stop_by_role(conn, "implementer", project_root="/repo/A")
    assert result["found"] is False
    assert result["deactivated"] is False

    # B's marker is still active
    active_b = markers.get_active(conn, project_root="/repo/B")
    assert active_b is not None


def test_on_stop_by_role_scoped_with_workflow_id(conn):
    """project_root + workflow_id narrow the scope further within a project."""
    markers.set_active(conn, "agent-wf1", "reviewer", project_root="/repo/A", workflow_id="wf-001")
    markers.set_active(conn, "agent-wf2", "reviewer", project_root="/repo/A", workflow_id="wf-002")

    # Stop only wf-001 in project A — wf-002 must survive
    result = on_stop_by_role(conn, "reviewer", project_root="/repo/A", workflow_id="wf-001")
    assert result["found"] is True
    assert result["agent_id"] == "agent-wf1"

    # wf-002 still active
    active_wf2 = markers.get_active(conn, project_root="/repo/A", workflow_id="wf-002")
    assert active_wf2 is not None
    assert active_wf2["agent_id"] == "agent-wf2"


def test_on_stop_by_role_unscoped_backward_compat(conn):
    """When called with no scoping (legacy path), behaviour is unchanged.

    statusline.py and other context-less callers continue to pass no scoping
    args; the old global behaviour must be preserved for backward compat.
    """
    on_agent_start(conn, "guardian", "agent-legacy")
    # Legacy unscoped call — must still work
    result = on_stop_by_role(conn, "guardian")
    assert result["found"] is True
    assert result["deactivated"] is True
    assert result["agent_id"] == "agent-legacy"


def test_cli_marker_get_active_scoped(db_path):
    """CLI `marker get-active --project-root` scopes the query correctly.

    Shell-boundary test: rt_marker_get_active_role in runtime-bridge.sh
    passes --project-root through to this CLI subcommand. If the CLI
    ignores the flag, the shell-side scoping is silently broken.
    """
    # Start two markers in different projects via CLI
    _cc("marker", "set", "agent-X", "implementer", "--project-root", "/proj/X", db_path=db_path)
    _cc("marker", "set", "agent-Y", "implementer", "--project-root", "/proj/Y", db_path=db_path)

    # Scoped query for X must return agent-X
    rc, data = _cc("marker", "get-active", "--project-root", "/proj/X", db_path=db_path)
    assert rc == 0
    assert data.get("found") is True
    assert data.get("agent_id") == "agent-X"

    # Scoped query for Y must return agent-Y
    rc2, data2 = _cc("marker", "get-active", "--project-root", "/proj/Y", db_path=db_path)
    assert rc2 == 0
    assert data2.get("found") is True
    assert data2.get("agent_id") == "agent-Y"


def test_cli_lifecycle_on_stop_scoped(db_path):
    """CLI `lifecycle on-stop --project-root` deactivates only the caller's marker."""
    # Two active implementers in different projects
    _cc("marker", "set", "agent-P", "implementer", "--project-root", "/proj/P", db_path=db_path)
    _cc("marker", "set", "agent-Q", "implementer", "--project-root", "/proj/Q", db_path=db_path)

    # Stop only in P
    rc, data = _cc(
        "lifecycle", "on-stop", "implementer", "--project-root", "/proj/P", db_path=db_path
    )
    assert rc == 0
    assert data.get("deactivated") is True
    assert data.get("agent_id") == "agent-P"

    # Q is still active
    rc2, q_data = _cc("marker", "get-active", "--project-root", "/proj/Q", db_path=db_path)
    assert rc2 == 0
    assert q_data.get("found") is True
    assert q_data.get("agent_id") == "agent-Q"

    # P is gone
    rc3, p_data = _cc("marker", "get-active", "--project-root", "/proj/P", db_path=db_path)
    assert rc3 == 0
    assert p_data.get("found") is False


def test_lifecycle_on_stop_compound_check_hook_sequence(db_path):
    """Compound-interaction test: full SubagentStop hook sequence.

    Exercises the exact production sequence a check-*.sh hook runs:
      1. SubagentStart writes marker via dispatch agent-start
      2. SubagentStop hook calls lifecycle on-stop <role>
      3. Marker is gone; a second lifecycle on-stop is a no-op

    This is the end-to-end proof that the lifecycle on-stop command
    replaces the bash-side query-and-decide pattern in all four hooks.
    """
    # Step 1: start marker (as subagent-start.sh would)
    _cc("dispatch", "agent-start", "reviewer", "agent-compound-001", db_path=db_path)

    # Confirm active
    _, active_before = _cc("marker", "get-active", db_path=db_path)
    assert active_before.get("found") is True
    assert active_before.get("role") == "reviewer"

    # Step 2: the reviewer stop adapter calls lifecycle on-stop (the new single authority)
    rc, stop_result = _cc("lifecycle", "on-stop", "reviewer", db_path=db_path)
    assert rc == 0
    assert stop_result.get("deactivated") is True

    # Step 3: marker is cleared
    _, active_after = _cc("marker", "get-active", db_path=db_path)
    assert active_after.get("found") is False

    # Step 4: idempotent — second call is a no-op, not an error
    rc2, second = _cc("lifecycle", "on-stop", "reviewer", db_path=db_path)
    assert rc2 == 0
    assert second.get("found") is False
    assert second.get("deactivated") is False

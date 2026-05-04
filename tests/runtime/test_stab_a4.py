"""Tests for TKT-STAB-A4: stale state auto-cleanup + test status migration.

Covers:
  1. markers.expire_stale — marks old active markers as 'expired'
  2. cli.py marker expire-stale subcommand — wires expire_stale into the CLI
  3. cli.py test-state get subcommand — reads SQLite and ignores flat-files
  4. Compound interaction: expire_stale transitions, then get_active returns None

@decision DEC-STAB-A4-001
Title: markers.expire_stale and test-state SQLite CLI bridge
Status: accepted
Rationale: TKT-STAB-A4 removes flat-file .test-status reads from guard.sh,
  subagent-start.sh, and check-guardian.sh. Instead those hooks call
  `python3 -m runtime.cli test-state get` which reads SQLite and returns
  structured JSON. This keeps the read surface uniform (all runtime reads go
  through the CLI). markers.expire_stale() TTL-based cleanup ensures
  stale active markers do not accumulate across crashed sessions.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
_PROJECT_ROOT = _HERE.parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

import runtime.core.markers as markers  # noqa: E402
from runtime.core.db import connect_memory  # noqa: E402
from runtime.schemas import ensure_schema  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def test_status_dir(tmp_path):
    """Temp dir with a .claude subdir for .test-status files."""
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()
    return tmp_path


# ---------------------------------------------------------------------------
# 1. markers.expire_stale
# ---------------------------------------------------------------------------


def test_expire_stale_no_active_markers(conn):
    """expire_stale returns 0 when no markers exist."""
    count = markers.expire_stale(conn)
    assert count == 0


def test_expire_stale_recent_marker_untouched(conn):
    """expire_stale leaves markers younger than TTL alone."""
    now = int(time.time())
    markers.set_active(conn, "agent-1", "implementer")
    count = markers.expire_stale(conn, ttl=7200, now=now + 100)
    assert count == 0
    assert markers.get_active(conn) is not None


def test_expire_stale_old_marker_expired(conn):
    """expire_stale transitions old active markers to status='expired'."""
    now = int(time.time())
    markers.set_active(conn, "agent-1", "implementer")
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'agent-1'",
        (now - 10800,),
    )
    conn.commit()

    count = markers.expire_stale(conn, ttl=7200, now=now)
    assert count == 1
    assert markers.get_active(conn) is None


def test_expire_stale_skips_inactive_markers(conn):
    """expire_stale does not re-expire already-deactivated markers."""
    now = int(time.time())
    markers.set_active(conn, "agent-1", "implementer")
    markers.deactivate(conn, "agent-1")
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'agent-1'",
        (now - 10800,),
    )
    conn.commit()

    count = markers.expire_stale(conn, ttl=7200, now=now)
    assert count == 0


def test_expire_stale_mixed_age_only_old_expired(conn):
    """expire_stale only expires markers that exceed TTL."""
    now = int(time.time())
    markers.set_active(conn, "agent-old", "implementer")
    markers.set_active(conn, "agent-new", "reviewer")
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'agent-old'",
        (now - 14400,),
    )
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'agent-new'",
        (now - 60,),
    )
    conn.commit()

    count = markers.expire_stale(conn, ttl=7200, now=now)
    assert count == 1

    active = markers.get_active(conn)
    assert active is not None
    assert active["agent_id"] == "agent-new"


def test_expire_stale_sets_expired_status(conn):
    """Expired markers show status='expired' in list_all."""
    now = int(time.time())
    markers.set_active(conn, "agent-1", "implementer")
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'agent-1'",
        (now - 10800,),
    )
    conn.commit()

    markers.expire_stale(conn, ttl=7200, now=now)

    rows = markers.list_all(conn)
    assert len(rows) == 1
    assert rows[0]["status"] == "expired"
    assert rows[0]["is_active"] == 0


# ---------------------------------------------------------------------------
# 2. CLI: marker expire-stale
# ---------------------------------------------------------------------------


def _run_cli(*args, cwd=None):
    """Run python3 -m runtime.cli <args>, return (returncode, stdout, stderr)."""
    result = subprocess.run(
        [sys.executable, "-m", "runtime.cli"] + list(args),
        capture_output=True,
        text=True,
        cwd=str(cwd or _PROJECT_ROOT),
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def test_cli_marker_expire_stale_returns_ok():
    """CLI marker expire-stale exits 0 and returns JSON with expired_count."""
    rc, stdout, stderr = _run_cli("marker", "expire-stale")
    assert rc == 0, f"Expected exit 0, got {rc}. stderr={stderr}"
    data = json.loads(stdout)
    assert data.get("status") == "ok"
    assert "expired_count" in data


# ---------------------------------------------------------------------------
# 3. CLI: test-state get/set (WS3: SQLite authority — flat-file bridge retired)
# ---------------------------------------------------------------------------
# These tests were rewritten for WS3. The old bridge read .claude/.test-status;
# the new implementation reads/writes the SQLite test_state table exclusively.
# test_status_dir fixture kept for backward compat with fixture name; tests now
# use it as a project_root dir and point at an isolated SQLite DB via env var.


def _run_cli_with_db(*args, tmp_path):
    """Run CLI with an isolated SQLite DB to avoid touching the project state.db."""
    import os

    db_path = tmp_path / "state.db"
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(db_path)
    result = subprocess.run(
        [sys.executable, "-m", "runtime.cli"] + list(args),
        capture_output=True,
        text=True,
        cwd=str(_PROJECT_ROOT),
        env=env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def test_cli_test_state_get_no_record(test_status_dir):
    """test-state get returns found=false when no SQLite row exists (WS3)."""
    rc, stdout, stderr = _run_cli_with_db(
        "test-state",
        "get",
        "--project-root",
        str(test_status_dir),
        tmp_path=test_status_dir,
    )
    assert rc == 0, f"Expected exit 0, got {rc}. stderr={stderr}"
    data = json.loads(stdout)
    assert data.get("found") is False
    assert data.get("status") == "unknown"


def test_cli_test_state_get_pass(test_status_dir):
    """test-state set then get returns status=pass from SQLite (WS3)."""
    # First write via set
    rc0, _, err0 = _run_cli_with_db(
        "test-state",
        "set",
        "pass",
        "--project-root",
        str(test_status_dir),
        tmp_path=test_status_dir,
    )
    assert rc0 == 0, f"set failed: {err0}"

    rc, stdout, stderr = _run_cli_with_db(
        "test-state",
        "get",
        "--project-root",
        str(test_status_dir),
        tmp_path=test_status_dir,
    )
    assert rc == 0, f"Expected exit 0, got {rc}. stderr={stderr}"
    data = json.loads(stdout)
    assert data.get("found") is True
    assert data.get("status") == "pass"
    assert data.get("fail_count") == 0


def test_cli_test_state_get_fail(test_status_dir):
    """test-state set fail then get returns status=fail from SQLite (WS3)."""
    rc0, _, err0 = _run_cli_with_db(
        "test-state",
        "set",
        "fail",
        "--project-root",
        str(test_status_dir),
        "--failed",
        "3",
        tmp_path=test_status_dir,
    )
    assert rc0 == 0, f"set failed: {err0}"

    rc, stdout, stderr = _run_cli_with_db(
        "test-state",
        "get",
        "--project-root",
        str(test_status_dir),
        tmp_path=test_status_dir,
    )
    assert rc == 0, f"Expected exit 0, got {rc}. stderr={stderr}"
    data = json.loads(stdout)
    assert data.get("found") is True
    assert data.get("status") == "fail"
    assert data.get("fail_count") == 3


def test_cli_test_state_flat_file_not_read(test_status_dir):
    """test-state get ignores .claude/.test-status flat file (WS3: bridge retired).

    Even with a flat-file present, get returns found=False when no SQLite row exists.
    """
    claude_dir = test_status_dir / ".claude"
    claude_dir.mkdir(exist_ok=True)
    (claude_dir / ".test-status").write_text(f"pass|0|{int(time.time())}\n")

    rc, stdout, _ = _run_cli_with_db(
        "test-state",
        "get",
        "--project-root",
        str(test_status_dir),
        tmp_path=test_status_dir,
    )
    assert rc == 0
    data = json.loads(stdout)
    assert data.get("found") is False, (
        "WS3: test-state get must read SQLite only; flat-file must be ignored"
    )


# ---------------------------------------------------------------------------
# 4. Compound interaction: expire_stale → get_active production sequence
# ---------------------------------------------------------------------------


def test_compound_crash_recovery_sequence(conn):
    """Production sequence: marker set at spawn, session crash, expire_stale, get_active=None.

    Mirrors the real flow:
      1. subagent-start.sh sets marker at spawn (rt_marker_set).
      2. Session crashes — deactivate never called.
      3. Next session: session-init.sh calls marker expire-stale.
      4. guard.sh calls rt_lease_expire_stale before Check 3.
      5. get_active() returns None — no ghost markers blocking new dispatch.
    """
    now = int(time.time())

    # Step 1: spawn-time marker set
    markers.set_active(conn, "agent-crashed", "implementer")

    # Step 2: crash — backdate 3 hours (TTL is 2h default)
    conn.execute(
        "UPDATE agent_markers SET started_at = ? WHERE agent_id = 'agent-crashed'",
        (now - 10800,),
    )
    conn.commit()

    # Confirm marker IS active before cleanup
    assert markers.get_active(conn) is not None

    # Step 3: session-init cleanup via expire_stale
    expired = markers.expire_stale(conn, ttl=7200, now=now)
    assert expired == 1

    # Step 4: get_active returns None — no ghost markers remain
    assert markers.get_active(conn) is None

    # Step 5: new marker set succeeds cleanly
    markers.set_active(conn, "agent-new", "reviewer")
    active = markers.get_active(conn)
    assert active is not None
    assert active["agent_id"] == "agent-new"

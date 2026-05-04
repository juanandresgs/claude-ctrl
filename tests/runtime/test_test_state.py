"""Unit tests for runtime.core.test_state and WS3 CLI integration.

Covers:
  1. test_state module: set_status, get_status, check_pass
  2. CLI: cc-policy test-state get reads from SQLite (not flat-file)
  3. CLI: cc-policy test-state set writes to SQLite
  4. Compound interaction: test-runner writes → guard.sh reads → enforcement

Production sequence exercised in compound test:
  test-runner.sh calls rt_test_state_set →
  stores in SQLite →
  guard.sh calls rt_test_state_get →
  reads from SQLite →
  status enforced before commit

@decision DEC-WS3-001
Title: test_state SQLite module replaces flat-file bridge
Status: accepted
Rationale: WS3 migrates test state from .claude/.test-status flat-file reads
  to a SQLite-backed test_state table. The CLI bridge in _handle_test_state
  is replaced with a real set/get backed by runtime.core.test_state. Hooks
  that previously called python3 -m runtime.cli test-state get now call
  rt_test_state_get from runtime-bridge.sh, which wraps cc-policy test-state get.
  Runtime hooks no longer write or read the retired flat-file; tests may create
  one only to prove it is ignored.
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

import runtime.core.test_state as ts_mod  # noqa: E402

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


# ---------------------------------------------------------------------------
# 1. test_state module: set_status / get_status / check_pass
# ---------------------------------------------------------------------------


def test_get_status_missing_returns_not_found(conn):
    """get_status returns found=False when no row exists for project_root."""
    result = ts_mod.get_status(conn, "/nonexistent/project")
    assert result["found"] is False
    assert result["status"] == "unknown"


def test_set_and_get_round_trip(conn):
    """set_status then get_status returns the stored values."""
    ts_mod.set_status(
        conn, "/proj/a", "pass", head_sha="abc123", pass_count=10, fail_count=0, total_count=10
    )
    result = ts_mod.get_status(conn, "/proj/a")
    assert result["found"] is True
    assert result["status"] == "pass"
    assert result["head_sha"] == "abc123"
    assert result["pass_count"] == 10
    assert result["fail_count"] == 0
    assert result["total_count"] == 10
    assert result["updated_at"] > 0


def test_set_status_upsert_updates(conn):
    """set_status upserts — second call overwrites first for same project_root."""
    ts_mod.set_status(conn, "/proj/a", "fail", fail_count=3, total_count=10)
    ts_mod.set_status(conn, "/proj/a", "pass", pass_count=10, total_count=10)
    result = ts_mod.get_status(conn, "/proj/a")
    assert result["status"] == "pass"
    assert result["fail_count"] == 0


def test_set_status_multiple_projects_isolated(conn):
    """Different project_roots are stored independently."""
    ts_mod.set_status(conn, "/proj/a", "pass")
    ts_mod.set_status(conn, "/proj/b", "fail", fail_count=2)
    a = ts_mod.get_status(conn, "/proj/a")
    b = ts_mod.get_status(conn, "/proj/b")
    assert a["status"] == "pass"
    assert b["status"] == "fail"
    assert b["fail_count"] == 2


def test_check_pass_true_when_status_pass(conn):
    """check_pass returns True for status='pass'."""
    ts_mod.set_status(conn, "/proj/a", "pass")
    assert ts_mod.check_pass(conn, "/proj/a") is True


def test_check_pass_true_when_status_pass_complete(conn):
    """check_pass returns True for status='pass_complete'."""
    ts_mod.set_status(conn, "/proj/a", "pass_complete")
    assert ts_mod.check_pass(conn, "/proj/a") is True


def test_check_pass_false_when_status_fail(conn):
    """check_pass returns False for status='fail'."""
    ts_mod.set_status(conn, "/proj/a", "fail", fail_count=1)
    assert ts_mod.check_pass(conn, "/proj/a") is False


def test_check_pass_false_when_not_found(conn):
    """check_pass returns False when no row exists."""
    assert ts_mod.check_pass(conn, "/nonexistent") is False


def test_check_pass_with_matching_head_sha(conn):
    """check_pass with head_sha returns True only when sha matches."""
    ts_mod.set_status(conn, "/proj/a", "pass", head_sha="abc123")
    assert ts_mod.check_pass(conn, "/proj/a", head_sha="abc123") is True
    assert ts_mod.check_pass(conn, "/proj/a", head_sha="wrongsha") is False


def test_check_pass_no_sha_skips_sha_check(conn):
    """check_pass without head_sha skips SHA validation."""
    ts_mod.set_status(conn, "/proj/a", "pass", head_sha="abc123")
    assert ts_mod.check_pass(conn, "/proj/a") is True


def test_set_status_without_head_sha(conn):
    """set_status works without head_sha; head_sha stored as None."""
    ts_mod.set_status(conn, "/proj/a", "pass")
    result = ts_mod.get_status(conn, "/proj/a")
    assert result["found"] is True
    assert result["head_sha"] is None


# ---------------------------------------------------------------------------
# 2. CLI: test-state get reads from SQLite
# ---------------------------------------------------------------------------


def _run_cli(*args, cwd=None, env=None):
    """Run python3 -m runtime.cli <args>, return (returncode, stdout, stderr)."""
    import os

    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    result = subprocess.run(
        [sys.executable, "-m", "runtime.cli"] + list(args),
        capture_output=True,
        text=True,
        cwd=str(cwd or _PROJECT_ROOT),
        env=run_env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def test_cli_test_state_get_no_record(tmp_path):
    """test-state get returns found=false when no SQLite row exists."""
    db_path = tmp_path / "state.db"
    rc, stdout, stderr = _run_cli(
        "test-state",
        "get",
        "--project-root",
        str(tmp_path),
        env={"CLAUDE_POLICY_DB": str(db_path)},
    )
    assert rc == 0, f"Expected exit 0, got {rc}. stderr={stderr}"
    data = json.loads(stdout)
    assert data.get("found") is False
    assert data.get("status") == "unknown"


def test_cli_test_state_set_then_get(tmp_path):
    """test-state set writes to SQLite; test-state get reads it back."""
    db_path = tmp_path / "state.db"
    env = {"CLAUDE_POLICY_DB": str(db_path)}

    # Set pass state
    rc, stdout, stderr = _run_cli(
        "test-state",
        "set",
        "pass",
        "--project-root",
        str(tmp_path),
        "--passed",
        "12",
        "--total",
        "12",
        env=env,
    )
    assert rc == 0, f"set failed: {stderr}"

    # Get it back
    rc2, stdout2, stderr2 = _run_cli(
        "test-state",
        "get",
        "--project-root",
        str(tmp_path),
        env=env,
    )
    assert rc2 == 0, f"get failed: {stderr2}"
    data = json.loads(stdout2)
    assert data.get("found") is True
    assert data.get("status") == "pass"
    assert data.get("pass_count") == 12
    assert data.get("total_count") == 12


def test_cli_test_state_set_fail_then_get(tmp_path):
    """test-state set with fail status; get returns fail + fail_count."""
    db_path = tmp_path / "state.db"
    env = {"CLAUDE_POLICY_DB": str(db_path)}

    rc, _, stderr = _run_cli(
        "test-state",
        "set",
        "fail",
        "--project-root",
        str(tmp_path),
        "--failed",
        "3",
        "--total",
        "10",
        env=env,
    )
    assert rc == 0, f"set failed: {stderr}"

    rc2, stdout2, _ = _run_cli(
        "test-state",
        "get",
        "--project-root",
        str(tmp_path),
        env=env,
    )
    data = json.loads(stdout2)
    assert data.get("status") == "fail"
    assert data.get("fail_count") == 3
    assert data.get("total_count") == 10


def test_cli_test_state_does_not_read_flat_file(tmp_path):
    """test-state get ignores .claude/.test-status flat file.

    Even if the flat file has a 'pass' entry, get returns found=False
    when no SQLite row exists — proving the flat-file bridge is gone.
    """
    db_path = tmp_path / "state.db"
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()
    # Write a flat-file that previously would have been read
    (claude_dir / ".test-status").write_text(f"pass|0|{int(time.time())}\n")

    rc, stdout, _ = _run_cli(
        "test-state",
        "get",
        "--project-root",
        str(tmp_path),
        env={"CLAUDE_POLICY_DB": str(db_path)},
    )
    assert rc == 0
    data = json.loads(stdout)
    # Must NOT return found=True from flat file — only SQLite counts
    assert data.get("found") is False, (
        "test-state get must read SQLite, not the flat-file .test-status"
    )


# ---------------------------------------------------------------------------
# 3. Compound interaction: production sequence end-to-end
# ---------------------------------------------------------------------------


def test_compound_test_runner_to_guard_production_sequence(tmp_path):
    """Production sequence: test-runner writes → guard reads → status enforced.

    Mirrors the real flow:
      1. test-runner.sh finishes; calls rt_test_state_set (→ cc-policy test-state set)
      2. guard.sh Check 8/9: calls rt_test_state_get (→ cc-policy test-state get)
      3. Returns status from SQLite — not from flat-file
      4. check_pass() returns True only when status is 'pass' or 'pass_complete'

    This exercises multiple internal components:
      cli.py → test_state.set_status → SQLite → test_state.get_status → check_pass
    """
    db_path = tmp_path / "state.db"
    env = {"CLAUDE_POLICY_DB": str(db_path)}
    project_root = str(tmp_path)

    # Step 1: Simulate test-runner writing fail state
    rc, _, stderr = _run_cli(
        "test-state",
        "set",
        "fail",
        "--project-root",
        project_root,
        "--failed",
        "5",
        "--total",
        "20",
        "--head-sha",
        "deadbeef",
        env=env,
    )
    assert rc == 0, f"Step 1 failed: {stderr}"

    # Step 2: Simulate guard.sh reading (fail → should deny)
    rc2, stdout2, _ = _run_cli(
        "test-state",
        "get",
        "--project-root",
        project_root,
        env=env,
    )
    data = json.loads(stdout2)
    assert data["found"] is True
    assert data["status"] == "fail"
    assert data["fail_count"] == 5

    # Step 3: Simulate test-runner writing pass state after fix
    rc3, _, stderr3 = _run_cli(
        "test-state",
        "set",
        "pass",
        "--project-root",
        project_root,
        "--passed",
        "20",
        "--total",
        "20",
        "--head-sha",
        "cafebabe",
        env=env,
    )
    assert rc3 == 0, f"Step 3 failed: {stderr3}"

    # Step 4: Guard reads again — now pass
    rc4, stdout4, _ = _run_cli(
        "test-state",
        "get",
        "--project-root",
        project_root,
        env=env,
    )
    data4 = json.loads(stdout4)
    assert data4["found"] is True
    assert data4["status"] == "pass"
    assert data4["head_sha"] == "cafebabe"

    # Step 5: Domain check_pass confirms pass
    from runtime.core.db import connect

    conn = connect(db_path)
    ensure_schema(conn)
    assert ts_mod.check_pass(conn, project_root) is True
    assert ts_mod.check_pass(conn, project_root, head_sha="cafebabe") is True
    assert ts_mod.check_pass(conn, project_root, head_sha="wrongsha") is False
    conn.close()

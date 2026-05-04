"""Test-state runtime authority.

Owns the test_state table. All mutations are in explicit transactions.
Status values are open strings (pass, fail, pass_complete, unknown) —
enforced by callers, not by SQL CHECK, so error messages stay human-readable.

@decision DEC-WS3-001
Title: test_state SQLite module replaces flat-file bridge
Status: accepted
Rationale: WS3 retires the .claude/.test-status flat-file as a READ authority.
  guard.sh Checks 8/9, subagent-start.sh, and check-guardian.sh previously
  called `python3 -m runtime.cli test-state get` which read the flat-file.
  That bridge is replaced here: test_state is the canonical runtime table
  for test results. Runtime hooks no longer write or read the retired
  flat-file; session cleanup only removes stale historical copies. The single
  source of truth is this module backed by SQLite.

  The module follows the same interface pattern as runtime.core.proof and
  runtime.core.evaluation: conn is passed in by the caller (cli.py) so
  the module is independently testable without subprocess overhead.

@decision DEC-CONV-001
Title: normalize_path() applied at every test_state persist/query boundary
Status: accepted
Rationale: test_state rows are keyed by project_root string equality. On macOS
  the same directory may be referenced as /tmp/x (symlink) or /private/tmp/x
  (realpath). Without normalization a row written with one form is invisible
  when queried with the other. Applying normalize_path() to project_root in
  set_status, get_status, and check_pass guarantees all rows share the same
  canonical key regardless of how the caller obtained the path.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.core.policy_utils import normalize_path

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def set_status(
    conn: sqlite3.Connection,
    project_root: str,
    status: str,
    head_sha: Optional[str] = None,
    pass_count: int = 0,
    fail_count: int = 0,
    total_count: int = 0,
) -> None:
    """Upsert test state for project_root.

    project_root is the unique key (one row per project). Subsequent calls
    overwrite all fields so callers never accumulate history here — that is
    the responsibility of the audit trail (events table).

    project_root is normalized via normalize_path() (DEC-CONV-001) before
    being stored so all rows use the canonical realpath form.

    No status validation: test-runner.sh may emit any status string; callers
    that care about validity (check_pass) use explicit comparisons.
    """
    canonical_root = normalize_path(project_root)
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO test_state
                (project_root, head_sha, status, pass_count, fail_count, total_count, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_root) DO UPDATE SET
                head_sha    = excluded.head_sha,
                status      = excluded.status,
                pass_count  = excluded.pass_count,
                fail_count  = excluded.fail_count,
                total_count = excluded.total_count,
                updated_at  = excluded.updated_at
            """,
            (canonical_root, head_sha, status, pass_count, fail_count, total_count, now),
        )


def get_status(conn: sqlite3.Connection, project_root: str) -> dict:
    """Return test state for project_root as a dict.

    Always returns a dict with at minimum:
      found (bool), status (str), head_sha (str|None),
      pass_count (int), fail_count (int), total_count (int), updated_at (int)

    Returns found=False with safe defaults when no row exists — callers
    can check `result["found"]` without branching on None.

    project_root is normalized via normalize_path() (DEC-CONV-001) before
    querying so the lookup key always matches the stored canonical form.
    """
    canonical_root = normalize_path(project_root)
    row = conn.execute(
        """
        SELECT project_root, head_sha, status, pass_count, fail_count, total_count, updated_at
        FROM test_state
        WHERE project_root = ?
        """,
        (canonical_root,),
    ).fetchone()

    if row is None:
        return {
            "found": False,
            "status": "unknown",
            "head_sha": None,
            "pass_count": 0,
            "fail_count": 0,
            "total_count": 0,
            "updated_at": 0,
        }

    return {
        "found": True,
        "status": row["status"],
        "head_sha": row["head_sha"],
        "pass_count": row["pass_count"],
        "fail_count": row["fail_count"],
        "total_count": row["total_count"],
        "updated_at": row["updated_at"],
    }


def check_pass(
    conn: sqlite3.Connection,
    project_root: str,
    head_sha: Optional[str] = None,
) -> bool:
    """Return True only when tests are passing for project_root.

    Passing means status is 'pass' or 'pass_complete'. If head_sha is
    provided, the stored sha must also match — this prevents a stale
    clearance from satisfying the gate after new commits.

    Returns False when no row exists (safe-fail: absence of evidence is
    not evidence of passing).

    project_root normalization is delegated to get_status() (DEC-CONV-001).
    """
    state = get_status(conn, project_root)
    if not state["found"]:
        return False
    if state["status"] not in ("pass", "pass_complete"):
        return False
    if head_sha is not None and state["head_sha"] != head_sha:
        return False
    return True

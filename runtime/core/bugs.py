"""Canonical bug-filing pipeline.

Provides durable, deduplicated bug tracking backed by:
  - SQLite `bugs` table as the local canonical authority
  - GitHub Issues via todo.sh as the durable external authority

This module is THE single entry point for recording bugs discovered during
hook execution, test runs, or evaluator reviews. It ensures:
  1. Every bug gets a deterministic fingerprint (dedup key)
  2. Every filing attempt is persisted in SQLite regardless of GitHub success
  3. Failed filings are retryable via retry_failed()
  4. Every disposition emits an audit event via events.emit()

@decision DEC-BUGS-001
Title: SQLite-first bug filing with external GitHub fallback
Status: accepted
Rationale: Bugs discovered at hook time must be durable even when the GitHub
  CLI is unavailable (network down, auth expired, rate-limited). By writing
  to SQLite first and treating GitHub Issues as the secondary authority,
  we guarantee zero data loss. The fingerprint dedup key prevents duplicate
  issues across worktrees, fresh projects, and test isolation — a key failure
  mode of the prior direct-todo.sh-add approach in hooks/lint.sh.
  todo.sh is invoked via subprocess with a configurable path so tests can
  inject a stub without patching subprocess globally.

@decision DEC-BUGS-002
Title: file_bug() never raises; always returns a result dict
Status: accepted
Rationale: file_bug() is called from hook scripts that run inside Claude's
  execution loop. A raised exception would terminate the hook unexpectedly
  and produce confusing output. All error paths are caught internally and
  returned as disposition='failed_to_file' or 'rejected_non_bug'. Callers
  check the disposition key, not exception state.
"""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Optional

import runtime.core.events as events


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Allowed bug_type values — anything outside this set is rejected as non-bug.
ALLOWED_BUG_TYPES: frozenset[str] = frozenset(
    {
        "enforcement_gap",
        "test_failure",
        "crash",
        "regression",
        "silent_failure",
        "config_error",
        "integration_bug",
        "state_corruption",
    }
)

#: Dispositions that represent "already handled" — skip re-filing.
_FILED_DISPOSITIONS: frozenset[str] = frozenset({"filed", "duplicate"})

#: Default todo.sh location.
_DEFAULT_TODO_SH = str(Path.home() / ".claude" / "scripts" / "todo.sh")


# ---------------------------------------------------------------------------
# fingerprint()
# ---------------------------------------------------------------------------


def fingerprint(bug_type: str, source_component: str, title: str) -> str:
    """Compute a stable 16-char hex fingerprint for a bug.

    Normalization removes volatile content so the same logical bug produces
    the same fingerprint across encounters:
      - lowercase everything
      - strip epoch timestamps (10-digit sequences)
      - strip absolute file paths, keeping only the basename
      - strip standalone numbers (counts, line numbers, exit codes)
      - collapse whitespace

    The fingerprint is the first 16 hex chars of the SHA-256 of
    ``f"{bug_type}:{source_component}:{normalized_title}"``.

    Args:
        bug_type:         The bug category string (e.g. ``"crash"``).
        source_component: The component that generated the bug (e.g. ``"hooks/lint.sh"``).
        title:            The human-readable bug title.

    Returns:
        16-character lowercase hex string.
    """
    normalized = title.lower()

    # Strip absolute paths, keeping basename only
    # Matches /path/to/file.ext patterns
    normalized = re.sub(r"/[^\s]+/([^\s/]+)", r"\1", normalized)

    # Strip epoch timestamps (9-13 digit numbers to catch past/future epochs)
    normalized = re.sub(r"\b\d{9,13}\b", "", normalized)

    # Strip remaining standalone numbers (counts, exit codes, line numbers)
    normalized = re.sub(r"\b\d+\b", "", normalized)

    # Collapse whitespace
    normalized = " ".join(normalized.split())

    raw = f"{bug_type}:{source_component}:{normalized}"
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    return digest[:16]


# ---------------------------------------------------------------------------
# qualify()
# ---------------------------------------------------------------------------


def qualify(
    bug_type: str,
    title: str,
    evidence: str,
    fixed_now: bool = False,
) -> str:
    """Determine whether a bug should be filed.

    Args:
        bug_type:  The bug category. Must be in ALLOWED_BUG_TYPES.
        title:     Human-readable bug title. Must be non-empty.
        evidence:  Supporting evidence text. Must be non-empty.
        fixed_now: If True, return ``"fixed_now"`` immediately (skip filing).

    Returns:
        One of:
          - ``"filed"``           — proceed to file_bug()
          - ``"fixed_now"``       — bug was self-healed; skip filing
          - ``"rejected_non_bug"``— invalid type, empty title, or empty evidence
    """
    if fixed_now:
        return "fixed_now"
    if not title or not title.strip():
        return "rejected_non_bug"
    if not evidence or not evidence.strip():
        return "rejected_non_bug"
    if bug_type not in ALLOWED_BUG_TYPES:
        return "rejected_non_bug"
    return "filed"


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _resolve_todo_sh(todo_sh_path: Optional[str]) -> Optional[str]:
    """Return a usable todo.sh path, or None if unavailable."""
    path = todo_sh_path or os.environ.get("CLAUDE_TODO_SH") or _DEFAULT_TODO_SH
    if path and os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    return None


def _invoke_todo_sh(todo_sh: str, title: str, body: str, scope: str) -> Optional[str]:
    """Call todo.sh add and return the issue URL from stdout, or None on failure.

    Args:
        todo_sh: Absolute path to the executable todo.sh script.
        title:   Issue title (fingerprint appended to body, not title).
        body:    Issue body text.
        scope:   ``"global"`` or ``"project"`` — maps to --global flag.

    Returns:
        Issue URL string if creation succeeded, None on any failure.
    """
    cmd = [todo_sh, "add"]
    if scope == "global":
        cmd.append("--global")
    cmd.append(title)
    if body:
        cmd.append(f"--body={body}")

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            return None
        # todo.sh add prints the issue URL on stdout (may have trailing newline)
        url = (result.stdout or "").strip()
        return url if url else None
    except Exception:
        return None


def _upsert_bug(
    conn: sqlite3.Connection,
    *,
    fp: str,
    bug_type: str,
    title: str,
    body: str,
    scope: str,
    source_component: str,
    file_path: str,
    evidence: str,
    disposition: str,
    issue_number: Optional[int],
    issue_url: Optional[str],
    now: int,
) -> int:
    """Insert a new bug row or update the existing one.

    On INSERT conflict (same fingerprint), increments encounter_count and
    updates last_seen_at and disposition.

    Returns the encounter_count after the operation.
    """
    with conn:
        # Try insert first
        try:
            conn.execute(
                """
                INSERT INTO bugs
                    (fingerprint, bug_type, title, body, scope,
                     source_component, file_path, evidence,
                     disposition, issue_number, issue_url,
                     first_seen_at, last_seen_at, encounter_count)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1)
                """,
                (
                    fp,
                    bug_type,
                    title,
                    body or "",
                    scope,
                    source_component or "",
                    file_path or "",
                    evidence or "",
                    disposition,
                    issue_number,
                    issue_url,
                    now,
                    now,
                ),
            )
            return 1
        except sqlite3.IntegrityError:
            # Row already exists — update it
            conn.execute(
                """
                UPDATE bugs
                SET    disposition = ?,
                       issue_number = COALESCE(?, issue_number),
                       issue_url    = COALESCE(?, issue_url),
                       last_seen_at = ?,
                       encounter_count = encounter_count + 1
                WHERE  fingerprint = ?
                """,
                (disposition, issue_number, issue_url, now, fp),
            )
            row = conn.execute(
                "SELECT encounter_count FROM bugs WHERE fingerprint = ?", (fp,)
            ).fetchone()
            return row["encounter_count"] if row else 1


# ---------------------------------------------------------------------------
# get_by_fingerprint()
# ---------------------------------------------------------------------------


def get_by_fingerprint(conn: sqlite3.Connection, fp: str) -> Optional[dict]:
    """Return the bug row for the given fingerprint, or None if not found.

    Args:
        conn: Open SQLite connection with schema applied.
        fp:   16-char fingerprint string.

    Returns:
        Dict of all column values, or None.
    """
    row = conn.execute("SELECT * FROM bugs WHERE fingerprint = ?", (fp,)).fetchone()
    return dict(row) if row else None


# ---------------------------------------------------------------------------
# list_bugs()
# ---------------------------------------------------------------------------


def list_bugs(
    conn: sqlite3.Connection,
    disposition: Optional[str] = None,
    limit: int = 50,
) -> list[dict]:
    """Return tracked bugs, newest first.

    Args:
        conn:        Open SQLite connection with schema applied.
        disposition: If given, filter to only rows with this disposition value.
        limit:       Maximum rows to return (default 50).

    Returns:
        List of bug dicts, ordered by id DESC (newest first).
    """
    if disposition is not None:
        rows = conn.execute(
            "SELECT * FROM bugs WHERE disposition = ? ORDER BY id DESC LIMIT ?",
            (disposition, limit),
        ).fetchall()
    else:
        rows = conn.execute("SELECT * FROM bugs ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# file_bug() — the single entry point
# ---------------------------------------------------------------------------


def file_bug(
    conn: sqlite3.Connection,
    bug_type: str,
    title: str,
    body: str,
    scope: str,
    source_component: str,
    file_path: str,
    evidence: str,
    fixed_now: bool = False,
    todo_sh_path: Optional[str] = None,
) -> dict:
    """File a bug through the canonical pipeline.

    This is THE single entry point for bug filing. It never raises — all error
    paths return a result dict with an appropriate disposition.

    Pipeline steps:
      1. qualify() — gate on type, title, evidence, fixed_now
      2. fingerprint() — compute dedup key
      3. SQLite lookup — check for existing row
         - found + filed/duplicate → return duplicate, increment count
         - found + failed_to_file → retry filing (continue to step 4)
         - not found → continue to step 4
      4. Invoke todo.sh add → parse issue URL
      5. Upsert SQLite row with disposition (filed | failed_to_file)
      6. Emit audit event
      7. Return result dict

    Args:
        conn:             Open SQLite connection with schema applied.
        bug_type:         Bug category (must be in ALLOWED_BUG_TYPES).
        title:            Human-readable title. Filed to GitHub Issues.
        body:             Extended description. Filed to GitHub Issues body.
        scope:            ``"global"`` or ``"project"``.
        source_component: Component that discovered the bug (e.g. ``"hooks/lint.sh"``).
        file_path:        Source file implicated (optional).
        evidence:         Supporting evidence text. Must be non-empty for filing.
        fixed_now:        If True, skip filing — bug was self-healed.
        todo_sh_path:     Override path to todo.sh executable (used in tests).

    Returns:
        Dict with keys: ``disposition``, ``fingerprint``, ``issue_url``,
        ``encounter_count``, and optionally ``error``.
    """
    try:
        return _file_bug_impl(
            conn=conn,
            bug_type=bug_type,
            title=title,
            body=body,
            scope=scope,
            source_component=source_component,
            file_path=file_path,
            evidence=evidence,
            fixed_now=fixed_now,
            todo_sh_path=todo_sh_path,
        )
    except Exception as exc:
        # DEC-BUGS-002: never raise; catch-all ensures hook callers are unaffected
        _emit_safe(conn, "bug_filing_failed", source_component, f"{title}: {exc}")
        return {
            "disposition": "failed_to_file",
            "fingerprint": "",
            "issue_url": None,
            "encounter_count": 0,
            "error": str(exc),
        }


def _file_bug_impl(
    conn: sqlite3.Connection,
    bug_type: str,
    title: str,
    body: str,
    scope: str,
    source_component: str,
    file_path: str,
    evidence: str,
    fixed_now: bool,
    todo_sh_path: Optional[str],
) -> dict:
    """Inner implementation — may raise; wrapped by file_bug()."""
    now = int(time.time())

    # Step 1: qualify
    disposition = qualify(bug_type, title, evidence, fixed_now=fixed_now)

    if disposition == "fixed_now":
        _emit_safe(conn, "bug_fixed_now", source_component, title)
        return {
            "disposition": "fixed_now",
            "fingerprint": "",
            "issue_url": None,
            "encounter_count": 0,
        }

    if disposition == "rejected_non_bug":
        _emit_safe(conn, "bug_rejected", source_component, title)
        return {
            "disposition": "rejected_non_bug",
            "fingerprint": "",
            "issue_url": None,
            "encounter_count": 0,
        }

    # Step 2: fingerprint
    fp = fingerprint(bug_type, source_component, title)

    # Step 3: SQLite lookup
    existing = get_by_fingerprint(conn, fp)
    if existing is not None:
        if existing["disposition"] in _FILED_DISPOSITIONS:
            # Duplicate — increment and return
            count = _upsert_bug(
                conn,
                fp=fp,
                bug_type=bug_type,
                title=title,
                body=body,
                scope=scope,
                source_component=source_component,
                file_path=file_path,
                evidence=evidence,
                disposition="duplicate",
                issue_number=existing.get("issue_number"),
                issue_url=existing.get("issue_url"),
                now=now,
            )
            _emit_safe(conn, "bug_duplicate", source_component, f"{fp}:{title}")
            return {
                "disposition": "duplicate",
                "fingerprint": fp,
                "issue_url": existing.get("issue_url"),
                "encounter_count": count,
            }
        # disposition == "failed_to_file" → fall through to retry filing

    # Step 4: invoke todo.sh
    todo_sh = _resolve_todo_sh(todo_sh_path)
    issue_url: Optional[str] = None
    final_disposition: str = "failed_to_file"

    if todo_sh:
        # Include fingerprint in body for GitHub-side dedup verification
        full_body = f"{body}\n\n[fingerprint:{fp}]" if body else f"[fingerprint:{fp}]"
        issue_url = _invoke_todo_sh(todo_sh, title, full_body, scope)

    if issue_url:
        final_disposition = "filed"
        # Parse issue number from URL (e.g. .../issues/42 → 42)
        m = re.search(r"/issues/(\d+)", issue_url)
        issue_number = int(m.group(1)) if m else None
    else:
        issue_number = None

    # Step 5: upsert SQLite
    count = _upsert_bug(
        conn,
        fp=fp,
        bug_type=bug_type,
        title=title,
        body=body,
        scope=scope,
        source_component=source_component,
        file_path=file_path,
        evidence=evidence,
        disposition=final_disposition,
        issue_number=issue_number,
        issue_url=issue_url,
        now=now,
    )

    # Step 6: emit audit event
    if final_disposition == "filed":
        _emit_safe(conn, "bug_filed", source_component, f"{fp}:{title}")
    else:
        _emit_safe(conn, "bug_filing_failed", source_component, f"{fp}:{title}")

    # Step 7: return
    return {
        "disposition": final_disposition,
        "fingerprint": fp,
        "issue_url": issue_url,
        "encounter_count": count,
    }


# ---------------------------------------------------------------------------
# retry_failed()
# ---------------------------------------------------------------------------


def retry_failed(
    conn: sqlite3.Connection,
    todo_sh_path: Optional[str] = None,
) -> list[dict]:
    """Retry all bugs with disposition='failed_to_file'.

    For each failed row, attempts to file via todo.sh. Updates disposition
    to 'filed' on success or leaves as 'failed_to_file' on continued failure.

    Args:
        conn:         Open SQLite connection with schema applied.
        todo_sh_path: Override path to todo.sh (used in tests).

    Returns:
        List of result dicts, one per retried row.
    """
    rows = conn.execute(
        "SELECT * FROM bugs WHERE disposition = 'failed_to_file' ORDER BY id"
    ).fetchall()

    results = []
    for row in rows:
        row_dict = dict(row)
        result = file_bug(
            conn,
            bug_type=row_dict["bug_type"],
            title=row_dict["title"],
            body=row_dict.get("body", ""),
            scope=row_dict.get("scope", "global"),
            source_component=row_dict.get("source_component", ""),
            file_path=row_dict.get("file_path", ""),
            evidence=row_dict.get("evidence", ""),
            todo_sh_path=todo_sh_path,
        )
        results.append(result)
    return results


# ---------------------------------------------------------------------------
# Internal emit helper (never raises)
# ---------------------------------------------------------------------------


def _emit_safe(
    conn: sqlite3.Connection,
    event_type: str,
    source: Optional[str],
    detail: Optional[str],
) -> None:
    """Emit an audit event, suppressing all errors.

    Wraps events.emit() so that a failed event write never surfaces to
    callers. Bug filing correctness must not depend on event write success.
    """
    try:
        events.emit(conn, event_type, source=source or None, detail=detail or None)
    except Exception:
        pass

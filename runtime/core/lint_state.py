# @decision DEC-LINT-STATE-DB-001 — linter cache and circuit breaker state live in SQLite
# Why: The linter hook previously wrote project-local ``.lint-cache-*`` and
# ``.lint-breaker-*`` files. Those files were operational state, not user
# artifacts, and created another authority beside state.db.
"""SQLite-backed linter hook state."""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.core.policy_utils import normalize_path

VALID_BREAKER_STATES: frozenset[str] = frozenset({"closed", "open", "half-open"})


def _now() -> int:
    return int(time.time())


def _normalise_project_root(project_root: str) -> str:
    value = str(project_root or "").strip()
    if not value:
        raise ValueError("project_root must be non-empty")
    return normalize_path(value)


def _normalise_ext(ext: str) -> str:
    value = str(ext or "").strip().lstrip(".").lower()
    if not value:
        raise ValueError("ext must be non-empty")
    return value


def cache_get(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    ext: str,
    config_mtime: int = 0,
) -> Optional[dict]:
    """Return a cached linter profile when it is fresh for config_mtime."""

    root = _normalise_project_root(project_root)
    suffix = _normalise_ext(ext)
    row = conn.execute(
        """
        SELECT project_root, ext, linter, config_mtime, updated_at
        FROM lint_profile_cache
        WHERE project_root = ? AND ext = ?
        """,
        (root, suffix),
    ).fetchone()
    if row is None:
        return None
    result = dict(row)
    result["fresh"] = int(result.get("config_mtime") or 0) >= int(config_mtime or 0)
    if not result["fresh"]:
        return None
    result["found"] = True
    return result


def cache_set(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    ext: str,
    linter: str,
    config_mtime: int = 0,
) -> dict:
    """Upsert the detected linter profile for an extension."""

    root = _normalise_project_root(project_root)
    suffix = _normalise_ext(ext)
    tool = str(linter or "").strip() or "none"
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO lint_profile_cache
                (project_root, ext, linter, config_mtime, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(project_root, ext) DO UPDATE SET
                linter = excluded.linter,
                config_mtime = excluded.config_mtime,
                updated_at = excluded.updated_at
            """,
            (root, suffix, tool, int(config_mtime or 0), now),
        )
    return {
        "found": True,
        "project_root": root,
        "ext": suffix,
        "linter": tool,
        "config_mtime": int(config_mtime or 0),
        "updated_at": now,
    }


def breaker_get(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    ext: str,
) -> Optional[dict]:
    """Return the current circuit breaker state for an extension."""

    root = _normalise_project_root(project_root)
    suffix = _normalise_ext(ext)
    row = conn.execute(
        """
        SELECT project_root, ext, state, failure_count, updated_at
        FROM lint_circuit_breakers
        WHERE project_root = ? AND ext = ?
        """,
        (root, suffix),
    ).fetchone()
    if row is None:
        return None
    result = dict(row)
    result["found"] = True
    return result


def breaker_set(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    ext: str,
    state: str,
    failure_count: int,
    updated_at: int | None = None,
) -> dict:
    """Upsert circuit breaker state."""

    root = _normalise_project_root(project_root)
    suffix = _normalise_ext(ext)
    status = str(state or "").strip()
    if status not in VALID_BREAKER_STATES:
        raise ValueError(f"invalid breaker state: {state!r}")
    count = max(0, int(failure_count or 0))
    ts = int(updated_at if updated_at is not None else _now())
    with conn:
        conn.execute(
            """
            INSERT INTO lint_circuit_breakers
                (project_root, ext, state, failure_count, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(project_root, ext) DO UPDATE SET
                state = excluded.state,
                failure_count = excluded.failure_count,
                updated_at = excluded.updated_at
            """,
            (root, suffix, status, count, ts),
        )
    return {
        "found": True,
        "project_root": root,
        "ext": suffix,
        "state": status,
        "failure_count": count,
        "updated_at": ts,
    }


def breaker_reset(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    ext: str,
) -> dict:
    return breaker_set(
        conn,
        project_root=project_root,
        ext=ext,
        state="closed",
        failure_count=0,
    )

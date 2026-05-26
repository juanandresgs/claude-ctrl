"""Policy engine enforcement config — single source of truth for toggles.

@decision DEC-CONFIG-AUTHORITY-001
Title: Policy engine is the canonical authority for enforcement toggles
Status: accepted
Rationale: Before this module, enforcement toggles were scattered across
  settings.json, the codex plugin's state.json, and various hardcoded
  defaults. The policy engine had no knowledge of plugin-side toggles.
  This module centralizes toggle storage in runtime/cc_state.db so that
  cc-policy is the sole authority. Plugin code (codex setup) becomes a
  thin shim that delegates to this module via cc-policy config set.

Scope precedence (lookup order):
  workflow=<id>  →  project=<root>  →  global  →  None

WHO gate: guardian remains the writer for enforcement-sensitive toggles.
  The sole exception is ``review_gate_regular_stop``: it is a user-facing
  session-end preference, so the orchestrator/user path (empty actor_role)
  may write it directly. This keeps the canonical authority in the runtime
  without forcing plugin setup through a guardian lease.

@decision DEC-V6-NO-HIDDEN-STOP-001
Title: Regular Stop review gate is explicit, not hidden default wiring
Status: accepted
Rationale: v6 review happens as first-order critic/reviewer stages, not as a
  hidden long-running regular Stop hook. The optional regular Stop preference
  remains in enforcement_config for explicit operator use, but its seeded
  default is false and the plugin manifest does not auto-wire a Stop hook.
  Dispatch/subagent safety review remains enabled through stage-machine gates.
"""

from __future__ import annotations

import sqlite3
from typing import Optional


class PermissionError(Exception):
    """Raised when a non-guardian actor attempts to set a config value.

    Named PermissionError (shadows the builtin in this module) so callers
    can catch it with a descriptive name. Import as
    ``from runtime.core.enforcement_config import PermissionError as ECPermissionError``
    to avoid shadowing the builtin in calling code.
    """


def get(
    conn: sqlite3.Connection,
    key: str,
    *,
    workflow_id: str = "",
    project_root: str = "",
) -> Optional[str]:
    """Look up a config value with scope precedence.

    Lookup order: workflow=<id> -> project=<root> -> global -> None

    Returns the most-specific value found, or None if no row exists for
    any scope. Callers must handle None explicitly — it means the key has
    never been written (not that the feature is disabled).
    """
    candidates: list[str] = []
    if workflow_id:
        candidates.append(f"workflow={workflow_id}")
    if project_root:
        candidates.append(f"project={project_root}")
    candidates.append("global")

    for scope in candidates:
        row = conn.execute(
            "SELECT value FROM enforcement_config WHERE scope=? AND key=? LIMIT 1",
            (scope, key),
        ).fetchone()
        if row:
            # Support both dict-style (sqlite3.Row) and tuple-style rows.
            return row["value"] if hasattr(row, "keys") else row[0]
    return None


def set_(
    conn: sqlite3.Connection,
    key: str,
    value: str,
    *,
    scope: str = "global",
    actor_role: Optional[str] = None,
) -> None:
    """Set a config value with the configured WHO gate.

    Guardian remains the writer for enforcement-sensitive keys. The sole
    exception is ``review_gate_regular_stop``, which may also be written by
    the orchestrator/user path (empty actor_role) because it is a user-facing
    regular-Stop preference.

    Uses UPSERT so re-setting an existing key updates updated_at atomically.
    """
    if key == "review_gate_regular_stop" and (actor_role is None or actor_role == ""):
        pass
    elif actor_role != "guardian":
        raise PermissionError(
            f"Only guardian role may set enforcement_config (got actor_role={actor_role!r})"
        )
    with conn:
        conn.execute(
            "INSERT INTO enforcement_config (scope, key, value, updated_at) "
            "VALUES (?, ?, ?, CAST(strftime('%s','now') AS INTEGER)) "
            "ON CONFLICT(scope, key) DO UPDATE SET "
            "value=excluded.value, updated_at=excluded.updated_at",
            (scope, key, value),
        )


def list_all(
    conn: sqlite3.Connection,
    scope: Optional[str] = None,
) -> list[dict]:
    """List config rows, optionally filtered by scope.

    Returns a list of dicts with keys: scope, key, value, updated_at.
    Results are ordered by scope then key for deterministic output.
    """
    if scope:
        rows = conn.execute(
            "SELECT scope, key, value, updated_at "
            "FROM enforcement_config WHERE scope=? ORDER BY key",
            (scope,),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT scope, key, value, updated_at FROM enforcement_config ORDER BY scope, key"
        ).fetchall()
    return [dict(r) for r in rows]

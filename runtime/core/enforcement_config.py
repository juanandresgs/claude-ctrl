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

WHO gate: write authority is resolved via ``authority_registry.capabilities_for()``
  and the ``CAN_SET_CONTROL_CONFIG`` capability. The authority registry
  (DEC-CLAUDEX-AUTHORITY-REGISTRY-001) declares planner as the sole stage
  carrying this capability — guardian stages (provision / land) do not carry it.
  The sole exception is ``review_gate_regular_stop``: it is the legacy explicit
  regular-Stop model review preference, so the orchestrator/user path (empty
  actor_role) may write it directly. The default live Stop chain uses
  deterministic ``hooks/stop-advisor.sh`` instead.

@decision DEC-REGULAR-STOP-REVIEW-001
Title: Legacy regular Stop model review gate toggled via enforcement_config, not state.json
Status: accepted
Rationale: The codex plugin's state.json previously held stopReviewGate as
  the sole authority for whether the regular-Stop review gate ran. Moving that
  toggle into enforcement_config makes the runtime the canonical authority with
  normal scope precedence semantics. DEC-STOP-ADVISOR-001 later removed broad
  model review from the default regular Stop path, so this key is now only a
  legacy explicit model-review preference. The plugin state.json is kept only
  as a compatibility mirror during the deprecation window.
"""

from __future__ import annotations

import sqlite3
from typing import Optional

from runtime.core.authority_registry import CAN_SET_CONTROL_CONFIG, capabilities_for


class PermissionError(Exception):
    """Raised when an actor without CAN_SET_CONTROL_CONFIG attempts to set a config value.

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

    Actors with CAN_SET_CONTROL_CONFIG may write enforcement-sensitive keys.
    The sole exception is ``review_gate_regular_stop``, which may also be
    written by the orchestrator/user path (empty actor_role) because it is a
    legacy regular-Stop preference.

    Uses UPSERT so re-setting an existing key updates updated_at atomically.
    """
    if key == "review_gate_regular_stop" and (actor_role is None or actor_role == ""):
        pass  # user-facing preference; orchestrator/user path exempt
    elif CAN_SET_CONTROL_CONFIG not in capabilities_for(actor_role or ""):
        raise PermissionError(
            f"Actor {actor_role!r} lacks {CAN_SET_CONTROL_CONFIG} capability "
            f"(required to write enforcement_config)"
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

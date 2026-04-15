"""ClauDEX canonical decision/work registry — first persistence substrate.

@decision DEC-CLAUDEX-DW-REGISTRY-001
Title: runtime/core/decision_work_registry.py is the sole canonical persistence surface for decisions and work items in the Phase 1 shadow kernel
Status: proposed (shadow-mode, Phase 1 constitutional kernel)
Rationale: CUTOVER_PLAN §Decision and Work Record Architecture (lines
  824-843) requires runtime-owned machine-readable records for
  decisions, work items, scope manifests, evaluation contracts,
  supersessions, authority changes, and landed-commit links. Until
  this slice landed, those records only existed as ad-hoc markdown
  ``@decision`` annotations and free-form MASTER_PLAN entries — a
  donor-era debt that the CUTOVER_PLAN calls out explicitly.

  This module delivers the **narrow first substrate** for the two
  primary entity kinds, decisions and work items. It intentionally
  does NOT attempt:

    * migration from markdown ``@decision`` annotations
      (deferred to a later slice with its own migration plan)
    * rendered projections (decision digest / master plan —
      the decision-digest projection is covered by the pure builder
      in ``runtime/core/decision_digest_projection.py`` as of Phase
      7 Slice 13; other projection families are still future work)
    * commit-trailer linkage (deferred to a Phase 4+ slice alongside
      guardian landing authority)
    * CLI mutations or broad CLI exposure. The only CLI surfaces
      that reach this registry are the read-only
      ``cc-policy decision digest`` adapter (Phase 7 Slice 14) and
      ``cc-policy decision digest-check`` adapter (Phase 7 Slice 15),
      both of which live in ``runtime/cli.py _handle_decision`` and
      import this module only at **function scope** via a
      ``mode=ro`` / ``mode=ro&immutable=1`` SQLite URI — never at
      module scope. Module-scope import from ``cli.py`` is banned
      and asserted by AST tests so the CLI module-load graph does
      not acquire a build-time dependency on the registry.
    * hook wiring (not imported by any live routing, policy, or
      hook module; only the function-scope CLI adapters above may
      reach it, and only for read-only projection rendering).

  What this slice DOES deliver:

    * Two SQLite tables in ``runtime/schemas.py`` (``decisions`` and
      ``work_items``) with the indexes the helpers below need.
    * Two frozen-dataclass record shapes (``DecisionRecord``,
      ``WorkItemRecord``) with constructor validation that rejects
      unknown statuses, empty required fields, non-positive versions,
      negative timestamps, and boolean-as-int confusion.
    * Round-trip insert / upsert / get / list helpers for both
      entities.
    * An atomic ``supersede_decision()`` helper that:
        1. refuses to supersede a nonexistent or already-superseded
           decision,
        2. inserts the new decision with ``supersedes`` set to the
           predecessor id, and
        3. updates the predecessor's ``status`` to ``superseded`` and
           its ``superseded_by`` to the new decision id, all in a
           single transaction.
    * A read-only ``supersession_chain()`` helper that walks the
      ``supersedes`` links backward to the origin decision.

  Shadow-only discipline:

    * **No live routing / policy / hook imports.** This module is
      not imported by ``dispatch_engine``, ``completions``,
      ``policy_engine``, or any hook — not at module scope, not at
      function scope. AST tests pin that invariant.
    * **CLI import only via the read-only projection adapter.**
      ``runtime/cli.py`` may reach this module exclusively through
      the ``_handle_decision`` function's function-scope import, used
      to serve ``cc-policy decision digest`` and
      ``cc-policy decision digest-check`` (both strictly read-only,
      ``mode=ro`` / ``mode=ro&immutable=1`` SQLite URI, no schema
      bootstrap, no writes). Module-scope import from ``cli.py`` is
      banned and asserted by
      ``test_cli_does_not_import_decision_work_registry_at_module_level``.
      No other CLI path (``dispatch``, ``eval``, ``shadow``,
      ``worktree``, ``leases``, ``work``, ``hook``, ``constitution``,
      ``prompt-pack``, …) is allowed to import this registry.
    * The module does not write anywhere outside the ``decisions``
      and ``work_items`` tables. It does not emit events, does not
      touch ``evaluation_state``, does not touch ``leases``, does
      not read ``settings`` / ``hooks`` / ``config``.
    * Status vocabularies are imported from ``runtime/schemas.py``
      (``DECISION_STATUSES``) and ``runtime/core/contracts.py``
      (``WORK_ITEM_STATUSES``) so the declared domain enums have a
      single source of truth per family.
"""

from __future__ import annotations

import dataclasses
import sqlite3
import time
from dataclasses import dataclass
from typing import List, Optional

from runtime.core.contracts import GOAL_STATUSES, WORK_ITEM_STATUSES
from runtime.schemas import DECISION_STATUSES

# Re-export for discoverability.
__all__ = [
    "DECISION_STATUSES",
    "GOAL_STATUSES",
    "WORK_ITEM_STATUSES",
    "DecisionRecord",
    "GoalRecord",
    "WorkItemRecord",
    "insert_decision",
    "upsert_decision",
    "get_decision",
    "list_decisions",
    "supersede_decision",
    "supersession_chain",
    "insert_goal",
    "upsert_goal",
    "get_goal",
    "list_goals",
    "insert_work_item",
    "upsert_work_item",
    "get_work_item",
    "list_work_items",
]


# ---------------------------------------------------------------------------
# Typed record shapes
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DecisionRecord:
    """A single canonical decision record.

    All required fields are enforced at construction time. Any write
    path that accepts caller-supplied dicts should convert them into
    this dataclass first so bad data cannot reach SQLite.

    Supersession model: a decision can carry a non-None ``supersedes``
    (the predecessor it replaces) and a non-None ``superseded_by``
    (the successor that replaced it). Both are strings naming another
    ``decision_id``. The ``supersede_decision`` helper maintains the
    invariant that these chains remain consistent.
    """

    decision_id: str
    title: str
    status: str
    rationale: str
    version: int
    author: str
    scope: str
    supersedes: Optional[str] = None
    superseded_by: Optional[str] = None
    created_at: int = 0
    updated_at: int = 0

    def __post_init__(self) -> None:
        _require_non_empty_str(self, "decision_id")
        _require_non_empty_str(self, "title")
        _require_non_empty_str(self, "rationale")
        _require_non_empty_str(self, "author")
        _require_non_empty_str(self, "scope")
        _require_optional_non_empty_str(self, "supersedes")
        _require_optional_non_empty_str(self, "superseded_by")
        if self.status not in DECISION_STATUSES:
            raise ValueError(
                f"unknown decision status {self.status!r}; "
                f"valid: {sorted(DECISION_STATUSES)}"
            )
        _require_positive_int(self, "version")
        _require_non_negative_int(self, "created_at")
        _require_non_negative_int(self, "updated_at")
        # Self-link sanity: a decision cannot supersede itself.
        if self.supersedes is not None and self.supersedes == self.decision_id:
            raise ValueError(
                f"decision {self.decision_id!r} cannot supersede itself"
            )
        if (
            self.superseded_by is not None
            and self.superseded_by == self.decision_id
        ):
            raise ValueError(
                f"decision {self.decision_id!r} cannot be superseded by itself"
            )


@dataclass(frozen=True)
class WorkItemRecord:
    """A single canonical work-item record.

    ``scope_json`` and ``evaluation_json`` are raw JSON strings — this
    slice does not couple the persistence layer to a specific typed
    serialization of ``ScopeManifest`` / ``EvaluationContract`` from
    ``runtime/core/contracts.py``. A later slice may add typed
    serializers once the contract shapes stabilise.
    """

    work_item_id: str
    goal_id: str
    title: str
    status: str
    version: int
    author: str
    scope_json: str = "{}"
    evaluation_json: str = "{}"
    head_sha: Optional[str] = None
    reviewer_round: int = 0
    created_at: int = 0
    updated_at: int = 0

    def __post_init__(self) -> None:
        _require_non_empty_str(self, "work_item_id")
        _require_non_empty_str(self, "goal_id")
        _require_non_empty_str(self, "title")
        _require_non_empty_str(self, "author")
        _require_optional_non_empty_str(self, "head_sha")
        if self.status not in WORK_ITEM_STATUSES:
            raise ValueError(
                f"unknown work-item status {self.status!r}; "
                f"valid: {sorted(WORK_ITEM_STATUSES)}"
            )
        _require_positive_int(self, "version")
        _require_non_negative_int(self, "reviewer_round")
        _require_non_negative_int(self, "created_at")
        _require_non_negative_int(self, "updated_at")
        # scope_json / evaluation_json must be strings — the helper
        # refuses dicts / bytes / None so a caller cannot accidentally
        # pass an unserialised payload.
        for attr in ("scope_json", "evaluation_json"):
            value = getattr(self, attr)
            if not isinstance(value, str):
                raise ValueError(
                    f"WorkItemRecord.{attr} must be a string; got "
                    f"{type(value).__name__}"
                )


@dataclass(frozen=True)
class GoalRecord:
    """A single canonical goal-contract record (shadow-only persistence).

    Mirrors :class:`runtime.core.contracts.GoalContract` field-for-field
    so a later prompt-pack workflow capture helper can resolve a
    ``goal_id`` directly into the typed contract the Phase 2 capstone
    helper :func:`runtime.core.prompt_pack.compile_prompt_pack_for_stage`
    already accepts. The four tuple-shaped contract fields
    (``continuation_rules``, ``stop_conditions``,
    ``escalation_boundaries``, ``user_decision_boundaries``) are
    persisted as JSON-encoded strings, mirroring the
    ``WorkItemRecord.scope_json`` / ``evaluation_json`` pattern. This
    slice does NOT couple persistence to a specific typed serializer
    — callers may shape their JSON freely as long as it parses; a
    later slice can introduce a typed encode / decode pair when the
    contract surface stabilises.

    Status validation runs against
    :data:`runtime.core.contracts.GOAL_STATUSES` so the persistence
    layer never accepts a value the contract layer would reject.
    """

    goal_id: str
    desired_end_state: str
    status: str
    autonomy_budget: int = 0
    continuation_rules_json: str = "[]"
    stop_conditions_json: str = "[]"
    escalation_boundaries_json: str = "[]"
    user_decision_boundaries_json: str = "[]"
    created_at: int = 0
    updated_at: int = 0

    def __post_init__(self) -> None:
        _require_non_empty_str(self, "goal_id")
        _require_non_empty_str(self, "desired_end_state")
        if self.status not in GOAL_STATUSES:
            raise ValueError(
                f"unknown goal status {self.status!r}; "
                f"valid: {sorted(GOAL_STATUSES)}"
            )
        _require_non_negative_int(self, "autonomy_budget")
        _require_non_negative_int(self, "created_at")
        _require_non_negative_int(self, "updated_at")
        # The four tuple-shaped contract fields are persisted as
        # JSON-encoded strings; the helper refuses dicts / lists /
        # bytes / None so a caller cannot accidentally pass an
        # unserialised payload through to SQLite.
        for attr in (
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ):
            value = getattr(self, attr)
            if not isinstance(value, str):
                raise ValueError(
                    f"GoalRecord.{attr} must be a string; got "
                    f"{type(value).__name__}"
                )


# ---------------------------------------------------------------------------
# Private validation helpers
# ---------------------------------------------------------------------------


def _require_non_empty_str(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if not isinstance(value, str) or not value:
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be a non-empty string; got {value!r}"
        )


def _require_optional_non_empty_str(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if value is None:
        return
    if not isinstance(value, str) or not value:
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be None or a non-empty string; "
            f"got {value!r}"
        )


def _require_positive_int(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be an int; got {type(value).__name__}"
        )
    if value < 1:
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be >= 1; got {value}"
        )


def _require_non_negative_int(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be an int; got {type(value).__name__}"
        )
    if value < 0:
        raise ValueError(
            f"{type(obj).__name__}.{attr} must be non-negative; got {value}"
        )


def _now() -> int:
    return int(time.time())


# ---------------------------------------------------------------------------
# Row conversion helpers
# ---------------------------------------------------------------------------


def _row_to_decision(row: sqlite3.Row) -> DecisionRecord:
    return DecisionRecord(
        decision_id=row["decision_id"],
        title=row["title"],
        status=row["status"],
        rationale=row["rationale"],
        version=int(row["version"]),
        author=row["author"],
        scope=row["scope"],
        supersedes=row["supersedes"],
        superseded_by=row["superseded_by"],
        created_at=int(row["created_at"]),
        updated_at=int(row["updated_at"]),
    )


def _row_to_work_item(row: sqlite3.Row) -> WorkItemRecord:
    return WorkItemRecord(
        work_item_id=row["work_item_id"],
        goal_id=row["goal_id"],
        title=row["title"],
        status=row["status"],
        version=int(row["version"]),
        author=row["author"],
        scope_json=row["scope_json"] or "{}",
        evaluation_json=row["evaluation_json"] or "{}",
        head_sha=row["head_sha"],
        reviewer_round=int(row["reviewer_round"]),
        created_at=int(row["created_at"]),
        updated_at=int(row["updated_at"]),
    )


def _row_to_goal(row: sqlite3.Row) -> GoalRecord:
    return GoalRecord(
        goal_id=row["goal_id"],
        desired_end_state=row["desired_end_state"],
        status=row["status"],
        autonomy_budget=int(row["autonomy_budget"]),
        continuation_rules_json=row["continuation_rules_json"] or "[]",
        stop_conditions_json=row["stop_conditions_json"] or "[]",
        escalation_boundaries_json=row["escalation_boundaries_json"] or "[]",
        user_decision_boundaries_json=row["user_decision_boundaries_json"] or "[]",
        created_at=int(row["created_at"]),
        updated_at=int(row["updated_at"]),
    )


_DECISION_COLUMNS = (
    "decision_id, title, status, rationale, version, author, scope, "
    "supersedes, superseded_by, created_at, updated_at"
)


_WORK_ITEM_COLUMNS = (
    "work_item_id, goal_id, title, status, version, author, "
    "scope_json, evaluation_json, head_sha, reviewer_round, "
    "created_at, updated_at"
)


_GOAL_COLUMNS = (
    "goal_id, desired_end_state, status, autonomy_budget, "
    "continuation_rules_json, stop_conditions_json, "
    "escalation_boundaries_json, user_decision_boundaries_json, "
    "created_at, updated_at"
)


# ---------------------------------------------------------------------------
# Decision helpers
# ---------------------------------------------------------------------------


def insert_decision(
    conn: sqlite3.Connection, record: DecisionRecord
) -> DecisionRecord:
    """Insert a new decision. Raises ``sqlite3.IntegrityError`` on id conflict.

    Returns the record with ``created_at`` / ``updated_at`` backfilled
    to the current wall clock when the caller passed ``0``.
    """
    now = _now()
    created = record.created_at or now
    updated = record.updated_at or now
    with conn:
        conn.execute(
            f"INSERT INTO decisions ({_DECISION_COLUMNS}) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                record.decision_id,
                record.title,
                record.status,
                record.rationale,
                record.version,
                record.author,
                record.scope,
                record.supersedes,
                record.superseded_by,
                created,
                updated,
            ),
        )
    return dataclasses.replace(record, created_at=created, updated_at=updated)


def upsert_decision(
    conn: sqlite3.Connection, record: DecisionRecord
) -> DecisionRecord:
    """Insert or update a decision by ``decision_id``.

    On update, every caller-supplied field overwrites the existing
    row, and ``updated_at`` is refreshed to the current wall clock
    (unless the caller passed a non-zero ``updated_at``).
    """
    now = _now()
    created = record.created_at or now
    updated = record.updated_at or now
    with conn:
        conn.execute(
            f"INSERT INTO decisions ({_DECISION_COLUMNS}) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(decision_id) DO UPDATE SET "
            "  title         = excluded.title, "
            "  status        = excluded.status, "
            "  rationale     = excluded.rationale, "
            "  version       = excluded.version, "
            "  author        = excluded.author, "
            "  scope         = excluded.scope, "
            "  supersedes    = excluded.supersedes, "
            "  superseded_by = excluded.superseded_by, "
            "  updated_at    = excluded.updated_at",
            (
                record.decision_id,
                record.title,
                record.status,
                record.rationale,
                record.version,
                record.author,
                record.scope,
                record.supersedes,
                record.superseded_by,
                created,
                updated,
            ),
        )
    return dataclasses.replace(record, created_at=created, updated_at=updated)


def get_decision(
    conn: sqlite3.Connection, decision_id: str
) -> Optional[DecisionRecord]:
    """Return the decision record for ``decision_id``, or ``None`` if absent."""
    row = conn.execute(
        f"SELECT {_DECISION_COLUMNS} FROM decisions WHERE decision_id = ?",
        (decision_id,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_decision(row)


def list_decisions(
    conn: sqlite3.Connection,
    *,
    status: Optional[str] = None,
    scope: Optional[str] = None,
) -> List[DecisionRecord]:
    """List decisions, optionally filtered by ``status`` and/or ``scope``.

    Results are ordered by ``created_at ASC, decision_id ASC`` so the
    return is deterministic for test assertions.
    """
    clauses: List[str] = []
    params: List[object] = []
    if status is not None:
        clauses.append("status = ?")
        params.append(status)
    if scope is not None:
        clauses.append("scope = ?")
        params.append(scope)
    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    rows = conn.execute(
        f"SELECT {_DECISION_COLUMNS} FROM decisions {where} "
        "ORDER BY created_at ASC, decision_id ASC",
        params,
    ).fetchall()
    return [_row_to_decision(r) for r in rows]


def supersede_decision(
    conn: sqlite3.Connection,
    old_decision_id: str,
    new_record: DecisionRecord,
) -> DecisionRecord:
    """Atomically supersede ``old_decision_id`` with ``new_record``.

    Invariants enforced by this helper:

      * The old decision must exist.
      * The old decision must not already be in status ``superseded``.
      * ``new_record.supersedes`` must either be ``None`` (helper fills
        it in) or exactly match ``old_decision_id``.
      * ``new_record.decision_id`` must differ from ``old_decision_id``.

    On success the new record is inserted with ``supersedes`` set and
    the old decision is updated to status ``superseded`` with
    ``superseded_by`` pointing at the new id — both within a single
    transaction so an interrupted write leaves consistent state.
    """
    if new_record.decision_id == old_decision_id:
        raise ValueError(
            "supersede_decision: new decision_id must differ from old_decision_id"
        )
    if new_record.supersedes is not None and new_record.supersedes != old_decision_id:
        raise ValueError(
            "supersede_decision: new_record.supersedes must be None or match "
            "old_decision_id"
        )

    # Must read the old record BEFORE opening the write transaction so
    # we fail fast and produce a helpful error.
    existing = get_decision(conn, old_decision_id)
    if existing is None:
        raise LookupError(
            f"supersede_decision: no decision with id {old_decision_id!r}"
        )
    if existing.status == "superseded":
        raise ValueError(
            f"supersede_decision: decision {old_decision_id!r} is already superseded"
        )

    now = _now()
    created = new_record.created_at or now
    updated = new_record.updated_at or now
    normalised = dataclasses.replace(
        new_record,
        supersedes=old_decision_id,
        created_at=created,
        updated_at=updated,
    )

    with conn:
        conn.execute(
            f"INSERT INTO decisions ({_DECISION_COLUMNS}) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                normalised.decision_id,
                normalised.title,
                normalised.status,
                normalised.rationale,
                normalised.version,
                normalised.author,
                normalised.scope,
                normalised.supersedes,
                normalised.superseded_by,
                normalised.created_at,
                normalised.updated_at,
            ),
        )
        conn.execute(
            "UPDATE decisions "
            "SET status = 'superseded', superseded_by = ?, updated_at = ? "
            "WHERE decision_id = ?",
            (normalised.decision_id, normalised.updated_at, old_decision_id),
        )

    return normalised


def supersession_chain(
    conn: sqlite3.Connection, decision_id: str
) -> List[DecisionRecord]:
    """Walk ``decisions.supersedes`` backward from ``decision_id`` to origin.

    Returns the chain in chronological order, oldest first. Returns an
    empty list if ``decision_id`` does not exist. Cycles (which
    supersede_decision prevents, but a direct DB write could create)
    are broken deterministically by a ``visited`` set.
    """
    chain: List[DecisionRecord] = []
    current = get_decision(conn, decision_id)
    visited: set[str] = set()
    while current is not None and current.decision_id not in visited:
        visited.add(current.decision_id)
        chain.append(current)
        if current.supersedes is None:
            break
        current = get_decision(conn, current.supersedes)
    chain.reverse()
    return chain


# ---------------------------------------------------------------------------
# Work-item helpers
# ---------------------------------------------------------------------------


def insert_work_item(
    conn: sqlite3.Connection, record: WorkItemRecord
) -> WorkItemRecord:
    """Insert a new work item. Raises ``sqlite3.IntegrityError`` on id conflict."""
    now = _now()
    created = record.created_at or now
    updated = record.updated_at or now
    with conn:
        conn.execute(
            f"INSERT INTO work_items ({_WORK_ITEM_COLUMNS}) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                record.work_item_id,
                record.goal_id,
                record.title,
                record.status,
                record.version,
                record.author,
                record.scope_json,
                record.evaluation_json,
                record.head_sha,
                record.reviewer_round,
                created,
                updated,
            ),
        )
    return dataclasses.replace(record, created_at=created, updated_at=updated)


def upsert_work_item(
    conn: sqlite3.Connection, record: WorkItemRecord
) -> WorkItemRecord:
    """Insert or update a work item by ``work_item_id``."""
    now = _now()
    created = record.created_at or now
    updated = record.updated_at or now
    with conn:
        conn.execute(
            f"INSERT INTO work_items ({_WORK_ITEM_COLUMNS}) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(work_item_id) DO UPDATE SET "
            "  goal_id         = excluded.goal_id, "
            "  title           = excluded.title, "
            "  status          = excluded.status, "
            "  version         = excluded.version, "
            "  author          = excluded.author, "
            "  scope_json      = excluded.scope_json, "
            "  evaluation_json = excluded.evaluation_json, "
            "  head_sha        = excluded.head_sha, "
            "  reviewer_round  = excluded.reviewer_round, "
            "  updated_at      = excluded.updated_at",
            (
                record.work_item_id,
                record.goal_id,
                record.title,
                record.status,
                record.version,
                record.author,
                record.scope_json,
                record.evaluation_json,
                record.head_sha,
                record.reviewer_round,
                created,
                updated,
            ),
        )
    return dataclasses.replace(record, created_at=created, updated_at=updated)


def get_work_item(
    conn: sqlite3.Connection, work_item_id: str
) -> Optional[WorkItemRecord]:
    """Return the work-item record for ``work_item_id``, or ``None``."""
    row = conn.execute(
        f"SELECT {_WORK_ITEM_COLUMNS} FROM work_items WHERE work_item_id = ?",
        (work_item_id,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_work_item(row)


def list_work_items(
    conn: sqlite3.Connection,
    *,
    goal_id: Optional[str] = None,
    status: Optional[str] = None,
) -> List[WorkItemRecord]:
    """List work items, optionally filtered by ``goal_id`` and/or ``status``.

    Results are ordered by ``created_at ASC, work_item_id ASC``.
    """
    clauses: List[str] = []
    params: List[object] = []
    if goal_id is not None:
        clauses.append("goal_id = ?")
        params.append(goal_id)
    if status is not None:
        clauses.append("status = ?")
        params.append(status)
    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    rows = conn.execute(
        f"SELECT {_WORK_ITEM_COLUMNS} FROM work_items {where} "
        "ORDER BY created_at ASC, work_item_id ASC",
        params,
    ).fetchall()
    return [_row_to_work_item(r) for r in rows]


# ---------------------------------------------------------------------------
# Goal-contract helpers
#
# Symmetric with the decision and work-item families above. The goal
# table is the narrow persistence substrate for
# ``runtime.core.contracts.GoalContract`` (DEC-CLAUDEX-GOAL-CONTRACTS-001).
# This slice deliberately does NOT add a typed encode / decode pair
# between ``GoalContract`` and ``GoalRecord`` — that bridge is a later
# slice that can land alongside the prompt-pack workflow capture
# helper.
# ---------------------------------------------------------------------------


def insert_goal(
    conn: sqlite3.Connection, record: GoalRecord
) -> GoalRecord:
    """Insert a new goal contract. Raises ``sqlite3.IntegrityError`` on id conflict.

    Returns the record with ``created_at`` / ``updated_at`` backfilled
    to the current wall clock when the caller passed ``0``.
    """
    now = _now()
    created = record.created_at or now
    updated = record.updated_at or now
    with conn:
        conn.execute(
            f"INSERT INTO goal_contracts ({_GOAL_COLUMNS}) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                record.goal_id,
                record.desired_end_state,
                record.status,
                record.autonomy_budget,
                record.continuation_rules_json,
                record.stop_conditions_json,
                record.escalation_boundaries_json,
                record.user_decision_boundaries_json,
                created,
                updated,
            ),
        )
    return dataclasses.replace(record, created_at=created, updated_at=updated)


def upsert_goal(
    conn: sqlite3.Connection, record: GoalRecord
) -> GoalRecord:
    """Insert or update a goal contract by ``goal_id``.

    On update, every caller-supplied field overwrites the existing
    row, and ``updated_at`` is refreshed to the current wall clock
    (unless the caller passed a non-zero ``updated_at``).
    """
    now = _now()
    created = record.created_at or now
    updated = record.updated_at or now
    with conn:
        conn.execute(
            f"INSERT INTO goal_contracts ({_GOAL_COLUMNS}) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(goal_id) DO UPDATE SET "
            "  desired_end_state             = excluded.desired_end_state, "
            "  status                        = excluded.status, "
            "  autonomy_budget               = excluded.autonomy_budget, "
            "  continuation_rules_json       = excluded.continuation_rules_json, "
            "  stop_conditions_json          = excluded.stop_conditions_json, "
            "  escalation_boundaries_json    = excluded.escalation_boundaries_json, "
            "  user_decision_boundaries_json = excluded.user_decision_boundaries_json, "
            "  updated_at                    = excluded.updated_at",
            (
                record.goal_id,
                record.desired_end_state,
                record.status,
                record.autonomy_budget,
                record.continuation_rules_json,
                record.stop_conditions_json,
                record.escalation_boundaries_json,
                record.user_decision_boundaries_json,
                created,
                updated,
            ),
        )
    return dataclasses.replace(record, created_at=created, updated_at=updated)


def get_goal(
    conn: sqlite3.Connection, goal_id: str
) -> Optional[GoalRecord]:
    """Return the goal-contract record for ``goal_id``, or ``None`` if absent."""
    row = conn.execute(
        f"SELECT {_GOAL_COLUMNS} FROM goal_contracts WHERE goal_id = ?",
        (goal_id,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_goal(row)


def list_goals(
    conn: sqlite3.Connection,
    *,
    status: Optional[str] = None,
) -> List[GoalRecord]:
    """List goal contracts, optionally filtered by ``status``.

    Results are ordered by ``created_at ASC, goal_id ASC`` so the
    return is deterministic for test assertions — symmetric with
    :func:`list_decisions` and :func:`list_work_items`.
    """
    clauses: List[str] = []
    params: List[object] = []
    if status is not None:
        clauses.append("status = ?")
        params.append(status)
    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    rows = conn.execute(
        f"SELECT {_GOAL_COLUMNS} FROM goal_contracts {where} "
        "ORDER BY created_at ASC, goal_id ASC",
        params,
    ).fetchall()
    return [_row_to_goal(r) for r in rows]

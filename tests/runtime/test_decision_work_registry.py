"""Tests for runtime/core/decision_work_registry.py and its SQLite schema.

@decision DEC-CLAUDEX-DW-REGISTRY-TESTS-001
Title: Canonical decision/work persistence is pinned — schema, round-trip, supersession, validation, and shadow-only discipline
Status: proposed (shadow-mode, Phase 1 constitutional kernel)
Rationale: The decision/work registry is the first Phase 1 slice that
  touches a constitution-level file (``runtime/schemas.py``) and the
  first shadow-kernel slice to add SQLite tables. The invariants it
  delivers — round-trip persistence, atomic supersession, and typed
  record validation — must be mechanically asserted so the tables
  cannot silently drift.

  Covered invariants:

    1. ``ensure_schema`` creates the ``decisions`` and ``work_items``
       tables and all declared indexes.
    2. ``ensure_schema`` is idempotent (second call is a no-op).
    3. Round-trip persistence for ``DecisionRecord`` and
       ``WorkItemRecord``: insert, get, list, upsert.
    4. Supersession semantics:
       * Old decision transitions to status ``superseded`` and its
         ``superseded_by`` field points at the new decision id.
       * New decision carries ``supersedes`` set to the old id.
       * ``supersession_chain`` walks back through the supersedes
         links to the origin decision.
       * Refuses to supersede a nonexistent or already-superseded
         decision.
       * Refuses to supersede with a new id equal to the old id.
       * Refuses a caller-supplied ``supersedes`` that disagrees
         with ``old_decision_id``.
    5. Typed record shapes enforce version/status/provenance at
       construction time:
       * Unknown status strings rejected for both record kinds.
       * Empty required string fields rejected.
       * Non-positive version rejected (``version >= 1``).
       * Negative timestamps rejected.
       * Boolean-as-int rejected on numeric fields.
       * Self-supersession rejected in ``DecisionRecord.__post_init__``.
    6. Shadow-only discipline via AST walk:
       * The module imports only stdlib + contracts + schemas.
       * Live routing / policy / hooks do not import the module.
"""

from __future__ import annotations

import ast
import inspect
import sqlite3

import pytest

from runtime.core import decision_work_registry as dwr
from runtime.core.contracts import GOAL_STATUSES, WORK_ITEM_STATUSES
from runtime.schemas import DECISION_STATUSES, ensure_schema


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _valid_decision(
    *,
    decision_id: str = "DEC-001",
    title: str = "initial decision",
    status: str = "accepted",
    rationale: str = "bootstrap",
    version: int = 1,
    author: str = "planner",
    scope: str = "kernel",
    supersedes: str | None = None,
    superseded_by: str | None = None,
    created_at: int = 0,
    updated_at: int = 0,
) -> dwr.DecisionRecord:
    return dwr.DecisionRecord(
        decision_id=decision_id,
        title=title,
        status=status,
        rationale=rationale,
        version=version,
        author=author,
        scope=scope,
        supersedes=supersedes,
        superseded_by=superseded_by,
        created_at=created_at,
        updated_at=updated_at,
    )


def _valid_work_item(
    *,
    work_item_id: str = "WI-001",
    goal_id: str = "G-001",
    title: str = "first slice",
    status: str = "pending",
    version: int = 1,
    author: str = "planner",
    scope_json: str = "{}",
    evaluation_json: str = "{}",
    head_sha: str | None = None,
    reviewer_round: int = 0,
    created_at: int = 0,
    updated_at: int = 0,
) -> dwr.WorkItemRecord:
    return dwr.WorkItemRecord(
        work_item_id=work_item_id,
        goal_id=goal_id,
        title=title,
        status=status,
        version=version,
        author=author,
        scope_json=scope_json,
        evaluation_json=evaluation_json,
        head_sha=head_sha,
        reviewer_round=reviewer_round,
        created_at=created_at,
        updated_at=updated_at,
    )


def _valid_goal(
    *,
    goal_id: str = "G-001",
    desired_end_state: str = "ship the slice",
    status: str = "active",
    autonomy_budget: int = 0,
    continuation_rules_json: str = "[]",
    stop_conditions_json: str = "[]",
    escalation_boundaries_json: str = "[]",
    user_decision_boundaries_json: str = "[]",
    created_at: int = 0,
    updated_at: int = 0,
) -> dwr.GoalRecord:
    return dwr.GoalRecord(
        goal_id=goal_id,
        desired_end_state=desired_end_state,
        status=status,
        autonomy_budget=autonomy_budget,
        continuation_rules_json=continuation_rules_json,
        stop_conditions_json=stop_conditions_json,
        escalation_boundaries_json=escalation_boundaries_json,
        user_decision_boundaries_json=user_decision_boundaries_json,
        created_at=created_at,
        updated_at=updated_at,
    )


def _imported_module_names(module) -> set[str]:
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            base = node.module or ""
            if base:
                names.add(base)
                for alias in node.names:
                    names.add(f"{base}.{alias.name}")
    return names


# ---------------------------------------------------------------------------
# 1. Schema bootstrap
# ---------------------------------------------------------------------------


class TestSchemaBootstrap:
    def test_decisions_table_exists(self, conn):
        row = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='decisions'"
        ).fetchone()
        assert row is not None

    def test_work_items_table_exists(self, conn):
        row = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='work_items'"
        ).fetchone()
        assert row is not None

    def test_decisions_table_has_expected_columns(self, conn):
        cols = {
            row[1] for row in conn.execute("PRAGMA table_info(decisions)").fetchall()
        }
        expected = {
            "decision_id",
            "title",
            "status",
            "rationale",
            "version",
            "author",
            "scope",
            "supersedes",
            "superseded_by",
            "created_at",
            "updated_at",
        }
        assert cols == expected, f"columns differ: {cols ^ expected}"

    def test_work_items_table_has_expected_columns(self, conn):
        cols = {
            row[1] for row in conn.execute("PRAGMA table_info(work_items)").fetchall()
        }
        expected = {
            "work_item_id",
            "goal_id",
            "title",
            "status",
            "version",
            "author",
            "scope_json",
            "evaluation_json",
            "head_sha",
            "reviewer_round",
            "created_at",
            "updated_at",
        }
        assert cols == expected, f"columns differ: {cols ^ expected}"

    def test_work_items_reviewer_round_default_is_zero(self, conn):
        # Defensive: pin both presence and the SQL-level default so a
        # later schema change cannot silently flip the default and
        # break stored rows that omit the field.
        rows = conn.execute("PRAGMA table_info(work_items)").fetchall()
        reviewer_round_row = next(
            row for row in rows if row[1] == "reviewer_round"
        )
        # PRAGMA table_info row layout: (cid, name, type, notnull, dflt_value, pk)
        assert reviewer_round_row[2].upper() == "INTEGER"
        assert reviewer_round_row[3] == 1  # NOT NULL
        assert reviewer_round_row[4] == "0"  # default '0'

    def test_decisions_indexes_exist(self, conn):
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='decisions'"
        ).fetchall()
        names = {row[0] for row in rows}
        assert "idx_decisions_status" in names
        assert "idx_decisions_scope" in names
        assert "idx_decisions_supersedes" in names

    def test_work_items_indexes_exist(self, conn):
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='work_items'"
        ).fetchall()
        names = {row[0] for row in rows}
        assert "idx_work_items_goal" in names
        assert "idx_work_items_status" in names

    def test_ensure_schema_is_idempotent(self, conn):
        # Second call should be a no-op and must not raise.
        ensure_schema(conn)
        ensure_schema(conn)
        # Tables still present and empty.
        count = conn.execute("SELECT COUNT(*) FROM decisions").fetchone()[0]
        assert count == 0

    def test_decision_status_vocabulary(self):
        assert DECISION_STATUSES == frozenset(
            {"proposed", "accepted", "rejected", "superseded", "deprecated"}
        )

    def test_goal_contracts_table_exists(self, conn):
        row = conn.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name='goal_contracts'"
        ).fetchone()
        assert row is not None

    def test_goal_contracts_table_has_expected_columns(self, conn):
        cols = {
            row[1]
            for row in conn.execute("PRAGMA table_info(goal_contracts)").fetchall()
        }
        expected = {
            "goal_id",
            "desired_end_state",
            "status",
            "autonomy_budget",
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
            "created_at",
            "updated_at",
        }
        assert cols == expected, f"columns differ: {cols ^ expected}"

    def test_goal_contracts_index_exists(self, conn):
        rows = conn.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type='index' AND tbl_name='goal_contracts'"
        ).fetchall()
        names = {row[0] for row in rows}
        assert "idx_goal_contracts_status" in names

    def test_goal_status_vocabulary_matches_contracts(self):
        # The registry must share the canonical status vocabulary
        # owned by contracts.py — not maintain a second copy.
        assert GOAL_STATUSES == frozenset(
            {"active", "awaiting_user", "complete", "blocked_external"}
        )


# ---------------------------------------------------------------------------
# 2. DecisionRecord typed shape + validation
# ---------------------------------------------------------------------------


class TestDecisionRecordShape:
    def test_construct_minimal_valid(self):
        rec = _valid_decision()
        assert rec.decision_id == "DEC-001"
        assert rec.status == "accepted"
        assert rec.version == 1

    def test_record_is_frozen(self):
        rec = _valid_decision()
        with pytest.raises(Exception):
            rec.status = "rejected"  # type: ignore[misc]

    @pytest.mark.parametrize(
        "status", ["accepted", "proposed", "rejected", "superseded", "deprecated"]
    )
    def test_all_legal_statuses_accepted(self, status):
        rec = _valid_decision(status=status)
        assert rec.status == status

    def test_unknown_status_rejected(self):
        with pytest.raises(ValueError):
            _valid_decision(status="banana")

    @pytest.mark.parametrize(
        "attr",
        ["decision_id", "title", "rationale", "author", "scope"],
    )
    def test_empty_required_string_rejected(self, attr):
        with pytest.raises(ValueError):
            _valid_decision(**{attr: ""})  # type: ignore[arg-type]

    def test_version_must_be_positive(self):
        with pytest.raises(ValueError):
            _valid_decision(version=0)
        with pytest.raises(ValueError):
            _valid_decision(version=-1)

    def test_version_must_be_int(self):
        with pytest.raises(ValueError):
            _valid_decision(version="1")  # type: ignore[arg-type]
        with pytest.raises(ValueError):
            _valid_decision(version=True)  # bool is subclass of int

    def test_negative_timestamps_rejected(self):
        with pytest.raises(ValueError):
            _valid_decision(created_at=-1)
        with pytest.raises(ValueError):
            _valid_decision(updated_at=-1)

    def test_empty_supersedes_rejected(self):
        with pytest.raises(ValueError):
            _valid_decision(supersedes="")

    def test_supersedes_is_optional(self):
        rec = _valid_decision(supersedes=None)
        assert rec.supersedes is None

    def test_self_supersession_rejected_in_constructor(self):
        with pytest.raises(ValueError):
            _valid_decision(decision_id="DEC-X", supersedes="DEC-X")

    def test_self_superseded_by_rejected_in_constructor(self):
        with pytest.raises(ValueError):
            _valid_decision(decision_id="DEC-X", superseded_by="DEC-X")


# ---------------------------------------------------------------------------
# 3. Decision persistence round-trip
# ---------------------------------------------------------------------------


class TestDecisionPersistence:
    def test_insert_and_get_round_trip(self, conn):
        rec = _valid_decision(created_at=0, updated_at=0)
        stored = dwr.insert_decision(conn, rec)
        # Timestamps backfilled
        assert stored.created_at > 0
        assert stored.updated_at > 0

        fetched = dwr.get_decision(conn, "DEC-001")
        assert fetched is not None
        assert fetched.decision_id == "DEC-001"
        assert fetched.title == "initial decision"
        assert fetched.status == "accepted"
        assert fetched.version == 1
        assert fetched.author == "planner"
        assert fetched.scope == "kernel"
        assert fetched.supersedes is None
        assert fetched.superseded_by is None
        assert fetched.created_at == stored.created_at
        assert fetched.updated_at == stored.updated_at

    def test_get_missing_returns_none(self, conn):
        assert dwr.get_decision(conn, "DEC-missing") is None

    def test_insert_rejects_duplicate_decision_id(self, conn):
        dwr.insert_decision(conn, _valid_decision(decision_id="DEC-dup"))
        with pytest.raises(sqlite3.IntegrityError):
            dwr.insert_decision(
                conn, _valid_decision(decision_id="DEC-dup", title="second attempt")
            )

    def test_upsert_inserts_when_missing(self, conn):
        dwr.upsert_decision(
            conn, _valid_decision(decision_id="DEC-up1", title="first")
        )
        fetched = dwr.get_decision(conn, "DEC-up1")
        assert fetched is not None
        assert fetched.title == "first"

    def test_upsert_updates_existing(self, conn):
        dwr.insert_decision(
            conn,
            _valid_decision(decision_id="DEC-up2", title="old", version=1),
        )
        updated = dwr.upsert_decision(
            conn,
            _valid_decision(
                decision_id="DEC-up2",
                title="new title",
                version=2,
                rationale="updated",
            ),
        )
        fetched = dwr.get_decision(conn, "DEC-up2")
        assert fetched is not None
        assert fetched.title == "new title"
        assert fetched.version == 2
        assert fetched.rationale == "updated"
        assert fetched.updated_at == updated.updated_at

    def test_list_returns_deterministic_order(self, conn):
        # created_at is backfilled to now(); insert with explicit
        # created_at so ordering is predictable.
        dwr.insert_decision(
            conn,
            _valid_decision(decision_id="DEC-B", created_at=200, updated_at=200),
        )
        dwr.insert_decision(
            conn,
            _valid_decision(decision_id="DEC-A", created_at=100, updated_at=100),
        )
        dwr.insert_decision(
            conn,
            _valid_decision(decision_id="DEC-C", created_at=300, updated_at=300),
        )
        listing = dwr.list_decisions(conn)
        assert [r.decision_id for r in listing] == ["DEC-A", "DEC-B", "DEC-C"]

    def test_list_filters_by_status(self, conn):
        dwr.insert_decision(
            conn, _valid_decision(decision_id="DEC-ok", status="accepted")
        )
        dwr.insert_decision(
            conn, _valid_decision(decision_id="DEC-no", status="rejected")
        )
        accepted = dwr.list_decisions(conn, status="accepted")
        assert [r.decision_id for r in accepted] == ["DEC-ok"]

    def test_list_filters_by_scope(self, conn):
        dwr.insert_decision(
            conn, _valid_decision(decision_id="DEC-k", scope="kernel")
        )
        dwr.insert_decision(
            conn, _valid_decision(decision_id="DEC-h", scope="hooks")
        )
        kernel = dwr.list_decisions(conn, scope="kernel")
        assert [r.decision_id for r in kernel] == ["DEC-k"]

    def test_list_filters_combine(self, conn):
        dwr.insert_decision(
            conn,
            _valid_decision(
                decision_id="DEC-ka", status="accepted", scope="kernel"
            ),
        )
        dwr.insert_decision(
            conn,
            _valid_decision(
                decision_id="DEC-kr", status="rejected", scope="kernel"
            ),
        )
        dwr.insert_decision(
            conn,
            _valid_decision(
                decision_id="DEC-ha", status="accepted", scope="hooks"
            ),
        )
        listing = dwr.list_decisions(conn, status="accepted", scope="kernel")
        assert [r.decision_id for r in listing] == ["DEC-ka"]


# ---------------------------------------------------------------------------
# 4. Decision supersession semantics
# ---------------------------------------------------------------------------


class TestDecisionSupersession:
    def _seed(self, conn) -> dwr.DecisionRecord:
        return dwr.insert_decision(
            conn,
            _valid_decision(
                decision_id="DEC-old",
                title="original",
                rationale="first cut",
                version=1,
            ),
        )

    def test_supersede_updates_old_status_and_link(self, conn):
        self._seed(conn)
        new = _valid_decision(
            decision_id="DEC-new",
            title="revision",
            rationale="improved",
            version=2,
        )
        returned = dwr.supersede_decision(conn, "DEC-old", new)

        # New record carries supersedes set.
        assert returned.supersedes == "DEC-old"
        # Old record is now superseded.
        old = dwr.get_decision(conn, "DEC-old")
        assert old is not None
        assert old.status == "superseded"
        assert old.superseded_by == "DEC-new"

    def test_supersede_persists_new_record(self, conn):
        self._seed(conn)
        dwr.supersede_decision(
            conn,
            "DEC-old",
            _valid_decision(decision_id="DEC-new", version=2, rationale="r"),
        )
        new_fetched = dwr.get_decision(conn, "DEC-new")
        assert new_fetched is not None
        assert new_fetched.supersedes == "DEC-old"
        assert new_fetched.version == 2

    def test_supersede_refuses_nonexistent_old(self, conn):
        with pytest.raises(LookupError):
            dwr.supersede_decision(
                conn,
                "DEC-ghost",
                _valid_decision(decision_id="DEC-new"),
            )

    def test_supersede_refuses_already_superseded(self, conn):
        self._seed(conn)
        dwr.supersede_decision(
            conn,
            "DEC-old",
            _valid_decision(decision_id="DEC-mid", version=2),
        )
        with pytest.raises(ValueError):
            dwr.supersede_decision(
                conn,
                "DEC-old",
                _valid_decision(decision_id="DEC-new", version=3),
            )

    def test_supersede_refuses_same_id(self, conn):
        self._seed(conn)
        with pytest.raises(ValueError):
            dwr.supersede_decision(
                conn,
                "DEC-old",
                _valid_decision(decision_id="DEC-old"),
            )

    def test_supersede_refuses_mismatched_supersedes(self, conn):
        self._seed(conn)
        dwr.insert_decision(conn, _valid_decision(decision_id="DEC-other"))
        bad = _valid_decision(
            decision_id="DEC-new",
            version=2,
            supersedes="DEC-other",
        )
        with pytest.raises(ValueError):
            dwr.supersede_decision(conn, "DEC-old", bad)

    def test_supersede_accepts_matching_supersedes(self, conn):
        self._seed(conn)
        ok = _valid_decision(
            decision_id="DEC-new",
            version=2,
            supersedes="DEC-old",
        )
        result = dwr.supersede_decision(conn, "DEC-old", ok)
        assert result.supersedes == "DEC-old"

    def test_supersede_is_atomic_in_single_transaction(self, conn):
        self._seed(conn)
        dwr.supersede_decision(
            conn,
            "DEC-old",
            _valid_decision(decision_id="DEC-new", version=2),
        )
        # Both rows must exist simultaneously with consistent state.
        old = dwr.get_decision(conn, "DEC-old")
        new = dwr.get_decision(conn, "DEC-new")
        assert old is not None and new is not None
        assert old.status == "superseded"
        assert old.superseded_by == new.decision_id
        assert new.supersedes == old.decision_id

    def test_supersession_chain_walks_back_to_origin(self, conn):
        self._seed(conn)
        dwr.supersede_decision(
            conn,
            "DEC-old",
            _valid_decision(decision_id="DEC-mid", version=2, rationale="r"),
        )
        dwr.supersede_decision(
            conn,
            "DEC-mid",
            _valid_decision(decision_id="DEC-new", version=3, rationale="r"),
        )
        chain = dwr.supersession_chain(conn, "DEC-new")
        assert [r.decision_id for r in chain] == ["DEC-old", "DEC-mid", "DEC-new"]

    def test_supersession_chain_for_unsuperseded_decision(self, conn):
        self._seed(conn)
        chain = dwr.supersession_chain(conn, "DEC-old")
        assert [r.decision_id for r in chain] == ["DEC-old"]

    def test_supersession_chain_for_missing_decision(self, conn):
        assert dwr.supersession_chain(conn, "DEC-nope") == []


# ---------------------------------------------------------------------------
# 5. WorkItemRecord typed shape
# ---------------------------------------------------------------------------


class TestWorkItemRecordShape:
    def test_construct_minimal_valid(self):
        rec = _valid_work_item()
        assert rec.work_item_id == "WI-001"
        assert rec.status == "pending"
        assert rec.version == 1
        assert rec.scope_json == "{}"
        assert rec.evaluation_json == "{}"

    def test_record_is_frozen(self):
        rec = _valid_work_item()
        with pytest.raises(Exception):
            rec.status = "in_progress"  # type: ignore[misc]

    def test_status_vocabulary_matches_contracts_export(self):
        # The registry module must share the vocabulary owned by
        # contracts.py — not maintain a second copy.
        for status in WORK_ITEM_STATUSES:
            rec = _valid_work_item(status=status)
            assert rec.status == status

    def test_unknown_status_rejected(self):
        with pytest.raises(ValueError):
            _valid_work_item(status="banana")

    @pytest.mark.parametrize(
        "attr", ["work_item_id", "goal_id", "title", "author"]
    )
    def test_empty_required_string_rejected(self, attr):
        with pytest.raises(ValueError):
            _valid_work_item(**{attr: ""})  # type: ignore[arg-type]

    def test_version_must_be_positive(self):
        with pytest.raises(ValueError):
            _valid_work_item(version=0)
        with pytest.raises(ValueError):
            _valid_work_item(version=-1)

    def test_version_must_be_int(self):
        with pytest.raises(ValueError):
            _valid_work_item(version=True)  # bool is subclass of int

    def test_head_sha_optional_but_must_be_non_empty_if_present(self):
        ok = _valid_work_item(head_sha=None)
        assert ok.head_sha is None
        ok2 = _valid_work_item(head_sha="abc123")
        assert ok2.head_sha == "abc123"
        with pytest.raises(ValueError):
            _valid_work_item(head_sha="")

    def test_scope_json_must_be_string(self):
        with pytest.raises(ValueError):
            _valid_work_item(scope_json={})  # type: ignore[arg-type]
        with pytest.raises(ValueError):
            _valid_work_item(evaluation_json=None)  # type: ignore[arg-type]

    def test_negative_timestamps_rejected(self):
        with pytest.raises(ValueError):
            _valid_work_item(created_at=-1)
        with pytest.raises(ValueError):
            _valid_work_item(updated_at=-1)

    def test_reviewer_round_defaults_to_zero(self):
        rec = _valid_work_item()
        assert rec.reviewer_round == 0

    def test_reviewer_round_accepts_zero(self):
        rec = _valid_work_item(reviewer_round=0)
        assert rec.reviewer_round == 0

    def test_reviewer_round_accepts_positive_int(self):
        rec = _valid_work_item(reviewer_round=5)
        assert rec.reviewer_round == 5

    def test_reviewer_round_rejects_negative(self):
        with pytest.raises(ValueError):
            _valid_work_item(reviewer_round=-1)

    def test_reviewer_round_rejects_bool(self):
        # bool is a subclass of int — without an explicit check the
        # validator would silently accept ``True`` as ``1``. The
        # _require_non_negative_int helper rejects bools first.
        with pytest.raises(ValueError):
            _valid_work_item(reviewer_round=True)  # type: ignore[arg-type]

    def test_reviewer_round_rejects_non_int(self):
        with pytest.raises(ValueError):
            _valid_work_item(reviewer_round="0")  # type: ignore[arg-type]
        with pytest.raises(ValueError):
            _valid_work_item(reviewer_round=None)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# 6. WorkItem persistence round-trip
# ---------------------------------------------------------------------------


class TestWorkItemPersistence:
    def test_insert_and_get_round_trip(self, conn):
        rec = _valid_work_item(
            scope_json='{"allowed":["runtime/"]}',
            evaluation_json='{"tests":["test_x.py"]}',
            head_sha="abc123",
            reviewer_round=2,
        )
        stored = dwr.insert_work_item(conn, rec)
        assert stored.created_at > 0

        fetched = dwr.get_work_item(conn, "WI-001")
        assert fetched is not None
        assert fetched.work_item_id == "WI-001"
        assert fetched.goal_id == "G-001"
        assert fetched.status == "pending"
        assert fetched.scope_json == '{"allowed":["runtime/"]}'
        assert fetched.evaluation_json == '{"tests":["test_x.py"]}'
        assert fetched.head_sha == "abc123"
        assert fetched.reviewer_round == 2

    def test_default_reviewer_round_round_trip(self, conn):
        # When the caller does not pass reviewer_round, the dataclass
        # default (0) must reach SQLite and round-trip back as 0.
        dwr.insert_work_item(
            conn, _valid_work_item(work_item_id="WI-default-rr")
        )
        fetched = dwr.get_work_item(conn, "WI-default-rr")
        assert fetched is not None
        assert fetched.reviewer_round == 0

    def test_upsert_updates_reviewer_round(self, conn):
        dwr.insert_work_item(
            conn,
            _valid_work_item(work_item_id="WI-rr-up", reviewer_round=0),
        )
        dwr.upsert_work_item(
            conn,
            _valid_work_item(
                work_item_id="WI-rr-up",
                status="in_review",
                reviewer_round=3,
            ),
        )
        fetched = dwr.get_work_item(conn, "WI-rr-up")
        assert fetched is not None
        assert fetched.status == "in_review"
        assert fetched.reviewer_round == 3

    def test_get_missing_returns_none(self, conn):
        assert dwr.get_work_item(conn, "WI-missing") is None

    def test_insert_rejects_duplicate_id(self, conn):
        dwr.insert_work_item(conn, _valid_work_item(work_item_id="WI-dup"))
        with pytest.raises(sqlite3.IntegrityError):
            dwr.insert_work_item(
                conn, _valid_work_item(work_item_id="WI-dup", title="second")
            )

    def test_upsert_updates_status_and_version(self, conn):
        dwr.insert_work_item(
            conn,
            _valid_work_item(work_item_id="WI-up", status="pending", version=1),
        )
        dwr.upsert_work_item(
            conn,
            _valid_work_item(
                work_item_id="WI-up", status="in_progress", version=2
            ),
        )
        fetched = dwr.get_work_item(conn, "WI-up")
        assert fetched is not None
        assert fetched.status == "in_progress"
        assert fetched.version == 2

    def test_list_deterministic_order(self, conn):
        dwr.insert_work_item(
            conn,
            _valid_work_item(
                work_item_id="WI-B", created_at=200, updated_at=200
            ),
        )
        dwr.insert_work_item(
            conn,
            _valid_work_item(
                work_item_id="WI-A", created_at=100, updated_at=100
            ),
        )
        listing = dwr.list_work_items(conn)
        assert [r.work_item_id for r in listing] == ["WI-A", "WI-B"]

    def test_list_filters_by_goal(self, conn):
        dwr.insert_work_item(
            conn, _valid_work_item(work_item_id="WI-g1", goal_id="G-1")
        )
        dwr.insert_work_item(
            conn, _valid_work_item(work_item_id="WI-g2", goal_id="G-2")
        )
        only_g1 = dwr.list_work_items(conn, goal_id="G-1")
        assert [r.work_item_id for r in only_g1] == ["WI-g1"]

    def test_list_filters_by_status(self, conn):
        dwr.insert_work_item(
            conn,
            _valid_work_item(work_item_id="WI-p", status="pending"),
        )
        dwr.insert_work_item(
            conn,
            _valid_work_item(work_item_id="WI-r", status="in_review"),
        )
        in_review = dwr.list_work_items(conn, status="in_review")
        assert [r.work_item_id for r in in_review] == ["WI-r"]


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline (AST inspection)
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_decision_work_registry_only_depends_on_contracts_and_schemas(self):
        imported = _imported_module_names(dwr)
        runtime_core_imports = {
            n for n in imported if n.startswith("runtime.core")
        }
        # Permitted base modules:
        permitted_bases = {"runtime.core", "runtime.core.contracts"}
        # Permitted dotted leaves (from ImportFrom expansion):
        permitted_leaves = {
            "runtime.core.contracts.GOAL_STATUSES",
            "runtime.core.contracts.WORK_ITEM_STATUSES",
        }
        for name in runtime_core_imports:
            assert name in permitted_bases | permitted_leaves, (
                f"decision_work_registry imports unexpected runtime.core "
                f"module {name!r}"
            )
        # Must also NOT import any live-routing token.
        forbidden = (
            "dispatch_engine",
            "completions",
            "policy_engine",
            "enforcement_config",
            "settings",
            "hooks",
            "runtime.core.leases",
            "runtime.core.workflows",
            "runtime.core.policy_utils",
        )
        for name in imported:
            for needle in forbidden:
                assert needle not in name, (
                    f"decision_work_registry imports {name!r} which "
                    f"contains forbidden live-module token {needle!r}"
                )

    def test_live_modules_do_not_import_decision_work_registry(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "decision_work_registry" not in name, (
                    f"{mod.__name__} imports {name!r} — decision_work_"
                    f"registry must stay shadow-only"
                )

    def test_cli_does_not_import_decision_work_registry_at_module_level(
        self,
    ):
        # Phase 7 Slice 14 introduced a read-only
        # ``cc-policy decision digest`` surface that calls
        # :func:`list_decisions` via a *function-scope* import inside
        # ``_handle_decision``; Phase 7 Slice 15 added the
        # ``cc-policy decision digest-check`` drift validator through
        # the same function-scope import. Module-level import from
        # ``cli.py`` remains forbidden so the CLI's module-load graph
        # does not acquire a build-time dependency on the canonical
        # decision authority. Function-scope CLI use is asserted
        # directly by ``tests/runtime/test_decision_digest_cli.py``.
        import runtime.cli as cli

        tree = ast.parse(inspect.getsource(cli))
        for node in tree.body:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    assert "decision_work_registry" not in alias.name, (
                        f"runtime/cli.py imports {alias.name!r} at "
                        f"module scope — decision_work_registry must "
                        f"stay function-scoped"
                    )
            elif isinstance(node, ast.ImportFrom):
                name = node.module or ""
                assert "decision_work_registry" not in name, (
                    f"runtime/cli.py imports from {name!r} at module "
                    f"scope — decision_work_registry must stay "
                    f"function-scoped"
                )


# ---------------------------------------------------------------------------
# 7b. work_items.reviewer_round migration on legacy schemas
# ---------------------------------------------------------------------------


class TestWorkItemsReviewerRoundMigration:
    """Pin that ensure_schema brings forward old work_items tables.

    Old DBs created before DEC-CLAUDEX-WORK-ITEM-REVIEWER-ROUND-001
    have a ``work_items`` table without the ``reviewer_round`` column.
    ``ensure_schema`` must apply an idempotent ``ALTER TABLE`` so the
    column exists with default 0 — without dropping or rewriting any
    existing rows.
    """

    _LEGACY_WORK_ITEMS_DDL = """
    CREATE TABLE work_items (
        work_item_id    TEXT    PRIMARY KEY,
        goal_id         TEXT    NOT NULL,
        title           TEXT    NOT NULL,
        status          TEXT    NOT NULL,
        version         INTEGER NOT NULL,
        author          TEXT    NOT NULL,
        scope_json      TEXT    NOT NULL DEFAULT '{}',
        evaluation_json TEXT    NOT NULL DEFAULT '{}',
        head_sha        TEXT,
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL
    )
    """

    def _legacy_conn(self) -> sqlite3.Connection:
        c = sqlite3.connect(":memory:")
        c.row_factory = sqlite3.Row
        # Stand up the legacy table directly, bypassing ensure_schema.
        c.execute(self._LEGACY_WORK_ITEMS_DDL)
        c.commit()
        return c

    def test_legacy_schema_lacks_reviewer_round_column(self):
        c = self._legacy_conn()
        try:
            cols = {
                row[1]
                for row in c.execute("PRAGMA table_info(work_items)").fetchall()
            }
            assert "reviewer_round" not in cols
        finally:
            c.close()

    def test_ensure_schema_adds_reviewer_round_column_to_legacy_table(self):
        c = self._legacy_conn()
        try:
            ensure_schema(c)
            cols = {
                row[1]
                for row in c.execute("PRAGMA table_info(work_items)").fetchall()
            }
            assert "reviewer_round" in cols
        finally:
            c.close()

    def test_ensure_schema_preserves_existing_legacy_rows(self):
        c = self._legacy_conn()
        try:
            # Insert a row using the legacy column set.
            c.execute(
                "INSERT INTO work_items "
                "(work_item_id, goal_id, title, status, version, author, "
                " scope_json, evaluation_json, head_sha, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    "WI-legacy",
                    "G-legacy",
                    "legacy slice",
                    "pending",
                    1,
                    "planner",
                    "{}",
                    "{}",
                    None,
                    100,
                    200,
                ),
            )
            c.commit()

            ensure_schema(c)

            # Row still exists, and the new column carries the
            # ALTER TABLE default (0). Reading via the registry helper
            # validates the row converter handles the migrated shape.
            fetched = dwr.get_work_item(c, "WI-legacy")
            assert fetched is not None
            assert fetched.work_item_id == "WI-legacy"
            assert fetched.title == "legacy slice"
            assert fetched.reviewer_round == 0
            assert fetched.created_at == 100
            assert fetched.updated_at == 200
        finally:
            c.close()

    def test_ensure_schema_is_idempotent_on_migrated_table(self):
        c = self._legacy_conn()
        try:
            ensure_schema(c)
            # Second call must be a no-op — the ALTER TABLE swallows
            # OperationalError when the column already exists.
            ensure_schema(c)
            cols = {
                row[1]
                for row in c.execute("PRAGMA table_info(work_items)").fetchall()
            }
            assert "reviewer_round" in cols
        finally:
            c.close()

    def test_ensure_schema_is_idempotent_on_fresh_schema(self):
        # Fresh schemas already include reviewer_round; the ALTER
        # TABLE call must still no-op without raising.
        c = sqlite3.connect(":memory:")
        c.row_factory = sqlite3.Row
        try:
            ensure_schema(c)
            ensure_schema(c)
            cols = {
                row[1]
                for row in c.execute("PRAGMA table_info(work_items)").fetchall()
            }
            assert "reviewer_round" in cols
        finally:
            c.close()

    def test_inserts_after_migration_carry_caller_reviewer_round(self):
        # End-to-end: legacy DB → ensure_schema → registry helper
        # writes a row with reviewer_round=4 → registry helper reads
        # it back at 4.
        c = self._legacy_conn()
        try:
            ensure_schema(c)
            dwr.insert_work_item(
                c,
                _valid_work_item(
                    work_item_id="WI-after-migration",
                    reviewer_round=4,
                ),
            )
            fetched = dwr.get_work_item(c, "WI-after-migration")
            assert fetched is not None
            assert fetched.reviewer_round == 4
        finally:
            c.close()


# ---------------------------------------------------------------------------
# 8. GoalRecord typed shape + validation
# ---------------------------------------------------------------------------


class TestGoalRecordShape:
    def test_construct_minimal_valid(self):
        rec = _valid_goal()
        assert rec.goal_id == "G-001"
        assert rec.desired_end_state == "ship the slice"
        assert rec.status == "active"
        assert rec.autonomy_budget == 0
        assert rec.continuation_rules_json == "[]"
        assert rec.stop_conditions_json == "[]"
        assert rec.escalation_boundaries_json == "[]"
        assert rec.user_decision_boundaries_json == "[]"

    def test_record_is_frozen(self):
        rec = _valid_goal()
        with pytest.raises(Exception):
            rec.status = "complete"  # type: ignore[misc]

    @pytest.mark.parametrize(
        "status", ["active", "awaiting_user", "complete", "blocked_external"]
    )
    def test_all_legal_statuses_accepted(self, status):
        rec = _valid_goal(status=status)
        assert rec.status == status

    def test_unknown_status_rejected(self):
        with pytest.raises(ValueError):
            _valid_goal(status="banana")

    def test_status_vocabulary_matches_contracts_export(self):
        # Every legal contracts.GoalContract status must round-trip
        # through GoalRecord — the registry shares the vocabulary.
        for status in GOAL_STATUSES:
            rec = _valid_goal(status=status)
            assert rec.status == status

    @pytest.mark.parametrize("attr", ["goal_id", "desired_end_state"])
    def test_empty_required_string_rejected(self, attr):
        with pytest.raises(ValueError):
            _valid_goal(**{attr: ""})  # type: ignore[arg-type]

    def test_autonomy_budget_must_be_non_negative(self):
        ok = _valid_goal(autonomy_budget=0)
        assert ok.autonomy_budget == 0
        ok2 = _valid_goal(autonomy_budget=10)
        assert ok2.autonomy_budget == 10
        with pytest.raises(ValueError):
            _valid_goal(autonomy_budget=-1)

    def test_autonomy_budget_must_be_int(self):
        with pytest.raises(ValueError):
            _valid_goal(autonomy_budget=True)  # bool is subclass of int

    def test_negative_timestamps_rejected(self):
        with pytest.raises(ValueError):
            _valid_goal(created_at=-1)
        with pytest.raises(ValueError):
            _valid_goal(updated_at=-1)

    @pytest.mark.parametrize(
        "attr",
        [
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ],
    )
    def test_tuple_field_must_be_string(self, attr):
        with pytest.raises(ValueError):
            _valid_goal(**{attr: []})  # type: ignore[arg-type]
        with pytest.raises(ValueError):
            _valid_goal(**{attr: None})  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# 9. Goal persistence round-trip
# ---------------------------------------------------------------------------


class TestGoalPersistence:
    def test_insert_and_get_round_trip(self, conn):
        rec = _valid_goal(
            goal_id="G-RT-1",
            desired_end_state="land the persistence layer",
            autonomy_budget=5,
            continuation_rules_json='["rule-a","rule-b"]',
            stop_conditions_json='["cond-a"]',
            escalation_boundaries_json='["boundary-a"]',
            user_decision_boundaries_json='["udb-a"]',
        )
        stored = dwr.insert_goal(conn, rec)
        # Timestamps backfilled
        assert stored.created_at > 0
        assert stored.updated_at > 0

        fetched = dwr.get_goal(conn, "G-RT-1")
        assert fetched is not None
        assert fetched.goal_id == "G-RT-1"
        assert fetched.desired_end_state == "land the persistence layer"
        assert fetched.status == "active"
        assert fetched.autonomy_budget == 5
        assert fetched.continuation_rules_json == '["rule-a","rule-b"]'
        assert fetched.stop_conditions_json == '["cond-a"]'
        assert fetched.escalation_boundaries_json == '["boundary-a"]'
        assert fetched.user_decision_boundaries_json == '["udb-a"]'
        assert fetched.created_at == stored.created_at
        assert fetched.updated_at == stored.updated_at

    def test_get_missing_returns_none(self, conn):
        assert dwr.get_goal(conn, "G-missing") is None

    def test_insert_rejects_duplicate_goal_id(self, conn):
        dwr.insert_goal(conn, _valid_goal(goal_id="G-dup"))
        with pytest.raises(sqlite3.IntegrityError):
            dwr.insert_goal(
                conn,
                _valid_goal(goal_id="G-dup", desired_end_state="second attempt"),
            )

    def test_upsert_inserts_when_missing(self, conn):
        dwr.upsert_goal(
            conn,
            _valid_goal(goal_id="G-up1", desired_end_state="first"),
        )
        fetched = dwr.get_goal(conn, "G-up1")
        assert fetched is not None
        assert fetched.desired_end_state == "first"

    def test_upsert_updates_existing(self, conn):
        dwr.insert_goal(
            conn,
            _valid_goal(
                goal_id="G-up2",
                desired_end_state="old",
                status="active",
                autonomy_budget=0,
            ),
        )
        updated = dwr.upsert_goal(
            conn,
            _valid_goal(
                goal_id="G-up2",
                desired_end_state="new",
                status="awaiting_user",
                autonomy_budget=3,
                continuation_rules_json='["c"]',
            ),
        )
        fetched = dwr.get_goal(conn, "G-up2")
        assert fetched is not None
        assert fetched.desired_end_state == "new"
        assert fetched.status == "awaiting_user"
        assert fetched.autonomy_budget == 3
        assert fetched.continuation_rules_json == '["c"]'
        assert fetched.updated_at == updated.updated_at

    def test_list_returns_deterministic_order(self, conn):
        dwr.insert_goal(
            conn,
            _valid_goal(goal_id="G-B", created_at=200, updated_at=200),
        )
        dwr.insert_goal(
            conn,
            _valid_goal(goal_id="G-A", created_at=100, updated_at=100),
        )
        dwr.insert_goal(
            conn,
            _valid_goal(goal_id="G-C", created_at=300, updated_at=300),
        )
        listing = dwr.list_goals(conn)
        assert [r.goal_id for r in listing] == ["G-A", "G-B", "G-C"]

    def test_list_tiebreak_on_goal_id_when_created_at_equal(self, conn):
        dwr.insert_goal(
            conn,
            _valid_goal(goal_id="G-Z", created_at=100, updated_at=100),
        )
        dwr.insert_goal(
            conn,
            _valid_goal(goal_id="G-A", created_at=100, updated_at=100),
        )
        dwr.insert_goal(
            conn,
            _valid_goal(goal_id="G-M", created_at=100, updated_at=100),
        )
        listing = dwr.list_goals(conn)
        assert [r.goal_id for r in listing] == ["G-A", "G-M", "G-Z"]

    def test_list_filters_by_status(self, conn):
        dwr.insert_goal(
            conn, _valid_goal(goal_id="G-act", status="active")
        )
        dwr.insert_goal(
            conn, _valid_goal(goal_id="G-wait", status="awaiting_user")
        )
        dwr.insert_goal(
            conn, _valid_goal(goal_id="G-done", status="complete")
        )
        only_active = dwr.list_goals(conn, status="active")
        assert [r.goal_id for r in only_active] == ["G-act"]
        only_wait = dwr.list_goals(conn, status="awaiting_user")
        assert [r.goal_id for r in only_wait] == ["G-wait"]

    def test_list_empty_database_returns_empty_list(self, conn):
        assert dwr.list_goals(conn) == []

    def test_list_returns_list_not_tuple(self, conn):
        # Symmetric with list_decisions / list_work_items: helpers
        # in this module return mutable lists. The bridge layer is
        # the place that converts to tuples for downstream consumers.
        dwr.insert_goal(conn, _valid_goal(goal_id="G-list"))
        result = dwr.list_goals(conn)
        assert isinstance(result, list)

    def test_repeat_get_does_not_mutate_record(self, conn):
        original = dwr.insert_goal(
            conn, _valid_goal(goal_id="G-stable", autonomy_budget=7)
        )
        a = dwr.get_goal(conn, "G-stable")
        b = dwr.get_goal(conn, "G-stable")
        assert a == b == original

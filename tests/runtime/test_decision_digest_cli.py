"""Tests for ``cc-policy decision digest`` (read-only projection CLI).

@decision DEC-CLAUDEX-DECISION-DIGEST-CLI-TESTS-001
Title: The read-only decision-digest CLI is a thin adapter over the pure projection builder
Status: proposed (Phase 7 Slice 14 read-only CLI)
Rationale: The Slice 14 CLI surface (``_handle_decision`` in
  ``runtime/cli.py``) bridges the canonical decision store
  (``runtime.core.decision_work_registry.list_decisions``) and the pure
  projection builder
  (``runtime.core.decision_digest_projection``). All projection logic
  lives in the library; the CLI handles argparse binding, optional
  filter pass-through, DB connection management, and JSON payload
  shaping. These tests pin:

    1. Happy-path digest against a seeded on-disk SQLite DB returns
       exit 0 with ``status=ok`` and a full payload including
       ``rendered_body``, ``projection``, ``metadata``,
       ``decision_ids``, ``decision_count``, ``cutoff_epoch``,
       ``filters``, and ``repo_root``.
    2. The rendered ``rendered_body`` equals the pure builder's output
       for the same records, and ``projection.content_hash`` equals
       the pure builder's content hash — the CLI does not re-implement
       any rendering logic.
    3. ``--status`` and ``--scope`` filters are passed through to
       ``list_decisions`` and change ``decision_ids`` accordingly.
    4. ``--cutoff-epoch`` filters out decisions with
       ``updated_at < cutoff_epoch`` — they disappear from
       ``decision_ids``, ``decision_count``, ``rendered_body``, and
       ``projection.decision_ids``.
    5. Empty result (no decisions in window) is healthy, deterministic,
       and returns exit 0 with a placeholder ``rendered_body``.
    6. Read-only guarantee: row counts in the ``decisions`` table are
       unchanged across the CLI call.
    7. Invalid ``--cutoff-epoch`` / ``--generated-at`` inputs (non-int,
       negative) produce a ``decision digest:`` error on stderr with
       a non-zero exit.
    8. CLI module-level import surface does NOT import
       ``decision_digest_projection`` or ``decision_work_registry`` at
       module scope; the ``digest`` branch reaches both only via
       function-scope imports.
"""

from __future__ import annotations

import ast
import inspect
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import decision_digest_projection as ddp
from runtime.core import decision_work_registry as dwr
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")


# ---------------------------------------------------------------------------
# Helpers — deterministic seeded DB and subprocess invocation
# ---------------------------------------------------------------------------


def _make_decision(
    *,
    decision_id: str,
    title: str = "T",
    status: str = "accepted",
    rationale: str = "R",
    version: int = 1,
    author: str = "planner",
    scope: str = "kernel",
    created_at: int = 1_000,
    updated_at: int = 1_000,
) -> dwr.DecisionRecord:
    return dwr.DecisionRecord(
        decision_id=decision_id,
        title=title,
        status=status,
        rationale=rationale,
        version=version,
        author=author,
        scope=scope,
        created_at=created_at,
        updated_at=updated_at,
    )


@pytest.fixture
def seeded_db(tmp_path: Path) -> Path:
    """Create an on-disk SQLite DB pre-populated with three decisions.

    Decisions cover multiple statuses, scopes, and updated_at values so
    filter and cutoff tests can partition them without extra setup.
    """
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        dwr.insert_decision(
            conn,
            _make_decision(
                decision_id="DEC-A",
                title="Alpha decision",
                status="accepted",
                scope="kernel",
                created_at=100,
                updated_at=1_000,
            ),
        )
        dwr.insert_decision(
            conn,
            _make_decision(
                decision_id="DEC-B",
                title="Beta decision",
                status="proposed",
                scope="kernel",
                created_at=200,
                updated_at=2_000,
            ),
        )
        dwr.insert_decision(
            conn,
            _make_decision(
                decision_id="DEC-C",
                title="Gamma decision",
                status="accepted",
                scope="projection",
                created_at=300,
                updated_at=3_000,
            ),
        )
        conn.commit()
    finally:
        conn.close()
    return db_path


def _run_cli(args: list[str], db_path: Path) -> tuple[int, dict, str, str]:
    """Invoke cc-policy via subprocess; return (rc, parsed_json, stdout, stderr)."""
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
    }
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    output = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output}
    return result.returncode, parsed, result.stdout, result.stderr


def _digest_args(
    *,
    cutoff_epoch: int | str | None = 0,
    generated_at: int | str | None = 1_700_000_000,
    status: str | None = None,
    scope: str | None = None,
) -> list[str]:
    args = ["decision", "digest"]
    if cutoff_epoch is not None:
        args.extend(["--cutoff-epoch", str(cutoff_epoch)])
    if generated_at is not None:
        args.extend(["--generated-at", str(generated_at)])
    if status is not None:
        args.extend(["--status", status])
    if scope is not None:
        args.extend(["--scope", scope])
    return args


def _digest_check_args(
    *,
    candidate_path: Path,
    cutoff_epoch: int | str | None = 0,
    status: str | None = None,
    scope: str | None = None,
) -> list[str]:
    args = [
        "decision",
        "digest-check",
        "--candidate-path",
        str(candidate_path),
    ]
    if cutoff_epoch is not None:
        args.extend(["--cutoff-epoch", str(cutoff_epoch)])
    if status is not None:
        args.extend(["--status", status])
    if scope is not None:
        args.extend(["--scope", scope])
    return args


def _read_decisions(db_path: Path) -> list[dwr.DecisionRecord]:
    """Open a read-only connection and return the decisions in canonical order."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        return dwr.list_decisions(conn)
    finally:
        conn.close()


def _count_decisions(db_path: Path) -> int:
    conn = sqlite3.connect(str(db_path))
    try:
        row = conn.execute("SELECT COUNT(*) AS n FROM decisions").fetchone()
        return int(row[0])
    finally:
        conn.close()


def _imported_module_names(module) -> tuple[set[str], set[str]]:
    """Return (module_level_names, function_level_names).

    module_level_names: imports at the top level of the module body.
    function_level_names: imports anywhere inside a ``def``/``async def``.
    """
    tree = ast.parse(inspect.getsource(module))
    module_level: set[str] = set()
    function_level: set[str] = set()

    def _collect(node, target: set[str]) -> None:
        for child in ast.walk(node):
            if isinstance(child, ast.Import):
                for alias in child.names:
                    target.add(alias.name)
            elif isinstance(child, ast.ImportFrom):
                name = child.module or ""
                if name:
                    target.add(name)
                    for alias in child.names:
                        target.add(f"{name}.{alias.name}")

    # Module-level body excluding function/class bodies.
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            _collect(node, module_level)

    # Function-level: walk every function and collect imports inside.
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            _collect(node, function_level)

    return module_level, function_level


# ---------------------------------------------------------------------------
# 1. Happy-path digest
# ---------------------------------------------------------------------------


class TestHappyPath:
    def test_exit_zero_and_status_ok(self, seeded_db: Path):
        rc, payload, _stdout, _stderr = _run_cli(_digest_args(), seeded_db)
        assert rc == 0, f"non-zero exit; payload={payload}"
        assert payload["status"] == "ok"
        assert payload["healthy"] is True

    def test_payload_has_all_required_top_level_keys(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(_digest_args(), seeded_db)
        assert rc == 0
        required = {
            "status",
            "healthy",
            "rendered_body",
            "projection",
            "metadata",
            "decision_count",
            "decision_ids",
            "cutoff_epoch",
            "filters",
            "repo_root",
            "db_read_mode",
        }
        assert required <= set(payload.keys()), (
            f"missing keys: {required - set(payload.keys())}"
        )

    def test_db_read_mode_is_valid_value(self, seeded_db: Path):
        """Successful payload must report which read-only path served the read.

        On a writable seeded DB we expect the primary ``mode=ro`` path to
        succeed; we accept ``ro_immutable`` as well so the test remains
        robust across sandboxes where the immutable fallback is the only
        path that avoids WAL/SHM sidecar creation.
        """
        rc, payload, _, _ = _run_cli(_digest_args(), seeded_db)
        assert rc == 0
        assert payload["db_read_mode"] in {"ro", "ro_immutable"}

    def test_decision_ids_contains_all_three_seeded(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(_digest_args(), seeded_db)
        assert rc == 0
        assert set(payload["decision_ids"]) == {"DEC-A", "DEC-B", "DEC-C"}
        assert payload["decision_count"] == 3

    def test_cutoff_epoch_echoed(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=500), seeded_db
        )
        assert rc == 0
        assert payload["cutoff_epoch"] == 500
        assert payload["projection"]["cutoff_epoch"] == 500

    def test_generated_at_echoed_in_metadata(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(
            _digest_args(generated_at=1_700_000_000), seeded_db
        )
        assert rc == 0
        assert payload["metadata"]["generated_at"] == 1_700_000_000

    def test_metadata_watches_canonical_decision_authority(
        self, seeded_db: Path
    ):
        rc, payload, _, _ = _run_cli(_digest_args(), seeded_db)
        assert rc == 0
        stale = payload["metadata"]["stale_condition"]
        assert stale["watched_authorities"] == ["decision_records"]
        assert stale["watched_files"] == [
            "runtime/core/decision_work_registry.py"
        ]

    def test_filters_echoed_without_filters(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(_digest_args(), seeded_db)
        assert rc == 0
        assert payload["filters"] == {"status": None, "scope": None}


# ---------------------------------------------------------------------------
# 2. CLI output matches pure-builder output (no re-implementation)
# ---------------------------------------------------------------------------


class TestBuilderEquivalence:
    def test_rendered_body_equals_pure_builder(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=0, generated_at=1_700_000_000),
            seeded_db,
        )
        assert rc == 0
        decisions = _read_decisions(seeded_db)
        expected_body = ddp.render_decision_digest(
            decisions, cutoff_epoch=0
        )
        assert payload["rendered_body"] == expected_body

    def test_projection_content_hash_equals_pure_builder(
        self, seeded_db: Path
    ):
        rc, payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=0, generated_at=1_700_000_000),
            seeded_db,
        )
        assert rc == 0
        decisions = _read_decisions(seeded_db)
        expected = ddp.build_decision_digest_projection(
            decisions, generated_at=1_700_000_000, cutoff_epoch=0
        )
        assert (
            payload["projection"]["content_hash"] == expected.content_hash
        )
        assert payload["projection"]["decision_ids"] == list(
            expected.decision_ids
        )

    def test_two_invocations_with_identical_inputs_are_byte_identical(
        self, seeded_db: Path
    ):
        rc1, p1, _, _ = _run_cli(
            _digest_args(cutoff_epoch=0, generated_at=1_700_000_000),
            seeded_db,
        )
        rc2, p2, _, _ = _run_cli(
            _digest_args(cutoff_epoch=0, generated_at=1_700_000_000),
            seeded_db,
        )
        assert rc1 == 0 and rc2 == 0
        assert p1 == p2


# ---------------------------------------------------------------------------
# 3. Filter pass-through — status and scope
# ---------------------------------------------------------------------------


class TestFilters:
    def test_status_filter_narrows_decision_ids(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(
            _digest_args(status="accepted"), seeded_db
        )
        assert rc == 0
        assert set(payload["decision_ids"]) == {"DEC-A", "DEC-C"}
        assert payload["decision_count"] == 2
        assert payload["filters"] == {"status": "accepted", "scope": None}

    def test_scope_filter_narrows_decision_ids(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(
            _digest_args(scope="kernel"), seeded_db
        )
        assert rc == 0
        assert set(payload["decision_ids"]) == {"DEC-A", "DEC-B"}
        assert payload["decision_count"] == 2
        assert payload["filters"] == {"status": None, "scope": "kernel"}

    def test_status_and_scope_filters_combine(self, seeded_db: Path):
        rc, payload, _, _ = _run_cli(
            _digest_args(status="accepted", scope="kernel"), seeded_db
        )
        assert rc == 0
        assert payload["decision_ids"] == ["DEC-A"]
        assert payload["filters"] == {
            "status": "accepted",
            "scope": "kernel",
        }

    def test_nonmatching_filters_produce_healthy_empty_output(
        self, seeded_db: Path
    ):
        rc, payload, _, _ = _run_cli(
            _digest_args(status="rejected"), seeded_db
        )
        assert rc == 0
        assert payload["healthy"] is True
        assert payload["decision_ids"] == []
        assert payload["decision_count"] == 0
        assert "No decisions within cutoff window" in payload["rendered_body"]


# ---------------------------------------------------------------------------
# 4. Cutoff filters older decisions
# ---------------------------------------------------------------------------


class TestCutoffFiltering:
    def test_cutoff_between_two_updated_at_values_drops_older(
        self, seeded_db: Path
    ):
        # updated_at values: DEC-A=1_000, DEC-B=2_000, DEC-C=3_000.
        # cutoff=2_000 keeps DEC-B and DEC-C; DEC-A must drop.
        rc, payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=2_000), seeded_db
        )
        assert rc == 0
        assert set(payload["decision_ids"]) == {"DEC-B", "DEC-C"}
        assert payload["decision_count"] == 2
        assert "DEC-A" not in payload["rendered_body"]
        assert "DEC-B" in payload["rendered_body"]
        assert "DEC-C" in payload["rendered_body"]

    def test_cutoff_above_all_updated_at_values_drops_everything(
        self, seeded_db: Path
    ):
        rc, payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=10_000), seeded_db
        )
        assert rc == 0
        assert payload["decision_ids"] == []
        assert payload["decision_count"] == 0
        assert "No decisions within cutoff window" in payload["rendered_body"]

    def test_cutoff_inclusive_lower_bound_keeps_boundary_decision(
        self, seeded_db: Path
    ):
        rc, payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=1_000), seeded_db
        )
        assert rc == 0
        # Inclusive: updated_at == cutoff is kept.
        assert "DEC-A" in payload["decision_ids"]


# ---------------------------------------------------------------------------
# 5. Empty result remains healthy and deterministic
# ---------------------------------------------------------------------------


class TestEmptyResult:
    def test_empty_db_is_healthy_with_placeholder_body(self, tmp_path: Path):
        db_path = tmp_path / "empty.db"
        conn = sqlite3.connect(str(db_path))
        try:
            ensure_schema(conn)
            conn.commit()
        finally:
            conn.close()
        rc, payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=0, generated_at=1_700_000_000),
            db_path,
        )
        assert rc == 0
        assert payload["status"] == "ok"
        assert payload["healthy"] is True
        assert payload["decision_ids"] == []
        assert payload["decision_count"] == 0
        assert "No decisions within cutoff window" in payload["rendered_body"]


# ---------------------------------------------------------------------------
# 6. Read-only — CLI never mutates the decisions table
# ---------------------------------------------------------------------------


def _run_cli_raw(args: list[str], db_env_path: Path) -> subprocess.CompletedProcess:
    """Invoke cc-policy and return the raw CompletedProcess for low-level assertions."""
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_env_path),
    }
    return subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )


class TestReadOnly:
    def test_decisions_row_count_unchanged_across_cli_call(
        self, seeded_db: Path
    ):
        before = _count_decisions(seeded_db)
        rc, _payload, _, _ = _run_cli(
            _digest_args(cutoff_epoch=0, generated_at=1_700_000_000),
            seeded_db,
        )
        assert rc == 0
        after = _count_decisions(seeded_db)
        assert before == after == 3

    def test_decisions_rows_unchanged_across_cli_call(
        self, seeded_db: Path
    ):
        before = _read_decisions(seeded_db)
        rc, _payload, _, _ = _run_cli(_digest_args(), seeded_db)
        assert rc == 0
        after = _read_decisions(seeded_db)
        assert [r.decision_id for r in before] == [
            r.decision_id for r in after
        ]
        assert [r.updated_at for r in before] == [
            r.updated_at for r in after
        ]

    def test_missing_db_path_errors_cleanly_without_creating_file(
        self, tmp_path: Path
    ):
        """A non-existent DB path must surface as a JSON error and must
        NOT cause the CLI to create the file or its parent directory.

        This pins the read-only contract the Slice 14 correction
        enforced: the handler must open the DB via SQLite URI
        ``mode=ro`` rather than the mutating ``connect() + ensure_schema()``
        bootstrap helper. A sandboxed caller (e.g. the Codex supervisor)
        cannot be crashed by an unwritable DB path — they get a clean
        JSON error they can handle.
        """
        missing = tmp_path / "does-not-exist" / "state.db"
        assert not missing.exists()
        assert not missing.parent.exists()

        proc = _run_cli_raw(
            _digest_args(cutoff_epoch=0, generated_at=1), missing
        )
        # Exit non-zero with JSON error on stderr.
        assert proc.returncode != 0
        stderr = proc.stderr.strip()
        payload = json.loads(stderr)
        assert payload["status"] == "error"
        assert "decision digest" in payload["message"]
        assert "read-only" in payload["message"] or "unable to open" in payload["message"]
        # Critically: no file creation, no parent-dir creation.
        assert not missing.exists(), (
            f"decision digest CLI created DB file at {missing} — "
            f"violates read-only contract"
        )
        assert not missing.parent.exists(), (
            f"decision digest CLI created parent dir {missing.parent} — "
            f"violates read-only contract"
        )

    def test_empty_schemaless_db_errors_without_creating_tables(
        self, tmp_path: Path
    ):
        """A DB file that exists but has NO schema must surface as a
        JSON error and must NOT be mutated (no tables created).

        The Slice 14 correction swapped ``_get_conn()`` (which calls
        ``ensure_schema()``) for a pure ``mode=ro`` URI connection. An
        empty DB under read-only mode therefore cannot be bootstrapped
        into a schema by the projection handler — the caller sees an
        error and the DB file stays zero-table.
        """
        empty_db = tmp_path / "bare.db"
        # Create an empty file that SQLite will recognise as a fresh
        # (schemaless) database. sqlite3.connect on an empty path
        # produces a valid empty DB; here we just touch the file so
        # SQLite has something to open read-only.
        conn = sqlite3.connect(str(empty_db))
        conn.close()
        assert empty_db.exists()
        # Confirm there are no user tables before the CLI call.
        conn = sqlite3.connect(str(empty_db))
        try:
            rows_before = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        finally:
            conn.close()
        assert rows_before == [], (
            "precondition: the empty DB must start schemaless"
        )

        proc = _run_cli_raw(
            _digest_args(cutoff_epoch=0, generated_at=1), empty_db
        )
        assert proc.returncode != 0
        payload = json.loads(proc.stderr.strip())
        assert payload["status"] == "error"
        assert "decision digest" in payload["message"]

        # The DB must still have no tables after the CLI call — the
        # handler must NOT have run ``ensure_schema()`` against it.
        conn = sqlite3.connect(str(empty_db))
        try:
            rows_after = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        finally:
            conn.close()
        assert rows_after == [], (
            f"decision digest CLI created tables in an empty DB: "
            f"{[r[0] for r in rows_after]} — violates read-only contract"
        )

    def test_read_only_cli_does_not_create_wal_sidecar(
        self, tmp_path: Path
    ):
        """A read-only connection must not switch the DB to WAL mode
        (which would create a ``<db>-wal`` sidecar file).

        The Slice 14 correction explicitly does not set WAL. This
        assertion ensures the DB directory is not touched with a
        journal-mode change by the read-only handler.
        """
        db_path = tmp_path / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            ensure_schema(conn)
            dwr.insert_decision(
                conn,
                _make_decision(
                    decision_id="DEC-ONLY",
                    title="only",
                    status="accepted",
                    scope="kernel",
                    created_at=1,
                    updated_at=1,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        wal_sidecar = db_path.parent / (db_path.name + "-wal")
        # The seeding connection above uses default (rollback-journal)
        # mode and therefore should not leave a ``-wal`` file behind.
        assert not wal_sidecar.exists(), (
            "precondition: seeded DB should not already have a WAL sidecar"
        )

        rc, payload, _, _ = _run_cli(_digest_args(), db_path)
        assert rc == 0
        assert payload["decision_ids"] == ["DEC-ONLY"]

        # The read-only CLI invocation must not have produced a WAL
        # sidecar file on the seeded DB.
        assert not wal_sidecar.exists(), (
            f"decision digest CLI created WAL sidecar at {wal_sidecar} — "
            f"violates read-only contract"
        )


# ---------------------------------------------------------------------------
# 7. Invalid input — non-int / negative cutoff-epoch and generated-at
# ---------------------------------------------------------------------------


class TestInputValidation:
    def test_nonint_cutoff_epoch_errors_cleanly(self, seeded_db: Path):
        rc, payload, _stdout, stderr = _run_cli(
            _digest_args(cutoff_epoch="not-an-int"), seeded_db
        )
        assert rc != 0
        assert payload["status"] == "error"
        assert "--cutoff-epoch" in payload["message"]

    def test_negative_cutoff_epoch_errors_cleanly(self, seeded_db: Path):
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_args(cutoff_epoch=-1), seeded_db
        )
        assert rc != 0
        assert payload["status"] == "error"
        assert "non-negative" in payload["message"]

    def test_nonint_generated_at_errors_cleanly(self, seeded_db: Path):
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_args(generated_at="yesterday"), seeded_db
        )
        assert rc != 0
        assert payload["status"] == "error"
        assert "--generated-at" in payload["message"]

    def test_negative_generated_at_errors_cleanly(self, seeded_db: Path):
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_args(generated_at=-5), seeded_db
        )
        assert rc != 0
        assert payload["status"] == "error"
        assert "non-negative" in payload["message"]


# ---------------------------------------------------------------------------
# 8. CLI import discipline — module-level vs function-level
# ---------------------------------------------------------------------------


class TestCliImportDiscipline:
    def test_cli_does_not_import_projection_at_module_level(self):
        import runtime.cli as cli

        module_level, _function_level = _imported_module_names(cli)
        for name in module_level:
            assert "decision_digest_projection" not in name, (
                f"runtime/cli.py imports {name!r} at module scope — "
                f"decision_digest_projection must stay function-scoped "
                f"so the CLI module-load graph does not depend on it"
            )

    def test_cli_does_not_import_registry_at_module_level(self):
        import runtime.cli as cli

        module_level, _function_level = _imported_module_names(cli)
        for name in module_level:
            assert "decision_work_registry" not in name, (
                f"runtime/cli.py imports {name!r} at module scope — "
                f"decision_work_registry must stay function-scoped "
                f"so the CLI module-load graph does not depend on it"
            )

    def test_cli_does_import_projection_at_function_level(self):
        # Sanity: this slice is expected to introduce a function-scope
        # import of decision_digest_projection inside _handle_decision.
        import runtime.cli as cli

        _module_level, function_level = _imported_module_names(cli)
        assert any(
            "decision_digest_projection" in name for name in function_level
        ), (
            "expected runtime/cli.py to use a function-scope import of "
            "runtime.core.decision_digest_projection (Phase 7 Slice 14)"
        )

    def test_cli_does_import_registry_at_function_level(self):
        import runtime.cli as cli

        _module_level, function_level = _imported_module_names(cli)
        assert any(
            "decision_work_registry" in name for name in function_level
        ), (
            "expected runtime/cli.py to use a function-scope import of "
            "runtime.core.decision_work_registry (Phase 7 Slice 14)"
        )


# ---------------------------------------------------------------------------
# 9. decision digest-check — Phase 7 Slice 15 drift validation
# ---------------------------------------------------------------------------


class TestDigestCheck:
    """Pin ``cc-policy decision digest-check`` behaviour.

    The subcommand is a thin adapter over
    :func:`decision_digest_projection.validate_decision_digest`: all
    drift comparison logic is in the pure validator. These tests pin
    the adapter contract (argparse wiring, candidate file read, DB
    read-only semantics, payload shape, exit codes).
    """

    def _write_candidate(
        self,
        tmp_path: Path,
        decisions,
        *,
        cutoff_epoch: int,
        name: str = "candidate.md",
    ) -> Path:
        body = ddp.render_decision_digest(
            decisions, cutoff_epoch=cutoff_epoch
        )
        p = tmp_path / name
        p.write_text(body, encoding="utf-8")
        return p

    # -- Happy round trip --------------------------------------------------

    def test_healthy_round_trip_exits_zero(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        candidate = self._write_candidate(
            tmp_path, decisions, cutoff_epoch=0
        )
        rc, payload, _stdout, stderr = _run_cli(
            _digest_check_args(candidate_path=candidate, cutoff_epoch=0),
            seeded_db,
        )
        assert rc == 0, (
            f"expected healthy round-trip; stderr={stderr!r} "
            f"payload={payload}"
        )
        assert payload["status"] == "ok"
        assert payload["report"]["status"] == "ok"
        assert payload["report"]["healthy"] is True
        assert payload["report"]["exact_match"] is True
        assert payload["report"]["first_mismatch"] is None

    def test_healthy_payload_has_all_required_top_level_keys(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        candidate = self._write_candidate(
            tmp_path, decisions, cutoff_epoch=0
        )
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(candidate_path=candidate), seeded_db
        )
        assert rc == 0
        required = {
            "status",
            "report",
            "candidate_path",
            "decision_count",
            "decision_ids",
            "cutoff_epoch",
            "filters",
            "db_read_mode",
            "repo_root",
        }
        assert required <= set(payload.keys()), (
            f"missing keys: {required - set(payload.keys())}"
        )

    def test_db_read_mode_is_valid_value(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        candidate = self._write_candidate(
            tmp_path, decisions, cutoff_epoch=0
        )
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(candidate_path=candidate), seeded_db
        )
        assert rc == 0
        assert payload["db_read_mode"] in {"ro", "ro_immutable"}

    def test_candidate_path_echoed_absolute(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        candidate = self._write_candidate(
            tmp_path, decisions, cutoff_epoch=0
        )
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(candidate_path=candidate), seeded_db
        )
        assert rc == 0
        assert payload["candidate_path"] == str(candidate.resolve())

    # -- Trailing-newline tolerance ----------------------------------------

    def test_missing_trailing_newline_still_healthy(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        body = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        # Strip the canonical trailing newline; the validator must pad
        # it back up rather than report drift.
        p = tmp_path / "candidate-stripped.md"
        p.write_text(body.rstrip("\n"), encoding="utf-8")
        rc, payload, _stdout, stderr = _run_cli(
            _digest_check_args(candidate_path=p), seeded_db
        )
        assert rc == 0, f"stderr={stderr!r} payload={payload}"
        assert payload["report"]["status"] == "ok"
        assert payload["report"]["healthy"] is True

    # -- Drift -------------------------------------------------------------

    def test_tampered_candidate_exits_one_with_violation(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        body = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        # Swap one decision title.
        tampered = body.replace("Gamma decision", "Gamma decision (tampered)")
        assert tampered != body
        p = tmp_path / "tampered.md"
        p.write_text(tampered, encoding="utf-8")
        rc, payload, stdout, _stderr = _run_cli(
            _digest_check_args(candidate_path=p), seeded_db
        )
        assert rc == 1, f"expected drift exit 1; stdout={stdout!r}"
        assert payload["status"] == "violation"
        assert payload["report"]["status"] == "drift"
        assert payload["report"]["healthy"] is False
        assert payload["report"]["first_mismatch"] is not None

    # -- Filters bind to expected body -------------------------------------

    def test_status_filter_changes_expected_body(
        self, seeded_db: Path, tmp_path: Path
    ):
        """Candidate built from one filter must not validate against another.

        Render a candidate from the full decision set. Re-render the
        expected body under ``--status=accepted``. Running digest-check
        with ``--status=accepted`` against the all-decisions candidate
        must report drift because the CLI re-queries the DB with the
        same filter as the caller.
        """
        decisions_all = _read_decisions(seeded_db)
        candidate = self._write_candidate(
            tmp_path, decisions_all, cutoff_epoch=0, name="all.md"
        )
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(
                candidate_path=candidate, status="accepted"
            ),
            seeded_db,
        )
        assert rc == 1
        assert payload["status"] == "violation"
        assert payload["filters"] == {"status": "accepted", "scope": None}
        # DEC-B is proposed, so it is filtered out of the expected body.
        assert "DEC-B" not in payload["decision_ids"]

    def test_scope_filter_round_trip_healthy(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        filtered = [r for r in decisions if r.scope == "kernel"]
        candidate = self._write_candidate(
            tmp_path, filtered, cutoff_epoch=0, name="kernel.md"
        )
        rc, payload, _stdout, stderr = _run_cli(
            _digest_check_args(candidate_path=candidate, scope="kernel"),
            seeded_db,
        )
        assert rc == 0, f"stderr={stderr!r} payload={payload}"
        assert payload["report"]["healthy"] is True
        assert set(payload["decision_ids"]) == {"DEC-A", "DEC-B"}

    def test_cutoff_epoch_binds_to_expected_body(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        # Candidate rendered at cutoff=2500 drops DEC-A and DEC-B.
        candidate = self._write_candidate(
            tmp_path, decisions, cutoff_epoch=2_500, name="cutoff.md"
        )
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(candidate_path=candidate, cutoff_epoch=2_500),
            seeded_db,
        )
        assert rc == 0
        assert payload["cutoff_epoch"] == 2_500
        assert payload["decision_ids"] == ["DEC-C"]

    # -- Error paths -------------------------------------------------------

    def test_missing_candidate_path_errors_cleanly(
        self, seeded_db: Path, tmp_path: Path
    ):
        missing = tmp_path / "does-not-exist.md"
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(candidate_path=missing), seeded_db
        )
        assert rc != 0
        assert payload["status"] == "error"
        assert "digest-check" in payload["message"]
        assert "not found" in payload["message"]

    def test_candidate_is_a_directory_errors_cleanly(
        self, seeded_db: Path, tmp_path: Path
    ):
        # ``is_file()`` rejects directories — adapter must not crash on them.
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(candidate_path=tmp_path), seeded_db
        )
        assert rc != 0
        assert payload["status"] == "error"
        assert "digest-check" in payload["message"]

    def test_nonint_cutoff_epoch_errors_cleanly(
        self, seeded_db: Path, tmp_path: Path
    ):
        decisions = _read_decisions(seeded_db)
        candidate = self._write_candidate(
            tmp_path, decisions, cutoff_epoch=0
        )
        rc, payload, _stdout, _stderr = _run_cli(
            _digest_check_args(
                candidate_path=candidate, cutoff_epoch="not-an-int"
            ),
            seeded_db,
        )
        assert rc != 0
        assert payload["status"] == "error"
        assert "--cutoff-epoch" in payload["message"]

    def test_missing_db_errors_without_creating_file(self, tmp_path: Path):
        """DB-missing sandbox repro for digest-check mirrors digest."""
        decisions = []  # validator won't be reached
        candidate = self._write_candidate(
            tmp_path, decisions, cutoff_epoch=0, name="cand.md"
        )
        missing_db = tmp_path / "missing.db"
        env = {
            **os.environ,
            "PYTHONPATH": str(_REPO_ROOT),
            "CLAUDE_POLICY_DB": str(missing_db),
        }
        result = subprocess.run(
            [sys.executable, _CLI] + _digest_check_args(
                candidate_path=candidate
            ),
            capture_output=True,
            text=True,
            env=env,
        )
        assert result.returncode != 0
        payload = json.loads(result.stderr.strip() or result.stdout.strip())
        assert payload["status"] == "error"
        assert "digest-check" in payload["message"]
        assert "read-only" in payload["message"] or "unable to open" in payload["message"]
        assert not missing_db.exists()

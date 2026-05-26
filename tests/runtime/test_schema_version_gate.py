"""Regression tests for v6 runtime DB major-version gating."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
from pathlib import Path

from runtime.core.db import connect
from runtime.schemas import ensure_schema, exercise_schema_upgrade, schema_status

ROOT = Path(__file__).resolve().parent.parent.parent


def _legacy_critic_runs(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE critic_runs (
            run_id TEXT PRIMARY KEY,
            workflow_id TEXT NOT NULL,
            lease_id TEXT,
            role TEXT NOT NULL,
            provider TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        INSERT INTO critic_runs (
            run_id, workflow_id, role, provider, status, started_at, updated_at
        ) VALUES (
            'old-run', 'wf-old', 'critic', 'codex', 'completed', 1, 1
        );
        """
    )
    conn.commit()


def _table_columns(db_path: Path, table: str) -> set[str]:
    with sqlite3.connect(db_path) as conn:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def _metadata_value(db_path: Path, key: str) -> str:
    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            "SELECT value FROM schema_metadata WHERE key = ?",
            (key,),
        ).fetchone()
    return str(row[0]) if row else ""


def test_unversioned_legacy_db_is_archived_and_recreated_as_v6(tmp_path: Path) -> None:
    db_path = tmp_path / "state.db"
    with sqlite3.connect(db_path) as conn:
        _legacy_critic_runs(conn)

    conn = connect(db_path)
    ensure_schema(conn)
    status = schema_status(conn)
    conn.close()

    assert status["schema_major"] == "6"
    assert _metadata_value(db_path, "last_reset_reason") == "schema_major_mismatch:missing"
    cols = _table_columns(db_path, "critic_runs")
    assert "stage_run_id" in cols
    assert "run_id" not in cols
    assert list(tmp_path.glob("state.db.pre-v6-*.bak"))


def test_claimed_v6_db_with_stale_shape_is_recreated_on_schema_error(tmp_path: Path) -> None:
    db_path = tmp_path / "state.db"
    with sqlite3.connect(db_path) as conn:
        conn.executescript(
            """
            CREATE TABLE schema_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            INSERT INTO schema_metadata (key, value, updated_at)
            VALUES ('schema_major', '6', 1);
            """
        )
        _legacy_critic_runs(conn)

    conn = connect(db_path)
    ensure_schema(conn)
    status = schema_status(conn)
    conn.close()

    assert status["schema_major"] == "6"
    assert _metadata_value(db_path, "last_reset_reason").startswith("schema_shape_error:")
    cols = _table_columns(db_path, "critic_runs")
    assert "stage_run_id" in cols
    assert "run_id" not in cols
    assert list(tmp_path.glob("state.db.pre-v6-*.bak"))


def test_schema_upgrade_exercise_uses_copy_and_proves_archive_reset(tmp_path: Path) -> None:
    source_db = tmp_path / "legacy.db"
    with sqlite3.connect(source_db) as conn:
        _legacy_critic_runs(conn)

    work_dir = tmp_path / "exercise"
    result = exercise_schema_upgrade(
        str(source_db),
        work_dir=str(work_dir),
        require_reset=True,
    )

    assert result["ok"] is True
    assert result["source_db"] == str(source_db)
    assert result["copy_db"] == str(work_dir / "state.db")
    assert result["before_schema_major"] == ""
    assert result["schema_major"] == "6"
    assert result["last_reset_reason"] == "schema_major_mismatch:missing"
    assert result["reset_exercised"] is True
    assert result["archive_exists"] is True
    assert "run_id" in _table_columns(source_db, "critic_runs")
    assert "stage_run_id" not in _table_columns(source_db, "critic_runs")


def test_schema_upgrade_exercise_require_reset_rejects_fresh_bootstrap_only(
    tmp_path: Path,
) -> None:
    current_db = tmp_path / "current.db"
    conn = connect(current_db)
    ensure_schema(conn)
    conn.close()

    result = exercise_schema_upgrade(
        str(current_db),
        work_dir=str(tmp_path / "exercise-current"),
        require_reset=True,
    )

    assert result["schema_major"] == "6"
    assert result["reset_exercised"] is False
    assert result["archive_exists"] is False
    assert result["ok"] is False


def test_schema_exercise_upgrade_cli_reports_required_proof(tmp_path: Path) -> None:
    source_db = tmp_path / "legacy-cli.db"
    with sqlite3.connect(source_db) as conn:
        _legacy_critic_runs(conn)

    proc = subprocess.run(
        [
            sys.executable,
            str(ROOT / "runtime" / "cli.py"),
            "schema",
            "exercise-upgrade",
            "--source-db",
            str(source_db),
            "--work-dir",
            str(tmp_path / "exercise-cli"),
            "--require-reset",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["status"] == "ok"
    assert payload["ok"] is True
    assert payload["before_schema_major"] == ""
    assert payload["schema_major"] == "6"
    assert payload["last_reset_reason"] == "schema_major_mismatch:missing"
    assert payload["archive_exists"] is True


def test_doctor_schema_upgrade_exercise_uses_stale_project_backup(
    tmp_path: Path,
) -> None:
    project = tmp_path / "project"
    claude_dir = project / ".claude"
    claude_dir.mkdir(parents=True)
    source_db = claude_dir / "state.db.pre-v6-test.bak"
    with sqlite3.connect(source_db) as conn:
        _legacy_critic_runs(conn)

    proc = subprocess.run(
        [
            sys.executable,
            str(ROOT / "runtime" / "cli.py"),
            "doctor",
            "--project-root",
            str(project),
            "--exercise-schema-upgrade",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    checks = {check["name"]: check for check in payload["checks"]}
    exercise_check = checks["schema_upgrade_exercise"]
    assert exercise_check["ok"] is True
    detail = json.loads(exercise_check["detail"])
    assert detail["schema_major"] == "6"
    assert detail["last_reset_reason"] == "schema_major_mismatch:missing"
    assert detail["archive_exists"] is True
    assert detail["reset_exercised"] is True
    assert "run_id" in _table_columns(source_db, "critic_runs")
    assert "stage_run_id" not in _table_columns(source_db, "critic_runs")

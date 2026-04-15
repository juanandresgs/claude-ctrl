from __future__ import annotations

import sqlite3
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = WORKSPACE_ROOT / "SCHEMA.sql"
DEFAULT_DB_PATH = WORKSPACE_ROOT / "state" / "braid2.db"


def connect(db_path: str | Path | None = None) -> sqlite3.Connection:
    path = Path(db_path) if db_path else DEFAULT_DB_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA_PATH.read_text(encoding="utf8"))
    conn.commit()


def open_db(db_path: str | Path | None = None) -> sqlite3.Connection:
    conn = connect(db_path)
    ensure_schema(conn)
    return conn


def row_to_dict(row: sqlite3.Row | None) -> dict | None:
    return dict(row) if row is not None else None


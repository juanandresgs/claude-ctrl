"""SQLite connection bootstrap helpers."""

from __future__ import annotations

from pathlib import Path
import sqlite3


def connect(db_path: Path) -> sqlite3.Connection:
    """Open a WAL-mode SQLite connection, creating parent dirs as needed."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def connect_memory() -> sqlite3.Connection:
    """Open an in-memory SQLite connection for tests."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn

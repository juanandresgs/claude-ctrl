"""Runtime configuration helpers."""

from __future__ import annotations

from pathlib import Path
import os


def default_db_path() -> Path:
    override = os.environ.get("CLAUDE_POLICY_DB")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".claude" / "state.db"

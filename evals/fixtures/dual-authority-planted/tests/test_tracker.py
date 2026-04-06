"""Tests for dual-authority-planted fixture src/tracker.py.

DEFECTIVE TEST SUITE: these tests mock the SQLite path entirely, so they only
exercise the flat-file fallback branch. The tests pass even if the SQLite
logic is broken. This is the second planted defect — mock-masking of the
primary authority.
"""

import sqlite3
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import tracker


def _mock_conn(row=None):
    conn = MagicMock(spec=sqlite3.Connection)
    cursor = MagicMock()
    cursor.fetchone.return_value = row
    conn.execute.return_value = cursor
    return conn


def test_get_role_returns_none_when_no_data(tmp_path):
    """get_role returns None when SQLite has no row and flat file is absent."""
    conn = _mock_conn(row=None)
    # Patch _TRACKER_FILE to a nonexistent path so flat file branch is skipped
    with patch.object(tracker, "_TRACKER_FILE", str(tmp_path / ".tracker")):
        result = tracker.get_role(conn, "/some/worktree")
    assert result is None


def test_get_role_returns_flat_file_value(tmp_path):
    """get_role falls back to flat file when SQLite has no row.

    DEFECT: this test only exercises the flat-file fallback, not the SQLite
    primary path. The SQLite path is mocked to return None.
    """
    conn = _mock_conn(row=None)
    tracker_file = tmp_path / ".tracker"
    tracker_file.write_text("implementer")
    with patch.object(tracker, "_TRACKER_FILE", str(tracker_file)):
        result = tracker.get_role(conn, "/some/worktree")
    assert result == "implementer"


def test_set_role_writes_to_flat_file(tmp_path):
    """set_role writes the role to the flat file.

    DEFECT: this test only checks the flat-file write, not the SQLite write.
    """
    conn = _mock_conn()
    tracker_file = tmp_path / ".tracker"
    with patch.object(tracker, "_TRACKER_FILE", str(tracker_file)):
        tracker.set_role(conn, "/some/worktree", "guardian")
    assert tracker_file.read_text() == "guardian"

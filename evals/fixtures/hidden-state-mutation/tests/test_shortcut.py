"""Tests for hidden-state-mutation fixture src/shortcut.py.

DEFECTIVE TEST SUITE: every test mocks sqlite3.connect so no real DB
connection is made. Tests pass but never validate actual state.db behavior.
The direct-connection defect is invisible to these tests.

PLANTED DEFECT: sqlite3.connect is mocked — tests pass but the non-isolated
state mutation pattern is never caught.
"""

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import src.shortcut as shortcut


def _mock_conn():
    conn = MagicMock(spec=["execute", "commit", "close"])
    return conn


def test_record_marker_executes_insert():
    """record_marker() calls INSERT OR REPLACE.

    DEFECT: sqlite3.connect is mocked — the real state.db is never touched,
    so the direct-connection violation is invisible.
    """
    mock_conn = _mock_conn()
    with patch("src.shortcut.sqlite3") as mock_sqlite3:
        mock_sqlite3.connect.return_value = mock_conn
        shortcut.record_marker("/some/worktree", "implementer")
    mock_conn.execute.assert_called_once()
    mock_conn.commit.assert_called_once()


def test_clear_marker_executes_delete():
    """clear_marker() calls DELETE.

    DEFECT: same sqlite3 mock — the direct ~/.claude/state.db path is
    never exercised.
    """
    mock_conn = _mock_conn()
    with patch("src.shortcut.sqlite3") as mock_sqlite3:
        mock_sqlite3.connect.return_value = mock_conn
        shortcut.clear_marker("/some/worktree")
    mock_conn.execute.assert_called_once()
    mock_conn.commit.assert_called_once()

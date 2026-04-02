"""Unit tests for runtime.core.bugs — canonical bug-filing pipeline.

Covers: fingerprinting, qualification, filing, deduplication, retry, listing,
and audit-event emission. All tests use in-memory SQLite so no external state
is touched. External todo.sh calls are mocked at the subprocess boundary.

@decision DEC-BUGS-001
Title: Bugs module test-first design
Status: accepted
Rationale: Tests define the contract before implementation. SQLite in-memory
  fixtures provide fast, isolated, repeatable coverage. subprocess is mocked
  at the boundary for todo.sh calls so tests do not require gh CLI or network.
  The compound-interaction test (test_file_bug_full_pipeline) exercises the
  real production sequence: qualify -> fingerprint -> SQLite upsert -> emit.
"""

from __future__ import annotations

import sys
import time
import unittest.mock as mock
from pathlib import Path

import pytest

# Add project root to sys.path so imports work
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.bugs as bugs
import runtime.core.events as events


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema."""
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def _make_todo_sh(tmp_path, succeed=True, issue_url="https://github.com/org/repo/issues/42"):
    """Create a stub todo.sh script for testing.

    Creates parent directories as needed so callers can pass subdirectory paths
    like ``tmp_path / "bad"`` without a preceding mkdir.
    """
    tmp_path = Path(tmp_path)
    tmp_path.mkdir(parents=True, exist_ok=True)
    script = tmp_path / "todo.sh"
    if succeed:
        script.write_text(f"#!/usr/bin/env bash\necho '{issue_url}'\nexit 0\n")
    else:
        script.write_text("#!/usr/bin/env bash\nexit 1\n")
    script.chmod(0o755)
    return str(script)


# ---------------------------------------------------------------------------
# qualify() tests
# ---------------------------------------------------------------------------


def test_qualify_real_bug():
    """enforcement_gap with evidence returns 'filed'."""
    result = bugs.qualify("enforcement_gap", "no linter for .md files", "lint.sh found no tool")
    assert result == "filed"


def test_qualify_feature_request():
    """bug_type not in allowed set returns 'rejected_non_bug'."""
    result = bugs.qualify("feature_idea", "add dark mode", "user wants it")
    assert result == "rejected_non_bug"


def test_qualify_fixed_now():
    """fixed_now=True short-circuits to 'fixed_now' regardless of bug_type."""
    result = bugs.qualify("crash", "segfault on startup", "backtrace present", fixed_now=True)
    assert result == "fixed_now"


def test_qualify_no_evidence():
    """Empty evidence returns 'rejected_non_bug'."""
    result = bugs.qualify("enforcement_gap", "some title", "")
    assert result == "rejected_non_bug"


def test_qualify_no_title():
    """Empty title returns 'rejected_non_bug'."""
    result = bugs.qualify("enforcement_gap", "", "found something")
    assert result == "rejected_non_bug"


def test_qualify_all_allowed_bug_types():
    """All documented bug_types are accepted."""
    allowed = [
        "enforcement_gap",
        "test_failure",
        "crash",
        "regression",
        "silent_failure",
        "config_error",
        "integration_bug",
        "state_corruption",
    ]
    for bt in allowed:
        result = bugs.qualify(bt, "some title", "some evidence")
        assert result == "filed", f"Expected 'filed' for bug_type={bt!r}, got {result!r}"


# ---------------------------------------------------------------------------
# fingerprint() tests
# ---------------------------------------------------------------------------


def test_fingerprint_stability():
    """Same inputs always produce the same fingerprint."""
    fp1 = bugs.fingerprint("crash", "hooks/lint.sh", "shellcheck crashed on file.sh")
    fp2 = bugs.fingerprint("crash", "hooks/lint.sh", "shellcheck crashed on file.sh")
    assert fp1 == fp2


def test_fingerprint_is_16_hex_chars():
    """Fingerprint is exactly 16 hex characters."""
    fp = bugs.fingerprint("enforcement_gap", "hooks/lint.sh", "no linter for .md")
    assert len(fp) == 16
    assert all(c in "0123456789abcdef" for c in fp)


def test_fingerprint_normalization_timestamps():
    """Timestamps in the title are stripped so the fingerprint is stable."""
    fp1 = bugs.fingerprint("crash", "component", "crash at epoch 1712345678")
    fp2 = bugs.fingerprint("crash", "component", "crash at epoch 9999999999")
    assert fp1 == fp2


def test_fingerprint_normalization_paths():
    """Absolute paths in the title are reduced to basename only."""
    fp1 = bugs.fingerprint("crash", "component", "error in /home/user/project/src/foo.py")
    fp2 = bugs.fingerprint("crash", "component", "error in /tmp/other/project/src/foo.py")
    # Same basename foo.py — fingerprints must match
    assert fp1 == fp2


def test_fingerprint_different_bug_types():
    """Different bug_types produce different fingerprints for same title."""
    fp1 = bugs.fingerprint("crash", "comp", "same title")
    fp2 = bugs.fingerprint("regression", "comp", "same title")
    assert fp1 != fp2


# ---------------------------------------------------------------------------
# file_bug() — success path
# ---------------------------------------------------------------------------


def test_file_bug_new(conn, tmp_path):
    """file_bug() creates a new bug row, returns disposition='filed' with issue_url."""
    todo_sh = _make_todo_sh(tmp_path, succeed=True)

    result = bugs.file_bug(
        conn,
        bug_type="enforcement_gap",
        title="test bug for filing",
        body="test body",
        scope="global",
        source_component="tests",
        file_path="",
        evidence="evidence text",
        todo_sh_path=todo_sh,
    )

    assert result["disposition"] == "filed"
    assert result["issue_url"] == "https://github.com/org/repo/issues/42"
    assert isinstance(result["fingerprint"], str) and len(result["fingerprint"]) == 16
    assert result["encounter_count"] == 1


def test_file_bug_new_row_persists_in_db(conn, tmp_path):
    """After filing, the bug row exists in SQLite with disposition='filed'."""
    todo_sh = _make_todo_sh(tmp_path, succeed=True)

    result = bugs.file_bug(
        conn,
        "crash",
        "db persistence test",
        "body",
        "global",
        "comp",
        "",
        "evidence",
        todo_sh_path=todo_sh,
    )

    fp = result["fingerprint"]
    row = bugs.get_by_fingerprint(conn, fp)
    assert row is not None
    assert row["disposition"] == "filed"
    assert row["title"] == "db persistence test"
    assert row["encounter_count"] == 1


# ---------------------------------------------------------------------------
# file_bug() — duplicate path
# ---------------------------------------------------------------------------


def test_file_bug_duplicate(conn, tmp_path):
    """Second call with same fingerprint returns disposition='duplicate', encounter_count=2."""
    todo_sh = _make_todo_sh(tmp_path, succeed=True)

    kwargs = dict(
        bug_type="enforcement_gap",
        title="duplicate test",
        body="body",
        scope="global",
        source_component="tests",
        file_path="",
        evidence="found it",
        todo_sh_path=todo_sh,
    )
    first = bugs.file_bug(conn, **kwargs)
    assert first["disposition"] == "filed"

    second = bugs.file_bug(conn, **kwargs)
    assert second["disposition"] == "duplicate"
    assert second["encounter_count"] == 2


def test_file_bug_duplicate_does_not_refile(conn, tmp_path):
    """Duplicate detection prevents a second todo.sh call."""
    call_count = 0

    def counting_todo(cmd, **kwargs):
        nonlocal call_count
        call_count += 1
        proc = mock.MagicMock()
        proc.returncode = 0
        proc.stdout = "https://github.com/org/repo/issues/99"
        return proc

    todo_sh = _make_todo_sh(tmp_path, succeed=True)

    kwargs = dict(
        bug_type="crash",
        title="dup-no-refile",
        body="",
        scope="global",
        source_component="x",
        file_path="",
        evidence="ev",
        todo_sh_path=todo_sh,
    )

    with mock.patch("subprocess.run", side_effect=counting_todo):
        bugs.file_bug(conn, **kwargs)
        bugs.file_bug(conn, **kwargs)

    # subprocess.run called exactly once — second call is deduped
    assert call_count == 1


# ---------------------------------------------------------------------------
# file_bug() — failed backend
# ---------------------------------------------------------------------------


def test_file_bug_failed_backend(conn, tmp_path):
    """When todo.sh fails, disposition='failed_to_file', but row persists in DB."""
    todo_sh = _make_todo_sh(tmp_path, succeed=False)

    result = bugs.file_bug(
        conn,
        "crash",
        "backend failure test",
        "body",
        "global",
        "comp",
        "",
        "evidence",
        todo_sh_path=todo_sh,
    )

    assert result["disposition"] == "failed_to_file"
    fp = result["fingerprint"]
    row = bugs.get_by_fingerprint(conn, fp)
    assert row is not None
    assert row["disposition"] == "failed_to_file"


def test_file_bug_never_raises(conn, tmp_path):
    """file_bug() never raises — always returns a result dict."""
    # Pass a non-existent todo.sh path to force a failure
    result = bugs.file_bug(
        conn,
        "crash",
        "no raise test",
        "body",
        "global",
        "comp",
        "",
        "evidence",
        todo_sh_path="/nonexistent/todo.sh",
    )
    assert isinstance(result, dict)
    assert "disposition" in result


# ---------------------------------------------------------------------------
# retry_failed()
# ---------------------------------------------------------------------------


def test_retry_failed(conn, tmp_path):
    """retry_failed() re-attempts failed_to_file rows and marks them filed."""
    # First, create a failed row
    bad_todo = _make_todo_sh(tmp_path / "bad", succeed=False)

    result = bugs.file_bug(
        conn,
        "regression",
        "retry target",
        "body",
        "global",
        "comp",
        "",
        "evidence",
        todo_sh_path=bad_todo,
    )
    assert result["disposition"] == "failed_to_file"

    # Now retry with a working todo.sh
    good_todo = _make_todo_sh(
        tmp_path, succeed=True, issue_url="https://github.com/org/repo/issues/77"
    )
    results = bugs.retry_failed(conn, todo_sh_path=good_todo)

    assert len(results) == 1
    assert results[0]["disposition"] == "filed"
    assert results[0]["issue_url"] == "https://github.com/org/repo/issues/77"


# ---------------------------------------------------------------------------
# list_bugs()
# ---------------------------------------------------------------------------


def test_list_bugs(conn, tmp_path):
    """list_bugs() returns all tracked bugs with correct fields."""
    todo_sh = _make_todo_sh(tmp_path, succeed=True)

    bugs.file_bug(conn, "crash", "bug one", "b", "global", "c", "", "ev", todo_sh_path=todo_sh)
    bugs.file_bug(conn, "regression", "bug two", "b", "global", "c", "", "ev", todo_sh_path=todo_sh)

    all_bugs = bugs.list_bugs(conn)
    assert len(all_bugs) == 2
    titles = {b["title"] for b in all_bugs}
    assert "bug one" in titles
    assert "bug two" in titles


def test_list_bugs_disposition_filter(conn, tmp_path):
    """list_bugs(disposition=...) filters correctly."""
    good_todo = _make_todo_sh(tmp_path, succeed=True)
    bad_todo = _make_todo_sh(tmp_path / "bad", succeed=False)

    bugs.file_bug(conn, "crash", "filed bug", "b", "global", "c", "", "ev", todo_sh_path=good_todo)
    bugs.file_bug(
        conn, "regression", "failed bug", "b", "global", "c", "", "ev", todo_sh_path=bad_todo
    )

    filed = bugs.list_bugs(conn, disposition="filed")
    assert len(filed) == 1
    assert filed[0]["title"] == "filed bug"

    failed = bugs.list_bugs(conn, disposition="failed_to_file")
    assert len(failed) == 1
    assert failed[0]["title"] == "failed bug"


# ---------------------------------------------------------------------------
# Audit events
# ---------------------------------------------------------------------------


def test_audit_events_emitted_on_filed(conn, tmp_path):
    """filing a new bug emits a 'bug_filed' event."""
    todo_sh = _make_todo_sh(tmp_path, succeed=True)
    bugs.file_bug(conn, "crash", "event test", "b", "global", "c", "", "ev", todo_sh_path=todo_sh)

    evts = events.query(conn, type="bug_filed")
    assert len(evts) == 1
    assert "event test" in (evts[0]["detail"] or "")


def test_audit_events_emitted_on_duplicate(conn, tmp_path):
    """Duplicate bug emits 'bug_duplicate' event."""
    todo_sh = _make_todo_sh(tmp_path, succeed=True)
    kwargs = dict(
        bug_type="crash",
        title="dup event test",
        body="",
        scope="global",
        source_component="c",
        file_path="",
        evidence="ev",
        todo_sh_path=todo_sh,
    )
    bugs.file_bug(conn, **kwargs)
    bugs.file_bug(conn, **kwargs)

    evts = events.query(conn, type="bug_duplicate")
    assert len(evts) == 1


def test_audit_events_emitted_on_failed(conn, tmp_path):
    """Failed filing emits 'bug_filing_failed' event."""
    bad_todo = _make_todo_sh(tmp_path, succeed=False)
    bugs.file_bug(conn, "crash", "fail event", "b", "global", "c", "", "ev", todo_sh_path=bad_todo)

    evts = events.query(conn, type="bug_filing_failed")
    assert len(evts) == 1


def test_audit_events_emitted_on_fixed_now(conn):
    """fixed_now=True emits 'bug_fixed_now' event."""
    bugs.file_bug(conn, "crash", "fixed now", "", "global", "c", "", "ev", fixed_now=True)
    evts = events.query(conn, type="bug_fixed_now")
    assert len(evts) == 1


def test_audit_events_emitted_on_rejected(conn):
    """Rejected bug emits 'bug_rejected' event."""
    bugs.file_bug(conn, "not_a_type", "rejected", "", "global", "c", "", "ev")
    evts = events.query(conn, type="bug_rejected")
    assert len(evts) == 1


# ---------------------------------------------------------------------------
# Compound-interaction: full production sequence
# ---------------------------------------------------------------------------


def test_file_bug_full_pipeline(conn, tmp_path):
    """Compound-interaction test: qualify -> fingerprint -> SQLite -> event emission.

    This exercises the real production sequence end-to-end:
    1. qualify() gates the bug
    2. fingerprint() is computed from the inputs
    3. SQLite is checked for duplicate (not found first time)
    4. todo.sh is invoked (mocked) and returns an issue URL
    5. Bug row is upserted with disposition='filed'
    6. Audit event 'bug_filed' is emitted
    7. Second call: duplicate detected via fingerprint match, 'bug_duplicate' event emitted
    """
    todo_sh = _make_todo_sh(
        tmp_path, succeed=True, issue_url="https://github.com/org/repo/issues/100"
    )

    payload = dict(
        bug_type="integration_bug",
        title="pipeline integration failure",
        body="something went wrong between components",
        scope="global",
        source_component="hooks/check-tester.sh",
        file_path="hooks/check-tester.sh",
        evidence="observed wrong state transition during tester stop",
        todo_sh_path=todo_sh,
    )

    # First filing
    r1 = bugs.file_bug(conn, **payload)
    assert r1["disposition"] == "filed"
    assert r1["issue_url"] == "https://github.com/org/repo/issues/100"
    fp = r1["fingerprint"]
    assert len(fp) == 16

    # Row is in DB
    row = bugs.get_by_fingerprint(conn, fp)
    assert row["disposition"] == "filed"
    assert row["encounter_count"] == 1

    # Events: one bug_filed event
    assert len(events.query(conn, type="bug_filed")) == 1
    assert len(events.query(conn, type="bug_duplicate")) == 0

    # Second filing — must be detected as duplicate
    r2 = bugs.file_bug(conn, **payload)
    assert r2["disposition"] == "duplicate"
    assert r2["encounter_count"] == 2

    # Row updated
    row2 = bugs.get_by_fingerprint(conn, fp)
    assert row2["encounter_count"] == 2

    # Events: still 1 bug_filed, now 1 bug_duplicate
    assert len(events.query(conn, type="bug_filed")) == 1
    assert len(events.query(conn, type="bug_duplicate")) == 1


# ---------------------------------------------------------------------------
# Schema: fingerprint UNIQUE constraint
# ---------------------------------------------------------------------------


def test_fingerprint_unique_constraint(conn):
    """SQLite UNIQUE constraint on fingerprint prevents duplicate rows at DB level."""
    fp = bugs.fingerprint("crash", "comp", "unique test")
    now = int(time.time())

    with conn:
        conn.execute(
            """INSERT INTO bugs
               (fingerprint, bug_type, title, scope, disposition,
                first_seen_at, last_seen_at, encounter_count)
               VALUES (?,?,?,?,?,?,?,?)""",
            (fp, "crash", "unique test", "global", "filed", now, now, 1),
        )

    import sqlite3

    with pytest.raises(sqlite3.IntegrityError):
        with conn:
            conn.execute(
                """INSERT INTO bugs
                   (fingerprint, bug_type, title, scope, disposition,
                    first_seen_at, last_seen_at, encounter_count)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (fp, "crash", "unique test", "global", "filed", now, now, 1),
            )


# ---------------------------------------------------------------------------
# qualify() — fixed_now skips evidence check
# ---------------------------------------------------------------------------


def test_qualify_fixed_now_skips_evidence_check():
    """fixed_now=True returns 'fixed_now' even with no evidence."""
    result = bugs.qualify("crash", "title", "", fixed_now=True)
    assert result == "fixed_now"

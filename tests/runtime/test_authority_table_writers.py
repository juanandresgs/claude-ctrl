"""Rule-1 mechanical enforcement: the four §2a supervision authority
tables may only be written by the declared runtime-owned domain modules.

CUTOVER_PLAN §2a design rule 1 ("tmux is execution surface, not
authority") is the governing constraint: transport adapters, hook
adapters, and bridge shell scripts must never bypass the runtime
domain modules and write ``agent_sessions`` / ``seats`` /
``supervision_threads`` / ``dispatch_attempts`` directly.  Prior to
this pin the constraint was enforced by review; now it is enforced
mechanically.

Approved writers (allowlist)
----------------------------
Only the runtime-owned domain modules and the schema DDL file may
issue ``INSERT`` / ``UPDATE`` / ``DELETE`` against the protected
tables:

* ``runtime/core/agent_sessions.py``
* ``runtime/core/seats.py``
* ``runtime/core/supervision_threads.py``
* ``runtime/core/dispatch_attempts.py``
* ``runtime/schemas.py``         (CREATE TABLE DDL + schema migrations)

Any other production file under ``runtime/``, ``hooks/``, or
``scripts/`` that issues such a write fails this invariant.

Out-of-scope surfaces
---------------------
* ``tests/**`` — tests legitimately seed rows via raw SQL to set up
  adversarial states the domain modules would refuse; tests are not
  a production authority surface.
* Markdown docs — strings quoted in planning artifacts are not
  production writes.

Coverage
--------
The scan includes every ``.py`` file under ``runtime/`` and every
``.sh`` file under ``hooks/`` and ``scripts/`` (including ``lib/``
sub-directories).  Shell adapters should call ``cc-policy`` rather
than open a direct SQLite connection; a violation surfaces through
the same pattern-matching regex that flags Python writes.

@decision DEC-AUTHORITY-WRITERS-001
@title Mechanical Rule-1 pin over supervision authority tables
@status accepted
@rationale Rule 1 was enforced by review prior to this slice; a
  mechanical invariant now fails the test suite if any non-allowlisted
  surface writes the protected tables.  Post-Phase-8 continuation
  under the closed Phase 2b scope; no new phase.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest


_REPO_ROOT = Path(__file__).resolve().parents[2]

_PROTECTED_TABLES = (
    "agent_sessions",
    "seats",
    "supervision_threads",
    "dispatch_attempts",
)

_AUTHORITY_WRITERS = frozenset(
    {
        "runtime/core/agent_sessions.py",
        "runtime/core/seats.py",
        "runtime/core/supervision_threads.py",
        "runtime/core/dispatch_attempts.py",
        "runtime/schemas.py",
    }
)

# Directories to scan, relative to the repo root.  Each entry is a
# (root_dir, suffixes) pair.
_SCAN_TARGETS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("runtime", (".py",)),
    ("hooks", (".sh",)),
    ("scripts", (".sh",)),
)

# Exclusion prefixes — paths whose rel form starts with any of these are
# skipped. Keep empty unless a new generated or vendored tree needs to be
# intentionally excluded from the production authority scan.
_EXCLUDE_PREFIXES: tuple[str, ...] = ()

_TABLES_ALT = "|".join(re.escape(t) for t in _PROTECTED_TABLES)
_FORBIDDEN_WRITE = re.compile(
    r"(?ix)"
    r"(?:"
    r"  INSERT\s+(?:OR\s+(?:IGNORE|REPLACE|ABORT|FAIL|ROLLBACK)\s+)?INTO\s+"
    r"| UPDATE\s+"
    r"| DELETE\s+FROM\s+"
    r")"
    r"(?P<table>" + _TABLES_ALT + r")"
    r"\b"
)


def _iter_scan_files() -> list[tuple[Path, str]]:
    """Return (absolute_path, rel_path) pairs for every file in scope."""
    results: list[tuple[Path, str]] = []
    for root, suffixes in _SCAN_TARGETS:
        base = _REPO_ROOT / root
        if not base.is_dir():
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            for filename in filenames:
                if not filename.endswith(suffixes):
                    continue
                abs_path = Path(dirpath) / filename
                rel_path = str(abs_path.relative_to(_REPO_ROOT))
                if any(rel_path.startswith(p) for p in _EXCLUDE_PREFIXES):
                    continue
                results.append((abs_path, rel_path))
    return sorted(results, key=lambda pair: pair[1])


def test_scan_finds_non_empty_set_of_files():
    """Sanity-check: the scanner must actually find files to scan.

    If this ever returns an empty list — because a path was renamed or
    because the test is invoked from a different cwd — the forbidden-
    write invariant below becomes trivially green for the wrong reason.
    """
    pairs = _iter_scan_files()
    assert len(pairs) > 20, (
        f"authority-writer scan collected only {len(pairs)} files; "
        "the forbidden-write invariant would be meaningless with such "
        "a small set"
    )


def test_authority_writers_are_the_only_direct_writers():
    """Rule-1 pin: only the allowlisted files may write the §2a tables."""
    violations: list[tuple[str, int, str]] = []
    for abs_path, rel_path in _iter_scan_files():
        if rel_path in _AUTHORITY_WRITERS:
            continue
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, start=1):
                m = _FORBIDDEN_WRITE.search(line)
                if m:
                    violations.append((rel_path, lineno, line.rstrip()))

    if violations:
        formatted = "\n".join(
            f"  {rel}:{lineno}: {line}" for rel, lineno, line in violations
        )
        pytest.fail(
            "Non-authority surface writes the §2a supervision tables "
            "directly.  Route the write through the owning domain "
            "module instead.\n"
            f"Allowlisted writers: {sorted(_AUTHORITY_WRITERS)}\n"
            f"Violations:\n{formatted}"
        )


@pytest.mark.parametrize(
    "line",
    [
        "conn.execute(\"INSERT INTO agent_sessions (session_id) VALUES (?)\", (x,))",
        "conn.execute(\"INSERT OR IGNORE INTO seats (seat_id) VALUES (?)\", (x,))",
        "conn.execute(\"INSERT OR REPLACE INTO supervision_threads VALUES (?)\", ())",
        "conn.execute(\"UPDATE dispatch_attempts SET status = ?\", (x,))",
        "conn.execute(\"DELETE FROM seats WHERE seat_id = ?\", (x,))",
        "'''\nINSERT INTO agent_sessions (col) VALUES (?)\n'''",
        # Mixed case is normalized by the re.IGNORECASE flag on the regex.
        "conn.execute('Insert Into Seats ...')",
    ],
)
def test_forbidden_regex_detects_known_violations(line):
    """Guard against the invariant silently passing because the regex
    fails to fire.  Every line here is a canonical violation shape and
    must be caught."""
    assert _FORBIDDEN_WRITE.search(line) is not None, (
        f"_FORBIDDEN_WRITE must flag known violation: {line!r}"
    )


@pytest.mark.parametrize(
    "line",
    [
        # Reads are allowed from anywhere.
        "rows = conn.execute('SELECT * FROM seats WHERE seat_id = ?', (x,))",
        "conn.execute('SELECT status FROM agent_sessions')",
        # CREATE TABLE is a DDL statement, not a per-row write.
        "conn.execute('CREATE TABLE IF NOT EXISTS seats (...)')",
        # A different table name that only contains a substring of a
        # protected name must not be flagged.
        "conn.execute('INSERT INTO some_seats_audit (...) VALUES (?)')",
        "conn.execute('UPDATE seats_backup SET ...')",
    ],
)
def test_forbidden_regex_does_not_false_positive(line):
    assert _FORBIDDEN_WRITE.search(line) is None, (
        f"_FORBIDDEN_WRITE must not flag legitimate line: {line!r}"
    )


def test_hook_shell_adapters_do_not_open_sqlite_directly():
    """Hook adapters must call cc-policy, not open SQLite connections.

    A shell adapter that reaches for ``sqlite3`` or .read() against
    ``state.db`` would be bypassing the runtime entirely.  This catches
    that class of drift before it can inject authority-surface writes.
    """
    suspicious: list[tuple[str, int, str]] = []
    shell_patterns = re.compile(
        r"(?i)"
        r"(?:\bsqlite3\b(?!\s*(?:import|from|py))"  # 'sqlite3 <db> <sql>' command
        r"|state\.db)"
    )
    for abs_path, rel_path in _iter_scan_files():
        if not rel_path.startswith(("hooks/", "scripts/")):
            continue
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, start=1):
                stripped = line.lstrip()
                # Skip comments — they often reference sqlite for context.
                if stripped.startswith("#"):
                    continue
                if "sqlite3" in line.lower() and (
                    "exec" in line.lower()
                    or "command" in line.lower()
                    or ".db" in line.lower()
                ):
                    # Candidate: shell is shelling out to sqlite3 CLI.
                    suspicious.append((rel_path, lineno, line.rstrip()))

    # This is intentionally tolerant — the invariant's job is to alert
    # reviewers to a class of change, not to ban the literal string.
    # An empty list today proves the pattern is not present.
    assert suspicious == [], (
        "Shell adapter appears to open a SQLite connection directly; "
        "hooks and scripts must use cc-policy instead.\n"
        + "\n".join(
            f"  {rel}:{lineno}: {line}" for rel, lineno, line in suspicious
        )
    )

"""Tests for ``cc-policy decision ingest-commit`` (write-path CLI).

@decision DEC-CLAUDEX-DEC-TRAILER-CLI-TESTS-001
Title: The ingest-commit CLI is a thin adapter over decision_trailer_ingest
Status: proposed (Phase 7 Slice 14 — commit-trailer ingestion CLI)
Rationale: The Slice 14 CLI surface (``ingest-commit`` action inside
  ``_handle_decision`` in ``runtime/cli.py``) bridges git commit messages
  to the canonical decision store via ``decision_trailer_ingest.ingest_commit``.
  These tests exercise the CLI end-to-end via subprocess against a temp
  git repo + temp SQLite DB to verify:

    1. Happy-path: a commit with Decision trailers → exit 0, JSON payload,
       rows written to DB.
    2. Dry-run: trailers found, nothing written to DB.
    3. No-trailers: exit 0 with decisions_ingested=0, DB unchanged.
    4. Unknown SHA: exit non-zero with status=error.
    5. Idempotent: two invocations → second produces "updated", no duplicates.

  The subprocess approach proves that the argparse wiring, function-scope
  imports, and DB path env-var override all work together in the real
  production entry-point.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import decision_work_registry as dwr
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def git_repo(tmp_path: Path) -> tuple[Path, str]:
    """Create a minimal git repo with one commit that has Decision trailers.

    Returns ``(repo_path, sha)`` where ``sha`` is the commit SHA that
    carries the ``Decision: DEC-CLI-001`` trailer.
    """
    repo = tmp_path / "repo"
    repo.mkdir()

    env = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@t.com",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@t.com"}

    subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@t.com"],
                   check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"],
                   check=True, capture_output=True)

    # Create and commit a file with a trailer-carrying message.
    (repo / "README.md").write_text("test repo")
    subprocess.run(["git", "-C", str(repo), "add", "README.md"],
                   check=True, capture_output=True)

    commit_msg = (
        "land: slice 14 decision trailer ingestion\n"
        "\n"
        "Deliver the commit-trailer ingestion path.\n"
        "\n"
        "decision: DEC-CLI-001\n"
        "DEC: DEC-CLI-002"
    )
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-m", commit_msg],
        check=True, capture_output=True, env=env,
    )

    sha_result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    )
    sha = sha_result.stdout.strip()
    return repo, sha


@pytest.fixture
def git_repo_no_trailers(tmp_path: Path) -> tuple[Path, str]:
    """Create a minimal git repo with one commit that has NO Decision trailers."""
    repo = tmp_path / "repo_no_trailers"
    repo.mkdir()

    env = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@t.com",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@t.com"}

    subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@t.com"],
                   check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"],
                   check=True, capture_output=True)

    (repo / "README.md").write_text("no trailer repo")
    subprocess.run(["git", "-C", str(repo), "add", "README.md"],
                   check=True, capture_output=True)

    commit_msg = "fix: minor bug\n\nNo decision trailers in this commit."
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-m", commit_msg],
        check=True, capture_output=True, env=env,
    )

    sha_result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    )
    sha = sha_result.stdout.strip()
    return repo, sha


@pytest.fixture
def db_path(tmp_path: Path) -> Path:
    """Create an empty but schema-initialised SQLite DB."""
    p = tmp_path / "state.db"
    conn = sqlite3.connect(str(p))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    conn.close()
    return p


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


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestIngestCommitCLI:

    def test_happy_path_exits_zero(self, git_repo, db_path):
        repo, sha = git_repo
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        assert rc == 0, f"Expected exit 0, got {rc}; stderr: {stderr}; stdout: {stdout}"

    def test_happy_path_returns_ok_status(self, git_repo, db_path):
        repo, sha = git_repo
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        assert payload.get("status") == "ok", f"Unexpected payload: {payload}"

    def test_happy_path_ingests_two_decisions(self, git_repo, db_path):
        repo, sha = git_repo
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        assert payload.get("decisions_ingested") == 2, f"Payload: {payload}"

    def test_happy_path_rows_written_to_db(self, git_repo, db_path):
        repo, sha = git_repo
        _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        decisions = dwr.list_decisions(conn)
        conn.close()
        ids = {d.decision_id for d in decisions}
        assert "DEC-CLI-001" in ids
        assert "DEC-CLI-002" in ids

    def test_dry_run_exits_zero(self, git_repo, db_path):
        repo, sha = git_repo
        rc, payload, stdout, stderr = _run_cli(
            [
                "decision", "ingest-commit", "--sha", sha,
                "--project-root", str(repo), "--dry-run",
            ],
            db_path,
        )
        assert rc == 0, f"Expected exit 0, got {rc}; stderr: {stderr}"

    def test_dry_run_does_not_write_to_db(self, git_repo, db_path):
        repo, sha = git_repo
        _run_cli(
            [
                "decision", "ingest-commit", "--sha", sha,
                "--project-root", str(repo), "--dry-run",
            ],
            db_path,
        )
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        decisions = dwr.list_decisions(conn)
        conn.close()
        assert len(decisions) == 0, "dry-run must not write to DB"

    def test_dry_run_reports_found_decisions(self, git_repo, db_path):
        repo, sha = git_repo
        rc, payload, stdout, stderr = _run_cli(
            [
                "decision", "ingest-commit", "--sha", sha,
                "--project-root", str(repo), "--dry-run",
            ],
            db_path,
        )
        found = payload.get("decisions_found", [])
        assert "DEC-CLI-001" in found
        assert "DEC-CLI-002" in found

    def test_dry_run_reports_decisions_ingested_zero(self, git_repo, db_path):
        repo, sha = git_repo
        rc, payload, stdout, stderr = _run_cli(
            [
                "decision", "ingest-commit", "--sha", sha,
                "--project-root", str(repo), "--dry-run",
            ],
            db_path,
        )
        assert payload.get("decisions_ingested") == 0

    def test_no_trailers_exits_zero(self, git_repo_no_trailers, db_path):
        repo, sha = git_repo_no_trailers
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        assert rc == 0, f"Expected exit 0, got {rc}; stderr: {stderr}"

    def test_no_trailers_decisions_ingested_zero(self, git_repo_no_trailers, db_path):
        repo, sha = git_repo_no_trailers
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        assert payload.get("decisions_ingested") == 0

    def test_no_trailers_status_ok(self, git_repo_no_trailers, db_path):
        repo, sha = git_repo_no_trailers
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        assert payload.get("status") == "ok"

    def test_invalid_sha_exits_nonzero(self, git_repo, db_path):
        repo, _ = git_repo
        rc, payload, stdout, stderr = _run_cli(
            [
                "decision", "ingest-commit",
                "--sha", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                "--project-root", str(repo),
            ],
            db_path,
        )
        assert rc != 0, f"Expected non-zero exit for unknown SHA; rc={rc}"

    def test_invalid_sha_returns_error_status(self, git_repo, db_path):
        repo, _ = git_repo
        rc, payload, stdout, stderr = _run_cli(
            [
                "decision", "ingest-commit",
                "--sha", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                "--project-root", str(repo),
            ],
            db_path,
        )
        assert payload.get("status") == "error", f"Payload: {payload}"

    def test_invalid_sha_leaves_db_empty(self, git_repo, db_path):
        repo, _ = git_repo
        _run_cli(
            [
                "decision", "ingest-commit",
                "--sha", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                "--project-root", str(repo),
            ],
            db_path,
        )
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        decisions = dwr.list_decisions(conn)
        conn.close()
        assert len(decisions) == 0

    def test_idempotent_second_call_produces_update(self, git_repo, db_path):
        repo, sha = git_repo
        cli_args = [
            "decision", "ingest-commit", "--sha", sha,
            "--project-root", str(repo),
        ]
        # First call
        rc1, payload1, _, _ = _run_cli(cli_args, db_path)
        assert rc1 == 0
        # Second call
        rc2, payload2, _, _ = _run_cli(cli_args, db_path)
        assert rc2 == 0
        rows2 = payload2.get("rows", [])
        assert all(r.get("action") == "updated" for r in rows2), (
            f"Expected all rows to be 'updated' on second call; rows: {rows2}"
        )

    def test_idempotent_no_duplicate_rows(self, git_repo, db_path):
        repo, sha = git_repo
        cli_args = [
            "decision", "ingest-commit", "--sha", sha,
            "--project-root", str(repo),
        ]
        _run_cli(cli_args, db_path)
        _run_cli(cli_args, db_path)

        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        decisions = dwr.list_decisions(conn)
        conn.close()
        # Exactly 2 unique decisions, no duplicates.
        assert len(decisions) == 2

    def test_sha_key_in_response_payload(self, git_repo, db_path):
        repo, sha = git_repo
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-commit", "--sha", sha, "--project-root", str(repo)],
            db_path,
        )
        assert payload.get("sha") == sha

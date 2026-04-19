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


# ---------------------------------------------------------------------------
# TestCliIngestRange — CLI integration tests for ingest-range
# (DEC-CLAUDEX-DEC-INGEST-BACKFILL-001)
# ---------------------------------------------------------------------------


def _make_git_repo_with_range(tmp_path: Path) -> tuple[Path, str, str, str, str]:
    """Create a 4-commit git repo (anchor + A + B + C) for range CLI tests.

    Commit 0 (anchor): no trailers
    Commit A: decision: DEC-CLI-RANGE-A-001
    Commit B: no trailers
    Commit C: decision: DEC-CLI-RANGE-C-001 + decision: DEC-CLI-RANGE-C-002

    Returns (repo_path, sha_0, sha_a, sha_b, sha_c).
    """
    repo = tmp_path / "range_repo"
    repo.mkdir()
    rp = str(repo)

    env = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@t.com",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@t.com"}

    subprocess.run(["git", "init", rp], check=True, capture_output=True)
    subprocess.run(["git", "-C", rp, "config", "user.email", "t@t.com"],
                   check=True, capture_output=True)
    subprocess.run(["git", "-C", rp, "config", "user.name", "Test"],
                   check=True, capture_output=True)

    def commit(filename, msg):
        (repo / filename).write_text(filename)
        subprocess.run(["git", "-C", rp, "add", filename],
                       check=True, capture_output=True, env=env)
        subprocess.run(["git", "-C", rp, "commit", "-m", msg],
                       check=True, capture_output=True, env=env)
        r = subprocess.run(["git", "-C", rp, "rev-parse", "HEAD"],
                           capture_output=True, text=True, check=True)
        return r.stdout.strip()

    sha_0 = commit("anchor.txt", "chore: anchor commit (lower range bound)")
    sha_a = commit("a.txt", "feat: A\n\nBody.\n\ndecision: DEC-CLI-RANGE-A-001")
    sha_b = commit("b.txt", "fix: B\n\nNo trailers.")
    sha_c = commit("c.txt", (
        "feat: C\n\nBody.\n\n"
        "decision: DEC-CLI-RANGE-C-001\n"
        "decision: DEC-CLI-RANGE-C-002"
    ))
    return repo, sha_0, sha_a, sha_b, sha_c


class TestCliIngestRange:
    """Subprocess-level CLI integration tests for ``cc-policy decision ingest-range``.

    These tests exercise the argparse wiring, handler logic, DB open/schema,
    and the ``ingest_range`` orchestrator together via the real CLI entry-point.
    """

    def test_happy_path_range_exits_zero_and_populates(self, tmp_path, db_path):
        """Valid range → rc=0, JSON payload, DB rows present."""
        repo, sha_0, sha_a, sha_b, sha_c = _make_git_repo_with_range(tmp_path)
        range_spec = f"{sha_0}..{sha_c}"
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-range", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc == 0, f"Expected rc=0; stderr: {stderr}; stdout: {stdout}"
        assert payload.get("status") == "ok", f"Payload: {payload}"
        assert payload.get("commits_scanned") == 3
        # sha_a has 1, sha_c has 2, sha_b has 0 → 3 decisions
        assert payload.get("decisions_ingested") == 3
        assert payload.get("range") == range_spec

        # Verify DB has the rows
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        from runtime.core import decision_work_registry as dwr
        decisions = dwr.list_decisions(conn)
        conn.close()
        ids = {d.decision_id for d in decisions}
        assert "DEC-CLI-RANGE-A-001" in ids
        assert "DEC-CLI-RANGE-C-001" in ids
        assert "DEC-CLI-RANGE-C-002" in ids

    def test_dry_run_reports_but_does_not_write(self, tmp_path, db_path):
        """--dry-run: commits_scanned populated, decisions_ingested=0, DB empty."""
        repo, sha_0, sha_a, sha_b, sha_c = _make_git_repo_with_range(tmp_path)
        range_spec = f"{sha_0}..{sha_c}"
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-range", "--range", range_spec,
             "--project-root", str(repo), "--dry-run"],
            db_path,
        )
        assert rc == 0, f"Expected rc=0; stderr: {stderr}"
        assert payload.get("status") == "ok"
        assert payload.get("dry_run") is True
        assert payload.get("decisions_ingested") == 0
        assert payload.get("rows") == []

        # DB must remain empty
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        from runtime.core import decision_work_registry as dwr
        decisions = dwr.list_decisions(conn)
        conn.close()
        assert len(decisions) == 0, "dry-run must not write to DB"

    def test_no_trailers_in_range_decisions_zero(self, tmp_path, db_path):
        """Range where no commit has trailers → rc=0, decisions_ingested=0."""
        repo, sha_0, sha_a, sha_b, sha_c = _make_git_repo_with_range(tmp_path)
        # sha_a..sha_b = just sha_b (no trailers)
        range_spec = f"{sha_a}..{sha_b}"
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-range", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc == 0, f"Expected rc=0; stderr: {stderr}"
        assert payload.get("status") == "ok"
        assert payload.get("decisions_ingested") == 0
        assert payload.get("commits_scanned") == 1

    def test_invalid_range_exits_nonzero(self, tmp_path, db_path):
        """Bogus --range → rc!=0, status=error."""
        repo, sha_0, sha_a, sha_b, sha_c = _make_git_repo_with_range(tmp_path)
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-range", "--range", "bogus_ref_xyz..HEAD",
             "--project-root", str(repo)],
            db_path,
        )
        assert rc != 0, f"Expected non-zero exit; rc={rc}; stdout={stdout}"
        assert payload.get("status") == "error", f"Payload: {payload}"

    def test_idempotent_range_second_run_updates(self, tmp_path, db_path):
        """Two runs of the same range → second run rows all show action=updated."""
        repo, sha_0, sha_a, sha_b, sha_c = _make_git_repo_with_range(tmp_path)
        range_spec = f"{sha_0}..{sha_c}"
        cli_args = [
            "decision", "ingest-range", "--range", range_spec,
            "--project-root", str(repo),
        ]
        # First run
        rc1, payload1, _, _ = _run_cli(cli_args, db_path)
        assert rc1 == 0
        assert payload1.get("decisions_ingested") == 3

        # Second run
        rc2, payload2, _, _ = _run_cli(cli_args, db_path)
        assert rc2 == 0
        rows2 = payload2.get("rows", [])
        assert all(r.get("action") == "updated" for r in rows2), (
            f"Expected all 'updated' on second run; rows: {rows2}"
        )

        # DB must have exactly 3 unique rows
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        from runtime.core import decision_work_registry as dwr
        decisions = dwr.list_decisions(conn)
        conn.close()
        assert len(decisions) == 3

    def test_sha_list_in_payload(self, tmp_path, db_path):
        """Payload carries per-SHA rows; ordering matches oldest-first."""
        repo, sha_0, sha_a, sha_b, sha_c = _make_git_repo_with_range(tmp_path)
        range_spec = f"{sha_0}..{sha_c}"
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-range", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc == 0
        rows = payload.get("rows", [])
        # sha_a's row must appear before sha_c's rows (oldest-first)
        sha_keys = [r.get("sha") for r in rows]
        # sha_a produces DEC-CLI-RANGE-A-001; sha_c produces C-001 and C-002
        a_indices = [i for i, r in enumerate(rows) if r.get("sha") == sha_a]
        c_indices = [i for i, r in enumerate(rows) if r.get("sha") == sha_c]
        assert a_indices, "sha_a must appear in rows"
        assert c_indices, "sha_c must appear in rows"
        assert max(a_indices) < min(c_indices), (
            "sha_a rows must appear before sha_c rows (oldest-first)"
        )

    def test_ingest_range_help_lists_flags(self, tmp_path, db_path):
        """``cc-policy decision ingest-range --help`` mentions --range and --dry-run."""
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "ingest-range", "--help"],
            db_path,
        )
        # --help exits 0
        assert rc == 0, f"Expected rc=0 for --help; rc={rc}"
        combined = stdout + stderr
        assert "--range" in combined, f"--range not in help output: {combined}"
        assert "--dry-run" in combined, f"--dry-run not in help output: {combined}"


# ---------------------------------------------------------------------------
# TestCliDriftCheck — CLI integration tests for drift-check
# (DEC-CLAUDEX-DEC-DRIFT-CHECK-001, Phase 7 Slice 16)
# ---------------------------------------------------------------------------


class TestCliDriftCheck:
    """Subprocess-level CLI integration tests for ``cc-policy decision drift-check``.

    These tests exercise the argparse wiring, handler logic, read-only DB open,
    and the ``drift_check`` function together via the real CLI entry-point.
    Mirrors the existing ``TestCliIngestRange`` shape.
    """

    def _make_drift_repo(self, tmp_path: Path):
        """Create a 3-commit repo (anchor, A with DEC-DRIFT-A-001, B with DEC-DRIFT-B-001).

        Returns ``(repo_path, sha_0, sha_a, sha_b)``.
        """
        repo = tmp_path / "drift_repo"
        repo.mkdir()
        rp = str(repo)

        env = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@t.com",
               "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@t.com"}

        subprocess.run(["git", "init", rp], check=True, capture_output=True)
        subprocess.run(["git", "-C", rp, "config", "user.email", "t@t.com"],
                       check=True, capture_output=True)
        subprocess.run(["git", "-C", rp, "config", "user.name", "Test"],
                       check=True, capture_output=True)

        def commit(filename, msg):
            (repo / filename).write_text(filename)
            subprocess.run(["git", "-C", rp, "add", filename],
                           check=True, capture_output=True, env=env)
            subprocess.run(["git", "-C", rp, "commit", "-m", msg],
                           check=True, capture_output=True, env=env)
            r = subprocess.run(["git", "-C", rp, "rev-parse", "HEAD"],
                               capture_output=True, text=True, check=True)
            return r.stdout.strip()

        sha_0 = commit("anchor.txt", "chore: anchor")
        sha_a = commit("a.txt", "feat: A\n\nBody.\n\ndecision: DEC-DRIFT-A-001")
        sha_b = commit("b.txt", "feat: B\n\nBody.\n\ndecision: DEC-DRIFT-B-001")
        return repo, sha_0, sha_a, sha_b

    def test_cli_drift_check_aligned_exit_zero(self, tmp_path, db_path):
        """Registry pre-populated with all trailer DECs → rc=0, aligned=True."""
        repo, sha_0, sha_a, sha_b = self._make_drift_repo(tmp_path)
        # Pre-ingest the range so the registry is aligned.
        range_spec = f"{sha_0}..{sha_b}"
        rc_ingest, _, _, _ = _run_cli(
            ["decision", "ingest-range", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc_ingest == 0, "ingest-range precondition failed"

        rc, payload, stdout, stderr = _run_cli(
            ["decision", "drift-check", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc == 0, f"Expected rc=0 on aligned; rc={rc}; stderr={stderr}; stdout={stdout}"
        assert payload.get("aligned") is True
        assert payload.get("status") == "ok"
        assert payload.get("missing_from_registry") == []
        assert payload.get("missing_from_commits") == []

    def test_cli_drift_check_drift_exit_one(self, tmp_path, db_path):
        """Trailer DEC missing from registry → rc=1 (not 2), status=ok, aligned=False."""
        repo, sha_0, sha_a, sha_b = self._make_drift_repo(tmp_path)
        range_spec = f"{sha_0}..{sha_b}"

        rc, payload, stdout, stderr = _run_cli(
            ["decision", "drift-check", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc == 1, f"Expected rc=1 on drift; rc={rc}; stdout={stdout}; stderr={stderr}"
        assert payload.get("aligned") is False
        assert payload.get("status") == "ok"
        assert "DEC-DRIFT-A-001" in payload.get("missing_from_registry", [])
        assert "DEC-DRIFT-B-001" in payload.get("missing_from_registry", [])

    def test_cli_drift_check_invalid_range_exit_nonzero(self, tmp_path, db_path):
        """Bogus --range → rc != 0 and rc != 1, status=error."""
        repo, sha_0, sha_a, sha_b = self._make_drift_repo(tmp_path)
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "drift-check", "--range", "nonexistent_ref..HEAD",
             "--project-root", str(repo)],
            db_path,
        )
        assert rc != 0, f"Expected non-zero exit; rc={rc}"
        assert rc != 1, f"Expected rc != 1 for fatal error; rc={rc}"
        assert payload.get("status") == "error", f"Payload: {payload}"

    def test_cli_drift_check_no_exit_on_drift_flag(self, tmp_path, db_path):
        """With --no-exit-on-drift, drift detected → rc=0 with drift payload."""
        repo, sha_0, sha_a, sha_b = self._make_drift_repo(tmp_path)
        range_spec = f"{sha_0}..{sha_b}"
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "drift-check", "--range", range_spec,
             "--project-root", str(repo), "--no-exit-on-drift"],
            db_path,
        )
        assert rc == 0, f"Expected rc=0 with --no-exit-on-drift; rc={rc}; stderr={stderr}"
        assert payload.get("aligned") is False
        assert payload.get("status") == "ok"
        missing = payload.get("missing_from_registry", [])
        assert "DEC-DRIFT-A-001" in missing or "DEC-DRIFT-B-001" in missing

    def test_cli_drift_check_help_lists_flags(self, tmp_path, db_path):
        """``cc-policy decision drift-check --help`` mentions --range, --exit-on-drift, --project-root."""
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "drift-check", "--help"],
            db_path,
        )
        assert rc == 0, f"Expected rc=0 for --help; rc={rc}"
        combined = stdout + stderr
        assert "--range" in combined, f"--range not in help; output: {combined}"
        assert "--exit-on-drift" in combined, f"--exit-on-drift not in help; output: {combined}"
        assert "--project-root" in combined, f"--project-root not in help; output: {combined}"

    def test_cli_drift_check_no_write_on_drift(self, tmp_path, db_path):
        """drift-check with drift detected leaves the decisions table unchanged."""
        repo, sha_0, sha_a, sha_b = self._make_drift_repo(tmp_path)
        range_spec = f"{sha_0}..{sha_b}"

        # Get row count before
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        from runtime.core import decision_work_registry as dwr_local
        count_before = len(dwr_local.list_decisions(conn))
        conn.close()

        _run_cli(
            ["decision", "drift-check", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )

        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        count_after = len(dwr_local.list_decisions(conn))
        conn.close()

        assert count_before == count_after, (
            f"drift-check must not write to DB; before={count_before}, after={count_after}"
        )

    def test_cli_drift_check_json_shape_fields_present(self, tmp_path, db_path):
        """Payload carries all contract fields from the drift-check spec."""
        repo, sha_0, sha_a, sha_b = self._make_drift_repo(tmp_path)
        range_spec = f"{sha_0}..{sha_b}"
        rc, payload, stdout, stderr = _run_cli(
            ["decision", "drift-check", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        required_keys = {
            "range", "commits_scanned", "registry_decision_count",
            "trailer_decisions_in_range", "missing_from_registry",
            "missing_from_commits", "aligned", "status",
        }
        missing_keys = required_keys - set(payload.keys())
        assert missing_keys == set(), f"Missing payload keys: {missing_keys}; payload: {payload}"

    def test_cli_drift_then_ingest_then_aligned(self, tmp_path, db_path):
        """E2E convergence: drift → ingest-range → aligned. Pins slice-15/slice-16 relationship."""
        repo, sha_0, sha_a, sha_b = self._make_drift_repo(tmp_path)
        range_spec = f"{sha_0}..{sha_b}"

        # Step 1: drift-check shows drift (rc=1)
        rc1, payload1, stdout1, stderr1 = _run_cli(
            ["decision", "drift-check", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc1 == 1, f"Expected rc=1 on drift; rc={rc1}; stderr={stderr1}"
        assert payload1.get("aligned") is False

        # Step 2: ingest-range to fill the gap
        rc_ingest, _, _, _ = _run_cli(
            ["decision", "ingest-range", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc_ingest == 0, "ingest-range should succeed"

        # Step 3: drift-check now aligned (rc=0)
        rc2, payload2, stdout2, stderr2 = _run_cli(
            ["decision", "drift-check", "--range", range_spec,
             "--project-root", str(repo)],
            db_path,
        )
        assert rc2 == 0, f"Expected rc=0 after ingest; rc={rc2}; stderr={stderr2}"
        assert payload2.get("aligned") is True
        assert payload2.get("missing_from_registry") == []
        assert payload2.get("missing_from_commits") == []

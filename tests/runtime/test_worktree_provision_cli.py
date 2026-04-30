"""Unit and integration tests for `cc-policy worktree provision` CLI action.

W-GWT-2: Guardian worktree provisioning — provision sequence tests.

Production sequence: Guardian agent calls
  `cc-policy worktree provision --workflow-id <W> --feature-name <F> --project-root <P>`
which:
  1. Checks filesystem for existing worktree path (idempotency)
  2. Runs `git worktree add .worktrees/feature-<F> -b feature/<F>` (if not exists)
  3. Calls worktrees.register(path, branch)
  4. Issues Guardian lease at PROJECT_ROOT
  5. Issues implementer lease at worktree_path
  6. Calls workflows.bind_workflow(workflow_id, worktree_path, branch)

Each test exercises the real CLI boundary (subprocess) so the argparse wiring,
JSON serialization, and domain module integration are all verified together.
Git side effects are isolated via temporary git repos so real `git worktree add`
calls succeed without touching the production repo.

@decision DEC-GUARD-WT-002
Title: Worktree provisioning is a runtime function, not a dispatch_engine side effect
Status: accepted
Rationale: The provision action is the single place in the runtime that has git
  side effects (by design, per DEC-GUARD-WT-002). These tests verify the full
  sequence: filesystem-first, DB writes, lease issuance, workflow binding,
  idempotency, and partial-failure cleanup. Using subprocess ensures the CLI
  boundary is exercised end-to-end.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

# Path resolution — must work from any cwd
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")
sys.path.insert(0, str(_REPO_ROOT))

import runtime.core.leases as leases_mod
import runtime.core.workflows as workflows_mod
import runtime.core.worktrees as worktrees_mod
from runtime.core.db import connect
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_cli(args: list[str], db_path: str) -> tuple[int, dict]:
    """Run cc-policy CLI via subprocess. Returns (exit_code, parsed_json)."""
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": str(_REPO_ROOT)}
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
    return result.returncode, parsed


def make_git_repo(path: Path) -> Path:
    """Create a minimal git repo at path with one commit. Returns the repo root."""
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", str(path)], check=True, capture_output=True)
    subprocess.run(
        ["git", "config", "user.email", "test@test.com"],
        check=True,
        capture_output=True,
        cwd=str(path),
    )
    subprocess.run(
        ["git", "config", "user.name", "Test"],
        check=True,
        capture_output=True,
        cwd=str(path),
    )
    (path / "README.md").write_text("test repo")
    subprocess.run(["git", "add", "."], check=True, capture_output=True, cwd=str(path))
    subprocess.run(
        ["git", "commit", "-m", "init"],
        check=True,
        capture_output=True,
        cwd=str(path),
    )
    return path


def make_unborn_git_repo(path: Path) -> Path:
    """Create a git repo with no commits yet. Returns the repo root."""
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", str(path)], check=True, capture_output=True)
    subprocess.run(
        ["git", "config", "user.email", "test@test.com"],
        check=True,
        capture_output=True,
        cwd=str(path),
    )
    subprocess.run(
        ["git", "config", "user.name", "Test"],
        check=True,
        capture_output=True,
        cwd=str(path),
    )
    return path


@pytest.fixture
def db(tmp_path):
    """Return a path to a fresh temporary database file."""
    return str(tmp_path / "test-state.db")


@pytest.fixture
def git_repo(tmp_path):
    """Create a minimal git repo and return its path as a string."""
    return str(make_git_repo(tmp_path / "project"))


@pytest.fixture
def unborn_git_repo(tmp_path):
    """Create a git repo with no commits yet and return its path as a string."""
    return str(make_unborn_git_repo(tmp_path / "unborn-project"))


def open_db(db_path: str):
    """Open a DB connection with schema ensured. connect() requires a Path object."""
    conn = connect(Path(db_path))
    ensure_schema(conn)
    return conn


# ---------------------------------------------------------------------------
# Test: happy path — fresh provision
# ---------------------------------------------------------------------------


def test_worktree_provision_cli(tmp_path, git_repo):
    """cc-policy worktree provision creates worktree, registers in DB, issues leases, binds workflow.

    This is the primary compound-interaction test: CLI args → git worktree add
    → DB writes → JSON output. Exercises the full production sequence end-to-end.
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-gwt2-happy-001"
    feature_name = "my-feature"
    expected_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    code, out = run_cli(
        [
            "worktree",
            "provision",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )

    assert code == 0, f"Expected exit 0, got {code}. Output: {out}"
    assert out.get("status") == "ok", f"Expected status=ok, got: {out}"
    assert out["worktree_path"] == expected_path, f"worktree_path mismatch: {out}"
    assert out["branch"] == f"feature/{feature_name}", f"branch mismatch: {out}"
    assert out["already_exists"] is False, f"Expected already_exists=false: {out}"
    assert out["repo_initialized"] is False, f"Expected repo_initialized=false: {out}"
    assert out["guardian_lease_id"], "Expected guardian_lease_id populated"
    assert out["implementer_lease_id"], "Expected implementer_lease_id populated"
    assert out["workflow_id"] == workflow_id

    # Verify filesystem
    assert Path(expected_path).exists(), f"Worktree directory not created: {expected_path}"

    # Verify DB state
    conn = open_db(db_path)
    try:
        # worktrees table — stored path may be normalized (realpath)
        active_wts = worktrees_mod.list_active(conn)
        wt_paths = [w["path"] for w in active_wts]
        assert any(p.endswith(f".worktrees/feature-{feature_name}") for p in wt_paths), (
            f"Worktree not registered in DB. Active paths: {wt_paths}"
        )

        # Guardian lease at PROJECT_ROOT
        g_lease = leases_mod.get_current(conn, worktree_path=project_root)
        assert g_lease is not None, "No active guardian lease at project_root"
        assert g_lease["role"] == "guardian"
        assert g_lease["workflow_id"] == workflow_id

        # Implementer lease at worktree_path
        i_lease = leases_mod.get_current(conn, worktree_path=expected_path)
        assert i_lease is not None, "No active implementer lease at worktree_path"
        assert i_lease["role"] == "implementer"
        assert i_lease["workflow_id"] == workflow_id

        # Workflow binding
        binding = workflows_mod.get_binding(conn, workflow_id)
        assert binding is not None, "No workflow binding found"
        assert binding["branch"] == f"feature/{feature_name}"

    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test: provision returns valid lease IDs
# ---------------------------------------------------------------------------


def test_worktree_provision_returns_leases(tmp_path, git_repo):
    """Provision result includes guardian_lease_id and implementer_lease_id that are real DB rows."""
    db_path = str(tmp_path / "state.db")
    workflow_id = "wf-gwt2-leases-001"
    feature_name = "lease-feature"

    code, out = run_cli(
        [
            "worktree",
            "provision",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            git_repo,
        ],
        db_path,
    )
    assert code == 0, f"Provision failed: {out}"

    conn = open_db(db_path)
    try:
        g_lease = leases_mod.get(conn, out["guardian_lease_id"])
        assert g_lease is not None, "guardian_lease_id not found in DB"
        assert g_lease["role"] == "guardian"
        assert g_lease["status"] == "active"

        i_lease = leases_mod.get(conn, out["implementer_lease_id"])
        assert i_lease is not None, "implementer_lease_id not found in DB"
        assert i_lease["role"] == "implementer"
        assert i_lease["status"] == "active"
    finally:
        conn.close()


def test_worktree_provision_initializes_unborn_repo_before_branching(tmp_path, unborn_git_repo):
    """Provision auto-creates the one-time bootstrap commit for an unborn repo.

    This closes the fresh-repo hole where `git worktree add` cannot branch from
    a repo with no HEAD. The runtime must initialize the base repo, exclude
    runtime state from the commit, and then continue the normal provision flow.
    """
    db_path = str(tmp_path / "state.db")
    project_root = Path(unborn_git_repo)
    workflow_id = "wf-gwt2-unborn-001"
    feature_name = "bootstrap-feature"

    (project_root / "README.md").write_text("bootstrap repo\n")
    docs_dir = project_root / "docs"
    docs_dir.mkdir()
    (docs_dir / "ARCHITECTURE.md").write_text("# Architecture\n")
    runtime_state_dir = project_root / ".claude"
    runtime_state_dir.mkdir()
    (runtime_state_dir / "state.db").write_text("do not commit runtime state\n")

    code, out = run_cli(
        [
            "worktree",
            "provision",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            str(project_root),
        ],
        db_path,
    )

    assert code == 0, f"Provision failed for unborn repo: {out}"
    assert out["repo_initialized"] is True, f"Expected repo_initialized=true: {out}"
    assert out["bootstrap_commit_sha"], f"Expected bootstrap commit sha: {out}"
    assert out["bootstrap_commit_message"] == (
        f"chore: initialize repository for workflow {workflow_id}"
    )
    assert out["bootstrap_commit_path_count"] == 2

    head_sha = subprocess.run(
        ["git", "-C", str(project_root), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert head_sha == out["bootstrap_commit_sha"]

    tracked = subprocess.run(
        ["git", "-C", str(project_root), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    assert "README.md" in tracked
    assert "docs/ARCHITECTURE.md" in tracked
    assert ".claude/state.db" not in tracked

    conn = open_db(db_path)
    try:
        init_events = conn.execute(
            """
            SELECT type, source, detail
            FROM events
            WHERE type = 'workflow.bootstrap.repo_initialized'
            ORDER BY id DESC
            LIMIT 1
            """
        ).fetchone()
    finally:
        conn.close()
    assert init_events is not None
    assert init_events["source"] == f"workflow:{workflow_id}"
    assert workflow_id in init_events["detail"]


def test_worktree_provision_initializes_empty_unborn_repo_with_allow_empty_commit(
    tmp_path, unborn_git_repo
):
    """If nothing committable exists, provision still creates an empty bootstrap commit."""
    db_path = str(tmp_path / "state.db")
    project_root = Path(unborn_git_repo)

    code, out = run_cli(
        [
            "worktree",
            "provision",
            "--workflow-id",
            "wf-gwt2-unborn-empty-001",
            "--feature-name",
            "empty-bootstrap",
            "--project-root",
            str(project_root),
        ],
        db_path,
    )

    assert code == 0, f"Provision failed for empty unborn repo: {out}"
    assert out["repo_initialized"] is True
    assert out["bootstrap_commit_sha"]
    assert out["bootstrap_commit_path_count"] == 0


# ---------------------------------------------------------------------------
# Test: workflow binding created at provision time
# ---------------------------------------------------------------------------


def test_worktree_provision_creates_binding(tmp_path, git_repo):
    """workflows.get_binding() returns the correct binding after provision."""
    db_path = str(tmp_path / "state.db")
    workflow_id = "wf-gwt2-bind-001"
    feature_name = "bind-feature"

    code, out = run_cli(
        [
            "worktree",
            "provision",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            git_repo,
        ],
        db_path,
    )
    assert code == 0, f"Provision failed: {out}"

    conn = open_db(db_path)
    try:
        binding = workflows_mod.get_binding(conn, workflow_id)
        assert binding is not None, "No workflow binding created"
        assert binding["branch"] == f"feature/{feature_name}"
        assert binding["workflow_id"] == workflow_id
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test: idempotent re-provision (already_exists path)
# ---------------------------------------------------------------------------


def test_worktree_provision_idempotent(tmp_path, git_repo):
    """Second call with same args returns already_exists=true, no duplicate leases.

    DEC-GUARD-WT-008 R3: filesystem check detects existing path. The second call
    must NOT revoke the active implementer lease issued by the first call.
    """
    db_path = str(tmp_path / "state.db")
    workflow_id = "wf-gwt2-idem-001"
    feature_name = "idem-feature"

    provision_args = [
        "worktree",
        "provision",
        "--workflow-id",
        workflow_id,
        "--feature-name",
        feature_name,
        "--project-root",
        git_repo,
    ]

    # First provision
    code1, out1 = run_cli(provision_args, db_path)
    assert code1 == 0, f"First provision failed: {out1}"
    assert out1["already_exists"] is False
    first_impl_lease_id = out1["implementer_lease_id"]

    # Second provision — idempotent re-call
    code2, out2 = run_cli(provision_args, db_path)
    assert code2 == 0, f"Second provision failed: {out2}"
    assert out2["already_exists"] is True, f"Expected already_exists=true: {out2}"
    assert out2["worktree_path"] == out1["worktree_path"]

    # The active implementer lease must NOT have been revoked on re-provision.
    # (The spec says: do NOT revoke active implementer lease if one exists.)
    conn = open_db(db_path)
    try:
        original_lease = leases_mod.get(conn, first_impl_lease_id)
        assert original_lease is not None, "Original implementer lease row missing"
        assert original_lease["status"] == "active", (
            f"Original implementer lease was revoked on re-provision: {original_lease['status']}"
        )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test: missing required args → error exit
# ---------------------------------------------------------------------------


def test_worktree_provision_missing_workflow_id(tmp_path, git_repo):
    """Provision without --workflow-id exits with error."""
    db_path = str(tmp_path / "state.db")
    code, _out = run_cli(
        ["worktree", "provision", "--feature-name", "x", "--project-root", git_repo],
        db_path,
    )
    assert code != 0, "Expected non-zero exit for missing --workflow-id"


def test_worktree_provision_missing_feature_name(tmp_path, git_repo):
    """Provision without --feature-name exits with error."""
    db_path = str(tmp_path / "state.db")
    code, _out = run_cli(
        ["worktree", "provision", "--workflow-id", "wf-x", "--project-root", git_repo],
        db_path,
    )
    assert code != 0, "Expected non-zero exit for missing --feature-name"


def test_worktree_provision_missing_project_root(tmp_path):
    """Provision without --project-root and no CLAUDE_PROJECT_DIR exits with error."""
    db_path = str(tmp_path / "state.db")
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": str(_REPO_ROOT)}
    env.pop("CLAUDE_PROJECT_DIR", None)
    result = subprocess.run(
        [
            sys.executable,
            _CLI,
            "worktree",
            "provision",
            "--workflow-id",
            "wf-x",
            "--feature-name",
            "feat-x",
        ],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode != 0, (
        f"Expected non-zero exit when project-root missing, got 0. stdout={result.stdout!r}"
    )


# ---------------------------------------------------------------------------
# Test: filesystem-first (git fail → no DB write)
# ---------------------------------------------------------------------------


def test_worktree_provision_filesystem_first(tmp_path):
    """If git worktree add fails, no DB state is written.

    DEC-GUARD-WT-008 R3: filesystem creation is the FIRST step. DB writes
    only happen after git succeeds. We pass a non-git directory as project_root
    so that `git worktree add` fails, and verify no DB state was written.
    """
    db_path = str(tmp_path / "state.db")
    # A plain directory that is NOT a git repo — git worktree add will fail
    project_root = str(tmp_path / "not-a-git-repo")
    os.makedirs(project_root, exist_ok=True)
    workflow_id = "wf-gwt2-fs-first"
    feature_name = "x"
    worktree_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    code, out = run_cli(
        [
            "worktree",
            "provision",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )

    # Must fail — not a git repo
    assert code != 0 or out.get("status") == "error", (
        f"Expected error when git worktree add fails, got: code={code} out={out}"
    )

    # No DB state must have been written
    conn = open_db(db_path)
    try:
        active_wts = worktrees_mod.list_active(conn)
        assert all(w["path"] != worktree_path for w in active_wts), (
            "Worktree was registered in DB despite git failure (filesystem-first violated)"
        )
        g_lease = leases_mod.get_current(conn, worktree_path=project_root)
        assert g_lease is None, "Guardian lease was issued despite git failure"
    finally:
        conn.close()

    # Worktree path must not exist on disk
    assert not Path(worktree_path).exists(), (
        f"Worktree directory {worktree_path} exists despite git failure"
    )


# ---------------------------------------------------------------------------
# Test: partial failure cleanup (git ok, DB fails → git worktree remove called)
# ---------------------------------------------------------------------------


def test_worktree_provision_partial_failure_cleanup(tmp_path, git_repo):
    """When git worktree add succeeds but register() raises, git worktree remove is called.

    DEC-GUARD-WT-008 R3: partial-failure cleanup prevents orphaned worktrees.
    register() is patched to raise after git worktree add creates the directory.
    The test verifies the worktree directory is removed (not orphaned).

    Note: patch.object only works in-process, so we call _provision_worktree directly
    rather than going through a subprocess. This tests the exact cleanup code path.
    """
    from runtime.cli import _provision_worktree

    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    feature_name = "cleanup-feature"
    worktree_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    conn = open_db(db_path)

    def register_raises(*args, **kwargs):
        raise RuntimeError("Simulated DB failure in register()")

    try:
        with patch.object(worktrees_mod, "register", side_effect=register_raises):
            with pytest.raises(RuntimeError, match="Simulated DB failure"):
                _provision_worktree(
                    conn,
                    workflow_id="wf-gwt2-cleanup",
                    feature_name=feature_name,
                    project_root=project_root,
                )
    finally:
        conn.close()

    # Worktree directory must have been cleaned up by partial-failure path
    assert not Path(worktree_path).exists(), (
        f"Orphaned worktree at {worktree_path} — partial-failure cleanup failed"
    )


# ---------------------------------------------------------------------------
# Test: provisioned verdict accepted (end-to-end chain)
# ---------------------------------------------------------------------------


def test_provisioned_verdict_accepted(tmp_path, git_repo):
    """End-to-end: provision → submit provisioned completion → guardian stop → implementer.

    Verifies the full production chain:
    1. `cc-policy worktree provision` creates worktree and issues Guardian lease
    2. Guardian submits completion with LANDING_RESULT=provisioned
    3. `dispatch process-stop` for guardian routes to implementer with worktree_path
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-gwt2-verdict-001"
    feature_name = "verdict-feature"

    # Step 1: provision
    code, prov_out = run_cli(
        [
            "worktree",
            "provision",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )
    assert code == 0, f"Provision failed: {prov_out}"
    worktree_path = prov_out["worktree_path"]
    guardian_lease_id = prov_out["guardian_lease_id"]

    # Step 2: submit guardian completion with provisioned verdict
    payload = json.dumps(
        {
            "LANDING_RESULT": "provisioned",
            "OPERATION_CLASS": "routine_local",
            "WORKTREE_PATH": worktree_path,
        }
    )
    run_cli(
        [
            "completion",
            "submit",
            "--lease-id",
            guardian_lease_id,
            "--workflow-id",
            workflow_id,
            "--role",
            "guardian",
            "--payload",
            payload,
        ],
        db_path,
    )

    # Step 3: process-stop for guardian → next_role=implementer
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": str(_REPO_ROOT)}
    stop_input = json.dumps({"agent_type": "guardian", "project_root": project_root})
    result = subprocess.run(
        [sys.executable, _CLI, "dispatch", "process-stop"],
        input=stop_input,
        capture_output=True,
        text=True,
        env=env,
    )
    stop_out = json.loads(result.stdout.strip() or result.stderr.strip())

    assert stop_out.get("next_role") == "implementer", (
        f"Expected next_role=implementer after provisioned, got: {stop_out}"
    )
    assert stop_out.get("worktree_path") == worktree_path, (
        f"Expected worktree_path={worktree_path}, got: {stop_out}"
    )

"""Invariant tests for `cc-policy worktree retire` — W-WTR-1 (DEC-WT-RETIRE-001..004).

Production sequence: After a successful landing, Guardian calls
  `cc-policy worktree retire --workflow-id <W> --feature-name <F> --project-root <P>`
which atomically:
  1. Issues a Guardian lease at PROJECT_ROOT (never at the feature path)
  2. Pre-flight merge check (git merge-base --is-ancestor) — fails before any mutation
  3. git worktree remove <path>   (BEFORE branch -d — DEC-WT-RETIRE-003a: git refuses
     branch -d on a checked-out branch)
  4. git branch -d <branch>   (after worktree remove, branch is no longer checked out)
  5. worktrees.remove(path)   — soft-delete (DEC-RT-001)
  6. Explicit lease revocation for all active leases at worktree_path
  7. Guardian lease released in finally (never strands)

Each test exercises the real CLI boundary (subprocess) so the argparse wiring,
JSON serialization, and domain module integration are all verified together.
Git side effects are isolated via temporary git repos so real git commands
succeed without touching the production repo.

@decision DEC-WT-RETIRE-001
Title: _retire_worktree is the sole atomic cleanup authority for feature worktrees
Status: accepted
Rationale: Symmetric counterpart to _provision_worktree. These tests verify the
  full retire sequence: lease-anchor invariant, ordering constraint, partial-failure
  rollback paths, idempotency, lease revocation, and force-delete classification.

@decision DEC-WT-RETIRE-002
Title: Retire Guardian lease anchored at project_root, not feature path
Status: accepted
Rationale: The lease must outlive the worktree disappearing mid-operation.
  test_retire_lease_anchor_is_project_root verifies this invariant directly.

@decision DEC-WT-RETIRE-003a
Title: git worktree remove runs before git branch -d (actual ordering)
Status: accepted
Rationale: test_retire_branch_d_fails_unmerged verifies that a failure on the
  pre-flight merge check (step 2) leaves zero state mutated; the explicit
  pre-flight preserves the fail-before-mutation invariant even though worktree
  remove (step 3) must precede branch -d (step 4). test_retire_branch_d_fails_after_worktree_remove
  verifies the correct partial-failure state when worktree remove succeeds but
  branch -d fails or when the worktree remove step itself fails.

@decision DEC-WT-RETIRE-004
Title: Retire explicitly revokes leases by path — does not call revoke_missing_worktrees
Status: accepted
Rationale: test_retire_revokes_path_anchored_leases verifies deterministic explicit
  revocation; the forbidden shortcut (revoke_missing_worktrees) is never called.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# Path resolution — must work from any cwd
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")
sys.path.insert(0, str(_REPO_ROOT))

import runtime.core.events as events_mod
import runtime.core.leases as leases_mod
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


def provision_worktree(
    project_root: str, workflow_id: str, feature_name: str, db_path: str
) -> dict:
    """Run cc-policy worktree provision and return the result dict."""
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
    assert code == 0, f"provision failed (code={code}): {out}"
    return out


def open_db(db_path: str):
    """Open a DB connection with schema ensured."""
    conn = connect(Path(db_path))
    ensure_schema(conn)
    return conn


@pytest.fixture
def git_repo(tmp_path):
    """Create a minimal git repo with one commit. Returns path as string."""
    return str(make_git_repo(tmp_path / "project"))


# ---------------------------------------------------------------------------
# Test 1: Happy path — full retire sequence
# ---------------------------------------------------------------------------


def test_retire_worktree_happy_path(tmp_path, git_repo):
    """cc-policy worktree retire atomically cleans up branch, worktree, DB, and leases.

    This is the primary compound-interaction test: provision -> commit on feature ->
    merge into main -> retire. Verifies the full production sequence end-to-end:
    CLI args -> git worktree remove -> git branch -d -> DB soft-delete -> lease
    revocation -> structured JSON output.
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-happy-001"
    feature_name = "retire-smoke"
    expected_wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")
    branch = f"feature/{feature_name}"

    # Provision the worktree
    prov = provision_worktree(project_root, workflow_id, feature_name, db_path)
    assert prov["worktree_path"] == expected_wt_path
    assert Path(expected_wt_path).exists(), "Worktree must exist before retire"

    # Make a commit on the feature branch
    feature_readme = Path(expected_wt_path) / "feature.txt"
    feature_readme.write_text("feature work")
    subprocess.run(
        ["git", "-C", expected_wt_path, "add", "feature.txt"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", expected_wt_path, "commit", "-m", "feat: add feature"],
        check=True,
        capture_output=True,
    )

    # Merge the feature branch into main
    subprocess.run(
        ["git", "-C", project_root, "merge", "--no-ff", branch, "-m", "Merge feature"],
        check=True,
        capture_output=True,
    )

    # Retire
    code, out = run_cli(
        [
            "worktree",
            "retire",
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
    assert out["branch"] == branch
    assert out["workflow_id"] == workflow_id
    assert "retire_lease_id" in out
    assert "revoked_lease_ids" in out

    # Filesystem: worktree directory must be gone
    assert not Path(expected_wt_path).exists(), (
        f"Worktree directory still exists after retire: {expected_wt_path}"
    )

    # Git: feature branch must be gone
    branch_check = subprocess.run(
        ["git", "-C", project_root, "branch", "--list", branch],
        capture_output=True,
        text=True,
    )
    assert branch_check.stdout.strip() == "", (
        f"Branch still exists after retire: {branch_check.stdout!r}"
    )

    # Git: worktree list shows only the main worktree
    wt_list_result = subprocess.run(
        ["git", "-C", project_root, "worktree", "list", "--porcelain"],
        capture_output=True,
        text=True,
    )
    worktree_paths = [
        line[len("worktree ") :].strip()
        for line in wt_list_result.stdout.splitlines()
        if line.startswith("worktree ")
    ]
    assert len(worktree_paths) == 1, (
        f"Expected 1 worktree after retire (only main), got {worktree_paths}"
    )
    assert worktree_paths[0] == os.path.realpath(project_root), (
        f"Expected only main worktree, got: {worktree_paths}"
    )

    # DB: worktree soft-deleted (removed_at is set)
    conn = open_db(db_path)
    try:
        active_wts = worktrees_mod.list_active(conn)
        active_paths = [w["path"] for w in active_wts]
        assert not any(p.endswith(f".worktrees/feature-{feature_name}") for p in active_paths), (
            f"Worktree still active in DB after retire: {active_paths}"
        )

        # DB: retire event was emitted
        events = events_mod.query(conn, type="workflow.retire.completed", limit=10)
        assert len(events) >= 1, "Expected workflow.retire.completed event"
        detail = json.loads(events[0]["detail"])
        assert detail["workflow_id"] == workflow_id
        assert detail["branch"] == branch

        # DB: retire Guardian lease was released (not stranded)
        retire_lease = leases_mod.get(conn, out["retire_lease_id"])
        assert retire_lease is not None, "retire_lease_id not found in DB"
        assert retire_lease["status"] == "released", (
            f"Expected retire lease to be released, got: {retire_lease['status']}"
        )
        # Lease-anchor invariant: retire lease must be at project_root
        assert retire_lease["worktree_path"] == os.path.realpath(project_root), (
            f"Retire lease must be anchored at project_root, got: {retire_lease['worktree_path']}"
        )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test 2: Lease anchor invariant — retire lease at project_root
# ---------------------------------------------------------------------------


def test_retire_lease_anchor_is_project_root(tmp_path, git_repo):
    """Retire's Guardian lease MUST be anchored at project_root, never the feature path.

    DEC-WT-RETIRE-002: The lease must outlive the worktree disappearing mid-op.
    Anchoring at the feature worktree_path would cause the lease to vanish with
    the worktree, stranding it. This test directly verifies the invariant.
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-anchor-001"
    feature_name = "anchor-check"
    branch = f"feature/{feature_name}"

    # Provision + commit + merge so branch -d succeeds without --force
    provision_worktree(project_root, workflow_id, feature_name, db_path)
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")
    (Path(wt_path) / "work.txt").write_text("anchor test")
    subprocess.run(["git", "-C", wt_path, "add", "work.txt"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "anchor work"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", project_root, "merge", "--no-ff", branch, "-m", "Merge anchor"],
        check=True,
        capture_output=True,
    )

    # Retire
    code, out = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )
    assert code == 0, f"Retire failed: {out}"

    # The retire_lease_id must exist in DB and be anchored at project_root
    conn = open_db(db_path)
    try:
        retire_lease = leases_mod.get(conn, out["retire_lease_id"])
        assert retire_lease is not None, "retire_lease_id not found in DB"

        # Core invariant (DEC-WT-RETIRE-002)
        assert retire_lease["worktree_path"] == os.path.realpath(project_root), (
            f"Lease anchor must be project_root={os.path.realpath(project_root)!r}, "
            f"got {retire_lease['worktree_path']!r}"
        )
        # Must NOT be anchored at the feature worktree path
        feature_realpath = os.path.realpath(
            str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")
        )
        assert retire_lease["worktree_path"] != feature_realpath, (
            "Retire lease must NOT be anchored at the feature worktree path"
        )

        # Must be released (not stranded) at end of operation
        assert retire_lease["status"] == "released", (
            f"Retire lease must be released in finally, got: {retire_lease['status']}"
        )
        assert retire_lease["role"] == "guardian", (
            f"Retire lease role must be guardian, got: {retire_lease['role']}"
        )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test 3: branch -d fails for unmerged branch (step 2 failure — no state mutated)
# ---------------------------------------------------------------------------


def test_retire_branch_d_fails_unmerged(tmp_path, git_repo):
    """git branch -d fails for an unmerged branch — retire must return error with zero mutation.

    DEC-WT-RETIRE-003a: The pre-flight merge check (step 2) runs before any git mutation,
    preserving the fail-before-mutation invariant even though worktree remove (step 3) must
    precede branch -d (step 4). If the pre-flight detects an unmerged branch, no filesystem
    or DB state has been touched. The caller may fix the cause (merge or --force) and retry.
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-unmerged-001"
    feature_name = "unmerged-feature"

    # Provision and commit on feature branch but do NOT merge into main
    provision_worktree(project_root, workflow_id, feature_name, db_path)
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")
    (Path(wt_path) / "unmerged.txt").write_text("not merged")
    subprocess.run(["git", "-C", wt_path, "add", "unmerged.txt"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "unmerged commit"],
        check=True,
        capture_output=True,
    )

    # Snapshot state before retire attempt
    assert Path(wt_path).exists(), "Worktree must exist before retire attempt"
    conn_pre = open_db(db_path)
    impl_lease_before = leases_mod.get_current(conn_pre, worktree_path=wt_path)
    conn_pre.close()

    # Retire WITHOUT --force: git branch -d should fail (unmerged)
    code, out = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )

    # Must fail with non-zero exit
    assert code != 0, f"Expected non-zero exit for unmerged branch, got {code}: {out}"
    assert out.get("status") == "error", f"Expected status=error, got: {out}"
    assert out.get("message"), f"Error message must be present: {out}"

    # Critical: worktree must still exist (no filesystem mutation on step-2 failure)
    assert Path(wt_path).exists(), (
        "Worktree directory must still exist after branch -d failure (no mutation)"
    )

    # Critical: DB must still have the active worktree row
    conn_post = open_db(db_path)
    try:
        active_after = [w["path"] for w in worktrees_mod.list_active(conn_post)]
        assert any(p.endswith(f".worktrees/feature-{feature_name}") for p in active_after), (
            f"Worktree must still be in DB after branch -d failure: {active_after}"
        )

        # Implementer lease must still be active
        if impl_lease_before:
            impl_lease_after = leases_mod.get(conn_post, impl_lease_before["lease_id"])
            assert impl_lease_after is not None
            assert impl_lease_after["status"] == "active", (
                f"Implementer lease must still be active after step-2 failure, "
                f"got: {impl_lease_after['status']}"
            )
    finally:
        conn_post.close()


# ---------------------------------------------------------------------------
# Test 4: step-4 failure — git branch -d fails after worktree remove succeeds
# ---------------------------------------------------------------------------


def test_retire_branch_d_fails_after_worktree_remove(tmp_path, git_repo):
    """Step-4 failure: git branch -d fails after git worktree remove succeeds.

    DEC-WT-RETIRE-003a rollback boundary (step 4 failure after step 3 success):
    The branch ref is pre-deleted before retire runs. When retire executes:
      step-3: git worktree remove succeeds (worktree dir is valid).
      step-4: git branch -d fails because the branch ref is already gone.
    Retire MUST return a structured error. The post-failure state:
      - worktree IS gone (step-3 succeeded)
      - branch IS gone (was pre-deleted; retire error confirms this)
      - Guardian PROJECT_ROOT lease is released in finally (never stranded)
      - workflow.retire.failed event emitted

    The pre-deletion uses git update-ref -d so no subprocess mocking is needed.

    DEC-WT-RETIRE-005 (supplementary): step-3 (worktree remove) may succeed even
    when step-4 fails; Guardian must handle partial-success atomically.
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-branch-d-fail-001"
    feature_name = "branch-d-fail"
    branch = f"feature/{feature_name}"
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    # Provision + commit + merge so the pre-flight merge check passes.
    provision_worktree(project_root, workflow_id, feature_name, db_path)
    (Path(wt_path) / "step4.txt").write_text("will merge")
    subprocess.run(["git", "-C", wt_path, "add", "step4.txt"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "step4 work"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", project_root, "merge", "--no-ff", branch, "-m", "Merge step4"],
        check=True,
        capture_output=True,
    )

    # Capture the branch tip SHA BEFORE deleting the ref — the commit is still
    # reachable via the worktree's reflog at this point.
    sha_result = subprocess.run(
        ["git", "-C", project_root, "rev-parse", branch],
        capture_output=True,
        text=True,
        check=True,
    )
    branch_sha = sha_result.stdout.strip()
    assert len(branch_sha) == 40, f"Expected 40-char SHA from rev-parse, got: {branch_sha!r}"

    # Pre-delete the branch ref using git update-ref so retire step-4 (git branch -d)
    # fails: branch not found. The SHA is preserved above so we can detach the
    # worktree HEAD (next block) before calling retire.
    subprocess.run(
        ["git", "-C", project_root, "update-ref", "-d", f"refs/heads/{branch}"],
        check=True,
        capture_output=True,
    )

    # Detach the worktree HEAD by overwriting its HEAD file with the bare SHA.
    #
    # After git update-ref -d removes the branch ref, the worktree HEAD still
    # contains "ref: refs/heads/<branch>" (a dangling symref). git worktree
    # remove (without --force) detects this as "contains modified or untracked
    # files" and refuses to remove the worktree — causing step-3 to fail instead
    # of step-4, which is the wrong rollback boundary.
    #
    # Writing the bare commit SHA to the HEAD file detaches the HEAD so git
    # sees a clean, non-dangling worktree. git worktree remove (no --force)
    # then succeeds at step-3, and git branch -D at step-4 fails because the
    # ref is already gone — exactly the step-4 failure boundary we want to test.
    #
    # The worktree .git file contains "gitdir: <path>" where <path> is absolute
    # on macOS linked worktrees. We strip the prefix and resolve to the HEAD
    # file under the shared .git/worktrees/<name>/ admin directory.
    wt_gitfile = Path(wt_path) / ".git"
    gitdir_line = wt_gitfile.read_text().strip()  # "gitdir: /abs/path/.git/worktrees/name"
    gitdir_rel = gitdir_line[len("gitdir:") :].strip()
    # gitdir_rel may be absolute (macOS) or relative (some Linux configs)
    if not Path(gitdir_rel).is_absolute():
        wt_head_file = (Path(wt_path) / gitdir_rel / "HEAD").resolve()
    else:
        wt_head_file = (Path(gitdir_rel) / "HEAD").resolve()
    wt_head_file.write_text(branch_sha + "\n")

    # Confirm the branch is pre-deleted, HEAD is detached, and the worktree still exists.
    branch_pre = subprocess.run(
        ["git", "-C", project_root, "branch", "--list", branch],
        capture_output=True,
        text=True,
        check=True,
    )
    assert branch_pre.stdout.strip() == "", "Branch must be absent before retire (pre-deletion)"
    assert Path(wt_path).exists(), "Worktree must still exist before retire attempt"
    head_content = wt_head_file.read_text().strip()
    assert head_content == branch_sha, (
        f"HEAD file must contain bare SHA (detached) after overwrite, got: {head_content!r}"
    )

    # Retire with --force to bypass the pre-flight merge check (step 2).
    # step-3 (git worktree remove) now succeeds because HEAD is detached (clean,
    # non-dangling). step-4 (git branch -D) fails because the ref is already gone.
    # This exercises the step-4 failure rollback boundary (DEC-WT-RETIRE-003a).
    code, out = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
            "--force",
        ],
        db_path,
    )

    assert code != 0, (
        f"Expected non-zero exit when branch -d fails (branch already gone), got {code}: {out}"
    )
    assert out.get("status") == "error", (
        f"Expected status=error from step-4-fail retire, got: {out}"
    )
    assert out.get("message"), "Error message must be present"

    # Critical: worktree IS gone (step-3 succeeded)
    assert not Path(wt_path).exists(), (
        "Worktree directory must be gone (step-3 git worktree remove succeeded)"
    )

    # Critical: branch IS gone (was pre-deleted)
    branch_after = subprocess.run(
        ["git", "-C", project_root, "branch", "--list", branch],
        capture_output=True,
        text=True,
        check=True,
    )
    assert branch_after.stdout.strip() == "", (
        f"Branch must remain absent (was pre-deleted): {branch_after.stdout!r}"
    )

    # Guardian retire lease must be released in finally — no orphan leases.
    conn = open_db(db_path)
    try:
        failed_events = events_mod.query(conn, type="workflow.retire.failed", limit=10)
        assert len(failed_events) >= 1, "Expected workflow.retire.failed event after step-4 failure"

        recent_guardian_leases = leases_mod.list_leases(conn, role="guardian")
        if recent_guardian_leases:
            latest_g = recent_guardian_leases[0]
            assert latest_g["status"] in ("released", "revoked"), (
                f"Guardian retire lease must be released in finally, got: {latest_g['status']}"
            )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test 4b: step-3 failure — git worktree remove blocked by lock (W-WTR-1)
# ---------------------------------------------------------------------------


def test_retire_worktree_remove_fails_when_locked(tmp_path, git_repo):
    """Step-3 failure: git worktree lock prevents worktree remove from succeeding.

    DEC-WT-RETIRE-003a rollback boundary (step 3 failure):
    git worktree lock prevents git worktree remove from succeeding. The retire
    function raises WITHOUT calling worktrees.remove() or revoking any leases.
    The next retry (after git worktree unlock) sees:
      - worktree still on disk
      - still-active registry row
      - branch still exists (pre-flight passed, but step-3 failed before step-4)
    and converges by retrying from the worktree remove step.

    This test uses git's own locking semantics — no subprocess mocking required.
    After asserting the failure state, the test unlocks the worktree and verifies
    that a second retire call succeeds and reaches the clean terminal state.

    Additional assertions:
      - git branch -d was NOT run (branch still exists after failed retire)
      - worktrees.list_active() still includes the path
      - The retire Guardian PROJECT_ROOT lease was released (no orphan leases)
      - A second retire call after git worktree unlock succeeds and converges
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-partial-001"
    feature_name = "partial-fail"
    branch = f"feature/{feature_name}"
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    # Provision + merge so the pre-flight merge check passes
    provision_worktree(project_root, workflow_id, feature_name, db_path)
    (Path(wt_path) / "step3.txt").write_text("will merge")
    subprocess.run(["git", "-C", wt_path, "add", "step3.txt"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "step3 work"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", project_root, "merge", "--no-ff", branch, "-m", "Merge step3"],
        check=True,
        capture_output=True,
    )

    # Lock the worktree so git worktree remove refuses it (without --force).
    # This uses git's own locking semantics — no subprocess mocking required.
    subprocess.run(
        ["git", "-C", project_root, "worktree", "lock", wt_path],
        check=True,
        capture_output=True,
    )

    # Attempt retire while worktree is locked — must fail at step 3 (worktree remove)
    code_locked, out_locked = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )

    # Must fail with non-zero exit
    assert code_locked != 0, (
        f"Expected non-zero exit when worktree is locked, got {code_locked}: {out_locked}"
    )
    assert out_locked.get("status") == "error", (
        f"Expected status=error from locked-worktree retire, got: {out_locked}"
    )

    # Critical: git branch -d was NOT run — branch still exists
    branch_check = subprocess.run(
        ["git", "-C", project_root, "branch", "--list", branch],
        capture_output=True,
        text=True,
        check=True,
    )
    assert branch_check.stdout.strip() != "", (
        f"Branch must still exist after failed retire (step 3 fail leaves branch untouched): "
        f"{branch_check.stdout!r}"
    )

    # Critical: worktree must still be on disk
    assert Path(wt_path).exists(), (
        "Worktree directory must still exist after failed retire (step 3 fail)"
    )

    # Critical: registry row must still be active
    conn = open_db(db_path)
    try:
        active_after = worktrees_mod.list_active(conn)
        active_paths = [w["path"] for w in active_after]
        assert any(p.endswith(f".worktrees/feature-{feature_name}") for p in active_paths), (
            f"Registry row must still be active after worktree-remove failure: "
            f"active_paths={active_paths}"
        )

        # retire.failed event must be emitted
        events = events_mod.query(conn, type="workflow.retire.failed", limit=10)
        assert len(events) >= 1, (
            "Expected workflow.retire.failed event after locked-worktree retire"
        )

        # Guardian retire lease must be released (not stranded) even though step 3 failed
        recent_guardian_leases = leases_mod.list_leases(conn, role="guardian")
        if recent_guardian_leases:
            latest = recent_guardian_leases[0]  # ordered by issued_at DESC
            assert latest["status"] in ("released", "revoked"), (
                f"Guardian retire lease must be released in finally, got: {latest['status']}"
            )
    finally:
        conn.close()

    # Unlock and verify that a second retire converges to clean terminal state
    subprocess.run(
        ["git", "-C", project_root, "worktree", "unlock", wt_path],
        check=True,
        capture_output=True,
    )

    code_retry, out_retry = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )
    assert code_retry == 0, (
        f"Second retire (after unlock) must succeed, got {code_retry}: {out_retry}"
    )
    assert out_retry.get("status") == "ok", f"Second retire must return status=ok, got: {out_retry}"

    # Clean terminal state: worktree gone, branch gone, registry empty
    assert not Path(wt_path).exists(), "Worktree must be gone after successful retry"
    branch_after = subprocess.run(
        ["git", "-C", project_root, "branch", "--list", branch],
        capture_output=True,
        text=True,
        check=True,
    )
    assert branch_after.stdout.strip() == "", (
        f"Branch must be gone after successful retry: {branch_after.stdout!r}"
    )
    conn2 = open_db(db_path)
    try:
        active_final = worktrees_mod.list_active(conn2)
        assert len(active_final) == 0, (
            f"No active worktrees expected after successful retry: {active_final}"
        )
    finally:
        conn2.close()


# ---------------------------------------------------------------------------
# Test 5: Idempotent — already retired (registry absent + git absent)
# ---------------------------------------------------------------------------


def test_retire_idempotent_already_retired(tmp_path, git_repo):
    """Retire of a workflow whose worktree is already gone returns a structured error.

    After the worktree and branch are already cleaned up, calling retire again
    should return a structured _err payload with a non-zero exit, not crash or
    silently succeed. The caller can detect and handle the already-retired state.
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-idempotent-001"
    feature_name = "already-gone"
    branch = f"feature/{feature_name}"

    # Provision + merge + first retire
    provision_worktree(project_root, workflow_id, feature_name, db_path)
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")
    (Path(wt_path) / "work.txt").write_text("work")
    subprocess.run(["git", "-C", wt_path, "add", "work.txt"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "work"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", project_root, "merge", "--no-ff", branch, "-m", "Merge"],
        check=True,
        capture_output=True,
    )

    # First retire — should succeed
    code1, out1 = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )
    assert code1 == 0, f"First retire failed: {out1}"
    assert not Path(wt_path).exists(), "Worktree must be gone after first retire"

    # Second retire — branch already gone, git branch -d should fail
    code2, out2 = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )

    # Must return a structured error, not 0
    assert code2 != 0, (
        f"Second retire should return non-zero (already retired): code={code2}, out={out2}"
    )
    assert out2.get("status") == "error", f"Expected status=error on re-retire, got: {out2}"
    assert out2.get("message"), "Error message must be present"


# ---------------------------------------------------------------------------
# Test 6: provision -> retire round trip — registry, git, and lease all clean
# ---------------------------------------------------------------------------


def test_provision_retire_round_trip(tmp_path, git_repo):
    """Full provision -> commit -> merge -> retire round trip leaves system in clean state.

    After retire:
    - git worktree list shows only the base (main) worktree
    - git branch --list 'feature/*' is empty
    - worktrees.list_active() is empty
    - No active leases exist for the workflow at the feature worktree path
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-roundtrip-001"
    feature_name = "round-trip"
    branch = f"feature/{feature_name}"
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    # Provision
    prov = provision_worktree(project_root, workflow_id, feature_name, db_path)
    assert Path(prov["worktree_path"]).exists()

    # Commit on feature
    (Path(wt_path) / "roundtrip.txt").write_text("round trip")
    subprocess.run(
        ["git", "-C", wt_path, "add", "roundtrip.txt"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "roundtrip"],
        check=True,
        capture_output=True,
    )

    # Merge
    subprocess.run(
        ["git", "-C", project_root, "merge", "--no-ff", branch, "-m", "Merge roundtrip"],
        check=True,
        capture_output=True,
    )

    # Retire
    code, out = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )
    assert code == 0, f"Retire failed: {out}"

    # git worktree list — only base
    wt_list = subprocess.run(
        ["git", "-C", project_root, "worktree", "list", "--porcelain"],
        capture_output=True,
        text=True,
        check=True,
    )
    wt_paths_after = [
        line[len("worktree ") :].strip()
        for line in wt_list.stdout.splitlines()
        if line.startswith("worktree ")
    ]
    assert len(wt_paths_after) == 1, (
        f"Expected only main worktree after round trip, got: {wt_paths_after}"
    )

    # git branch --list 'feature/*' — empty
    branch_list = subprocess.run(
        ["git", "-C", project_root, "branch", "--list", "feature/*"],
        capture_output=True,
        text=True,
        check=True,
    )
    assert branch_list.stdout.strip() == "", (
        f"Feature branches must be empty after round trip: {branch_list.stdout!r}"
    )

    # DB: no active worktrees
    conn = open_db(db_path)
    try:
        active_wts = worktrees_mod.list_active(conn)
        assert len(active_wts) == 0, f"No active worktrees expected after retire: {active_wts}"

        # No active leases at feature worktree path
        active_wt_leases = leases_mod.list_leases(conn, status="active", worktree_path=wt_path)
        assert len(active_wt_leases) == 0, (
            f"No active leases should remain at feature worktree path after retire: "
            f"{active_wt_leases}"
        )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Test 7: retire revokes all active leases anchored to the worktree path
# ---------------------------------------------------------------------------


def test_retire_revokes_path_anchored_leases(tmp_path, git_repo):
    """Retire explicitly revokes leases anchored at the feature worktree_path.

    DEC-WT-RETIRE-004: retire must NOT call revoke_missing_worktrees() as a
    substitute. Instead it calls leases.revoke() by lease_id for each active
    lease at the worktree_path. This test verifies:
    - Pre-retire: implementer lease active at feature worktree_path
    - Post-retire: that lease is revoked (status='revoked')
    - revoked_lease_ids in the retire result contains the implementer lease ID
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-revoke-001"
    feature_name = "revoke-check"
    branch = f"feature/{feature_name}"
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    # Provision
    prov = provision_worktree(project_root, workflow_id, feature_name, db_path)
    implementer_lease_id = prov["implementer_lease_id"]

    # Verify implementer lease is active before retire
    conn = open_db(db_path)
    try:
        impl_lease_before = leases_mod.get(conn, implementer_lease_id)
        assert impl_lease_before is not None, "Implementer lease must exist before retire"
        assert impl_lease_before["status"] == "active", (
            "Implementer lease must be active before retire"
        )
    finally:
        conn.close()

    # Commit + merge so branch -d succeeds without --force
    (Path(wt_path) / "revoke.txt").write_text("revoke test")
    subprocess.run(
        ["git", "-C", wt_path, "add", "revoke.txt"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "revoke work"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", project_root, "merge", "--no-ff", branch, "-m", "Merge revoke"],
        check=True,
        capture_output=True,
    )

    # Retire
    code, out = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )
    assert code == 0, f"Retire failed: {out}"

    # revoked_lease_ids must include the implementer lease
    assert implementer_lease_id in out["revoked_lease_ids"], (
        f"implementer_lease_id {implementer_lease_id!r} not in revoked_lease_ids: "
        f"{out['revoked_lease_ids']}"
    )

    # DB: implementer lease must now be status='revoked' (not active, not expired)
    conn2 = open_db(db_path)
    try:
        impl_lease_after = leases_mod.get(conn2, implementer_lease_id)
        assert impl_lease_after is not None, "Implementer lease row must still exist in DB"
        assert impl_lease_after["status"] == "revoked", (
            f"Implementer lease must be revoked after retire, got: {impl_lease_after['status']}"
        )
    finally:
        conn2.close()


# ---------------------------------------------------------------------------
# Test 8: --force passes -D to git branch (destructive-class verification)
# ---------------------------------------------------------------------------


def test_retire_force_destructive_class(tmp_path, git_repo):
    """--force flag causes git branch -D (force-delete) to run instead of -d.

    Verifies the --force plumbing: an unmerged branch that would fail under -d
    succeeds under -D when --force is passed. This is the only path that uses
    the destructive git branch -D variant.
    """
    db_path = str(tmp_path / "state.db")
    project_root = git_repo
    workflow_id = "wf-retire-force-001"
    feature_name = "force-delete"
    branch = f"feature/{feature_name}"
    wt_path = str(Path(project_root) / ".worktrees" / f"feature-{feature_name}")

    # Provision + commit on feature branch but do NOT merge
    provision_worktree(project_root, workflow_id, feature_name, db_path)
    (Path(wt_path) / "unmerged.txt").write_text("unmerged work")
    subprocess.run(
        ["git", "-C", wt_path, "add", "unmerged.txt"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", wt_path, "commit", "-m", "unmerged"],
        check=True,
        capture_output=True,
    )

    # Without --force: must fail (unmerged)
    code_no_force, out_no_force = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
        ],
        db_path,
    )
    assert code_no_force != 0, (
        f"Expected failure without --force for unmerged branch, got {code_no_force}: {out_no_force}"
    )

    # After the failed attempt, worktree must still exist (no partial mutation)
    assert Path(wt_path).exists(), "Worktree must still exist after failed non-force retire"

    # With --force: must succeed
    code_force, out_force = run_cli(
        [
            "worktree",
            "retire",
            "--workflow-id",
            workflow_id,
            "--feature-name",
            feature_name,
            "--project-root",
            project_root,
            "--force",
        ],
        db_path,
    )
    assert code_force == 0, f"Expected success with --force, got {code_force}: {out_force}"
    assert out_force.get("status") == "ok", f"Expected status=ok with --force, got: {out_force}"
    assert out_force["force"] is True, "Result must record force=True"

    # Branch must be gone
    branch_check = subprocess.run(
        ["git", "-C", project_root, "branch", "--list", branch],
        capture_output=True,
        text=True,
    )
    assert branch_check.stdout.strip() == "", (
        f"Branch must be gone after --force retire: {branch_check.stdout!r}"
    )

    # Worktree directory must be gone
    assert not Path(wt_path).exists(), "Worktree directory must be gone after --force retire"

    # DB: worktree soft-deleted
    conn = open_db(db_path)
    try:
        active_wts = worktrees_mod.list_active(conn)
        active_paths = [w["path"] for w in active_wts]
        assert not any(p.endswith(f".worktrees/feature-{feature_name}") for p in active_paths), (
            f"Worktree must be soft-deleted after --force retire: {active_paths}"
        )
    finally:
        conn.close()

"""
Slice 22: CUTOVER Invariant #15 Write/Edit real-path mirror.

@decision DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001:
    hooks/track.sh DEC-EVAL-005 block invalidates evaluation_state
    (ready_for_guardian → pending) on Write|Edit source-file mutations.
    Empirically covered by the hook script alone; locked here via real
    subprocess tests that invoke hooks/track.sh end-to-end.
    Mirror for Bash path's test_post_bash_eval_invalidation.py (DEC-EVAL-006-TESTS-001).

Production sequence exercised (track.sh / PostToolUse Write|Edit path):
  1. Reviewer seeds evaluation_state = ready_for_guardian.
  2. Implementer invokes the Write/Edit tool on a source file.
  3. PostToolUse → hooks/track.sh fires (matcher: Write|Edit).
  4. track.sh reads tool_input.file_path from HOOK_INPUT.
  5. is_source_file() + !is_skippable_path() classify the file.
  6. lease_context() resolves workflow_id (lease-first, DEC-WS1-TRACK-001).
  7. rt_eval_invalidate(workflow_id) fires → state flips to pending.
  8. Guardian is denied landing authority until a new reviewer pass.

Invariants locked by this module:
  1. Write/Edit source mutation → ready_for_guardian flipped (DEC-EVAL-005)
  2. Non-source path → readiness preserved (is_source_file / is_skippable_path gate)
  3. Lease-first workflow identity honored (DEC-WS1-TRACK-001)
  4. Idempotent on already non-ready evaluation state (rt_eval_invalidate no-op)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Repo-root resolution
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
_HOOK = str(_REPO_ROOT / "hooks" / "track.sh")
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run_cli(args: list[str], db_path: str, project_root: str = "") -> tuple[int, dict]:
    """Run runtime/cli.py; return (exit_code, parsed_json).

    DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: mirrored from
    test_post_bash_eval_invalidation.py for consistent seeding/assertion.
    """
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": str(_REPO_ROOT)}
    if project_root:
        env["CLAUDE_PROJECT_DIR"] = project_root
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    raw = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = {"_raw": raw}
    return result.returncode, parsed


def _seed_ready(db_path: str, workflow_id: str, project_root: str = "") -> None:
    """Seed evaluation_state = ready_for_guardian for workflow_id.

    DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: canonical seeding helper
    using cc-policy evaluation set (mirrors sibling test).
    """
    code, out = _run_cli(
        ["evaluation", "set", workflow_id, "ready_for_guardian"],
        db_path,
        project_root,
    )
    assert code == 0, f"seed_ready failed (wf={workflow_id!r}): {out}"


def _get_eval_status(db_path: str, workflow_id: str, project_root: str = "") -> str:
    """Return the current evaluation status string for workflow_id.

    DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: mirrors sibling test helper.
    """
    code, out = _run_cli(
        ["evaluation", "get", workflow_id],
        db_path,
        project_root,
    )
    assert code == 0, f"eval get failed (wf={workflow_id!r}): {out}"
    return out.get("status", "")


def _run_track_sh(
    db_path: str,
    project_root: str,
    file_path: str,
    session_id: str = "test-session-track-001",
    ensure_parent: bool = True,
) -> tuple[int, str]:
    """Invoke hooks/track.sh with a synthetic PostToolUse Write payload.

    DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: track.sh reads only
    .tool_input.file_path from HOOK_INPUT (session_id included for completeness).
    The hook is agnostic to tool_name at runtime — the harness matcher handles
    Write|Edit filtering before the hook fires. In tests we supply a realistic
    payload shape matching PostToolUse Write.

    CRITICAL: track.sh line 21 exits silently when the parent directory of
    file_path does not exist:
        [[ ! -e "$(dirname "$FILE_PATH")" ]] && exit 0
    This mirrors real Write/Edit behaviour (the tool can only write to a file
    whose parent exists). Tests must ensure the parent directory exists for
    invalidation cases (ensure_parent=True, the default).

    Returns (exit_code, combined_stderr_output).
    """
    if ensure_parent:
        Path(file_path).parent.mkdir(parents=True, exist_ok=True)

    payload = {
        "session_id": session_id,
        "tool_name": "Write",
        "tool_input": {"file_path": file_path},
        "tool_response": {"output": ""},
    }
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db_path,
        "CLAUDE_PROJECT_DIR": project_root,
        "CLAUDE_SESSION_ID": session_id,
        "PYTHONPATH": str(_REPO_ROOT),
    }
    result = subprocess.run(
        ["bash", _HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stderr


def _git_init(project_path: Path) -> str:
    """Initialise a git repo in project_path with an initial commit.

    DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: track.sh's fallback workflow
    identity path (current_workflow_id) calls git -C root rev-parse --abbrev-ref HEAD.
    A git repo is required so the branch name can be resolved when no lease is active.
    Returns the branch name for workflow_id computation.
    """
    subprocess.run(["git", "init", str(project_path)], capture_output=True, check=True)
    subprocess.run(
        ["git", "-C", str(project_path), "config", "user.email", "test@test.com"],
        capture_output=True, check=True,
    )
    subprocess.run(
        ["git", "-C", str(project_path), "config", "user.name", "Test"],
        capture_output=True, check=True,
    )
    (project_path / "README.md").write_text("# test\n")
    subprocess.run(
        ["git", "-C", str(project_path), "add", "README.md"],
        capture_output=True, check=True,
    )
    subprocess.run(
        ["git", "-C", str(project_path), "commit", "-m", "init"],
        capture_output=True, check=True,
    )
    branch_out = subprocess.run(
        ["git", "-C", str(project_path), "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True, text=True,
    )
    return branch_out.stdout.strip()


def _sanitize_token(raw: str) -> str:
    """Mirror context-lib.sh sanitize_token for workflow_id computation.

    DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: tr '/: ' '---' + keep alnum._-
    """
    import re
    out = raw.replace("/", "-").replace(":", "-").replace(" ", "-")
    out = re.sub(r"[^a-zA-Z0-9._-]", "-", out)
    return out if out else "default"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def project(tmp_path):
    """A git-initialised project directory with an initial commit.

    DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: git init needed because
    track.sh calls current_workflow_id() → git rev-parse --abbrev-ref HEAD
    when no active lease is present. Returns (project_path, branch_name).
    """
    proj = tmp_path / "project"
    proj.mkdir()
    branch = _git_init(proj)
    return proj, branch


@pytest.fixture
def db(tmp_path):
    """Path to a fresh SQLite database (string)."""
    return str(tmp_path / "state.db")


# ---------------------------------------------------------------------------
# Vacuous-truth: infrastructure exists before substantive tests
# ---------------------------------------------------------------------------


class TestInfrastructureExists:
    """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: confirm hooks exist."""

    def test_track_sh_exists_and_nonempty(self):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: track.sh must exist
        and be non-empty before any invalidation test can be meaningful.
        """
        hook = Path(_HOOK)
        assert hook.exists(), f"hooks/track.sh not found at {hook}"
        assert hook.stat().st_size > 0, "hooks/track.sh is empty"

    def test_schema_has_evaluation_state_table(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: evaluation_state table
        must exist after schema init for SQLite assertions to be valid.
        """
        import sqlite3
        proj, _ = project
        # Seed triggers schema init via cli.py
        _seed_ready(db, "wf-infra-check", str(proj))
        conn = sqlite3.connect(db)
        tables = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )}
        conn.close()
        assert "evaluation_state" in tables, (
            f"evaluation_state table missing; found: {tables}"
        )

    def test_parent_dir_guard_preserves_ready_when_parent_absent(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: track.sh line 21
        exits silently when the parent directory of file_path does not exist.

        This is a production-reality guard: the Write/Edit tool always writes
        to a path whose parent exists. When the parent is absent, track.sh
        exits 0 without touching evaluation_state. Tests must create parent
        directories for invalidation to fire — this test explicitly locks the
        guard behaviour so future changes to track.sh cannot accidentally
        remove this early-exit check and fire invalidation on phantom paths.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))
        assert _get_eval_status(db, wf_id, str(proj)) == "ready_for_guardian"

        # Source file whose parent dir does NOT exist — trigger the early-exit guard
        phantom_file = str(proj / "nonexistent_dir" / "module.py")
        assert not Path(phantom_file).parent.exists(), (
            "Test setup error: phantom parent directory must not exist"
        )

        # ensure_parent=False so we don't mkdir (simulates the guard condition)
        code, stderr = _run_track_sh(
            db, str(proj), phantom_file, ensure_parent=False
        )
        assert code == 0, f"track.sh must exit 0 even for phantom path: {code}\n{stderr}"

        # State must remain ready_for_guardian (early exit, no invalidation)
        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "ready_for_guardian", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: parent-dir guard must "
            f"prevent invalidation for paths with missing parent, got {status!r}"
        )


# ---------------------------------------------------------------------------
# Invariant 1: Write source mutation invalidates ready_for_guardian
# ---------------------------------------------------------------------------


class TestWriteSourceMutationInvalidatesReady:
    """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Invariant 1.

    Write to a source-extension path (.py, .sh, .ts, ...) while
    evaluation_state is ready_for_guardian MUST flip it to pending.
    This mirrors the DEC-EVAL-005 block in track.sh lines 46-84.
    """

    def test_write_py_source_invalidates_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Write to a .py file
        when eval is ready_for_guardian flips it to pending.

        Production sequence:
          1. Seed ready_for_guardian.
          2. Run track.sh with file_path pointing to a .py source path.
          3. Assert state is now pending.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))
        assert _get_eval_status(db, wf_id, str(proj)) == "ready_for_guardian"

        # Source file path: .py extension triggers is_source_file()
        source_file = str(proj / "runtime" / "core" / "something.py")

        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, (
            f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"
        )

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "pending", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected pending "
            f"after .py Write source mutation, got {status!r}"
        )

    def test_write_sh_source_invalidates_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: .sh is in SOURCE_EXTENSIONS;
        Write to a shell script must also invalidate readiness.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))

        source_file = str(proj / "hooks" / "some_hook.sh")
        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "pending", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected pending "
            f"after .sh Write source mutation, got {status!r}"
        )

    def test_write_ts_source_invalidates_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: .ts is in SOURCE_EXTENSIONS;
        Write to a TypeScript file must also invalidate readiness.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))

        source_file = str(proj / "src" / "index.ts")
        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "pending", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected pending "
            f"after .ts Write source mutation, got {status!r}"
        )


# ---------------------------------------------------------------------------
# Invariant 2: Non-source path preserves readiness
# ---------------------------------------------------------------------------


class TestNonSourcePathPreservesReadiness:
    """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Invariant 2.

    Write to a non-source path (.md, .txt, .json, skippable build/ dir)
    must NOT invalidate evaluation_state. The is_source_file() + is_skippable_path()
    gate must silently skip invalidation for these paths.
    """

    def test_write_md_file_preserves_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: .md is NOT in
        SOURCE_EXTENSIONS. Write to a Markdown file must leave readiness intact.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))
        assert _get_eval_status(db, wf_id, str(proj)) == "ready_for_guardian"

        # .md file: not a source extension
        doc_file = str(proj / "ClauDEX" / "SOME_DOC.md")
        code, stderr = _run_track_sh(db, str(proj), doc_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "ready_for_guardian", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected ready_for_guardian "
            f"preserved after .md Write, got {status!r}"
        )

    def test_write_json_file_preserves_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: .json is NOT in
        SOURCE_EXTENSIONS. Write to a JSON config file must leave readiness intact.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))

        json_file = str(proj / "settings.json")
        code, stderr = _run_track_sh(db, str(proj), json_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "ready_for_guardian", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected ready_for_guardian "
            f"preserved after .json Write, got {status!r}"
        )

    def test_write_skippable_build_path_preserves_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Paths matching
        is_skippable_path() (build/, dist/, node_modules/, __pycache__/ etc.)
        must NOT invalidate evaluation_state even when the file extension is .py.

        is_skippable_path pattern: 'build' matches build/ directories.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))

        # .py under build/ — source extension but skippable directory
        skippable_file = str(proj / "build" / "output.py")
        code, stderr = _run_track_sh(db, str(proj), skippable_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "ready_for_guardian", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected ready_for_guardian "
            f"preserved after build/.py skippable Write, got {status!r}"
        )

    def test_write_node_modules_path_preserves_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: node_modules/ matches
        is_skippable_path(). Write to a .js file in node_modules must be a no-op.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))

        skippable_file = str(proj / "node_modules" / "lib" / "index.js")
        code, stderr = _run_track_sh(db, str(proj), skippable_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "ready_for_guardian", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected ready_for_guardian "
            f"preserved after node_modules/.js skippable Write, got {status!r}"
        )

    def test_write_tmp_non_source_path_preserves_ready(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: tmp/*.txt is NOT a
        source file. Write to a scratch file preserves readiness.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))

        scratch_file = str(proj / "tmp" / "scratch.txt")
        code, stderr = _run_track_sh(db, str(proj), scratch_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "ready_for_guardian", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected ready_for_guardian "
            f"preserved after tmp/.txt Write, got {status!r}"
        )


# ---------------------------------------------------------------------------
# Invariant 3: Lease-first workflow identity resolution
# ---------------------------------------------------------------------------


class TestLeaseFirstWorkflowIdentityResolution:
    """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Invariant 3.

    When an active implementer lease is present, track.sh must derive
    workflow_id from the lease (DEC-WS1-TRACK-001), NOT from the git branch.
    This ensures invalidation targets the same workflow_id the evaluator
    (reviewer) cleared, avoiding the scenario where the stale ready_for_guardian
    state persists because invalidation fired against the wrong workflow_id.
    """

    def test_lease_first_identity_invalidates_correct_workflow(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Active lease workflow_id
        determines which evaluation row is invalidated.

        Production sequence:
          1. Issue + claim a lease with an explicit workflow_id distinct from
             the branch-derived id.
          2. Seed ready_for_guardian under the LEASE workflow_id.
          3. Verify branch-derived workflow_id is NOT ready.
          4. Run track.sh with a source file_path.
          5. Assert LEASE workflow_id evaluation is now pending.
          6. Assert branch-derived workflow_id is unchanged (no spurious flip).
        """
        proj, branch = project
        branch_wf_id = _sanitize_token(branch)

        # Lease workflow_id deliberately differs from the branch-derived id
        lease_wf_id = "lease-track-invariant3-001"

        # Issue a lease so lease_context() returns it for this worktree
        code, lease_out = _run_cli(
            [
                "lease", "issue-for-dispatch",
                "implementer",
                "--workflow-id", lease_wf_id,
                "--worktree-path", str(proj),
                "--branch", branch,
                "--no-eval",
            ],
            db,
            str(proj),
        )
        assert code == 0, f"lease issue failed: {lease_out}"

        lease_id = (
            lease_out.get("lease_id", "")
            or (lease_out.get("lease") or {}).get("lease_id", "")
        )
        assert lease_id, f"lease_id missing from issue response: {lease_out}"

        # Claim the lease so lease current returns it for this worktree
        code, claim_out = _run_cli(
            ["lease", "claim", "impl-track-test-001", "--lease-id", lease_id],
            db,
            str(proj),
        )
        assert code == 0, f"lease claim failed: {claim_out}"

        # Seed ready_for_guardian under the LEASE workflow_id
        _seed_ready(db, lease_wf_id, str(proj))
        assert _get_eval_status(db, lease_wf_id, str(proj)) == "ready_for_guardian"

        # Branch-derived workflow_id should NOT be ready
        branch_status = _get_eval_status(db, branch_wf_id, str(proj))
        assert branch_status in ("idle", "pending", ""), (
            f"branch-derived wf_id {branch_wf_id!r} should not be ready: {branch_status!r}"
        )

        # Run track.sh with a source file — must use lease-first identity
        source_file = str(proj / "runtime" / "core" / "impl.py")
        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, (
            f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"
        )

        # LEASE workflow_id evaluation must be invalidated
        lease_status_after = _get_eval_status(db, lease_wf_id, str(proj))
        assert lease_status_after == "pending", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected lease "
            f"workflow_id {lease_wf_id!r} evaluation_state=pending after source "
            f"mutation (lease-first identity DEC-WS1-TRACK-001), got {lease_status_after!r}\n"
            f"stderr:\n{stderr}"
        )

        # Branch-derived workflow_id must remain unchanged (no spurious flip)
        branch_status_after = _get_eval_status(db, branch_wf_id, str(proj))
        assert branch_status_after == branch_status, (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: branch-derived "
            f"workflow_id {branch_wf_id!r} changed unexpectedly: "
            f"{branch_status!r} → {branch_status_after!r}"
        )


# ---------------------------------------------------------------------------
# Invariant 4: Idempotent on already non-ready evaluation state
# ---------------------------------------------------------------------------


class TestIdempotentInvalidation:
    """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Invariant 4.

    rt_eval_invalidate only fires when status is exactly ready_for_guardian.
    For any other state (pending, idle, needs_changes), a source Write must
    be a silent no-op — state unchanged, exit 0.
    """

    def test_already_pending_is_noop(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: evaluation_state=pending
        before Write → must remain pending (no double-invalidation error).
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        # Seed pending (not ready_for_guardian)
        code, _ = _run_cli(
            ["evaluation", "set", wf_id, "pending"],
            db, str(proj),
        )
        assert code == 0

        source_file = str(proj / "runtime" / "core" / "already_pending.py")
        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "pending", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected pending "
            f"state unchanged after second Write, got {status!r}"
        )

    def test_already_needs_changes_is_noop(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: evaluation_state=needs_changes
        before Write → must remain needs_changes (idempotent, no error).
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        code, _ = _run_cli(
            ["evaluation", "set", wf_id, "needs_changes"],
            db, str(proj),
        )
        assert code == 0

        source_file = str(proj / "src" / "component.py")
        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, f"track.sh exited non-zero: {code}\nstderr:\n{stderr}"

        status = _get_eval_status(db, wf_id, str(proj))
        assert status == "needs_changes", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: expected needs_changes "
            f"state unchanged after Write, got {status!r}"
        )

    def test_double_write_is_idempotent(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Two consecutive Write
        events: first flips ready → pending; second is a no-op leaving pending.
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        _seed_ready(db, wf_id, str(proj))
        assert _get_eval_status(db, wf_id, str(proj)) == "ready_for_guardian"

        source_file = str(proj / "main.py")

        # First Write: should flip ready → pending
        code1, stderr1 = _run_track_sh(db, str(proj), source_file)
        assert code1 == 0, f"first track.sh run failed: {code1}\nstderr:\n{stderr1}"
        assert _get_eval_status(db, wf_id, str(proj)) == "pending"

        # Second Write on same file: must remain pending (no error, no double-flip)
        code2, stderr2 = _run_track_sh(db, str(proj), source_file)
        assert code2 == 0, f"second track.sh run failed: {code2}\nstderr:\n{stderr2}"
        assert _get_eval_status(db, wf_id, str(proj)) == "pending", (
            f"DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: second Write must "
            f"be idempotent (pending unchanged), got "
            f"{_get_eval_status(db, wf_id, str(proj))!r}"
        )


# ---------------------------------------------------------------------------
# Compound interaction: full production sequence end-to-end
# ---------------------------------------------------------------------------


class TestFullProductionSequenceE2E:
    """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Compound-interaction test.

    Exercises the real production sequence crossing multiple internal components:
      - runtime/cli.py (evaluation set/get, lease issue/claim)
      - hooks/track.sh (shell hook adapter)
      - hooks/context-lib.sh (is_source_file, is_skippable_path, lease_context,
        current_workflow_id, rt_eval_invalidate)
      - hooks/lib/runtime-bridge.sh (cc_policy, rt_eval_invalidate wrapper)
      - SQLite evaluation_state table

    Required by implementer spec: one test exercising the real production sequence
    end-to-end, crossing the boundaries of multiple internal components and covering
    the actual state transitions involved in production.
    """

    def test_full_write_edit_eval_invalidation_cycle(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Full cycle.

        Phase 1: reviewer seeds ready_for_guardian.
        Phase 2: implementer Writes a source file → state flips to pending.
        Phase 3: non-source Write → state remains pending (no double-flip).
        Phase 4: (simulated) re-clearance → ready_for_guardian.
        Phase 5: another source Write → pending again.
        Phase 6: non-source Write → still pending (no spurious change).
        """
        proj, branch = project
        wf_id = _sanitize_token(branch)

        # Phase 1: reviewer clears → ready_for_guardian
        _seed_ready(db, wf_id, str(proj))
        assert _get_eval_status(db, wf_id, str(proj)) == "ready_for_guardian"

        # Phase 2: implementer Writes a source file
        source_file = str(proj / "runtime" / "core" / "evaluation.py")
        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, f"track.sh phase 2 failed: {code}\nstderr:\n{stderr}"
        assert _get_eval_status(db, wf_id, str(proj)) == "pending", (
            "DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Phase 2 must flip "
            "ready_for_guardian → pending"
        )

        # Phase 3: Write a non-source file → state stays pending
        doc_file = str(proj / "docs" / "NOTES.md")
        code, _ = _run_track_sh(db, str(proj), doc_file)
        assert code == 0
        assert _get_eval_status(db, wf_id, str(proj)) == "pending", (
            "DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Phase 3 non-source "
            "Write must leave pending unchanged"
        )

        # Phase 4: simulated re-clearance by reviewer
        _seed_ready(db, wf_id, str(proj))
        assert _get_eval_status(db, wf_id, str(proj)) == "ready_for_guardian"

        # Phase 5: another source Write → pending again
        source_file_2 = str(proj / "hooks" / "new_hook.sh")
        code, stderr = _run_track_sh(db, str(proj), source_file_2)
        assert code == 0, f"track.sh phase 5 failed: {code}\nstderr:\n{stderr}"
        assert _get_eval_status(db, wf_id, str(proj)) == "pending", (
            "DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Phase 5 second source "
            "Write must flip ready_for_guardian → pending again"
        )

        # Phase 6: non-source Write → still pending (no change)
        json_file = str(proj / "package.json")
        code, _ = _run_track_sh(db, str(proj), json_file)
        assert code == 0
        assert _get_eval_status(db, wf_id, str(proj)) == "pending", (
            "DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: Phase 6 non-source "
            "Write must leave pending unchanged"
        )

    def test_lease_first_e2e_invalidation_with_source_write(self, project, db):
        """DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: End-to-end with lease.

        Full production sequence with an active implementer lease:
          1. Issue + claim implementer lease with explicit workflow_id.
          2. Seed ready_for_guardian under lease workflow_id.
          3. Write source file → track.sh uses lease-first identity.
          4. Lease workflow_id flips to pending.
          5. Non-source Write → state unchanged (still pending).
        """
        proj, branch = project
        lease_wf_id = "lease-e2e-track-002"

        # Issue + claim lease
        code, lease_out = _run_cli(
            [
                "lease", "issue-for-dispatch",
                "implementer",
                "--workflow-id", lease_wf_id,
                "--worktree-path", str(proj),
                "--branch", branch,
                "--no-eval",
            ],
            db,
            str(proj),
        )
        assert code == 0, f"lease issue failed: {lease_out}"
        lease_id = (
            lease_out.get("lease_id", "")
            or (lease_out.get("lease") or {}).get("lease_id", "")
        )
        assert lease_id, f"lease_id missing: {lease_out}"

        code, claim_out = _run_cli(
            ["lease", "claim", "impl-e2e-001", "--lease-id", lease_id],
            db, str(proj),
        )
        assert code == 0, f"lease claim failed: {claim_out}"

        # Seed ready under lease workflow
        _seed_ready(db, lease_wf_id, str(proj))
        assert _get_eval_status(db, lease_wf_id, str(proj)) == "ready_for_guardian"

        # Source Write → lease-first identity → lease wf invalidated
        source_file = str(proj / "runtime" / "core" / "leases.py")
        code, stderr = _run_track_sh(db, str(proj), source_file)
        assert code == 0, f"track.sh failed: {code}\nstderr:\n{stderr}"

        assert _get_eval_status(db, lease_wf_id, str(proj)) == "pending", (
            "DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: E2E lease-first: "
            f"lease workflow_id {lease_wf_id!r} must be pending after source Write"
        )

        # Non-source Write → still pending
        doc_file = str(proj / "README.md")
        code, _ = _run_track_sh(db, str(proj), doc_file)
        assert code == 0
        assert _get_eval_status(db, lease_wf_id, str(proj)) == "pending", (
            "DEC-CLAUDEX-TRACK-HOOK-EVAL-INVALIDATION-001: E2E: non-source Write "
            "after pending must leave state unchanged"
        )

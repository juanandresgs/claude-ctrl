"""Shell-boundary tests for hooks/post-bash.sh — Invariant #15.

Verifies that post-bash.sh closes the Bash shell-mutation bypass for
evaluation_state readiness invalidation (DEC-EVAL-006).

Production sequence (what these tests exercise):
  1. Orchestrator seeds evaluation_state = ready_for_guardian via CLI.
  2. Implementer runs a Bash command that modifies a source file
     (e.g. `sed -i ...`, `python3 gen.py > src/out.py`).
  3. PostToolUse Bash → hooks/post-bash.sh fires.
  4. post-bash.sh detects git-visible source mutation via
     `git diff --name-only HEAD`.
  5. rt_eval_invalidate is called → state flips to pending.
  6. Guardian is denied landing authority until a new reviewer pass.

Tests use a tempdir + git-init project + SQLite fixture (same pattern
as other shell-boundary tests). post-bash.sh is invoked via subprocess
with a synthetic PostToolUse payload on stdin.

@decision DEC-EVAL-006-TESTS-001
@title Shell-boundary tests for post-bash.sh eval invalidation
@status accepted
@rationale Invariant #15 (DEC-EVAL-006) must be proven by running the
  actual hook script in a realistic environment, not mocked. Policy-unit
  tests (conftest.py / make_context) test Python policy modules; the
  shell adapter needs subprocess-level coverage so future refactors cannot
  silently break the hook without a test failure.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
_HOOK = str(_REPO_ROOT / "hooks" / "post-bash.sh")
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run_cli(args: list[str], db_path: str, project_root: str = "") -> tuple[int, dict]:
    """Run runtime/cli.py; return (exit_code, parsed_json)."""
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


def _run_hook(
    db_path: str,
    project_root: str,
    command: str = "echo hello",
    session_id: str = "test-session-001",
    tool_use_id: str = "",
    set_env_session_id: bool = True,
    payload_cwd: str = "",
) -> tuple[int, str]:
    """Run post-bash.sh with a synthetic PostToolUse Bash payload.

    Returns (exit_code, combined_stderr_output).
    """
    payload_obj = {
        "session_id": session_id,
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "tool_response": {"output": ""},
        "cwd": payload_cwd or project_root,
    }
    if tool_use_id:
        payload_obj["tool_use_id"] = tool_use_id
    payload = json.dumps(payload_obj)
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db_path,
        "CLAUDE_PROJECT_DIR": project_root,
        "PYTHONPATH": str(_REPO_ROOT),
    }
    if set_env_session_id:
        env["CLAUDE_SESSION_ID"] = session_id
    result = subprocess.run(
        ["bash", _HOOK],
        input=payload,
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stderr


def _capture_baseline(
    project_root: str,
    session_id: str = "test-session-001",
    baseline_key: str | None = None,
) -> str:
    """Capture a source-fingerprint baseline (mirrors pre-bash.sh capture).

    Calls compute_source_fingerprint from context-lib.sh and writes the
    result to the same tmp file that pre-bash.sh would create.
    Returns the fingerprint string.
    """
    hooks_dir = str(_REPO_ROOT / "hooks")
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_SESSION_ID": session_id,
    }
    key = baseline_key or session_id
    script = (
        f'source "{hooks_dir}/log.sh"\n'
        f'source "{hooks_dir}/context-lib.sh"\n'
        f'FP=$(compute_source_fingerprint "{project_root}")\n'
        f'mkdir -p "{project_root}/tmp"\n'
        f'printf \'%s\' "$FP" > "{project_root}/tmp/.bash-source-baseline-{key}"\n'
        f'printf \'%s\' "$FP"\n'
    )
    result = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env=env,
    )
    return result.stdout.strip()


def _git_init(project_path: Path) -> None:
    """Initialise a bare git repo in project_path with an initial commit."""
    subprocess.run(["git", "init", str(project_path)], capture_output=True, check=True)
    subprocess.run(
        ["git", "-C", str(project_path), "config", "user.email", "test@test.com"],
        capture_output=True, check=True,
    )
    subprocess.run(
        ["git", "-C", str(project_path), "config", "user.name", "Test"],
        capture_output=True, check=True,
    )
    # Initial commit so HEAD exists
    readme = project_path / "README.md"
    readme.write_text("# test\n")
    subprocess.run(
        ["git", "-C", str(project_path), "add", "README.md"],
        capture_output=True, check=True,
    )
    subprocess.run(
        ["git", "-C", str(project_path), "commit", "-m", "init"],
        capture_output=True, check=True,
    )


def _seed_ready(db_path: str, workflow_id: str, project_root: str = "") -> None:
    """Seed evaluation_state = ready_for_guardian for workflow_id."""
    code, out = _run_cli(
        ["evaluation", "set", workflow_id, "ready_for_guardian"],
        db_path,
        project_root,
    )
    assert code == 0, f"seed_ready failed: {out}"


def _get_eval_status(db_path: str, workflow_id: str, project_root: str = "") -> str:
    """Return the current evaluation status string."""
    code, out = _run_cli(
        ["evaluation", "get", workflow_id],
        db_path,
        project_root,
    )
    assert code == 0, f"eval get failed: {out}"
    return out.get("status", "")


def _get_eval_record(db_path: str, workflow_id: str, project_root: str = "") -> dict:
    """Return the current evaluation row."""
    code, out = _run_cli(
        ["evaluation", "get", workflow_id],
        db_path,
        project_root,
    )
    assert code == 0, f"eval get failed: {out}"
    return out


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def project(tmp_path):
    """A git-initialised project directory with an initial commit."""
    proj = tmp_path / "project"
    proj.mkdir()
    _git_init(proj)
    return proj


@pytest.fixture
def db(tmp_path):
    """Path to a fresh SQLite database."""
    return str(tmp_path / "state.db")


# ---------------------------------------------------------------------------
# 1. Mutating bash invalidates ready_for_guardian → pending
# ---------------------------------------------------------------------------


class TestMutatingBashInvalidatesReady:
    def test_mutating_bash_invalidates_ready_to_pending(self, project, db):
        """A Bash command that modifies a tracked source file must flip
        evaluation_state from ready_for_guardian → pending.

        Production sequence:
          1. Seed ready_for_guardian.
          2. Create a modified .py file (simulates `sed -i` or similar).
          3. Run post-bash.sh.
          4. Assert state is now pending.
        """
        # Derive workflow_id the same way context-lib.sh does (branch name)
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        # Sanitize: tr '/: ' '---' + tr -cd '[:alnum:]._-'
        import re
        wf_id = re.sub(r"[^a-zA-Z0-9._-]", "-", branch.replace("/", "-").replace(":", "-").replace(" ", "-"))

        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # Simulate a Bash source mutation: create a modified .py file
        src_file = project / "src.py"
        src_file.write_text("# modified\n")

        # Run post-bash.sh — it should detect the untracked .py file
        code, stderr = _run_hook(db, str(project), command="echo mutated")
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "pending", (
            f"expected evaluation_state=pending after source mutation, got {status!r}"
        )


# ---------------------------------------------------------------------------
# 2. Non-mutating bash leaves ready_for_guardian unchanged
# ---------------------------------------------------------------------------


class TestNonMutatingBashLeavesReady:
    def test_non_mutating_bash_leaves_ready_unchanged(self, project, db):
        """A Bash command that does NOT modify any source file must leave
        evaluation_state = ready_for_guardian unchanged.

        Commands like `pytest`, `ls`, `echo` produce no git-visible mutations.
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(r"[^a-zA-Z0-9._-]", "-", branch.replace("/", "-").replace(":", "-").replace(" ", "-"))

        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # No source file mutation — project is clean
        code, stderr = _run_hook(db, str(project), command="pytest -q")
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "ready_for_guardian", (
            f"expected evaluation_state=ready_for_guardian unchanged, got {status!r}"
        )


# ---------------------------------------------------------------------------
# 3. Non-source file mutation does not invalidate
# ---------------------------------------------------------------------------


class TestNonSourceFileMutationDoesNotInvalidate:
    def test_skippable_path_mutation_does_not_invalidate(self, project, db):
        """Modifying a path that is_skippable_path returns True for must NOT
        invalidate evaluation_state.

        Skippable paths include: node_modules, vendor, build, __pycache__,
        .generated., .min., .config., .test., .spec. — see context-lib.sh.
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(r"[^a-zA-Z0-9._-]", "-", branch.replace("/", "-").replace(":", "-").replace(" ", "-"))

        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # Create a file in a skippable path (build/ directory)
        build_dir = project / "build"
        build_dir.mkdir()
        skippable_file = build_dir / "output.js"
        skippable_file.write_text("// build artifact\n")

        code, stderr = _run_hook(db, str(project), command="make build")
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "ready_for_guardian", (
            f"expected evaluation_state=ready_for_guardian after skippable "
            f"path mutation (build/output.js), got {status!r}"
        )

    def test_doc_file_mutation_does_not_invalidate(self, project, db):
        """Modifying a .md file (not a source extension) must NOT invalidate.

        is_source_file() only matches SOURCE_EXTENSIONS. .md files do not
        match, so they are invisible to the invalidation logic.
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(r"[^a-zA-Z0-9._-]", "-", branch.replace("/", "-").replace(":", "-").replace(" ", "-"))

        _seed_ready(db, wf_id, str(project))

        # Modify docs/NOTES.md (not a source extension)
        docs_dir = project / "docs"
        docs_dir.mkdir()
        (docs_dir / "NOTES.md").write_text("# notes\n")

        code, stderr = _run_hook(db, str(project), command="echo docs")
        assert code == 0

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "ready_for_guardian", (
            f"expected ready_for_guardian after .md mutation, got {status!r}"
        )


# ---------------------------------------------------------------------------
# 4. Lease-first workflow_id used for invalidation
# ---------------------------------------------------------------------------


class TestLeaseFirstWorkflowIdUsedForInvalidation:
    def test_lease_first_workflow_id_used_for_invalidation(self, project, db):
        """When an active lease is present, invalidation must target the
        lease's workflow_id, not the branch-derived id.

        This mirrors DEC-WS1-TRACK-001 (track.sh lease-first identity).
        Without lease-first identity, a source write fires rt_eval_invalidate
        against the branch-derived workflow_id while the evaluator clearance
        lives under the lease workflow_id — the invalidation is a no-op and
        the stale ready_for_guardian state persists.

        Production sequence:
          1. Issue a lease with an explicit workflow_id (differs from branch).
          2. Seed ready_for_guardian under the LEASE workflow_id.
          3. Modify a source file (simulates Bash mutation).
          4. Run post-bash.sh.
          5. Assert the LEASE workflow_id state is now pending.
          6. Assert the branch-derived workflow_id is still idle/unset
             (no spurious invalidation against the wrong key).
        """
        # Branch-derived workflow_id (what falls back when no lease exists)
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        branch_wf_id = re.sub(
            r"[^a-zA-Z0-9._-]", "-",
            branch.replace("/", "-").replace(":", "-").replace(" ", "-"),
        )

        # Lease workflow_id is deliberately different from the branch name
        lease_wf_id = "lease-test-workflow-001"

        # Issue a lease for this worktree/workflow
        code, lease_out = _run_cli(
            [
                "lease", "issue-for-dispatch",
                "implementer",
                "--workflow-id", lease_wf_id,
                "--worktree-path", str(project),
                "--branch", branch,
                "--no-eval",
            ],
            db,
            str(project),
        )
        assert code == 0, f"lease issue failed: {lease_out}"
        # lease_out has shape {"lease": {"lease_id": ...}, "status": "ok"}
        lease_id = (
            lease_out.get("lease_id", "")
            or (lease_out.get("lease") or {}).get("lease_id", "")
        )
        assert lease_id, f"lease_id missing from: {lease_out}"

        # Claim the lease so it becomes active for this worktree
        code, claim_out = _run_cli(
            ["lease", "claim", "impl-001", "--lease-id", lease_id],
            db,
            str(project),
        )
        assert code == 0, f"lease claim failed: {claim_out}"

        # Seed ready_for_guardian under the LEASE workflow_id
        _seed_ready(db, lease_wf_id, str(project))
        assert _get_eval_status(db, lease_wf_id, str(project)) == "ready_for_guardian"

        # Verify branch-derived workflow_id is NOT ready
        assert _get_eval_status(db, branch_wf_id, str(project)) in (
            "idle", "pending", ""
        ), "branch-derived id must not have ready state before the test"

        # Simulate a source mutation
        src_file = project / "main.py"
        src_file.write_text("# source change\n")

        # Run post-bash.sh — must use lease-first identity
        code, stderr = _run_hook(db, str(project), command="echo source mutated")
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        # LEASE workflow_id must be invalidated
        lease_status = _get_eval_status(db, lease_wf_id, str(project))
        assert lease_status == "pending", (
            f"expected lease workflow_id '{lease_wf_id}' evaluation_state=pending "
            f"after source mutation, got {lease_status!r}. "
            "post-bash.sh must use lease-first identity (DEC-WS1-TRACK-001)."
        )


# ---------------------------------------------------------------------------
# 5. State already pending is a no-op (idempotent)
# ---------------------------------------------------------------------------


class TestIdempotentInvalidation:
    def test_already_pending_is_noop(self, project, db):
        """If evaluation_state is already pending, running post-bash.sh
        with a source mutation should remain pending (no-op, not error).
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(r"[^a-zA-Z0-9._-]", "-", branch.replace("/", "-").replace(":", "-").replace(" ", "-"))

        # Seed pending (not ready_for_guardian) directly
        code, _ = _run_cli(
            ["evaluation", "set", wf_id, "pending"],
            db, str(project),
        )
        assert code == 0

        # Create a source mutation
        (project / "app.py").write_text("# change\n")

        code, stderr = _run_hook(db, str(project), command="echo already-pending")
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "pending", (
            f"expected pending state unchanged, got {status!r}"
        )


# ---------------------------------------------------------------------------
# 6. Compound interaction: full production sequence end-to-end
# ---------------------------------------------------------------------------


class TestFullProductionSequenceE2E:
    """Exercises the full production sequence crossing multiple internal
    components: git, SQLite eval state, lease context, and the shell hook.

    This is the Compound-Interaction Test required by the implementer spec.
    """

    def test_full_eval_invalidation_cycle(self, project, db):
        """Full cycle: seed ready → bash mutation → invalidated → stays pending.

        This sequence crosses:
          - runtime/cli.py (evaluation set/get/invalidate commands)
          - hooks/post-bash.sh (shell adapter)
          - git working tree (mutation detection)
          - SQLite (state storage)
          - context-lib.sh (is_source_file, is_skippable_path, lease_context,
            current_workflow_id, rt_eval_invalidate)
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(r"[^a-zA-Z0-9._-]", "-", branch.replace("/", "-").replace(":", "-").replace(" ", "-"))

        # Phase 1: reviewer clears the code → ready_for_guardian
        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # Phase 2: implementer runs a Bash command that modifies source
        (project / "utils.py").write_text("def util(): pass\n")

        # Phase 3: PostToolUse Bash fires
        code, stderr = _run_hook(db, str(project), command="python3 codegen.py")
        assert code == 0

        # Phase 4: state must be pending (clearance revoked)
        assert _get_eval_status(db, wf_id, str(project)) == "pending"

        # Phase 5: a second Bash command (non-mutating) must not affect state
        code, _ = _run_hook(db, str(project), command="ls -la")
        assert code == 0
        # State stays pending — the mutation is still there
        assert _get_eval_status(db, wf_id, str(project)) == "pending"

        # Phase 6: commit the change, re-seed ready_for_guardian (simulates
        # reviewer re-clearing after the fix)
        subprocess.run(
            ["git", "-C", str(project), "add", "utils.py"], capture_output=True
        )
        subprocess.run(
            ["git", "-C", str(project), "commit", "-m", "add utils"],
            capture_output=True,
        )
        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # Phase 7: no new mutation — state stays ready
        code, _ = _run_hook(db, str(project), command="git status")
        assert code == 0
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"


# ---------------------------------------------------------------------------
# 6b. Guardian commit materialization keeps readiness on the new commit
# ---------------------------------------------------------------------------


class TestGuardianCommitHeadPromotion:
    def test_git_dash_c_commit_from_parent_payload_promotes_eval_head(self, tmp_path, db):
        """Post-bash must follow the git -C target and promote reviewer head.

        Live regression: Guardian committed reviewed staged work in a linked
        feature worktree via ``git -C <worktree> commit`` from a parent-session
        cwd. The feature commit succeeded, but post-bash resolved the parent
        cwd and left evaluation_state.head_sha pinned to the pre-commit parent,
        so the subsequent merge was denied as stale.
        """
        repo = tmp_path / "repo"
        repo.mkdir()
        _git_init(repo)

        worktree = repo / ".worktrees" / "feature-head-promotion"
        worktree.parent.mkdir()
        subprocess.run(
            ["git", "-C", str(repo), "worktree", "add", str(worktree), "-b", "feature/head-promotion"],
            capture_output=True,
            text=True,
            check=True,
        )

        wf_id = "wf-head-promotion"
        old_head = subprocess.run(
            ["git", "-C", str(worktree), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        code, out = _run_cli(
            ["evaluation", "set", wf_id, "ready_for_guardian", "--head-sha", old_head],
            db,
            str(worktree),
        )
        assert code == 0, out
        code, out = _run_cli(
            [
                "lease",
                "issue-for-dispatch",
                "guardian",
                "--workflow-id",
                wf_id,
                "--worktree-path",
                str(worktree),
                "--allowed-ops",
                '["routine_local","high_risk"]',
            ],
            db,
            str(worktree),
        )
        assert code == 0, out

        (worktree / "src").mkdir()
        (worktree / "src" / "feature.py").write_text("VALUE = 1\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(worktree), "add", "src/feature.py"], check=True)
        _capture_baseline(str(worktree), baseline_key="tool-commit")

        command = f'git -C "{worktree}" commit -m "feature commit"'
        subprocess.run(
            ["git", "-C", str(worktree), "commit", "-m", "feature commit"],
            capture_output=True,
            text=True,
            check=True,
        )
        new_head = subprocess.run(
            ["git", "-C", str(worktree), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        assert new_head != old_head

        code, stderr = _run_hook(
            db,
            str(repo),
            command=command,
            tool_use_id="tool-commit",
            payload_cwd=str(repo),
        )
        assert code == 0, stderr

        eval_row = _get_eval_record(db, wf_id, str(worktree))
        assert eval_row.get("status") == "ready_for_guardian"
        assert eval_row.get("head_sha") == new_head


# ---------------------------------------------------------------------------
# 7. Staged-source-baseline: pre-existing changes + non-mutating command
#    must NOT invalidate (circular invalidation fix)
# ---------------------------------------------------------------------------


class TestStagedSourceBaselineNoInvalidation:
    """Pre-existing staged source changes that are unchanged across a Bash
    command must NOT trigger invalidation. This is the core fix for the
    circular invalidation bug where every Bash command reset evaluation_state
    because post-bash.sh detected already-staged files as 'mutations'.
    """

    def test_preexisting_staged_source_preserves_ready(self, project, db):
        """Sequence:
          1. Create and stage a source file (pre-existing checkpoint debt).
          2. Seed ready_for_guardian.
          3. Capture baseline fingerprint (simulates pre-bash.sh).
          4. Run post-bash.sh with a non-mutating command.
          5. Assert state remains ready_for_guardian (fingerprints match).
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(
            r"[^a-zA-Z0-9._-]", "-",
            branch.replace("/", "-").replace(":", "-").replace(" ", "-"),
        )

        # Create a pre-existing source change (simulates checkpoint debt)
        src_file = project / "staged_module.py"
        src_file.write_text("# pre-existing staged change\ndef checkpoint(): pass\n")
        subprocess.run(
            ["git", "-C", str(project), "add", "staged_module.py"],
            capture_output=True, check=True,
        )

        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # Capture baseline fingerprint (pre-bash.sh would do this)
        baseline = _capture_baseline(str(project))
        assert baseline, "baseline fingerprint must be non-empty"

        # Run post-bash.sh — non-mutating command, fingerprints should match
        code, stderr = _run_hook(db, str(project), command="echo non-mutating")
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "ready_for_guardian", (
            f"expected ready_for_guardian preserved (pre-existing staged source "
            f"unchanged across command), got {status!r}"
        )


# ---------------------------------------------------------------------------
# 8. Staged-mutation: already-changed source file mutated further during
#    command must invalidate
# ---------------------------------------------------------------------------


class TestStagedMutationInvalidates:
    """A source file that was already changed (staged) BEFORE the command,
    then mutated FURTHER during the command, must trigger invalidation.
    The fingerprint detects content changes, not just path presence.
    """

    def test_further_mutation_of_staged_source_invalidates(self, project, db):
        """Sequence:
          1. Create and stage a source file with content A.
          2. Seed ready_for_guardian.
          3. Capture baseline fingerprint (includes file with content A hash).
          4. Modify the file to content B and stage it (simulates Bash mutation).
          5. Run post-bash.sh.
          6. Assert state is pending (fingerprints differ due to content change).
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(
            r"[^a-zA-Z0-9._-]", "-",
            branch.replace("/", "-").replace(":", "-").replace(" ", "-"),
        )

        # Create source file with content A and stage it
        src_file = project / "evolving_module.py"
        src_file.write_text("# version A\ndef original(): pass\n")
        subprocess.run(
            ["git", "-C", str(project), "add", "evolving_module.py"],
            capture_output=True, check=True,
        )

        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # Capture baseline fingerprint with content A
        baseline = _capture_baseline(str(project))
        assert baseline, "baseline fingerprint must be non-empty"

        # Simulate Bash command mutating the file further (content B)
        src_file.write_text("# version B\ndef mutated(): pass\n")
        subprocess.run(
            ["git", "-C", str(project), "add", "evolving_module.py"],
            capture_output=True, check=True,
        )

        # Run post-bash.sh — fingerprints should differ, triggering invalidation
        code, stderr = _run_hook(db, str(project), command="python3 codegen.py")
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "pending", (
            f"expected evaluation_state=pending after further mutation of "
            f"already-staged source file, got {status!r}"
        )


# ---------------------------------------------------------------------------
# 9. Payload identity fallback: baseline key must remain stable even when
#    CLAUDE_SESSION_ID env var is absent
# ---------------------------------------------------------------------------


class TestPayloadIdentityBaselineKey:
    """Regression for live harness behavior where CLAUDE_SESSION_ID may be absent.

    pre-bash/post-bash must use hook payload identity (tool_use_id/session_id)
    so they share the same baseline filename and avoid false invalidation.
    """

    def test_payload_tool_use_id_baseline_without_env_session_id(self, project, db):
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(
            r"[^a-zA-Z0-9._-]", "-",
            branch.replace("/", "-").replace(":", "-").replace(" ", "-"),
        )

        # Pre-existing staged source change (matches real checkpoint-debt setup).
        src_file = project / "payload_identity_module.py"
        src_file.write_text("# staged baseline content\n")
        subprocess.run(
            ["git", "-C", str(project), "add", "payload_identity_module.py"],
            capture_output=True, check=True,
        )

        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        baseline_key = "toolu-payload-key-001"
        baseline = _capture_baseline(
            str(project),
            session_id="unused-session-id",
            baseline_key=baseline_key,
        )
        assert baseline, "baseline fingerprint must be non-empty"

        # No CLAUDE_SESSION_ID in env; hook must still resolve the same baseline
        # file via payload tool_use_id and preserve ready_for_guardian.
        code, stderr = _run_hook(
            db,
            str(project),
            command="echo payload-key",
            session_id="payload-session-001",
            tool_use_id=baseline_key,
            set_env_session_id=False,
        )
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "ready_for_guardian", (
            f"expected ready_for_guardian preserved via payload baseline key, got {status!r}"
        )

    def test_payload_session_id_fallback_without_env_or_tool_use_id(self, project, db):
        """When tool_use_id is absent from the payload, the baseline key must
        fall back to payload session_id — NOT to $$ (PID).

        This simulates the production case where CLAUDE_SESSION_ID is unset
        and the payload does not carry tool_use_id but does carry session_id.
        pre and post hooks run as separate processes (different PIDs), so $$
        would produce different filenames and break the pairing.
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(
            r"[^a-zA-Z0-9._-]", "-",
            branch.replace("/", "-").replace(":", "-").replace(" ", "-"),
        )

        src_file = project / "session_fallback_module.py"
        src_file.write_text("# pre-existing staged content\n")
        subprocess.run(
            ["git", "-C", str(project), "add", "session_fallback_module.py"],
            capture_output=True, check=True,
        )

        _seed_ready(db, wf_id, str(project))
        assert _get_eval_status(db, wf_id, str(project)) == "ready_for_guardian"

        # Baseline key = payload session_id (no tool_use_id)
        payload_session = "session-fallback-key-002"
        baseline = _capture_baseline(
            str(project),
            session_id="unused",
            baseline_key=payload_session,
        )
        assert baseline, "baseline fingerprint must be non-empty"

        # No CLAUDE_SESSION_ID, no tool_use_id — hook must use payload session_id
        code, stderr = _run_hook(
            db,
            str(project),
            command="echo session-fallback",
            session_id=payload_session,
            tool_use_id="",
            set_env_session_id=False,
        )
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "ready_for_guardian", (
            f"expected ready_for_guardian preserved via payload session_id "
            f"fallback, got {status!r}"
        )

    def test_mutation_invalidates_with_payload_key(self, project, db):
        """Even with payload-based baseline key, a real source mutation
        between pre and post MUST still trigger invalidation.
        """
        branch_out = subprocess.run(
            ["git", "-C", str(project), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True,
        )
        branch = branch_out.stdout.strip()
        import re
        wf_id = re.sub(
            r"[^a-zA-Z0-9._-]", "-",
            branch.replace("/", "-").replace(":", "-").replace(" ", "-"),
        )

        src_file = project / "payload_mutated.py"
        src_file.write_text("# version A\n")
        subprocess.run(
            ["git", "-C", str(project), "add", "payload_mutated.py"],
            capture_output=True, check=True,
        )

        _seed_ready(db, wf_id, str(project))

        baseline_key = "toolu-mutation-key-003"
        _capture_baseline(str(project), baseline_key=baseline_key)

        # Mutate the file after baseline capture
        src_file.write_text("# version B — mutated\n")

        code, stderr = _run_hook(
            db,
            str(project),
            command="echo mutated",
            session_id="unused",
            tool_use_id=baseline_key,
            set_env_session_id=False,
        )
        assert code == 0, f"post-bash.sh exited non-zero: {code}\nstderr: {stderr}"

        status = _get_eval_status(db, wf_id, str(project))
        assert status == "pending", (
            f"expected pending after real mutation with payload key, got {status!r}"
        )

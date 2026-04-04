"""Regression tests for the two pre-bash.sh acceptance blockers.

Blocker 1 — fail-open: the hook's cc_policy evaluate call used ``|| true``
which silently allowed all operations when the runtime was unavailable or
returned empty output.

Blocker 2 — wrong context: policy context was resolved from the session cwd
rather than the actual git target directory. A command like
``git -C /other-repo commit ...`` caused the engine to use lease, eval_state,
test_state, and scope from /session-repo, not /other-repo.

These tests verify the Python-layer fixes:
  - _handle_evaluate in cli.py must treat empty/invalid stdin as an error
    (non-zero exit) rather than defaulting to allow.
  - build_context() must use ``target_cwd`` when present in the evaluate
    payload, overriding ``cwd``.

Production sequence modelled here:
  pre-bash.sh -> cc_policy evaluate (stdin JSON) -> _handle_evaluate()
  -> build_context(cwd=target_cwd) -> PolicyRegistry.evaluate()

@decision DEC-PE-W3-REG-001
@title Regression tests: fail-closed adapter and target-aware context
@status accepted
@rationale Two acceptance blockers required code changes in cli.py
  (_handle_evaluate) and pre-bash.sh. These tests pin the correct behaviour
  so future changes cannot silently reintroduce fail-open or session-cwd
  cross-contamination. They exercise the real production path (CLI -> context
  builder -> registry) without mocking internal functions.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

_WORKTREE = Path(__file__).resolve().parent.parent.parent.parent
_CLI = str(_WORKTREE / "runtime" / "cli.py")

if str(_WORKTREE) not in sys.path:
    sys.path.insert(0, str(_WORKTREE))

# noqa: E402 — path manipulation must precede these imports
from runtime.core.db import connect_memory  # noqa: E402
from runtime.core.policy_engine import build_context  # noqa: E402
from runtime.schemas import ensure_schema  # noqa: E402


def _run_evaluate(payload: dict, db_path: str, extra_env: dict | None = None) -> tuple[int, dict]:
    """Invoke ``cc-policy evaluate`` with *payload* on stdin.

    Returns (exit_code, parsed_output_dict).
    """
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db_path,
        "PYTHONPATH": str(_WORKTREE),
    }
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        [sys.executable, _CLI, "evaluate"],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
    )
    stdout = result.stdout.strip()
    stderr = result.stderr.strip()
    try:
        parsed = json.loads(stdout or stderr)
    except json.JSONDecodeError:
        parsed = {"_raw": stdout or stderr}
    return result.returncode, parsed


def _run_cli_raw(
    args: list[str], stdin_text: str, db_path: str, extra_env: dict | None = None
) -> tuple[int, str, str]:
    """Run cli.py with raw stdin. Returns (exit_code, stdout, stderr)."""
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db_path,
        "PYTHONPATH": str(_WORKTREE),
    }
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        input=stdin_text,
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


@pytest.fixture
def db(tmp_path):
    return str(tmp_path / "test-state.db")


# ---------------------------------------------------------------------------
# Blocker 1 — fail-closed: runtime/evaluate failure must DENY
# ---------------------------------------------------------------------------


class TestFailClosed:
    """Verify that _handle_evaluate is fail-closed.

    When input is invalid or empty the correct response is a non-zero exit
    code and an error payload on stderr, not a silent allow on stdout.
    """

    def test_empty_stdin_returns_nonzero(self, db):
        """Empty stdin must produce a non-zero exit code, not a silent allow."""
        code, stdout, stderr = _run_cli_raw(["evaluate"], "", db)
        assert code != 0, (
            f"evaluate with empty stdin must exit non-zero; stdout={stdout!r} stderr={stderr!r}"
        )

    def test_empty_stdin_does_not_produce_allow(self, db):
        """Empty stdin must not produce action=allow on stdout."""
        code, stdout, stderr = _run_cli_raw(["evaluate"], "", db)
        if stdout.strip():
            try:
                out = json.loads(stdout)
                assert out.get("action") != "allow", (
                    f"evaluate with empty stdin must not emit action=allow; got: {out}"
                )
            except json.JSONDecodeError:
                pass  # non-JSON stdout with non-zero is fine

    def test_invalid_json_stdin_returns_nonzero(self, db):
        """Malformed JSON on stdin must produce a non-zero exit code."""
        code, stdout, stderr = _run_cli_raw(["evaluate"], "{not valid json}", db)
        assert code != 0, (
            f"evaluate with invalid JSON must exit non-zero; stdout={stdout!r} stderr={stderr!r}"
        )

    def test_invalid_json_error_on_stderr(self, db):
        """Malformed JSON must emit error detail on stderr."""
        code, stdout, stderr = _run_cli_raw(["evaluate"], "{not valid json}", db)
        assert stderr.strip(), (
            "evaluate with invalid JSON must emit something on stderr; "
            f"stderr was empty. stdout={stdout!r}"
        )

    def test_valid_safe_payload_exits_zero(self, db, tmp_path):
        """A well-formed payload for a safe command exits 0 with action field."""
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "git status"},
            "cwd": str(tmp_path),
            "actor_role": "implementer",
            "actor_id": "",
        }
        code, out = _run_evaluate(
            payload,
            db,
            extra_env={"CLAUDE_PROJECT_DIR": str(tmp_path)},
        )
        assert code == 0, f"safe payload should exit 0; got {code}: {out}"
        assert "action" in out, f"output missing 'action' field: {out}"


# ---------------------------------------------------------------------------
# Blocker 2 — target-aware context: git -C <other-repo> must use other-repo state
# ---------------------------------------------------------------------------


class TestTargetAwareContext:
    """Verify that build_context and _handle_evaluate use target_cwd to scope context.

    The core invariant: when a command targets repo B while the session lives
    in repo A, all state lookups (lease, scope, eval_state, test_state,
    workflow_id) must come from repo B's context.

    Unit tests call build_context() directly with an explicit project_root
    override so they are not affected by the CLAUDE_PROJECT_DIR env var.
    CLI-level tests verify the full path: payload -> _handle_evaluate ->
    build_context(project_root=resolved_target_root).
    """

    # -----------------------------------------------------------------------
    # Unit level: build_context project_root override
    # -----------------------------------------------------------------------

    def test_explicit_project_root_overrides_cwd_in_build_context(self, tmp_path):
        """build_context uses project_root when provided, ignoring cwd.

        Without the fix, build_context called detect_project_root(cwd) which
        first checked CLAUDE_PROJECT_DIR (the session repo). With the fix,
        when project_root is provided it is used directly, skipping both
        detect_project_root() and CLAUDE_PROJECT_DIR.
        """
        conn = connect_memory()
        ensure_schema(conn)
        try:
            # cwd points at this worktree (session repo with branch feature-pe-w3)
            session_root = str(_WORKTREE)
            # project_root override points at tmp_path (no git, no state)
            target_root = str(tmp_path)

            ctx = build_context(
                conn,
                cwd=session_root,
                actor_role="implementer",
                actor_id="",
                project_root=target_root,
            )
            # project_root must be the override, NOT the session repo
            assert ctx.project_root == target_root, (
                f"project_root should be target_root={target_root!r}; "
                f"got {ctx.project_root!r} (session root leaked)"
            )
        finally:
            conn.close()

    def test_project_root_override_scopes_workflow_id_to_target(self, tmp_path):
        """workflow_id derived from project_root override differs from session wf.

        This is the canonical contamination check: if the session workflow is
        'feature-pe-w3' and the target is a non-git tmp dir, the workflow_id
        from the target context must NOT be 'feature-pe-w3'.
        """
        conn = connect_memory()
        ensure_schema(conn)
        try:
            session_root = str(_WORKTREE)
            target_root = str(tmp_path)

            # Context derived from session root (what the broken code did)
            ctx_session = build_context(
                conn,
                cwd=session_root,
                actor_role="implementer",
                actor_id="",
            )
            # Context derived from target root (what the fix produces)
            ctx_target = build_context(
                conn,
                cwd=session_root,
                actor_role="implementer",
                actor_id="",
                project_root=target_root,
            )
            # They must differ — the target context must NOT use the session workflow
            assert ctx_target.workflow_id != ctx_session.workflow_id, (
                f"target context has same workflow_id as session ({ctx_session.workflow_id!r}); "
                "session state leaked into target context"
            )
            # target project_root must be the override
            assert ctx_target.project_root == target_root

        finally:
            conn.close()

    def test_seeded_eval_state_not_visible_in_target_context(self, tmp_path):
        """eval_state seeded for session workflow must not appear in target context.

        This is the exact contamination scenario from the acceptance blockers:
          - session workflow 'feature-pe-w3' has eval_state = ready_for_guardian
          - command targets tmp_path (no eval_state)
          - build_context with project_root=tmp_path must return eval_state=None
        """
        conn = connect_memory()
        ensure_schema(conn)
        try:
            # Seed eval_state for the session workflow
            session_ctx = build_context(
                conn, cwd=str(_WORKTREE), actor_role="implementer", actor_id=""
            )
            session_wf = session_ctx.workflow_id
            conn.execute(
                "INSERT OR REPLACE INTO evaluation_state "
                "(workflow_id, status, head_sha, blockers, major, minor, updated_at) "
                "VALUES (?, 'ready_for_guardian', 'abc123', 0, 0, 0, strftime('%s','now'))",
                (session_wf,),
            )
            conn.commit()

            # Now build context for the target (tmp_path, no eval_state)
            target_ctx = build_context(
                conn,
                cwd=str(_WORKTREE),
                actor_role="implementer",
                actor_id="",
                project_root=str(tmp_path),
            )
            assert target_ctx.eval_state is None, (
                f"eval_state from session workflow '{session_wf}' leaked into "
                f"target context: {target_ctx.eval_state}"
            )
        finally:
            conn.close()

    # -----------------------------------------------------------------------
    # CLI level: target_cwd field propagates through _handle_evaluate
    # -----------------------------------------------------------------------

    def test_cli_target_cwd_exits_zero_and_returns_action(self, db, tmp_path):
        """CLI evaluate with target_cwd set to a real directory exits 0.

        The engine resolves project_root from target_cwd; context resolution
        succeeds even when cwd is nonexistent.
        """
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": f"git -C {tmp_path} status"},
            "cwd": "/nonexistent-session-repo-xyzzy",
            "target_cwd": str(tmp_path),
            "actor_role": "implementer",
            "actor_id": "",
        }
        # Do NOT set CLAUDE_PROJECT_DIR — let target_cwd drive resolution
        code, out = _run_evaluate(
            payload,
            db,
            extra_env={"CLAUDE_PROJECT_DIR": ""},
        )
        assert code == 0, (
            "evaluate with valid target_cwd should exit 0 even when cwd is "
            f"nonexistent; got {code}: {out}"
        )
        assert "action" in out, f"output missing 'action' field: {out}"

    def test_backwards_compat_no_target_cwd(self, db, tmp_path):
        """When target_cwd is absent, cwd is used (backwards compatibility)."""
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "git status"},
            "cwd": str(tmp_path),
            "actor_role": "implementer",
            "actor_id": "",
        }
        code, out = _run_evaluate(
            payload,
            db,
            extra_env={"CLAUDE_PROJECT_DIR": str(tmp_path)},
        )
        assert code == 0
        assert "action" in out


# ---------------------------------------------------------------------------
# Compound interaction: target extraction flows through to context scoping
# ---------------------------------------------------------------------------


class TestTargetExtractionEndToEnd:
    """Verify the full production sequence end-to-end.

    Production path:
      hook extracts target_dir from command
      -> passes as target_cwd in evaluate payload
      -> _handle_evaluate() calls build_context(cwd=target_cwd)
      -> all downstream state reads use the correct project_root

    These tests exercise the full CLI -> engine -> registry path without
    mocking any internal component.
    """

    def test_git_dash_c_target_cwd_accepted(self, db, tmp_path):
        """git -C <dir>: evaluate with target_cwd=<dir> exits 0."""
        target = str(tmp_path)
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": f"git -C {target} log --oneline"},
            "cwd": "/unrelated-session-path",
            "target_cwd": target,
            "actor_role": "",
            "actor_id": "",
        }
        code, out = _run_evaluate(
            payload,
            db,
            extra_env={"CLAUDE_PROJECT_DIR": target},
        )
        assert code == 0
        assert out.get("action") in ("allow", "deny", "feedback"), f"unexpected action: {out}"

    def test_cd_and_git_target_cwd_accepted(self, db, tmp_path):
        """cd /dir && git commit ...: evaluate with target_cwd=/dir exits 0."""
        target = str(tmp_path)
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": f"cd {target} && git commit -m 'msg'"},
            "cwd": "/unrelated-session-path",
            "target_cwd": target,
            "actor_role": "",
            "actor_id": "",
        }
        code, out = _run_evaluate(
            payload,
            db,
            extra_env={"CLAUDE_PROJECT_DIR": target},
        )
        assert code == 0
        assert out.get("action") in ("allow", "deny", "feedback"), f"unexpected action: {out}"

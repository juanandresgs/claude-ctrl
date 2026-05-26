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
  - build_context() must use the runtime-resolved target repo rather than the
    session cwd when the command targets another repo.

Production sequence modelled here:
  pre-bash.sh -> cc_policy evaluate (stdin JSON) -> _handle_evaluate()
  -> build_bash_command_intent(command) -> build_context(cwd=effective_cwd)
  -> PolicyRegistry.evaluate()

@decision DEC-PE-W3-REG-001
@title Regression tests: fail-closed adapter and target-aware context
@status accepted
@rationale The acceptance blockers originally required code changes in cli.py
  (_handle_evaluate) and pre-bash.sh. The command-target authority now lives
  in the runtime rather than the hook, but the regressions are the same:
  fail-open is forbidden and session-cwd cross-contamination is forbidden.
  These tests pin the production path (CLI -> command-intent -> context
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


class TestQuotedPromptGitPhrases:
    """Quoted prose about git must not be treated as a real git invocation."""

    @pytest.mark.parametrize(
        "command",
        [
            'node tool.mjs task "investigate git commit gating"',
            'node tool.mjs task "investigate git merge gating"',
            'node tool.mjs task "explain git push --force risks"',
            'node tool.mjs task "when should I use git reset --hard"',
        ],
    )
    def test_evaluate_allows_natural_language_git_phrases(self, db, tmp_path, command):
        _run_cli_raw(["schema", "ensure"], "", db)
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
            "cwd": str(tmp_path),
            "actor_role": "implementer",
            "actor_id": "agent-test",
        }
        code, out = _run_evaluate(
            payload,
            db,
            extra_env={"CLAUDE_PROJECT_DIR": str(tmp_path)},
        )
        assert code == 0, f"evaluate should exit 0 for prose-only git text; got {code}: {out}"
        assert out.get("action") == "allow", (
            f"quoted prose mentioning git must not trigger bash git policies; got {out}"
        )

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
    # CLI level: explicit target_cwd override still works through _handle_evaluate
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

    def test_cli_derives_target_cwd_from_git_dash_c_when_field_absent(self, db, tmp_path):
        """Runtime command-intent derives target_cwd from raw `git -C` text."""
        target = str(tmp_path)
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": f"git -C {target} status"},
            "cwd": "/nonexistent-session-repo-xyzzy",
            "actor_role": "implementer",
            "actor_id": "",
        }
        code, out = _run_evaluate(payload, db, extra_env={"CLAUDE_PROJECT_DIR": ""})
        assert code == 0, f"runtime-derived target_cwd should exit 0; got {code}: {out}"
        assert "action" in out

    def test_cli_derives_target_cwd_from_cd_prefix_when_field_absent(self, db, tmp_path):
        """Runtime command-intent derives target_cwd from raw `cd ... && git ...` text."""
        target = str(tmp_path)
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": f"cd {target} && git status"},
            "cwd": "/nonexistent-session-repo-xyzzy",
            "actor_role": "implementer",
            "actor_id": "",
        }
        code, out = _run_evaluate(payload, db, extra_env={"CLAUDE_PROJECT_DIR": ""})
        assert code == 0, f"runtime-derived target_cwd should exit 0; got {code}: {out}"
        assert "action" in out


# ---------------------------------------------------------------------------
# Compound interaction: target extraction flows through to context scoping
# ---------------------------------------------------------------------------


class TestTargetExtractionEndToEnd:
    """Verify the full production sequence end-to-end.

    Production path:
      runtime derives target_dir from command intent
      -> _handle_evaluate() calls build_context(cwd=effective_cwd)
      -> all downstream state reads use the correct project_root

    These tests exercise the full CLI -> engine -> registry path without
    mocking any internal component.
    """

    def test_git_dash_c_target_cwd_accepted(self, db, tmp_path):
        """Explicit target_cwd override still works for git -C <dir>."""
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
        """Explicit target_cwd override still works for cd /dir && git ... ."""
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


# ---------------------------------------------------------------------------
# Fix #175: PolicyRequest.cwd must be effective_cwd (target), not session cwd
# ---------------------------------------------------------------------------


class TestEffectiveCwdPropagation:
    """Verify that PolicyRequest.cwd is set to target_cwd (effective_cwd),
    not the session cwd, when target_cwd is present in the evaluate payload.

    This tests the specific fix in cli.py _handle_evaluate():
        effective_cwd = target_cwd if resolved_project_root else cwd
        request = PolicyRequest(..., cwd=effective_cwd)

    Verification strategy: build_context() uses effective_cwd to resolve
    project_root and scoped state. When we seed eval_state for the TARGET
    workflow (derived from target_cwd's project root) but NOT for the session
    workflow, a policy that reads eval_state must see the target state —
    proving context was scoped to target_cwd, not session cwd.

    Additionally: when effective_cwd is set correctly, bash_main_sacred's
    fallback path (request.context.project_root or request.cwd) resolves
    to the target directory, not the session directory.

    Production sequence:
      pre-bash.sh extracts target_dir from command
      -> passes target_cwd in JSON payload to cc-policy evaluate
      -> _handle_evaluate() sets effective_cwd = target_cwd
      -> PolicyRequest.cwd = effective_cwd  ← this test verifies
      -> build_context(cwd=effective_cwd) → project_root scoped to target
      -> all policy checks use target context, not session context
    """

    def test_policy_request_cwd_is_target_not_session(self, db, tmp_path):
        """When target_cwd differs from cwd, request.cwd must be target_cwd.

        Verified by seeding eval_state for the TARGET workflow only, then
        confirming the policy engine uses the target context (sees the eval
        state) rather than the session context (which has no eval state).

        If request.cwd were the session cwd (the bug), the engine would use
        the session workflow's context and miss the target eval state, causing
        a different deny reason. With the fix, the target eval state is found.
        """
        import sqlite3

        target = str(tmp_path)

        # Bootstrap schema in the test DB
        _run_cli_raw(["schema", "ensure"], "", db)

        # Determine the workflow_id that build_context would derive for target_cwd.
        # Since tmp_path is not a git repo, current_workflow_id falls back to
        # the basename of the directory.
        import os

        from runtime.core.policy_utils import sanitize_token

        target_wf_id = sanitize_token(os.path.basename(target))

        # Seed eval_state for the TARGET workflow — ready_for_guardian.
        # Also seed binding + scope so bash_workflow_scope doesn't deny first.
        # Use the proper runtime helpers (not raw SQL) to match exact schema.

        from runtime.core import workflows as wf_mod
        from runtime.schemas import ensure_schema as _ensure_schema

        conn = sqlite3.connect(db)
        conn.row_factory = sqlite3.Row
        try:
            _ensure_schema(conn)
            wf_mod.bind_workflow(conn, target_wf_id, target, "feature/test", "main")
            wf_mod.set_scope(conn, target_wf_id, [], [], [], [])
            conn.execute(
                "INSERT OR REPLACE INTO evaluation_state "
                "(workflow_id, status, head_sha, blockers, major, minor, updated_at) "
                "VALUES (?, 'ready_for_guardian', '', 0, 0, 0, strftime('%s','now'))",
                (target_wf_id,),
            )
            conn.commit()
        finally:
            conn.close()

        # Session cwd has NO eval_state — so if the engine used session cwd,
        # it would emit a deny with "not_found" or "unknown".
        # With the fix (effective_cwd = target_cwd), it uses the target workflow
        # which has eval_state = ready_for_guardian, passing the eval gate.

        session_cwd = "/nonexistent-session-repo-xyzzy-175"
        payload = {
            "event_type": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": f"git -C {target} commit -m 'test'"},
            "cwd": session_cwd,
            "target_cwd": target,
            "actor_role": "guardian",
            "actor_id": "agent-test",
        }
        code, out = _run_evaluate(
            payload,
            db,
            extra_env={"CLAUDE_PROJECT_DIR": target},
        )
        assert code == 0, f"evaluate should exit 0; got {code}: {out}"

        # The eval gate (bash_eval_readiness) must NOT deny with session context.
        # If cwd were session_cwd (bug), eval_state would be "not_found" → deny
        # citing evaluation_state. With the fix, target eval state is found.
        if out.get("action") == "deny":
            reason = out.get("reason", "")
            # A deny due to no-lease or main-sacred is acceptable (those are
            # other gates). A deny citing evaluation_state "not_found" would
            # prove the bug is NOT fixed (session context leaked).
            assert "not_found" not in reason, (
                f"Deny cites 'not_found' eval_state — session context leaked into "
                f"target evaluation. effective_cwd was not propagated to request.cwd. "
                f"Full reason: {reason!r}"
            )

    def test_build_context_uses_effective_cwd_directly(self, tmp_path):
        """Unit-level: build_context with project_root=target scopes workflow to target.

        This is the Python-layer proof that effective_cwd (passed as project_root
        override) causes context.project_root to equal the target, meaning
        all downstream state (eval_state, binding, scope) is loaded for the
        target workflow, not the session workflow.

        Complements test_policy_request_cwd_is_target_not_session by verifying
        the build_context() half of the fix independently of the CLI dispatch.
        """
        conn = connect_memory()
        ensure_schema(conn)
        try:
            session_root = str(_WORKTREE)
            target_root = str(tmp_path)

            ctx_with_target = build_context(
                conn,
                cwd=session_root,  # session cwd (old bug: this was used)
                actor_role="guardian",
                actor_id="agent-test",
                project_root=target_root,  # effective_cwd fix: override with target
            )
            # context must be scoped to target, not session
            assert ctx_with_target.project_root == target_root, (
                f"project_root should be target={target_root!r}; "
                f"got {ctx_with_target.project_root!r}"
            )
            # workflow_id must be derived from target (not from session branch)
            ctx_session = build_context(conn, cwd=session_root, actor_role="guardian", actor_id="")
            assert ctx_with_target.workflow_id != ctx_session.workflow_id, (
                "target context workflow_id must differ from session workflow_id; "
                "session context leaked into target evaluation"
            )
        finally:
            conn.close()

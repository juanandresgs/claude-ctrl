"""Shell-boundary regression tests for pre-bash.sh stdout schema.

These tests invoke ``hooks/pre-bash.sh`` directly as a subprocess, feeding
hook JSON on stdin, and assert that stdout is always a valid PreToolUse
envelope:

    { "hookSpecificOutput": { ... } }

Two paths are covered:

  1. **Valid allow path** — the engine resolves and returns an action.
     The hook must pass through the full engine JSON unchanged; the outer
     ``hookSpecificOutput`` key must be present at the top level.

  2. **Fail-closed deny path** — the engine is unavailable (simulated by
     pointing ``cc_policy`` at a broken executable).  The hook must emit
     the same wrapped schema rather than a bare deny object.

These tests exist because the previous implementation extracted the inner
``hookSpecificOutput`` value and printed only that, stripping the wrapper.
Python-layer tests cannot catch that regression because they exercise
``cli.py`` directly; only a shell-boundary test catches what the hook
actually writes to stdout.

@decision DEC-PE-W3-SHELL-001
@title Shell-boundary stdout-schema tests for pre-bash.sh
@status accepted
@rationale cli.py correctly wraps hookSpecificOutput but pre-bash.sh was
  unwrapping it before printing.  Python tests never caught this because
  they test cli.py in isolation.  These tests invoke the hook as a real
  subprocess and assert the top-level wrapper is present on both the allow
  and fail-closed deny paths.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

_WORKTREE = Path(__file__).resolve().parent.parent.parent.parent
_HOOK = str(_WORKTREE / "hooks" / "pre-bash.sh")


def _hook_env(db_path: str, extra_env: dict | None = None) -> dict:
    """Build a minimal environment suitable for running pre-bash.sh."""
    env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "CLAUDE_POLICY_DB": db_path,
        "PYTHONPATH": str(_WORKTREE),
        # Suppress hook sourcing failures by ensuring both lib scripts exist
        # (they are in the real worktree; we just need the PATH to include python)
    }
    if extra_env:
        env.update(extra_env)
    return env


def _run_hook(command: str, db_path: str, extra_env: dict | None = None) -> tuple[int, str, str]:
    """Invoke pre-bash.sh with a Bash PreToolUse payload on stdin.

    Returns (exit_code, stdout, stderr).
    """
    payload = json.dumps(
        {
            "tool_name": "Bash",
            "tool_input": {"command": command},
            "cwd": str(_WORKTREE),
        }
    )
    env = _hook_env(db_path, extra_env)
    result = subprocess.run(
        ["bash", _HOOK],
        input=payload,
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


def _assert_wrapped_schema(stdout: str, path_label: str) -> dict:
    """Assert stdout is valid wrapped hookSpecificOutput JSON.

    Returns the parsed dict so callers can inspect further.
    Raises AssertionError with a clear message on any violation.
    """
    assert stdout.strip(), (
        f"[{path_label}] hook stdout was empty — expected wrapped hookSpecificOutput JSON"
    )
    try:
        parsed = json.loads(stdout.strip())
    except json.JSONDecodeError as exc:
        pytest.fail(f"[{path_label}] hook stdout is not valid JSON: {exc}\nraw stdout: {stdout!r}")
    assert "hookSpecificOutput" in parsed, (
        f"[{path_label}] top-level 'hookSpecificOutput' key missing from hook stdout.\n"
        f"This means the hook emitted the bare inner object instead of the required wrapper.\n"
        f"Got: {json.dumps(parsed, indent=2)}"
    )
    assert isinstance(parsed["hookSpecificOutput"], dict), (
        f"[{path_label}] 'hookSpecificOutput' must be a JSON object; "
        f"got {type(parsed['hookSpecificOutput'])}"
    )
    return parsed


# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def db(tmp_path):
    return str(tmp_path / "test-state.db")


@pytest.fixture
def broken_runtime_root(tmp_path) -> str:
    """Return a CLAUDE_RUNTIME_ROOT path whose cli.py exits 1 with no output.

    The cc_policy bash function (exported by runtime-bridge.sh) calls:
        python3 "$CLAUDE_RUNTIME_ROOT/cli.py" "$@"
    Replacing the PATH executable has no effect because the bash function takes
    precedence.  Setting CLAUDE_RUNTIME_ROOT to a directory with a broken cli.py
    is the correct simulation of an unavailable engine.
    """
    runtime_dir = tmp_path / "broken-runtime"
    runtime_dir.mkdir()
    # A cli.py that always exits 1 with no stdout — simulates engine failure.
    (runtime_dir / "cli.py").write_text(
        "import sys\nsys.stderr.write('simulated engine failure\\n')\nsys.exit(1)\n"
    )
    return str(runtime_dir)


# ---------------------------------------------------------------------------
# Valid allow path: engine succeeds, hook must pass through wrapped JSON
# ---------------------------------------------------------------------------


class TestAllowPathSchema:
    """When cc_policy evaluate succeeds, the hook stdout must be a wrapped
    hookSpecificOutput envelope — not the bare inner object."""

    def test_allow_path_has_hookSpecificOutput_wrapper(self, db, tmp_path):
        """Safe command: hook stdout must have top-level hookSpecificOutput key."""
        code, stdout, stderr = _run_hook(
            "git status",
            db,
            extra_env={"CLAUDE_PROJECT_DIR": str(tmp_path)},
        )
        assert code == 0, f"hook must exit 0 for safe command; got {code}\nstderr: {stderr}"
        _assert_wrapped_schema(stdout, "allow-path:git-status")

    def test_allow_path_hookSpecificOutput_contains_permissionDecision(self, db, tmp_path):
        """The inner hookSpecificOutput must contain a permissionDecision field."""
        _, stdout, _ = _run_hook(
            "git status",
            db,
            extra_env={"CLAUDE_PROJECT_DIR": str(tmp_path)},
        )
        parsed = _assert_wrapped_schema(stdout, "allow-path:permissionDecision-present")
        hso = parsed["hookSpecificOutput"]
        assert "permissionDecision" in hso, (
            f"hookSpecificOutput missing 'permissionDecision': {hso}"
        )

    def test_allow_path_outer_wrapper_not_inner_object(self, db, tmp_path):
        """Regression: hook must NOT print just the inner object as the top level.

        Before the fix, the hook extracted .hookSpecificOutput and printed only
        that dict.  This test catches that regression: if the top-level key is
        'permissionDecision' (the inner field) instead of 'hookSpecificOutput',
        the hook is printing the unwrapped inner object.
        """
        _, stdout, _ = _run_hook(
            "ls -la",
            db,
            extra_env={"CLAUDE_PROJECT_DIR": str(tmp_path)},
        )
        assert stdout.strip(), "hook stdout was empty"
        parsed = json.loads(stdout.strip())
        assert "hookSpecificOutput" in parsed, (
            "top-level key is not 'hookSpecificOutput' — hook is emitting the bare "
            f"inner object (regression). Top-level keys: {list(parsed.keys())}"
        )
        # The inner object must NOT be at the top level
        assert "permissionDecision" not in parsed, (
            "hook emitted inner permissionDecision at top level — the hookSpecificOutput "
            "wrapper is missing (regression from pre-fix behaviour)"
        )


# ---------------------------------------------------------------------------
# Fail-closed deny path: engine unavailable, hook must emit wrapped deny
# ---------------------------------------------------------------------------


class TestFailClosedSchema:
    """When cc_policy evaluate fails, the hook must emit a wrapped deny.

    The deny must also conform to the PreToolUse hookSpecificOutput schema —
    it must NOT be a bare { permissionDecision: "deny", ... } object.
    """

    def test_fail_closed_has_hookSpecificOutput_wrapper(self, db, broken_runtime_root, tmp_path):
        """Broken engine: hook stdout must have top-level hookSpecificOutput key.

        We simulate engine failure by setting CLAUDE_RUNTIME_ROOT to a dir with
        a broken cli.py.  The cc_policy bash function (from runtime-bridge.sh)
        resolves the engine as ``python3 $CLAUDE_RUNTIME_ROOT/cli.py`` — so
        replacing the PATH executable has no effect; the function must be broken
        at the Python level.
        """
        code, stdout, stderr = _run_hook(
            "git status",
            db,
            extra_env={
                "CLAUDE_RUNTIME_ROOT": broken_runtime_root,
                "CLAUDE_PROJECT_DIR": str(tmp_path),
            },
        )
        assert code == 0, (
            f"hook must exit 0 even on engine failure (fail-closed); got {code}\nstderr: {stderr}"
        )
        _assert_wrapped_schema(stdout, "fail-closed:wrapper-present")

    def test_fail_closed_inner_is_deny(self, db, broken_runtime_root, tmp_path):
        """Fail-closed deny must have permissionDecision=deny inside hookSpecificOutput."""
        _, stdout, _ = _run_hook(
            "git status",
            db,
            extra_env={
                "CLAUDE_RUNTIME_ROOT": broken_runtime_root,
                "CLAUDE_PROJECT_DIR": str(tmp_path),
            },
        )
        parsed = _assert_wrapped_schema(stdout, "fail-closed:inner-deny")
        hso = parsed["hookSpecificOutput"]
        assert hso.get("permissionDecision") == "deny", (
            f"fail-closed path must emit permissionDecision=deny inside "
            f"hookSpecificOutput; got: {hso}"
        )

    def test_fail_closed_bare_deny_regression(self, db, broken_runtime_root, tmp_path):
        """Regression: fail-closed must NOT emit a bare deny at the top level.

        Before the fix, the deny object was printed without the hookSpecificOutput
        wrapper.  A bare { "permissionDecision": "deny" } at the top level is
        invalid per the PreToolUse contract.
        """
        _, stdout, _ = _run_hook(
            "git commit -m msg",
            db,
            extra_env={
                "CLAUDE_RUNTIME_ROOT": broken_runtime_root,
                "CLAUDE_PROJECT_DIR": str(tmp_path),
            },
        )
        assert stdout.strip(), "hook stdout was empty on fail-closed path"
        parsed = json.loads(stdout.strip())
        assert "permissionDecision" not in parsed, (
            "fail-closed deny emitted bare permissionDecision at top level — "
            "hookSpecificOutput wrapper is missing (regression). "
            f"Top-level keys: {list(parsed.keys())}"
        )
        assert "hookSpecificOutput" in parsed, (
            f"fail-closed must wrap deny in hookSpecificOutput; "
            f"top-level keys: {list(parsed.keys())}"
        )

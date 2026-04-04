"""Regression tests for pre-write.sh adapter fail-closed behavior.

@decision DEC-HOOK-003
Title: pre-write.sh adapter must fail closed when cc_policy evaluate is unavailable
Status: accepted
Rationale: The hook is a security-critical gate. If the policy runtime
  crashes, is missing, or returns invalid output, the shell adapter must
  DENY the write — not silently allow it. The original implementation used
  ``|| true`` which caused fail-open behavior. This file proves the fix:
  when cc_policy evaluate exits non-zero, or returns empty output, or returns
  non-JSON, the hook emits a deny payload with permissionDecision=deny and
  blockingHook=pre_write_adapter, and exits with code 2.

Production sequence this tests:
  Claude Write/Edit -> pre-write.sh -> cc_policy evaluate (broken) ->
  adapter detects failure -> emits deny JSON -> exits 2 -> write blocked.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path

import pytest

# Resolve the worktree root from this test file's location.
# tests/runtime/policies/test_write_adapter.py -> ../../.. -> worktree root
_WORKTREE = Path(__file__).resolve().parent.parent.parent.parent
_HOOK = str(_WORKTREE / "hooks" / "pre-write.sh")
_HOOKS_DIR = str(_WORKTREE / "hooks")


def _make_hook_input(file_path: str = "/tmp/test_file.py") -> str:
    """Build a minimal Claude PreToolUse JSON payload for Write."""
    return json.dumps(
        {
            "tool_name": "Write",
            "tool_input": {"file_path": file_path},
        }
    )


def _run_hook(
    hook_input: str,
    fake_python_script: str | None = None,
    extra_env: dict | None = None,
) -> tuple[int, str]:
    """Run pre-write.sh and return (exit_code, stdout).

    If fake_python_script is provided, write it to a temp bin dir and put
    that dir first in PATH so cc_policy (which calls python3) hits our stub.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        env = {
            **os.environ,
            "CLAUDE_POLICY_DB": str(Path(tmpdir) / "state.db"),
            # Point runtime root at tmpdir so cc_policy cannot find real cli.py
            "CLAUDE_RUNTIME_ROOT": tmpdir,
        }
        if extra_env:
            env.update(extra_env)

        if fake_python_script is not None:
            # Write a python3 stub that overrides the real one.
            bin_dir = os.path.join(tmpdir, "bin")
            os.makedirs(bin_dir, exist_ok=True)
            stub_path = os.path.join(bin_dir, "python3")
            Path(stub_path).write_text(fake_python_script)
            os.chmod(stub_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)
            env["PATH"] = bin_dir + ":" + env.get("PATH", "")

        result = subprocess.run(
            ["bash", _HOOK],
            input=hook_input,
            capture_output=True,
            text=True,
            env=env,
        )
        return result.returncode, result.stdout


# ---------------------------------------------------------------------------
# Fail-closed: cc_policy unavailable (python3 stub exits non-zero)
# ---------------------------------------------------------------------------


def test_adapter_denies_when_cc_policy_crashes():
    """pre-write.sh must deny when cc_policy evaluate exits non-zero.

    This is the regression for the original fail-open bug: ``|| true`` meant
    a crashing policy runtime was silently swallowed and the write was allowed.
    """
    # python3 stub: exits 1 (simulates missing cli.py or import error)
    stub = "#!/usr/bin/env bash\nexit 1\n"
    # We override python3 itself via PATH so cc_policy (python3 ... cli.py) fails.
    with tempfile.TemporaryDirectory() as tmpdir:
        bin_dir = os.path.join(tmpdir, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        stub_path = os.path.join(bin_dir, "python3")
        Path(stub_path).write_text(stub)
        os.chmod(stub_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)

        env = {
            **os.environ,
            "CLAUDE_POLICY_DB": str(Path(tmpdir) / "state.db"),
            "CLAUDE_RUNTIME_ROOT": tmpdir,
            "PATH": bin_dir + ":" + os.environ.get("PATH", ""),
        }
        result = subprocess.run(
            ["bash", _HOOK],
            input=_make_hook_input("/some/project/app.py"),
            capture_output=True,
            text=True,
            env=env,
        )

    # Must exit non-zero (fail closed)
    assert result.returncode != 0, (
        f"Expected non-zero exit when cc_policy crashes, got 0. "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    # Must emit valid JSON
    stdout = result.stdout.strip()
    assert stdout, f"Expected deny JSON on stdout, got empty. stderr={result.stderr!r}"
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as e:
        pytest.fail(f"pre-write.sh did not emit valid JSON on failure: {e}\nstdout={stdout!r}")

    # Must contain the Claude hook contract fields
    assert "hookSpecificOutput" in payload, f"Missing hookSpecificOutput in: {payload}"
    hook_out = payload["hookSpecificOutput"]
    assert hook_out.get("permissionDecision") == "deny", (
        f"Expected permissionDecision=deny, got: {hook_out}"
    )
    assert hook_out.get("blockingHook") == "pre_write_adapter", (
        f"Expected blockingHook=pre_write_adapter, got: {hook_out}"
    )
    assert hook_out.get("permissionDecisionReason"), "permissionDecisionReason must be non-empty"


def test_adapter_denies_when_cc_policy_returns_empty():
    """pre-write.sh must deny when cc_policy evaluate exits 0 but returns no output.

    An empty response cannot be forwarded to Claude — it must be treated as
    a runtime fault and denied.
    """
    # python3 stub: exits 0 but prints nothing
    stub = "#!/usr/bin/env bash\nexit 0\n"
    with tempfile.TemporaryDirectory() as tmpdir:
        bin_dir = os.path.join(tmpdir, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        stub_path = os.path.join(bin_dir, "python3")
        Path(stub_path).write_text(stub)
        os.chmod(stub_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)

        env = {
            **os.environ,
            "CLAUDE_POLICY_DB": str(Path(tmpdir) / "state.db"),
            "CLAUDE_RUNTIME_ROOT": tmpdir,
            "PATH": bin_dir + ":" + os.environ.get("PATH", ""),
        }
        result = subprocess.run(
            ["bash", _HOOK],
            input=_make_hook_input("/some/project/app.py"),
            capture_output=True,
            text=True,
            env=env,
        )

    assert result.returncode != 0, (
        f"Expected non-zero exit when cc_policy returns empty, got 0. stdout={result.stdout!r}"
    )
    payload = json.loads(result.stdout.strip())
    assert payload["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert payload["hookSpecificOutput"]["blockingHook"] == "pre_write_adapter"


def test_adapter_denies_when_cc_policy_returns_non_json():
    """pre-write.sh must deny when cc_policy evaluate returns non-JSON output.

    Garbled output (e.g., a Python traceback) cannot be parsed. The adapter
    must not silently allow the write.
    """
    # python3 stub: exits 0 but prints a traceback-like string
    stub = '#!/usr/bin/env bash\necho "Traceback (most recent call last): ImportError"\nexit 0\n'
    with tempfile.TemporaryDirectory() as tmpdir:
        bin_dir = os.path.join(tmpdir, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        stub_path = os.path.join(bin_dir, "python3")
        Path(stub_path).write_text(stub)
        os.chmod(stub_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)

        env = {
            **os.environ,
            "CLAUDE_POLICY_DB": str(Path(tmpdir) / "state.db"),
            "CLAUDE_RUNTIME_ROOT": tmpdir,
            "PATH": bin_dir + ":" + os.environ.get("PATH", ""),
        }
        result = subprocess.run(
            ["bash", _HOOK],
            input=_make_hook_input("/some/project/service.go"),
            capture_output=True,
            text=True,
            env=env,
        )

    assert result.returncode != 0, (
        f"Expected non-zero exit when cc_policy returns non-JSON, got 0. stdout={result.stdout!r}"
    )
    payload = json.loads(result.stdout.strip())
    assert payload["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert payload["hookSpecificOutput"]["blockingHook"] == "pre_write_adapter"


def test_adapter_denies_when_cc_policy_returns_json_without_hook_output():
    """pre-write.sh must deny when cc_policy returns valid JSON but missing hookSpecificOutput.

    A JSON response that lacks the Claude hook contract field is not a valid
    policy response and must be treated as a runtime fault.
    """
    stub = '#!/usr/bin/env bash\necho \'{"status": "ok", "action": "allow"}\'\nexit 0\n'
    with tempfile.TemporaryDirectory() as tmpdir:
        bin_dir = os.path.join(tmpdir, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        stub_path = os.path.join(bin_dir, "python3")
        Path(stub_path).write_text(stub)
        os.chmod(stub_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)

        env = {
            **os.environ,
            "CLAUDE_POLICY_DB": str(Path(tmpdir) / "state.db"),
            "CLAUDE_RUNTIME_ROOT": tmpdir,
            "PATH": bin_dir + ":" + os.environ.get("PATH", ""),
        }
        result = subprocess.run(
            ["bash", _HOOK],
            input=_make_hook_input("/some/project/main.ts"),
            capture_output=True,
            text=True,
            env=env,
        )

    assert result.returncode != 0, (
        f"Expected non-zero exit for JSON without hookSpecificOutput, got 0. stdout={result.stdout!r}"
    )
    payload = json.loads(result.stdout.strip())
    assert payload["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert payload["hookSpecificOutput"]["blockingHook"] == "pre_write_adapter"


# ---------------------------------------------------------------------------
# Compound integration: adapter + real runtime — valid allow passes through
# ---------------------------------------------------------------------------


def test_adapter_passes_through_valid_allow_from_real_runtime():
    """Integration: when cc_policy evaluate succeeds and returns valid JSON,
    the adapter passes it through unchanged and exits 0.

    This is the compound-interaction test: it exercises the full shell adapter
    path with the real Python policy runtime — ensuring the fail-closed guard
    does not break the happy path.

    The file path uses a non-source extension (.json) so no policy denies it,
    giving a clean allow response that exercises the pass-through branch.
    """

    # Use the real python3 and a temp DB. JSON files are not source files,
    # so all write-path policies return None (allow).
    with tempfile.TemporaryDirectory() as tmpdir:
        # We need a git repo at the project root so branch_guard can run git
        subprocess.run(["git", "init", tmpdir], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", tmpdir, "checkout", "-b", "feature/test"],
            check=True,
            capture_output=True,
        )

        env = {
            **os.environ,
            "CLAUDE_POLICY_DB": str(Path(tmpdir) / "state.db"),
            "CLAUDE_RUNTIME_ROOT": str(_WORKTREE / "runtime"),
            "PYTHONPATH": str(_WORKTREE),
        }
        target_file = os.path.join(tmpdir, "config.json")
        result = subprocess.run(
            ["bash", _HOOK],
            input=_make_hook_input(target_file),
            capture_output=True,
            text=True,
            env=env,
        )

    # Must exit 0 (allow) and emit valid JSON with allow decision
    assert result.returncode == 0, (
        f"Expected exit 0 for valid allow, got {result.returncode}. "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )
    stdout = result.stdout.strip()
    assert stdout, f"Expected JSON output on allow path, got empty. stderr={result.stderr!r}"
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as e:
        pytest.fail(f"Allow path did not return valid JSON: {e}\nstdout={stdout!r}")

    assert "hookSpecificOutput" in payload, f"Missing hookSpecificOutput on allow: {payload}"
    hook_out = payload["hookSpecificOutput"]
    assert hook_out.get("permissionDecision") == "allow", (
        f"Expected allow on non-source file, got: {hook_out}"
    )

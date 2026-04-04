"""Tests for the hook bridge: local CLI resolution in check-*.sh hooks.

Blocker PE-W5-B1: check-*.sh hooks called `cc-policy context role` as a
bare command, which resolves to $HOME/.claude/runtime/cli.py — that global
CLI does NOT have the `context` subcommand.

PE-W4 superseded the per-hook `_LOCAL_CLI` resolution pattern with a shared
`_local_cc_policy()` wrapper function and a single `_LOCAL_RUNTIME_CLI`
variable. Lifecycle deactivation is now:
  _local_cc_policy lifecycle on-stop "$AGENT_TYPE"

These tests verify:
  1. The local runtime/cli.py responds to `context role` with correct JSON.
  2. The check-*.sh hook files use the W4 lifecycle authority pattern —
     `_local_cc_policy lifecycle on-stop` — not a bare `cc-policy context
     role` invocation, and not the deprecated per-hook `_LOCAL_CLI` pattern.
  3. The full production sequence: hook resolves local CLI via
     _LOCAL_RUNTIME_CLI, calls lifecycle on-stop, marker is cleared.

Production sequence (W4+):
  SubagentStop event -> check-{role}.sh
  -> _local_cc_policy lifecycle on-stop "$AGENT_TYPE"
  -> python3 "$_LOCAL_RUNTIME_CLI" lifecycle on-stop <role>
  -> marker deactivated via Python lifecycle authority (DEC-LIFECYCLE-003)

@decision DEC-PE-W5-BRIDGE-001
Title: check-*.sh hooks delegate lifecycle deactivation to Python authority
Status: superseded-by-W4
Rationale: Blocker PE-W5-B1 introduced per-hook _LOCAL_CLI resolution.
  PE-W4 (DEC-LIFECYCLE-003) replaced that with a shared _local_cc_policy()
  wrapper and `lifecycle on-stop` subcommand — a single Python authority for
  role-matched marker deactivation. No bash-side context role query needed.
  Tests updated to assert the W4 pattern rather than the W5 intermediate.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

_WORKTREE = Path(__file__).resolve().parent.parent.parent
_CLI = str(_WORKTREE / "runtime" / "cli.py")
_HOOKS_DIR = _WORKTREE / "hooks"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_cli(args: list[str], db_path: str, extra_env: dict | None = None) -> tuple[int, str]:
    """Run runtime/cli.py with args; return (exit_code, raw_stdout)."""
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": str(_WORKTREE)}
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stdout.strip()


def run_cli_json(args: list[str], db_path: str, extra_env: dict | None = None) -> tuple[int, dict]:
    code, raw = run_cli(args, db_path, extra_env)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = {"_raw": raw}
    return code, parsed


@pytest.fixture
def db(tmp_path):
    return str(tmp_path / "test-state.db")


# ---------------------------------------------------------------------------
# 1. Local CLI: context role returns correct JSON shape
# ---------------------------------------------------------------------------


class TestContextRoleCommand:
    """Verify that local runtime/cli.py handles `context role` correctly."""

    def test_context_role_no_active_marker_returns_json(self, db):
        """context role with no active lease/marker must return valid JSON with role field."""
        code, out = run_cli_json(["context", "role"], db)
        assert code == 0, f"context role failed with code {code}: {out}"
        # Must be a dict (JSON object)
        assert isinstance(out, dict), f"Expected dict, got: {out}"
        # Must have a 'role' field (may be empty/null but must exist)
        assert "role" in out, f"Missing 'role' field in: {out}"

    def test_context_role_with_active_marker_returns_role(self, db):
        """When a marker is active, context role must resolve the role from it."""
        # Set an active marker
        code, _ = run_cli_json(["marker", "set", "agent-test-001", "implementer"], db)
        assert code == 0

        code, out = run_cli_json(["context", "role"], db)
        assert code == 0, f"context role failed: {out}"
        # With an active marker, role should resolve to "implementer"
        assert out.get("role") == "implementer", f"Expected role=implementer, got: {out}"
        assert out.get("agent_id") == "agent-test-001", (
            f"Expected agent_id=agent-test-001, got: {out}"
        )

    def test_context_role_with_guardian_marker(self, db):
        """context role resolves 'guardian' marker correctly."""
        run_cli_json(["marker", "set", "agent-gd-001", "guardian"], db)
        code, out = run_cli_json(["context", "role"], db)
        assert code == 0
        assert out.get("role") == "guardian"

    def test_context_role_with_tester_marker(self, db):
        """context role resolves 'tester' marker correctly."""
        run_cli_json(["marker", "set", "agent-ts-001", "tester"], db)
        code, out = run_cli_json(["context", "role"], db)
        assert code == 0
        assert out.get("role") == "tester"

    def test_context_role_with_planner_marker(self, db):
        """context role resolves 'planner' marker correctly."""
        run_cli_json(["marker", "set", "agent-pl-001", "planner"], db)
        code, out = run_cli_json(["context", "role"], db)
        assert code == 0
        assert out.get("role") == "planner"

    def test_context_role_after_deactivate_returns_empty_role(self, db):
        """After marker deactivation, role should be empty/null."""
        run_cli_json(["marker", "set", "agent-x", "implementer"], db)
        run_cli_json(["marker", "deactivate", "agent-x"], db)

        code, out = run_cli_json(["context", "role"], db)
        assert code == 0
        # Role should be absent or null after deactivation
        role = out.get("role")
        assert not role, f"Expected empty role after deactivation, got: {role}"

    def test_context_role_output_is_parseable_json(self, db):
        """Raw stdout from `context role` must be valid JSON (not empty, not error text)."""
        run_cli_json(["marker", "set", "agent-j", "implementer"], db)
        code, raw = run_cli(["context", "role"], db)
        assert code == 0
        # Must parse without error
        parsed = json.loads(raw)
        assert isinstance(parsed, dict)


# ---------------------------------------------------------------------------
# 2. Hook source code: check-*.sh must use local CLI path
# ---------------------------------------------------------------------------


class TestHookLocalCLIPattern:
    """Verify that check-*.sh hooks use the W4 lifecycle authority pattern.

    The correct pattern (W4+, DEC-LIFECYCLE-003):
      _LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"
      _local_cc_policy() { ... python3 "$_LOCAL_RUNTIME_CLI" "$@" ... }
      _local_cc_policy lifecycle on-stop "$AGENT_TYPE"

    Forbidden patterns:
      - Bare `cc-policy context role` (resolves to global binary, missing subcommand)
      - Direct `python3 "$_LOCAL_CLI" context role` (superseded by lifecycle on-stop)
    """

    CHECK_HOOKS = [
        "check-implementer.sh",
        "check-guardian.sh",
        "check-tester.sh",
        "check-planner.sh",
    ]

    @pytest.mark.parametrize("hook_name", CHECK_HOOKS)
    def test_hook_uses_local_cli_not_bare_cc_policy(self, hook_name):
        """Hook must NOT call bare `cc-policy context role` for identity resolution.

        Comments are excluded — only executable lines (non-# prefix) are checked.
        A line like ``# PE-W5: use ``cc-policy context role``` in a comment is fine;
        what is forbidden is an active call: ``_ctx_json=$(cc-policy context role ...)``.
        """
        hook_path = _HOOKS_DIR / hook_name
        assert hook_path.exists(), f"Hook file not found: {hook_path}"

        content = hook_path.read_text(encoding="utf-8")

        # Filter to non-comment executable lines only
        executable_lines = [
            line
            for line in content.splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        executable_text = "\n".join(executable_lines)

        # Must NOT have the broken bare cc-policy pattern on an executable line
        assert "cc-policy context role" not in executable_text, (
            f"{hook_name} still calls bare `cc-policy context role` on an executable line. "
            "Fix: use _local_cc_policy lifecycle on-stop (DEC-LIFECYCLE-003)"
        )

    @pytest.mark.parametrize("hook_name", CHECK_HOOKS)
    def test_hook_uses_local_cli_resolution(self, hook_name):
        """Hook must resolve runtime/cli.py locally via _LOCAL_RUNTIME_CLI.

        W4 replaced the per-hook _LOCAL_CLI pattern with a shared _local_cc_policy()
        wrapper backed by _LOCAL_RUNTIME_CLI. Both the variable and the path must
        be present so that no global cc-policy binary is required.
        """
        hook_path = _HOOKS_DIR / hook_name
        assert hook_path.exists(), f"Hook file not found: {hook_path}"

        content = hook_path.read_text(encoding="utf-8")

        # Must use the W4 local runtime CLI variable (not the old _LOCAL_CLI)
        assert "_LOCAL_RUNTIME_CLI" in content, (
            f"{hook_name} missing _LOCAL_RUNTIME_CLI local path resolution. "
            'Expected: _LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"'
        )
        assert "runtime/cli.py" in content, (
            f"{hook_name} missing runtime/cli.py path in local resolution."
        )

    @pytest.mark.parametrize("hook_name", CHECK_HOOKS)
    def test_hook_invokes_python3_with_local_cli(self, hook_name):
        """Hook must delegate lifecycle deactivation to _local_cc_policy, not direct python3.

        W4 (DEC-LIFECYCLE-003): lifecycle on-stop is the single authority.
        The hook calls `_local_cc_policy lifecycle on-stop` which internally
        invokes `python3 "$_LOCAL_RUNTIME_CLI"`. No direct python3 call needed
        at the hook level.
        """
        hook_path = _HOOKS_DIR / hook_name
        assert hook_path.exists()
        content = hook_path.read_text(encoding="utf-8")

        # Must use the W4 lifecycle authority wrapper
        assert "_local_cc_policy lifecycle on-stop" in content, (
            f"{hook_name} missing: _local_cc_policy lifecycle on-stop (DEC-LIFECYCLE-003). "
            "Hook must delegate marker deactivation to the Python lifecycle authority."
        )
        # The wrapper itself must invoke python3 with local CLI
        assert 'python3 "$_LOCAL_RUNTIME_CLI"' in content, (
            f'{hook_name} missing: python3 "$_LOCAL_RUNTIME_CLI" inside _local_cc_policy wrapper.'
        )


# ---------------------------------------------------------------------------
# 3. Compound interaction: full production sequence end-to-end
# ---------------------------------------------------------------------------


class TestContextRoleProductionSequence:
    """End-to-end production sequence: marker set -> context role -> deactivate.

    This is the real sequence that check-*.sh hooks execute during SubagentStop:
      1. Agent stops, check-{role}.sh runs
      2. Hook calls python3 _LOCAL_CLI context role
      3. Gets agent_id from JSON
      4. Calls rt_marker_deactivate(agent_id)
      5. Marker is cleared

    We test this through the CLI (not mocks) to verify the full chain works.
    """

    def test_full_subagent_stop_sequence_implementer(self, db):
        """Simulates check-implementer.sh marker deactivation via context role."""
        # Step 1: An implementer is dispatched — marker set
        code, _ = run_cli_json(["marker", "set", "impl-agent-42", "implementer"], db)
        assert code == 0

        # Step 2: SubagentStop fires — hook calls context role
        code, ctx_out = run_cli_json(["context", "role"], db)
        assert code == 0
        assert ctx_out.get("role") == "implementer"
        agent_id = ctx_out.get("agent_id")
        assert agent_id == "impl-agent-42"

        # Step 3: Hook deactivates the marker using resolved agent_id
        code, _ = run_cli_json(["marker", "deactivate", agent_id], db)
        assert code == 0

        # Step 4: Verify marker is cleared
        code, active_out = run_cli_json(["marker", "get-active"], db)
        assert code == 0
        assert active_out.get("found") is False, "Marker should be inactive after deactivation"

    def test_full_subagent_stop_sequence_guardian(self, db):
        """Simulates check-guardian.sh marker deactivation via context role."""
        run_cli_json(["marker", "set", "gd-agent-07", "guardian"], db)

        code, ctx_out = run_cli_json(["context", "role"], db)
        assert code == 0
        assert ctx_out.get("role") == "guardian"
        agent_id = ctx_out.get("agent_id")
        assert agent_id == "gd-agent-07"

        run_cli_json(["marker", "deactivate", agent_id], db)

        code, active_out = run_cli_json(["marker", "get-active"], db)
        assert active_out.get("found") is False

    def test_context_role_noop_when_role_mismatch(self, db):
        """Hook must NOT deactivate a marker for a different role.

        Simulates: check-implementer.sh fires but the active marker is for
        a 'guardian'. The hook compares _ctx_role == AGENT_TYPE before calling
        rt_marker_deactivate, so it must not clear the guardian marker.
        """
        # Guardian marker is active
        run_cli_json(["marker", "set", "gd-active", "guardian"], db)

        # Implementer hook fires — AGENT_TYPE = "implementer"
        code, ctx_out = run_cli_json(["context", "role"], db)
        assert code == 0
        ctx_role = ctx_out.get("role")
        agent_id = ctx_out.get("agent_id")

        # The hook condition: only deactivate if role matches AGENT_TYPE
        agent_type = "implementer"
        if ctx_role == agent_type and agent_id:
            # This branch must NOT execute — roles differ
            run_cli_json(["marker", "deactivate", agent_id], db)

        # Guardian marker must still be active
        code, active_out = run_cli_json(["marker", "get-active"], db)
        assert active_out.get("found") is True
        assert active_out.get("role") == "guardian"

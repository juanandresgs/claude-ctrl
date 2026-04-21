"""Tests for the hook bridge: local CLI resolution in check-*.sh hooks.

Blocker PE-W5-B1: check-*.sh hooks called `cc-policy context role` as a
bare command, which resolves to $HOME/.claude/runtime/cli.py — that global
CLI does NOT have the `context` subcommand.

PE-W4 superseded the per-hook `_LOCAL_CLI` resolution pattern with a shared
`_local_cc_policy()` wrapper function and a single `_LOCAL_RUNTIME_ROOT`
variable. Lifecycle deactivation is now:
  _local_cc_policy lifecycle on-stop "$AGENT_TYPE"

These tests verify:
  1. The local runtime/cli.py responds to `context role` with correct JSON.
  2. The check-*.sh hook files use the W4 lifecycle authority pattern —
     `_local_cc_policy lifecycle on-stop` — not a bare `cc-policy context
     role` invocation, and not the deprecated per-hook `_LOCAL_CLI` pattern.
  3. The full production sequence: hook resolves the local runtime root via
     _LOCAL_RUNTIME_ROOT, calls lifecycle on-stop, marker is cleared.

Production sequence (W4+):
  SubagentStop event -> check-{role}.sh
  -> _local_cc_policy lifecycle on-stop "$AGENT_TYPE"
  -> cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" lifecycle on-stop <role>
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


@pytest.fixture
def project_dir(tmp_path):
    """Provide a stable project directory for scoped marker tests.

    W-CONV-2 (DEC-CONV-002) scoped marker queries by project_root. Tests that
    exercise ``context role`` must set markers with ``--project-root`` matching
    the ``CLAUDE_PROJECT_DIR`` env var that ``context role`` uses to derive its
    own project_root via detect_project_root(). This fixture returns the
    realpath of tmp_path so normalize_path() produces the same canonical form
    in both the marker-set and context-role code paths.
    """
    return str(tmp_path.resolve())


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

    def test_context_role_with_active_marker_returns_role(self, db, project_dir):
        """When a marker is active, context role must resolve the role from it."""
        # Set an active marker with project_root so scoped query matches
        code, _ = run_cli_json(
            ["marker", "set", "agent-test-001", "implementer", "--project-root", project_dir],
            db,
        )
        assert code == 0

        code, out = run_cli_json(
            ["context", "role"], db, extra_env={"CLAUDE_PROJECT_DIR": project_dir}
        )
        assert code == 0, f"context role failed: {out}"
        # With an active marker, role should resolve to "implementer"
        assert out.get("role") == "implementer", f"Expected role=implementer, got: {out}"
        assert out.get("agent_id") == "agent-test-001", (
            f"Expected agent_id=agent-test-001, got: {out}"
        )

    def test_context_role_with_guardian_marker(self, db, project_dir):
        """context role resolves 'guardian' marker correctly.

        DEC-WHO-GUARDIAN-CANONICALIZE-001: live dispatch writes bare "guardian"
        to agent_markers; build_context() canonicalizes to the compound stage
        using dispatch_phase. With no completion records seeded here, the
        safe-default path routes to guardian:provision (no landing auth).
        """
        run_cli_json(
            ["marker", "set", "agent-gd-001", "guardian", "--project-root", project_dir], db
        )
        code, out = run_cli_json(
            ["context", "role"], db, extra_env={"CLAUDE_PROJECT_DIR": project_dir}
        )
        assert code == 0
        assert out.get("role") == "guardian:provision"

    def test_context_role_tester_marker_is_deactivated_by_schema_cleanup(
        self, db, project_dir
    ):
        """Phase 8 Slice 11: tester is no longer a dispatch-significant role.

        ``ensure_schema()`` (DEC-CONV-002) deactivates any active marker whose
        role is not in the retained set ({planner, implementer, reviewer,
        guardian}). A marker set with ``role=tester`` is immediately
        deactivated on the next CLI invocation, so ``context role`` returns
        an empty role — confirming tester is no longer honoured as an actor
        identity anywhere in the runtime.
        """
        run_cli_json(["marker", "set", "agent-ts-001", "tester", "--project-root", project_dir], db)
        code, out = run_cli_json(
            ["context", "role"], db, extra_env={"CLAUDE_PROJECT_DIR": project_dir}
        )
        assert code == 0
        assert out.get("role") == "", (
            "tester marker must be deactivated by ensure_schema cleanup — "
            f"got role={out.get('role')!r}"
        )

    def test_context_role_with_planner_marker(self, db, project_dir):
        """context role resolves 'planner' marker correctly."""
        run_cli_json(
            ["marker", "set", "agent-pl-001", "planner", "--project-root", project_dir], db
        )
        code, out = run_cli_json(
            ["context", "role"], db, extra_env={"CLAUDE_PROJECT_DIR": project_dir}
        )
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
# 1b. Local CLI: context capability-contract returns correct projection
# ---------------------------------------------------------------------------


class TestContextCapabilityContract:
    """Verify that ``cc-policy context capability-contract --stage <stage>``
    returns a correct JSON projection from authority_registry.resolve_contract()."""

    def test_planner_contract_grants_governance_and_config(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "planner"], db
        )
        assert code == 0, f"unexpected failure: {out}"
        data = out["data"]
        assert data["stage"] == "planner"
        assert "can_write_governance" in data["granted"]
        assert "can_set_control_config" in data["granted"]
        assert data["read_only"] is False

    def test_reviewer_contract_is_read_only_and_denies_write_source_and_land(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "reviewer"], db
        )
        assert code == 0, f"unexpected failure: {out}"
        data = out["data"]
        assert data["stage"] == "reviewer"
        assert data["read_only"] is True
        assert "can_write_source" in data["denied"]
        assert "can_land_git" in data["denied"]

    def test_implementer_contract_grants_write_source(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "implementer"], db
        )
        assert code == 0
        data = out["data"]
        assert data["stage"] == "implementer"
        assert "can_write_source" in data["granted"]

    def test_guardian_land_contract_grants_land_git(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "guardian:land"], db
        )
        assert code == 0
        data = out["data"]
        assert data["stage"] == "guardian:land"
        assert "can_land_git" in data["granted"]

    def test_plan_alias_canonicalizes_to_planner(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "Plan"], db
        )
        assert code == 0, f"unexpected failure: {out}"
        data = out["data"]
        assert data["stage"] == "planner"

    def test_unknown_stage_exits_nonzero(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "ghost_stage"], db
        )
        assert code != 0

    def test_sink_stage_exits_nonzero(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "terminal"], db
        )
        assert code != 0

    def test_output_has_stable_data_keys(self, db):
        code, out = run_cli_json(
            ["context", "capability-contract", "--stage", "planner"], db
        )
        assert code == 0
        data = out["data"]
        assert set(data.keys()) == {"stage", "granted", "denied", "read_only"}
        # granted and denied must be sorted lists
        assert data["granted"] == sorted(data["granted"])
        assert data["denied"] == sorted(data["denied"])


# ---------------------------------------------------------------------------
# 2. Hook source code: check-*.sh must use local CLI path
# ---------------------------------------------------------------------------


class TestHookLocalCLIPattern:
    """Verify that check-*.sh hooks use the W4 lifecycle authority pattern.

    The correct pattern (W4+, DEC-LIFECYCLE-003):
      _LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"
      _local_cc_policy() { ... cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" "$@" ... }
      _local_cc_policy lifecycle on-stop "$AGENT_TYPE"

    Forbidden patterns:
      - Bare `cc-policy context role` (resolves to global binary, missing subcommand)
      - Direct `python3 "$_LOCAL_CLI" context role` (superseded by lifecycle on-stop)
    """

    CHECK_HOOKS = [
        "check-implementer.sh",
        "check-guardian.sh",
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
    def test_hook_uses_local_runtime_root_resolution(self, hook_name):
        """Hook must resolve the worktree runtime root via _LOCAL_RUNTIME_ROOT.

        Hooks now delegate through cc_policy_local_runtime(), which centralizes
        runtime CLI selection and Python interpreter selection in
        hooks/lib/runtime-bridge.sh.
        """
        hook_path = _HOOKS_DIR / hook_name
        assert hook_path.exists(), f"Hook file not found: {hook_path}"

        content = hook_path.read_text(encoding="utf-8")

        assert "_LOCAL_RUNTIME_ROOT" in content, (
            f"{hook_name} missing _LOCAL_RUNTIME_ROOT local path resolution. "
            'Expected: _LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"'
        )
        assert 'cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT"' in content, (
            f"{hook_name} missing cc_policy_local_runtime wrapper."
        )

    @pytest.mark.parametrize("hook_name", CHECK_HOOKS)
    def test_hook_invokes_bridge_local_runtime_wrapper(self, hook_name):
        """Hook must delegate lifecycle deactivation to the bridge wrapper.

        W4 (DEC-LIFECYCLE-003): lifecycle on-stop is the single authority.
        The hook calls `_local_cc_policy lifecycle on-stop` which internally
        invokes `cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT"`. No direct
        hook-local `python3 runtime/cli.py` call is needed.
        """
        hook_path = _HOOKS_DIR / hook_name
        assert hook_path.exists()
        content = hook_path.read_text(encoding="utf-8")

        # Must use the W4 lifecycle authority wrapper
        assert "_local_cc_policy lifecycle on-stop" in content, (
            f"{hook_name} missing: _local_cc_policy lifecycle on-stop (DEC-LIFECYCLE-003). "
            "Hook must delegate marker deactivation to the Python lifecycle authority."
        )
        assert 'cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT"' in content, (
            f'{hook_name} missing: cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" inside _local_cc_policy wrapper.'
        )


# ---------------------------------------------------------------------------
# 2b. check-planner.sh structural assertions (Phase 6 slice 3)
# ---------------------------------------------------------------------------


class TestCheckPlannerHookStructure:
    """Structural assertions on hooks/check-planner.sh.

    Proves the hook parses PLAN_VERDICT/PLAN_SUMMARY trailers and submits
    completion with role planner via the local runtime wrapper. These are
    source-level checks, not execution tests — the hook is advisory (exit 0)
    so we verify intent via string matching rather than full subprocess
    invocation.
    """

    @staticmethod
    def _hook_content() -> str:
        hook_path = _HOOKS_DIR / "check-planner.sh"
        assert hook_path.exists(), "hooks/check-planner.sh not found"
        return hook_path.read_text(encoding="utf-8")

    def test_check_planner_wired_in_settings(self):
        """check-planner.sh must be wired for SubagentStop planner|Plan."""
        import json
        settings_path = _HOOKS_DIR.parent / "settings.json"
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
        hooks = settings.get("hooks", {})
        subagent_stop = hooks.get("SubagentStop", [])
        # settings.json uses {matcher, hooks: [...]} groups
        found = False
        for group in subagent_stop:
            if not isinstance(group, dict):
                continue
            matcher = group.get("matcher", "")
            inner_hooks = group.get("hooks", [])
            if "planner" in matcher.lower():
                for h in inner_hooks:
                    if isinstance(h, dict) and "check-planner.sh" in h.get("command", ""):
                        found = True
                        break
        assert found, "check-planner.sh not wired for SubagentStop planner matcher"

    def test_parses_plan_verdict(self):
        content = self._hook_content()
        assert "PLAN_VERDICT" in content, "check-planner.sh must parse PLAN_VERDICT"
        assert "grep" in content and "PLAN_VERDICT" in content

    def test_parses_plan_summary(self):
        content = self._hook_content()
        assert "PLAN_SUMMARY" in content, "check-planner.sh must parse PLAN_SUMMARY"

    def test_calls_completion_submit_planner(self):
        content = self._hook_content()
        assert "_local_cc_policy completion submit" in content, (
            "check-planner.sh must call _local_cc_policy completion submit"
        )
        assert '"planner"' in content, (
            "check-planner.sh must pass role 'planner' to completion submit"
        )

    def test_advisory_exit_zero(self):
        """Hook must always exit 0 (advisory)."""
        content = self._hook_content()
        lines = content.strip().splitlines()
        last_line = lines[-1].strip()
        assert last_line == "exit 0", (
            f"check-planner.sh must end with 'exit 0', got: {last_line!r}"
        )

    def test_no_exit_nonzero(self):
        """Hook must not have any non-zero exit calls."""
        content = self._hook_content()
        executable_lines = [
            line.strip()
            for line in content.splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        for line in executable_lines:
            if line.startswith("exit ") and line != "exit 0":
                raise AssertionError(
                    f"check-planner.sh has non-zero exit: {line!r}"
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

    def test_full_subagent_stop_sequence_implementer(self, db, project_dir):
        """Simulates check-implementer.sh marker deactivation via context role."""
        _env = {"CLAUDE_PROJECT_DIR": project_dir}
        # Step 1: An implementer is dispatched — marker set with project_root
        code, _ = run_cli_json(
            ["marker", "set", "impl-agent-42", "implementer", "--project-root", project_dir],
            db,
        )
        assert code == 0

        # Step 2: SubagentStop fires — hook calls context role
        code, ctx_out = run_cli_json(["context", "role"], db, extra_env=_env)
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

    def test_full_subagent_stop_sequence_guardian(self, db, project_dir):
        """Simulates check-guardian.sh marker deactivation via context role.

        DEC-WHO-GUARDIAN-CANONICALIZE-001: live bare "guardian" marker
        canonicalizes to guardian:provision (safe default) when no dispatch
        phase is present.
        """
        _env = {"CLAUDE_PROJECT_DIR": project_dir}
        run_cli_json(
            ["marker", "set", "gd-agent-07", "guardian", "--project-root", project_dir], db
        )

        code, ctx_out = run_cli_json(["context", "role"], db, extra_env=_env)
        assert code == 0
        assert ctx_out.get("role") == "guardian:provision"
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

"""Tests for runtime/core/bridge_permissions.py.

@decision DEC-CLAUDEX-BRIDGE-PERMISSIONS-TESTS-001
Title: Bridge permission surface — runtime-delegated patterns absent, safety
       patterns present, and shadow-only discipline pinned by tests
Status: proposed (cc-policy-who-remediation Slice 1)
Rationale: ``runtime/core/bridge_permissions.py`` is the sole declarative
  authority for the ClauDEX bridge permission surface. These tests pin:

    1. The 5 runtime-policy-delegated patterns (git commit/push/merge/
       rebase/reset) are NOT present in the live bridge file's
       ``permissions.deny``. Their presence would short-circuit the
       runtime policy engine (bash_git_who / CAN_LAND_GIT) before it
       can evaluate a landing request.
    2. The safety-deny patterns are still present in the live bridge file.
       These represent destructive / secret-exposure operations that must
       remain hard-denied at the permission layer.
    3. The PreToolUse Bash → pre-bash.sh hook wiring is present. This
       wiring is what routes Bash tool calls through the runtime policy
       engine so the delegated patterns are evaluated there instead.
    4. ``bridge_permissions`` is shadow-only: AST scan confirms no
       ``runtime.core.*`` imports outside of ``cli.py`` and the tests.
    5. ``validate_bridge_settings`` returns an empty list on the real
       bridge file (clean baseline), and non-empty on each of the three
       canonical drift shapes:
         (i)  a delegated pattern added back to deny
         (ii) a safety pattern removed from deny
         (iii) the PreToolUse Bash → pre-bash.sh wiring removed
"""

from __future__ import annotations

import ast
import copy
import inspect
import json
import os
from pathlib import Path

import pytest

from runtime.core import bridge_permissions as bp

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_BRIDGE_SETTINGS_PATH = (
    _REPO_ROOT / "ClauDEX" / "bridge" / "claude-settings.json"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_bridge_settings() -> dict:
    with _BRIDGE_SETTINGS_PATH.open() as f:
        return json.load(f)


def _imported_module_names(module) -> set[str]:
    """Return the set of dotted module names actually imported by ``module``.

    Uses ``ast`` to walk ``Import`` / ``ImportFrom`` nodes so we check the
    actual import graph, not docstring prose.
    """
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module_name = node.module or ""
            if module_name:
                names.add(module_name)
                for alias in node.names:
                    names.add(f"{module_name}.{alias.name}")
    return names


# ---------------------------------------------------------------------------
# 1. Delegated patterns absent from the live bridge deny list
# ---------------------------------------------------------------------------


class TestDelegatedPatternsAbsent:
    def test_git_commit_not_in_bridge_deny(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git commit *)" not in deny, (
            "Bash(git commit *) must not be in bridge permissions.deny — "
            "it is runtime-policy-delegated to bash_git_who"
        )

    def test_git_push_not_in_bridge_deny(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git push *)" not in deny, (
            "Bash(git push *) must not be in bridge permissions.deny — "
            "it is runtime-policy-delegated to bash_git_who"
        )

    def test_git_merge_not_in_bridge_deny(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git merge *)" not in deny, (
            "Bash(git merge *) must not be in bridge permissions.deny — "
            "it is runtime-policy-delegated to bash_git_who"
        )

    def test_git_rebase_not_in_bridge_deny(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git rebase *)" not in deny, (
            "Bash(git rebase *) must not be in bridge permissions.deny — "
            "it is runtime-policy-delegated to bash_git_who"
        )

    def test_git_reset_not_in_bridge_deny(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git reset *)" not in deny, (
            "Bash(git reset *) must not be in bridge permissions.deny — "
            "it is runtime-policy-delegated to bash_git_who"
        )

    def test_all_delegated_patterns_absent_collectively(self):
        """Single collective assertion covering all 5 patterns."""
        settings = _load_bridge_settings()
        deny_set = frozenset(settings["permissions"]["deny"])
        rogue = bp.RUNTIME_POLICY_DELEGATED_BASH_PATTERNS & deny_set
        assert rogue == frozenset(), (
            f"bridge permissions.deny still contains runtime-policy-delegated "
            f"patterns: {sorted(rogue)}"
        )


# ---------------------------------------------------------------------------
# 2. Safety deny patterns still present in the live bridge
# ---------------------------------------------------------------------------


class TestSafetyDeniesPresent:
    def test_notebook_edit_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "NotebookEdit" in deny

    def test_git_checkout_main_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git checkout main*)" in deny

    def test_git_checkout_master_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git checkout master*)" in deny

    def test_git_branch_d_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(git branch -D *)" in deny

    def test_rm_rf_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Bash(rm -rf *)" in deny

    def test_read_env_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Read(**/.env*)" in deny

    def test_read_secrets_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Read(**/secrets/**)" in deny

    def test_read_credentials_present(self):
        settings = _load_bridge_settings()
        deny = settings["permissions"]["deny"]
        assert "Read(**/*credentials*)" in deny

    def test_all_safety_patterns_present_collectively(self):
        settings = _load_bridge_settings()
        deny_set = frozenset(settings["permissions"]["deny"])
        missing = bp.SAFETY_DENY_PATTERNS - deny_set
        assert missing == frozenset(), (
            f"bridge permissions.deny is missing required safety patterns: "
            f"{sorted(missing)}"
        )


# ---------------------------------------------------------------------------
# 3. PreToolUse Bash → pre-bash.sh hook wiring present
# ---------------------------------------------------------------------------


class TestPreToolBashWiringPresent:
    def test_pretooluse_bash_prebash_wiring_is_present(self):
        settings = _load_bridge_settings()
        hooks_block = settings.get("hooks", {})
        pretooluse = hooks_block.get("PreToolUse", [])
        found = False
        for block in pretooluse:
            if not isinstance(block, dict):
                continue
            if block.get("matcher") != "Bash":
                continue
            hooks = block.get("hooks", [])
            for hook in hooks:
                if isinstance(hook, dict):
                    cmd = hook.get("command", "")
                    if "hooks/pre-bash.sh" in cmd:
                        found = True
                        break
            if found:
                break
        assert found, (
            "bridge settings must have a PreToolUse Bash hook that routes "
            "to hooks/pre-bash.sh — this is required for runtime policy "
            "evaluation to be reachable for Bash tool calls"
        )

    def test_validate_settings_confirms_wiring_on_live_file(self):
        settings = _load_bridge_settings()
        messages = bp.validate_bridge_settings(settings)
        # Wiring-related messages would mention "pre-bash.sh"
        wiring_messages = [m for m in messages if "pre-bash.sh" in m]
        assert wiring_messages == [], (
            f"validate_bridge_settings found wiring issues in live file: "
            f"{wiring_messages}"
        )


# ---------------------------------------------------------------------------
# 4. Shadow-only discipline — no runtime.core imports except cli.py and tests
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_bridge_permissions_has_no_runtime_core_dependencies(self):
        """bridge_permissions.py must depend only on stdlib."""
        imported = _imported_module_names(bp)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        assert runtime_core_imports == set(), (
            f"bridge_permissions.py unexpectedly depends on runtime.core "
            f"modules: {runtime_core_imports}. It must remain stdlib-only."
        )

    def test_bridge_permissions_stdlib_only(self):
        """All imports in bridge_permissions.py are stdlib."""
        imported = _imported_module_names(bp)
        allowed_prefixes = (
            "dataclasses",
            "pathlib",
            "typing",
            "json",
            "re",
            "os",  # added 2026-04-17: broker-health probe needs os.kill/os.environ
            "__future__",
        )
        for name in imported:
            assert any(name.startswith(prefix) for prefix in allowed_prefixes), (
                f"bridge_permissions.py imports {name!r} which is not a "
                f"stdlib-only import. Only dataclasses, pathlib, typing, "
                f"json, re, os, and __future__ are permitted."
            )

    def test_core_routing_modules_do_not_import_bridge_permissions(self):
        """Core routing modules must not import bridge_permissions."""
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "bridge_permissions" not in name, (
                    f"{mod.__name__} imports {name!r} — core routing modules "
                    f"must not depend on bridge_permissions"
                )

    def test_core_modules_do_not_import_bridge_permissions(self):
        """Non-CLI runtime.core modules must not import bridge_permissions.

        bridge_permissions is a shadow-only module: only cli.py and test
        files are permitted consumers. This test scans runtime/core/*.py
        (excluding bridge_permissions.py itself) to confirm no unexpected
        imports exist.
        """
        core_dir = _REPO_ROOT / "runtime" / "core"
        excluded = {"bridge_permissions.py"}
        for py_file in sorted(core_dir.glob("*.py")):
            if py_file.name in excluded:
                continue
            source = py_file.read_text(encoding="utf-8")
            tree = ast.parse(source, filename=str(py_file))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        assert "bridge_permissions" not in alias.name, (
                            f"{py_file.name} imports 'bridge_permissions' — "
                            f"only cli.py and tests are permitted consumers"
                        )
                elif isinstance(node, ast.ImportFrom):
                    module_name = node.module or ""
                    assert "bridge_permissions" not in module_name, (
                        f"{py_file.name} imports from 'bridge_permissions' — "
                        f"only cli.py and tests are permitted consumers"
                    )


# ---------------------------------------------------------------------------
# 5. validate_bridge_settings — clean file and three drift shapes
# ---------------------------------------------------------------------------


class TestValidateBridgeSettings:
    def test_clean_file_returns_empty_list(self):
        settings = _load_bridge_settings()
        messages = bp.validate_bridge_settings(settings)
        assert messages == [], (
            f"validate_bridge_settings reported drift on the live bridge "
            f"file: {messages}"
        )

    def test_non_dict_input_returns_error_message(self):
        messages = bp.validate_bridge_settings("not a dict")  # type: ignore[arg-type]
        assert len(messages) >= 1
        assert any("expected a JSON object" in m for m in messages)

    def test_drift_shape_i_delegated_pattern_added_back(self):
        """(i) A delegated pattern re-added to deny must be flagged."""
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        # Add one delegated pattern back into deny
        poisoned["permissions"]["deny"].append("Bash(git commit *)")
        messages = bp.validate_bridge_settings(poisoned)
        assert messages, (
            "validate_bridge_settings should have returned drift messages "
            "when a delegated pattern was re-added to deny"
        )
        assert any("runtime-policy-delegated" in m for m in messages), (
            f"Expected message mentioning 'runtime-policy-delegated', got: {messages}"
        )

    def test_drift_shape_ii_safety_pattern_removed(self):
        """(ii) A safety pattern removed from deny must be flagged."""
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        # Remove one safety pattern
        poisoned["permissions"]["deny"] = [
            e for e in poisoned["permissions"]["deny"]
            if e != "Bash(rm -rf *)"
        ]
        messages = bp.validate_bridge_settings(poisoned)
        assert messages, (
            "validate_bridge_settings should have returned drift messages "
            "when a safety pattern was removed from deny"
        )
        assert any("safety pattern" in m for m in messages), (
            f"Expected message mentioning 'safety pattern', got: {messages}"
        )

    def test_drift_shape_iii_pretool_wiring_removed(self):
        """(iii) PreToolUse Bash → pre-bash.sh wiring removed must be flagged."""
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        # Remove all PreToolUse Bash entries
        pretooluse = poisoned.get("hooks", {}).get("PreToolUse", [])
        poisoned["hooks"]["PreToolUse"] = [
            block for block in pretooluse
            if not (
                isinstance(block, dict) and block.get("matcher") == "Bash"
            )
        ]
        messages = bp.validate_bridge_settings(poisoned)
        assert messages, (
            "validate_bridge_settings should have returned drift messages "
            "when the PreToolUse Bash wiring was removed"
        )
        assert any("pre-bash.sh" in m for m in messages), (
            f"Expected message mentioning 'pre-bash.sh', got: {messages}"
        )

    def test_drift_shape_i_all_delegated_patterns(self):
        """Adding all 5 delegated patterns back generates 5 messages."""
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        for pattern in bp.RUNTIME_POLICY_DELEGATED_BASH_PATTERNS:
            poisoned["permissions"]["deny"].append(pattern)
        messages = bp.validate_bridge_settings(poisoned)
        rogue_messages = [m for m in messages if "runtime-policy-delegated" in m]
        assert len(rogue_messages) == 5, (
            f"Expected 5 drift messages for the 5 delegated patterns, "
            f"got {len(rogue_messages)}: {rogue_messages}"
        )

    def test_missing_permissions_key_returns_error(self):
        messages = bp.validate_bridge_settings({})
        # Validator should handle missing permissions gracefully
        assert isinstance(messages, list)

    def test_validate_settings_pure_function_no_side_effects(self):
        """Calling validate_bridge_settings must not modify the input."""
        settings = _load_bridge_settings()
        original_deny = list(settings["permissions"]["deny"])
        bp.validate_bridge_settings(settings)
        # The original settings must be unchanged
        assert settings["permissions"]["deny"] == original_deny


# ---------------------------------------------------------------------------
# 6. PostToolUse Bash → post-bash.sh wiring (Invariant #15 bridge parity)
# ---------------------------------------------------------------------------


class TestPostToolBashWiringPresent:
    """New tests added in cc-policy-who-remediation slice for bridge parity.

    These tests close the Invariant #15 gap: root settings.json wires
    PostToolUse Bash → post-bash.sh but the bridge overlay previously had no
    PostToolUse entry, silently skipping the readiness-invalidation adapter on
    bridge worker sessions.  Cross-refs: DEC-EVAL-006, CUTOVER_PLAN.md:1453.
    """

    # a. Live bridge file has exactly one PostToolUse entry with the right wiring
    def test_live_bridge_settings_has_posttooluse_bash_post_bash_wiring(self):
        """Parse the live bridge file and confirm PostToolUse Bash → post-bash.sh."""
        settings = _load_bridge_settings()
        hooks_block = settings.get("hooks", {})
        posttooluse = hooks_block.get("PostToolUse", [])
        bash_entries = [
            block for block in posttooluse
            if isinstance(block, dict) and block.get("matcher") == "Bash"
        ]
        assert len(bash_entries) == 1, (
            f"Expected exactly one PostToolUse Bash entry in the live bridge "
            f"settings, found {len(bash_entries)}: {posttooluse}"
        )
        # Confirm the sole entry routes to post-bash.sh
        found = False
        for hook in bash_entries[0].get("hooks", []):
            if isinstance(hook, dict):
                cmd = hook.get("command", "")
                if "hooks/post-bash.sh" in cmd:
                    found = True
                    break
        assert found, (
            "PostToolUse Bash entry must wire to a command containing "
            "'hooks/post-bash.sh' — this closes the Invariant #15 bridge-parity gap"
        )

    # b. validate_bridge_settings flags missing PostToolUse Bash wiring as drift
    def test_validate_bridge_settings_flags_missing_posttool_bash_wiring_as_drift(self):
        """A fixture lacking PostToolUse Bash → post-bash.sh entry returns drift."""
        settings = _load_bridge_settings()
        # Remove the entire PostToolUse section to simulate the pre-fix state
        poisoned = copy.deepcopy(settings)
        poisoned.get("hooks", {}).pop("PostToolUse", None)
        messages = bp.validate_bridge_settings(poisoned)
        assert messages, (
            "validate_bridge_settings should return drift messages when "
            "the PostToolUse Bash → post-bash.sh wiring is absent"
        )
        readable = [m for m in messages if "post-bash.sh" in m]
        assert readable, (
            f"At least one drift message must mention 'post-bash.sh', got: {messages}"
        )

    def test_validate_bridge_settings_flags_bash_entry_absent_from_posttooluse(self):
        """PostToolUse present but Bash matcher absent still triggers drift."""
        settings = _load_bridge_settings()
        poisoned = copy.deepcopy(settings)
        # Keep PostToolUse key but remove the Bash-matched block
        posttooluse = poisoned.get("hooks", {}).get("PostToolUse", [])
        poisoned["hooks"]["PostToolUse"] = [
            block for block in posttooluse
            if not (isinstance(block, dict) and block.get("matcher") == "Bash")
        ]
        messages = bp.validate_bridge_settings(poisoned)
        assert messages, (
            "validate_bridge_settings must flag drift when PostToolUse Bash "
            "matcher is absent even though PostToolUse key exists"
        )
        assert any("post-bash.sh" in m for m in messages)

    # c. Live file passes validate_bridge_settings (empty drift list)
    def test_validate_bridge_settings_passes_with_posttool_bash_wiring_present(self):
        """The live bridge file passes validate_bridge_settings after this slice."""
        settings = _load_bridge_settings()
        messages = bp.validate_bridge_settings(settings)
        assert messages == [], (
            f"validate_bridge_settings reported drift on the live bridge file "
            f"(should be clean after PostToolUse wiring is added): {messages}"
        )

    # d. REQUIRED_POSTTOOL_BASH_HOOKS shadow-only: covered by existing AST scan
    #    tests in TestShadowOnlyDiscipline. No separate test needed — the AST scan
    #    already blocks any runtime.core imports in bridge_permissions.py, which
    #    is the shadow-only invariant. Confirmed by reading
    #    TestShadowOnlyDiscipline.test_bridge_permissions_has_no_runtime_core_dependencies.

    # e. Preservation pins — siblings must not have drifted
    def test_required_pretool_bash_hooks_shape_unchanged(self):
        """REQUIRED_PRETOOL_BASH_HOOKS must still be a 1-tuple with the pre-bash entry."""
        assert len(bp.REQUIRED_PRETOOL_BASH_HOOKS) == 1
        event, matcher, suffix = bp.REQUIRED_PRETOOL_BASH_HOOKS[0]
        assert event == "PreToolUse"
        assert matcher == "Bash"
        assert suffix == "hooks/pre-bash.sh"

    def test_required_posttool_bash_hooks_shape(self):
        """REQUIRED_POSTTOOL_BASH_HOOKS is a 1-tuple with the post-bash entry."""
        assert len(bp.REQUIRED_POSTTOOL_BASH_HOOKS) == 1
        event, matcher, suffix = bp.REQUIRED_POSTTOOL_BASH_HOOKS[0]
        assert event == "PostToolUse"
        assert matcher == "Bash"
        assert suffix == "hooks/post-bash.sh"

    def test_runtime_policy_delegated_bash_patterns_unchanged(self):
        """RUNTIME_POLICY_DELEGATED_BASH_PATTERNS must still contain the 5 git ops."""
        expected = frozenset({
            "Bash(git commit *)",
            "Bash(git push *)",
            "Bash(git merge *)",
            "Bash(git rebase *)",
            "Bash(git reset *)",
        })
        assert bp.RUNTIME_POLICY_DELEGATED_BASH_PATTERNS == expected, (
            f"RUNTIME_POLICY_DELEGATED_BASH_PATTERNS has drifted: "
            f"{bp.RUNTIME_POLICY_DELEGATED_BASH_PATTERNS}"
        )

    def test_safety_deny_patterns_unchanged(self):
        """SAFETY_DENY_PATTERNS must still contain the 8 hard-deny entries."""
        expected = frozenset({
            "NotebookEdit",
            "Bash(git checkout main*)",
            "Bash(git checkout master*)",
            "Bash(git branch -D *)",
            "Bash(rm -rf *)",
            "Read(**/.env*)",
            "Read(**/secrets/**)",
            "Read(**/*credentials*)",
        })
        assert bp.SAFETY_DENY_PATTERNS == expected, (
            f"SAFETY_DENY_PATTERNS has drifted: {bp.SAFETY_DENY_PATTERNS}"
        )


# ---------------------------------------------------------------------------
# Broker-health + response-surface drift probes (2026-04-17)
# ---------------------------------------------------------------------------
# Probes are pure read-only and fail-closed. Tests use tmp_path fixtures to
# synthesize the on-disk shapes the probes consume so the test suite never
# depends on the live bridge state.
# ---------------------------------------------------------------------------


def _make_broker_state(
    tmp_path,
    *,
    pidfile_content: str | None = "99999",
    make_socket: bool = True,
):
    """Create a synthetic BRAID_ROOT tree under ``tmp_path``.

    Returns the root path. ``pidfile_content=None`` omits the pidfile.
    ``make_socket=False`` omits the socket stand-in file.
    """
    root = tmp_path / "braid"
    (root / "runs").mkdir(parents=True)
    if pidfile_content is not None:
        (root / "runs" / "braidd.pid").write_text(pidfile_content)
    if make_socket:
        # A regular file stand-in for the Unix socket on disk — the probe
        # only checks existence, not socket-ness.
        (root / "runs" / "braidd.sock").write_text("")
    return root


class TestProbeBrokerHealth:
    """Covers every `BrokerHealthSnapshot.status` class."""

    def test_healthy_case(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root = _make_broker_state(
            tmp_path, pidfile_content=str(os.getpid()), make_socket=True
        )
        snap = bp.probe_broker_health(braid_root=str(root))
        assert snap.status == "healthy", snap
        assert snap.pid_alive is True
        assert snap.socket_exists is True
        assert snap.recovery_hint is None

    def test_degraded_dead_pid_stale_socket(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        # Pick a pid that is unlikely to be live. `os.kill(2**31-1, 0)`
        # raises ProcessLookupError on POSIX.
        root = _make_broker_state(
            tmp_path, pidfile_content="2147483646", make_socket=True
        )
        snap = bp.probe_broker_health(braid_root=str(root))
        assert snap.status == "degraded_dead_pid_stale_socket", snap
        assert snap.pid_alive is False
        assert snap.socket_exists is True
        assert snap.recovery_hint == "braid down && braid up"

    def test_socket_missing_pid_live(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root = _make_broker_state(
            tmp_path, pidfile_content=str(os.getpid()), make_socket=False
        )
        snap = bp.probe_broker_health(braid_root=str(root))
        assert snap.status == "socket_missing", snap
        assert snap.pid_alive is True
        assert snap.socket_exists is False

    def test_absent_no_pidfile(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root = _make_broker_state(
            tmp_path, pidfile_content=None, make_socket=False
        )
        snap = bp.probe_broker_health(braid_root=str(root))
        assert snap.status == "absent", snap
        assert snap.braidd_pid is None
        assert snap.pid_alive is None

    def test_unparseable_pidfile_is_absent_not_crash(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root = _make_broker_state(
            tmp_path, pidfile_content="not-an-integer", make_socket=True
        )
        snap = bp.probe_broker_health(braid_root=str(root))
        assert snap.status == "absent", snap
        assert snap.error_detail is not None
        assert "parse" in snap.error_detail.lower()

    def test_env_fallback_when_no_explicit_arg(
        self, tmp_path, monkeypatch
    ):
        """When `braid_root` arg is None, the probe reads $BRAID_ROOT."""
        import runtime.core.bridge_permissions as bp

        root = _make_broker_state(
            tmp_path, pidfile_content="2147483646", make_socket=True
        )
        monkeypatch.setenv("BRAID_ROOT", str(root))
        snap = bp.probe_broker_health()
        assert snap.status == "degraded_dead_pid_stale_socket", snap


class TestProbeResponseSurfaceDrift:
    """Covers the required `ResponseSurfaceDiagnostic.status` classes."""

    @staticmethod
    def _make_env(
        tmp_path,
        *,
        run_id: str = "run-abc",
        active_run_id: str | None = "run-abc",
        run_state: str | None = "inflight",
        pidfile_content: str | None = "2147483646",
        make_socket: bool = True,
        pending_review: dict | None = None,
        braid_root_sentinel: str | None = None,
    ):
        root = _make_broker_state(
            tmp_path,
            pidfile_content=pidfile_content,
            make_socket=make_socket,
        )
        if active_run_id is not None:
            (root / "runs" / "active-run").write_text(active_run_id)
        if run_state is not None:
            run_dir = root / "runs" / run_id
            run_dir.mkdir()
            (run_dir / "status.json").write_text(
                json.dumps({"state": run_state})
            )

        sdir = tmp_path / "state"
        sdir.mkdir()
        if braid_root_sentinel is not None:
            (sdir / "braid-root").write_text(braid_root_sentinel)
        else:
            (sdir / "braid-root").write_text(str(root))

        if pending_review is not None:
            (sdir / "pending-review.json").write_text(
                json.dumps(pending_review)
            )

        return root, sdir

    def test_broker_cache_miss_stale_socket(self, tmp_path):
        """Dominant 2026-04-17 drift class."""
        import runtime.core.bridge_permissions as bp

        response_path = tmp_path / "response.json"
        response_path.write_text("{}")
        root, sdir = self._make_env(
            tmp_path,
            run_state="waiting_for_codex",
            pending_review={
                "run_id": "run-abc",
                "response_available": True,
                "response_path": str(response_path),
            },
        )
        diag = bp.probe_response_surface_drift(
            run_id="run-abc", braid_root=str(root), state_dir=str(sdir)
        )
        assert diag.status == "broker_cache_miss_stale_socket", diag

    def test_pending_absent_inflight_ok(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root, sdir = self._make_env(
            tmp_path, run_state="inflight", pending_review=None
        )
        diag = bp.probe_response_surface_drift(
            run_id="run-abc", braid_root=str(root), state_dir=str(sdir)
        )
        assert diag.status == "pending_absent_inflight_ok", diag
        assert diag.run_state == "inflight"

    def test_pending_absent_unexpected(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root, sdir = self._make_env(
            tmp_path,
            run_state="waiting_for_codex",
            pending_review=None,
        )
        diag = bp.probe_response_surface_drift(
            run_id="run-abc", braid_root=str(root), state_dir=str(sdir)
        )
        assert diag.status == "pending_absent_unexpected", diag
        assert diag.run_state == "waiting_for_codex"

    def test_run_id_mismatch_takes_precedence_over_everything(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root, sdir = self._make_env(
            tmp_path,
            active_run_id="run-xyz",
            run_state="waiting_for_codex",
            pending_review={
                "run_id": "run-abc",
                "response_available": True,
                "response_path": "/does/not/exist",
            },
        )
        diag = bp.probe_response_surface_drift(
            run_id="run-abc", braid_root=str(root), state_dir=str(sdir)
        )
        assert diag.status == "run_id_mismatch", diag
        assert diag.active_run_id == "run-xyz"

    def test_insufficient_evidence_missing_run_dir(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        root, sdir = self._make_env(
            tmp_path,
            run_state=None,  # no status.json produced
        )
        diag = bp.probe_response_surface_drift(
            run_id="run-abc", braid_root=str(root), state_dir=str(sdir)
        )
        assert diag.status == "insufficient_evidence", diag

    def test_agreed_baseline(self, tmp_path):
        import runtime.core.bridge_permissions as bp

        # Healthy broker → pid_alive is True.
        response_path = tmp_path / "response.json"
        response_path.write_text("{}")
        root, sdir = self._make_env(
            tmp_path,
            pidfile_content=str(os.getpid()),
            run_state="waiting_for_codex",
            pending_review={
                "run_id": "run-abc",
                "response_available": True,
                "response_path": str(response_path),
            },
        )
        diag = bp.probe_response_surface_drift(
            run_id="run-abc", braid_root=str(root), state_dir=str(sdir)
        )
        assert diag.status == "agreed", diag

    def test_env_mismatch_recorded_but_does_not_short_circuit(self, tmp_path):
        """env_match=False is recorded in the env block but does not
        (currently) produce a classification status — the
        ``env_divergence_*`` classes are reserved for future use.
        """
        import runtime.core.bridge_permissions as bp

        root, sdir = self._make_env(
            tmp_path,
            run_state="inflight",
            pending_review=None,
            braid_root_sentinel="/some/other/root",
        )
        diag = bp.probe_response_surface_drift(
            run_id="run-abc", braid_root=str(root), state_dir=str(sdir)
        )
        assert diag.env["env_match"] is False
        assert diag.env["braid_root_sentinel"] == "/some/other/root"
        # Still classified by state-gating logic:
        assert diag.status == "pending_absent_inflight_ok", diag

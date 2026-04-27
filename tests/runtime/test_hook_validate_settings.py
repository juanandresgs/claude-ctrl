"""Tests for cc-policy hook validate-settings + the pure validate_settings helper.

@decision DEC-CLAUDEX-HOOK-VALIDATOR-TESTS-001
Title: Pure validate_settings helper and cc-policy hook validate-settings CLI pin settings.json drift in both directions
Status: proposed (shadow-mode, Phase 2 hook adapter reduction)
Rationale: The validator is the first Phase 2 consumer of
  ``runtime.core.hook_manifest``. It must catch drift between the
  manifest and ``settings.json`` in both directions, surface missing
  adapter files as a distinct invalid state, and treat
  deprecated-still-wired entries as a surfaced-but-not-failing
  condition (so the current repo remains ``healthy=True`` while the
  H8 removal is still pending).

  These tests pin:

    1. ``extract_repo_owned_entries`` parses well-formed and
       malformed settings.json shapes without raising.
    2. ``validate_settings`` returns the stable report contract
       (status / healthy / counts / four drift lists) and classifies
       each category correctly.
    3. Status computation ordering: invalid_files > drift >
       ok_with_deprecated > ok.
    4. The CLI exit code maps healthy→0 and unhealthy→1.
    5. CLI output is always valid JSON on stdout regardless of
       exit code.
    6. The real repo's settings.json passes as healthy (exit 0,
       status ok_with_deprecated) so CI of this slice and future
       slices remains green until the H8 removal lands.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import hook_manifest as hm

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")
_REAL_SETTINGS = _REPO_ROOT / "settings.json"


# ---------------------------------------------------------------------------
# Synthetic settings helpers
# ---------------------------------------------------------------------------


def _settings_from_manifest_entries(
    entries: list[hm.HookManifestEntry],
) -> dict:
    """Build a minimal settings.json-shaped dict from manifest entries.

    Groups entries by ``(event, matcher)`` so the output matches the
    real settings.json shape: ``hooks -> event -> [ {matcher, hooks:
    [{command}]} ]``.
    """
    grouped: dict[str, dict[str, list[hm.HookManifestEntry]]] = {}
    for entry in entries:
        grouped.setdefault(entry.event, {}).setdefault(entry.matcher, []).append(
            entry
        )
    hooks_block: dict = {}
    for event in sorted(grouped.keys()):
        matcher_entries = []
        for matcher in sorted(grouped[event].keys()):
            matcher_entries.append(
                {
                    "matcher": matcher,
                    "hooks": [
                        {
                            "type": "command",
                            "command": f"$HOME/.claude/{e.adapter_path}",
                        }
                        for e in grouped[event][matcher]
                    ],
                }
            )
        hooks_block[event] = matcher_entries
    return {"hooks": hooks_block}


def _load_real_settings() -> dict:
    with _REAL_SETTINGS.open() as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# 1. extract_repo_owned_entries parser (pure)
# ---------------------------------------------------------------------------


class TestExtractRepoOwnedEntries:
    def test_empty_settings_returns_empty_set(self):
        assert hm.extract_repo_owned_entries({}) == frozenset()

    def test_missing_hooks_key_returns_empty_set(self):
        assert hm.extract_repo_owned_entries({"other": 1}) == frozenset()

    def test_non_mapping_input_returns_empty_set(self):
        assert hm.extract_repo_owned_entries("oops") == frozenset()  # type: ignore[arg-type]
        assert hm.extract_repo_owned_entries(None) == frozenset()  # type: ignore[arg-type]

    def test_real_settings_parses_to_31_entries(self):
        # Phase 8 Slice 3: 33 → 32 after removing PreToolUse:EnterWorktree.
        # Phase 8 Slice 10: 32 → 30 after removing SubagentStop:tester
        # (check-tester.sh + post-task.sh).
        # Invariant #15 (DEC-EVAL-006): +1 PostToolUse Bash → post-bash.sh.
        # Implementer critic: +1 SubagentStop:implementer → implementer-critic.sh.
        # Forward-motion Stop hook removed as non-outcome style friction.
        settings = _load_real_settings()
        entries = hm.extract_repo_owned_entries(settings)
        assert len(entries) == 31

    def test_bash_passthrough_is_skipped(self):
        settings = {
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "{ cat; echo; } >> $HOME/.claude/runtime/dispatch-debug.jsonl",
                            }
                        ],
                    }
                ]
            }
        }
        assert hm.extract_repo_owned_entries(settings) == frozenset()

    def test_plugin_script_is_skipped(self):
        settings = {
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "node $HOME/.claude/sidecars/codex-review/scripts/stop-review-gate-hook.mjs",
                            }
                        ],
                    }
                ]
            }
        }
        assert hm.extract_repo_owned_entries(settings) == frozenset()

    def test_command_with_node_prefix_on_hooks_path_is_skipped(self):
        # A command like ``node $HOME/.claude/hooks/foo.js`` is not a
        # bare shell adapter invocation and must not be counted as a
        # repo-owned adapter.
        settings = {
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "node $HOME/.claude/hooks/foo.js",
                            }
                        ],
                    }
                ]
            }
        }
        assert hm.extract_repo_owned_entries(settings) == frozenset()

    def test_command_with_args_is_skipped(self):
        # An adapter invocation with arguments is not a canonical
        # repo-owned adapter wiring.
        settings = {
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "$HOME/.claude/hooks/pre-bash.sh --debug",
                            }
                        ],
                    }
                ]
            }
        }
        assert hm.extract_repo_owned_entries(settings) == frozenset()

    def test_malformed_entries_are_skipped_not_raised(self):
        settings = {
            "hooks": {
                "PreToolUse": [
                    {"matcher": "Bash"},  # no hooks list
                    {"matcher": "Bash", "hooks": "not-a-list"},
                    {"matcher": "Bash", "hooks": [{"command": None}]},
                    {"matcher": "Bash", "hooks": [{"command": ""}]},
                    "not a dict",
                ]
            }
        }
        # Must not raise.
        result = hm.extract_repo_owned_entries(settings)
        assert result == frozenset()


# ---------------------------------------------------------------------------
# 2. validate_settings — pure drift classification
# ---------------------------------------------------------------------------


class TestValidateSettings:
    def test_report_has_stable_keys(self):
        report = hm.validate_settings({"hooks": {}})
        expected = {
            "status",
            "healthy",
            "settings_repo_entry_count",
            "manifest_wired_entry_count",
            "missing_in_manifest",
            "missing_in_settings",
            "deprecated_still_wired",
            "invalid_adapter_files",
        }
        assert set(report.keys()) == expected

    def test_report_is_json_serialisable(self):
        report = hm.validate_settings(_load_real_settings())
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_real_settings_is_ok(self):
        # Phase 8 Slice 3: real settings now maps 1:1 onto active
        # manifest entries, so status == ok (not ok_with_deprecated).
        report = hm.validate_settings(_load_real_settings())
        assert report["status"] == hm.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["missing_in_manifest"] == []
        assert report["missing_in_settings"] == []
        assert report["invalid_adapter_files"] == []
        assert report["deprecated_still_wired"] == []

    def test_full_manifest_as_settings_is_ok(self):
        # Rebuilding settings from every currently-wired manifest
        # entry must produce the same healthy OK state.
        synthetic = _settings_from_manifest_entries(
            list(hm.currently_wired_entries())
        )
        report = hm.validate_settings(synthetic)
        assert report["status"] == hm.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["deprecated_still_wired"] == []

    def test_ok_with_deprecated_status_when_manifest_has_a_deprecated_entry(self, monkeypatch):
        # The ok_with_deprecated vocabulary entry is retained for any
        # future slice that flags an entry for coordinated removal.
        # Simulate that future by replacing one active entry with a
        # deprecated clone and rewiring settings to match.
        manifest_list = list(hm.HOOK_MANIFEST)
        original = manifest_list[0]
        replacement = hm.HookManifestEntry(
            event=original.event,
            matcher=original.matcher,
            adapter_path=original.adapter_path,
            status=hm.STATUS_DEPRECATED,
            rationale="synthetic deprecated entry for test",
        )
        manifest_list[0] = replacement
        monkeypatch.setattr(hm, "HOOK_MANIFEST", tuple(manifest_list))

        synthetic = _settings_from_manifest_entries(list(hm.currently_wired_entries()))
        report = hm.validate_settings(synthetic)
        assert report["status"] == hm.VALIDATION_STATUS_OK_WITH_DEPRECATED
        assert report["healthy"] is True
        assert len(report["deprecated_still_wired"]) == 1

    def test_missing_in_manifest_is_drift_unhealthy(self):
        synthetic = _settings_from_manifest_entries(
            list(hm.currently_wired_entries())
        )
        # Add a repo-owned command that the manifest does not declare.
        synthetic["hooks"].setdefault("PreToolUse", []).append(
            {
                "matcher": "Bash",
                "hooks": [
                    {
                        "type": "command",
                        "command": "$HOME/.claude/hooks/ghost-hook.sh",
                    }
                ],
            }
        )
        report = hm.validate_settings(synthetic)
        assert report["status"] == hm.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        assert any(
            e["adapter_path"] == "hooks/ghost-hook.sh"
            for e in report["missing_in_manifest"]
        )

    def test_missing_in_settings_is_drift_unhealthy(self):
        # Drop one entry from the manifest-built settings.
        wired = list(hm.currently_wired_entries())
        dropped = wired[0]
        synthetic = _settings_from_manifest_entries(wired[1:])
        report = hm.validate_settings(synthetic)
        assert report["status"] == hm.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        # The dropped entry must show up in missing_in_settings.
        assert any(
            e["adapter_path"] == dropped.adapter_path
            and e["event"] == dropped.event
            and e["matcher"] == dropped.matcher
            for e in report["missing_in_settings"]
        )

    def test_both_drift_directions_surfaced_together(self):
        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired[1:])  # drop 1
        # And add a ghost.
        synthetic["hooks"].setdefault("Stop", []).append(
            {
                "matcher": "",
                "hooks": [
                    {
                        "type": "command",
                        "command": "$HOME/.claude/hooks/ghost-stop.sh",
                    }
                ],
            }
        )
        report = hm.validate_settings(synthetic)
        assert report["status"] == hm.VALIDATION_STATUS_DRIFT
        assert report["missing_in_manifest"]
        assert report["missing_in_settings"]

    def test_invalid_adapter_files_overrides_deprecated(self):
        # Even if deprecated-still-wired is present, an invalid file
        # must promote the status to "invalid".
        settings = _load_real_settings()
        report = hm.validate_settings(
            settings,
            missing_files=("hooks/pre-bash.sh",),
        )
        assert report["status"] == hm.VALIDATION_STATUS_INVALID
        assert report["healthy"] is False
        assert report["invalid_adapter_files"] == ["hooks/pre-bash.sh"]

    def test_invalid_adapter_files_overrides_drift(self):
        # Drift + invalid file → invalid wins.
        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired[1:])
        report = hm.validate_settings(
            synthetic,
            missing_files=("hooks/pre-bash.sh",),
        )
        assert report["status"] == hm.VALIDATION_STATUS_INVALID
        assert report["healthy"] is False

    def test_deprecated_still_wired_is_surfaced_distinctly(self, monkeypatch):
        # Phase 8 Slice 3: the real settings has zero deprecated
        # entries. Simulate a deprecated wiring with a monkey-patched
        # manifest to pin that the surfacing contract still holds.
        manifest_list = list(hm.HOOK_MANIFEST)
        original = manifest_list[0]
        replacement = hm.HookManifestEntry(
            event=original.event,
            matcher=original.matcher,
            adapter_path=original.adapter_path,
            status=hm.STATUS_DEPRECATED,
            rationale="synthetic deprecated entry for test",
        )
        manifest_list[0] = replacement
        monkeypatch.setattr(hm, "HOOK_MANIFEST", tuple(manifest_list))

        synthetic = _settings_from_manifest_entries(list(hm.currently_wired_entries()))
        report = hm.validate_settings(synthetic)
        assert report["deprecated_still_wired"], (
            "deprecated entries must be surfaced, not hidden"
        )
        for d in report["deprecated_still_wired"]:
            assert d["status"] == hm.STATUS_DEPRECATED
            # And they must NOT appear in missing_in_manifest / missing_in_settings.
            assert (
                d["event"],
                d["matcher"],
                d["adapter_path"],
            ) not in {
                (e["event"], e["matcher"], e["adapter_path"])
                for e in report["missing_in_manifest"] + report["missing_in_settings"]
            }

    def test_counts_reflect_entry_sets(self):
        # Phase 8 Slice 3: 33 → 32 after removing PreToolUse:EnterWorktree.
        # Phase 8 Slice 10: 32 → 30 after removing SubagentStop:tester wiring.
        # Invariant #15 (DEC-EVAL-006): 30 → 31 adding PostToolUse Bash.
        # Implementer critic: 31 → 32 adding SubagentStop:implementer critic.
        # Forward-motion Stop hook removal: 32 → 31.
        report = hm.validate_settings(_load_real_settings())
        assert report["settings_repo_entry_count"] == 31
        assert report["manifest_wired_entry_count"] == 31

    def test_empty_settings_is_drift_due_to_missing_in_settings(self):
        report = hm.validate_settings({"hooks": {}})
        assert report["status"] == hm.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        assert len(report["missing_in_settings"]) == 31

    def test_removing_post_bash_entry_from_settings_is_drift_unhealthy(self):
        # Invariant #15 (DEC-EVAL-006): removing PostToolUse/Bash/post-bash.sh
        # from settings.json must be caught as drift. This pins that the
        # validator catches the removal so a future accidental deletion is
        # detected mechanically rather than silently.
        settings = _load_real_settings()
        # Strip out only the PostToolUse Bash post-bash.sh command.
        post_tool = settings.get("hooks", {}).get("PostToolUse", [])
        filtered = []
        for group in post_tool:
            if not isinstance(group, dict):
                filtered.append(group)
                continue
            matcher = group.get("matcher", "")
            if matcher != "Bash":
                filtered.append(group)
                continue
            # Remove only the post-bash.sh hook command from this group.
            inner = [
                h for h in group.get("hooks", [])
                if "post-bash.sh" not in h.get("command", "")
            ]
            if inner:
                filtered.append(dict(group, hooks=inner))
            # If group becomes empty, drop it entirely.
        settings["hooks"]["PostToolUse"] = filtered
        report = hm.validate_settings(settings)
        assert report["status"] == hm.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        assert any(
            e["adapter_path"] == "hooks/post-bash.sh"
            and e["event"] == "PostToolUse"
            and e["matcher"] == "Bash"
            for e in report["missing_in_settings"]
        ), f"post-bash.sh removal not surfaced in missing_in_settings: {report}"


# ---------------------------------------------------------------------------
# 3. CLI integration — subprocess tests
# ---------------------------------------------------------------------------


def _run_cli(args: list[str]) -> tuple[int, dict]:
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
    }
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


class TestValidateSettingsCli:
    def test_real_settings_exits_zero(self):
        # Phase 8 Slice 3: report status is plain ``ok`` — no
        # deprecated entries remain.
        code, out = _run_cli(["hook", "validate-settings"])
        assert code == 0, f"unexpected failure: {out}"
        assert out["status"] == "ok"
        assert out["report"]["status"] == hm.VALIDATION_STATUS_OK
        assert out["report"]["healthy"] is True
        assert out["report"]["deprecated_still_wired"] == []

    def test_explicit_settings_path_override(self, tmp_path):
        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired)
        # Place the synthetic settings.json alongside a fake "hooks"
        # directory so the CLI's filesystem existence check still
        # passes. We symlink or mirror the real hooks directory.
        fake_repo = tmp_path / "fake-repo"
        fake_repo.mkdir()
        fake_hooks = fake_repo / "hooks"
        fake_hooks.mkdir()
        # Create empty marker files for each adapter path.
        for entry in hm.currently_wired_entries():
            target = fake_repo / entry.adapter_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\nexit 0\n")
        settings_file = fake_repo / "settings.json"
        settings_file.write_text(json.dumps(synthetic))

        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 0, f"unexpected failure: {out}"
        # Phase 8 Slice 3: no deprecated entries → plain OK status.
        assert out["report"]["status"] == hm.VALIDATION_STATUS_OK
        assert out["report"]["healthy"] is True

    def test_missing_in_manifest_exits_non_zero(self, tmp_path):
        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired)
        synthetic["hooks"].setdefault("PreToolUse", []).append(
            {
                "matcher": "Bash",
                "hooks": [
                    {
                        "type": "command",
                        "command": "$HOME/.claude/hooks/ghost-hook.sh",
                    }
                ],
            }
        )
        fake_repo = tmp_path / "r"
        fake_repo.mkdir()
        for entry in hm.currently_wired_entries():
            target = fake_repo / entry.adapter_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\nexit 0\n")
        # Also create the ghost file so filesystem check passes and
        # only the drift category fires.
        (fake_repo / "hooks" / "ghost-hook.sh").write_text("#!/bin/sh\nexit 0\n")
        settings_file = fake_repo / "settings.json"
        settings_file.write_text(json.dumps(synthetic))

        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 1
        assert out["status"] == "violation"
        assert out["report"]["status"] == hm.VALIDATION_STATUS_DRIFT
        assert out["report"]["healthy"] is False
        assert any(
            e["adapter_path"] == "hooks/ghost-hook.sh"
            for e in out["report"]["missing_in_manifest"]
        )

    def test_missing_in_settings_exits_non_zero(self, tmp_path):
        wired = list(hm.currently_wired_entries())
        # Drop one entry.
        dropped = wired[0]
        synthetic = _settings_from_manifest_entries(wired[1:])
        fake_repo = tmp_path / "r"
        fake_repo.mkdir()
        for entry in wired[1:]:
            target = fake_repo / entry.adapter_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\nexit 0\n")
        settings_file = fake_repo / "settings.json"
        settings_file.write_text(json.dumps(synthetic))

        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 1
        assert out["report"]["status"] == hm.VALIDATION_STATUS_DRIFT
        assert out["report"]["healthy"] is False
        assert any(
            e["adapter_path"] == dropped.adapter_path
            for e in out["report"]["missing_in_settings"]
        )

    def test_missing_adapter_file_exits_non_zero(self, tmp_path):
        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired)
        fake_repo = tmp_path / "r"
        fake_repo.mkdir()
        # Create all adapter files EXCEPT one so filesystem check
        # fires.
        sacrificed = "hooks/pre-bash.sh"
        for entry in wired:
            if entry.adapter_path == sacrificed:
                continue
            target = fake_repo / entry.adapter_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\nexit 0\n")
        settings_file = fake_repo / "settings.json"
        settings_file.write_text(json.dumps(synthetic))

        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 1
        assert out["report"]["status"] == hm.VALIDATION_STATUS_INVALID
        assert out["report"]["healthy"] is False
        assert sacrificed in out["report"]["invalid_adapter_files"]

    def test_missing_settings_file_returns_error(self, tmp_path):
        bogus = tmp_path / "nope.json"
        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(bogus)]
        )
        assert code != 0
        assert "not found" in out.get("message", "") or "_raw" in out

    def test_malformed_settings_json_returns_error(self, tmp_path):
        fake_settings = tmp_path / "settings.json"
        fake_settings.write_text("{ not valid json")
        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(fake_settings)]
        )
        assert code != 0
        assert "failed to read" in out.get("message", "") or "_raw" in out

    def test_output_is_always_valid_json(self, tmp_path):
        # Both healthy and unhealthy paths must emit parseable JSON
        # on stdout.
        code, out = _run_cli(["hook", "validate-settings"])
        assert "_raw" not in out, "healthy path emitted non-JSON"

        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired[1:])
        fake_repo = tmp_path / "r"
        fake_repo.mkdir()
        for entry in wired[1:]:
            target = fake_repo / entry.adapter_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\nexit 0\n")
        settings_file = fake_repo / "settings.json"
        settings_file.write_text(json.dumps(synthetic))
        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert "_raw" not in out, "unhealthy path emitted non-JSON"


# ---------------------------------------------------------------------------
# 4. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_validator_does_not_execute_hooks(self, tmp_path):
        # Create a fake hooks tree where every adapter file contains
        # a sentinel marker. If the validator were to execute any
        # adapter, a marker file would be created.
        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired)
        fake_repo = tmp_path / "r"
        fake_repo.mkdir()
        sentinel_dir = tmp_path / "sentinels"
        sentinel_dir.mkdir()
        for entry in wired:
            target = fake_repo / entry.adapter_path
            target.parent.mkdir(parents=True, exist_ok=True)
            # Write a script that would leave a sentinel if run.
            target.write_text(
                "#!/bin/sh\n"
                f'touch "{sentinel_dir}/$(basename "$0").ran"\n'
                "exit 0\n"
            )
            target.chmod(0o755)
        settings_file = fake_repo / "settings.json"
        settings_file.write_text(json.dumps(synthetic))

        code, out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 0
        # No sentinel files should exist — the validator must not
        # execute any hook script.
        ran_markers = list(sentinel_dir.iterdir())
        assert ran_markers == [], (
            f"validator unexpectedly executed hook scripts: {ran_markers}"
        )

    def test_validator_does_not_write_to_settings_file(self, tmp_path):
        wired = list(hm.currently_wired_entries())
        synthetic = _settings_from_manifest_entries(wired)
        fake_repo = tmp_path / "r"
        fake_repo.mkdir()
        for entry in wired:
            target = fake_repo / entry.adapter_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\nexit 0\n")
        settings_file = fake_repo / "settings.json"
        original = json.dumps(synthetic, sort_keys=True)
        settings_file.write_text(original)
        pre_mtime = settings_file.stat().st_mtime

        code, _out = _run_cli(
            ["hook", "validate-settings", "--settings-path", str(settings_file)]
        )
        assert code == 0
        assert settings_file.read_text() == original
        assert settings_file.stat().st_mtime == pre_mtime

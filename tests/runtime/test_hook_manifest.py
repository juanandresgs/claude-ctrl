"""Tests for runtime/core/hook_manifest.py.

@decision DEC-CLAUDEX-HOOK-MANIFEST-TESTS-001
Title: Hook manifest authority — entries are deterministic, grounded in real tracked files, and match the current settings.json repo-local surface
Status: proposed (shadow-mode, Phase 2 bootstrap)
Rationale: The hook manifest is the first Phase 2 authority surface,
  and it only has value if drift between the manifest and the real
  wiring in ``settings.json`` is detectable. These tests pin:

    1. Structural invariants: every entry is frozen, has a known
       status, has a known event, has a canonical adapter path under
       ``hooks/``, and has a non-empty rationale.
    2. Uniqueness: no two entries share the same
       ``(event, matcher, adapter_path)`` triple.
    3. Adapter resolution: every ``active`` or ``deprecated`` entry's
       ``adapter_path`` resolves to a real tracked file in the repo
       right now. This is the "grounded in currently existing repo
       surface" invariant from the slice instruction.
    4. settings.json cross-check (bidirectional): every repo-owned
       adapter wired in ``settings.json`` appears in the manifest,
       and every currently-wired manifest entry is referenced by
       ``settings.json``. Non-repo-owned commands (bash passthroughs,
       plugin scripts) are explicitly excluded from the comparison.
    5. Active-only policy (Phase 8 Slice 3): every currently-wired
       entry is ``active``. The previously-deprecated
       ``block-worktree-create.sh`` entries were resolved per
       DEC-PHASE0-001 (WorktreeCreate un-deprecated as verified-live
       fail-closed safety) and DEC-PHASE0-002 (PreToolUse:EnterWorktree
       removed as an unsupported event).
    6. Lookup helper semantics: ``entries_for_event``,
       ``entries_for_adapter``, ``adapter_paths``, and
       ``is_manifest_adapter`` behave deterministically and never
       raise on bad input.
    7. Shadow-only discipline via AST walk: the module imports only
       stdlib and is not imported by any live routing / policy / CLI
       module.
"""

from __future__ import annotations

import ast
import inspect
import json
from pathlib import Path

import pytest

from runtime.core import hook_manifest as hm

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SETTINGS = _REPO_ROOT / "settings.json"


def _imported_module_names(module) -> set[str]:
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            base = node.module or ""
            if base:
                names.add(base)
                for alias in node.names:
                    names.add(f"{base}.{alias.name}")
    return names


def _load_settings_repo_adapters() -> set[tuple[str, str, str]]:
    """Return the set of (event, matcher, repo_path) triples from settings.json.

    Filters to repo-owned adapters only: commands that are single
    path invocations where the path resolves under ``$HOME/.claude/
    hooks/<script>.sh`` (which is the symlinked view of ``hooks/`` in
    this repo). Bare bash passthroughs (``{ cat; echo; } >> ...``) and
    plugin scripts (``node $HOME/.claude/plugins/...``) are excluded.
    """
    with _SETTINGS.open() as f:
        data = json.load(f)
    result: set[tuple[str, str, str]] = set()
    for event, matcher_entries in (data.get("hooks") or {}).items():
        if not isinstance(matcher_entries, list):
            continue
        for entry in matcher_entries:
            matcher = entry.get("matcher", "")
            for hook in entry.get("hooks") or []:
                cmd = hook.get("command", "")
                if not isinstance(cmd, str):
                    continue
                # Keep only single-command invocations of a
                # ``$HOME/.claude/hooks/<script>.sh`` path.
                if "{ cat; echo;" in cmd:
                    continue
                if "plugins/marketplaces" in cmd:
                    continue
                token = cmd.strip()
                prefix = "$HOME/.claude/hooks/"
                if prefix in token:
                    # Everything after the prefix — should be just the
                    # bare script name with no additional args for the
                    # adapters this manifest covers.
                    idx = token.find(prefix)
                    tail = token[idx + len(prefix) :]
                    # Guard: no spaces (no args), no quoting residue.
                    tail = tail.strip().strip("'\"")
                    if tail and " " not in tail:
                        repo_path = f"hooks/{tail}"
                        result.add((event, matcher, repo_path))
                        continue
                # Anything else is non-repo-owned for the purposes
                # of the manifest.
    return result


# ---------------------------------------------------------------------------
# 1. Structural invariants
# ---------------------------------------------------------------------------


class TestStructure:
    def test_hook_manifest_is_tuple(self):
        assert isinstance(hm.HOOK_MANIFEST, tuple)

    def test_manifest_is_non_empty(self):
        assert len(hm.HOOK_MANIFEST) > 0

    def test_every_entry_is_frozen(self):
        entry = hm.HOOK_MANIFEST[0]
        with pytest.raises(Exception):
            entry.status = "planned"  # type: ignore[misc]

    def test_every_entry_has_known_status(self):
        for entry in hm.HOOK_MANIFEST:
            assert entry.status in hm.HOOK_ENTRY_STATUSES, (
                f"entry {entry.adapter_path!r} has unknown status {entry.status!r}"
            )

    def test_every_entry_has_known_event(self):
        for entry in hm.HOOK_MANIFEST:
            assert entry.event in hm.KNOWN_HOOK_EVENTS, (
                f"entry {entry.adapter_path!r} has unknown event {entry.event!r}"
            )

    def test_every_entry_has_canonical_hook_rooted_path(self):
        for entry in hm.HOOK_MANIFEST:
            assert entry.adapter_path.startswith("hooks/"), entry.adapter_path
            assert ".." not in entry.adapter_path.split("/")
            assert not entry.adapter_path.startswith("/")

    def test_every_entry_has_non_empty_rationale(self):
        for entry in hm.HOOK_MANIFEST:
            assert entry.rationale.strip() != "", (
                f"entry {entry.adapter_path!r} has an empty rationale"
            )

    def test_status_vocabulary_is_closed(self):
        assert hm.HOOK_ENTRY_STATUSES == frozenset(
            {"active", "deprecated", "planned"}
        )

    def test_known_event_vocabulary_is_the_expected_set(self):
        assert hm.KNOWN_HOOK_EVENTS == frozenset(
            {
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "Notification",
                "SubagentStart",
                "SubagentStop",
                "PreCompact",
                "Stop",
                "SessionEnd",
                "WorktreeCreate",
            }
        )

    def test_entries_are_unique_by_triple(self):
        triples = [
            (e.event, e.matcher, e.adapter_path) for e in hm.HOOK_MANIFEST
        ]
        assert len(triples) == len(set(triples)), (
            "manifest contains duplicate (event, matcher, adapter_path) entries"
        )


# ---------------------------------------------------------------------------
# 2. Adapter resolution — every wired entry exists on disk
# ---------------------------------------------------------------------------


class TestAdapterResolution:
    def test_every_active_entry_resolves_to_a_tracked_file(self):
        missing = []
        for entry in hm.active_entries():
            full = _REPO_ROOT / entry.adapter_path
            if not full.is_file():
                missing.append(entry.adapter_path)
        assert missing == [], f"active manifest entries missing on disk: {missing}"

    def test_every_deprecated_entry_resolves_to_a_tracked_file(self):
        # Deprecated entries are still wired in settings.json today,
        # so the file must still exist until the removal slice lands.
        missing = []
        for entry in hm.deprecated_entries():
            full = _REPO_ROOT / entry.adapter_path
            if not full.is_file():
                missing.append(entry.adapter_path)
        assert missing == [], (
            f"deprecated manifest entries missing on disk: {missing}"
        )

    def test_planned_entries_are_not_required_to_exist(self):
        # For this slice the expectation is that there are no planned
        # entries yet; a future slice may add them. Pin that nothing
        # in the planned list pretends to be tracked.
        for entry in hm.planned_entries():
            # Planned entries don't have to exist on disk. This test
            # passes regardless of their path presence — it just
            # documents the intent.
            assert entry.status == hm.STATUS_PLANNED

    def test_no_adapter_path_leaves_hooks_directory(self):
        for entry in hm.HOOK_MANIFEST:
            full = (_REPO_ROOT / entry.adapter_path).resolve()
            hooks_dir = (_REPO_ROOT / "hooks").resolve()
            assert hooks_dir in full.parents or full == hooks_dir, (
                f"{entry.adapter_path} resolves outside hooks/"
            )


# ---------------------------------------------------------------------------
# 3. Bidirectional cross-check with settings.json
# ---------------------------------------------------------------------------


class TestSettingsJsonAlignment:
    def test_every_settings_repo_adapter_is_declared_by_manifest(self):
        settings_set = _load_settings_repo_adapters()
        manifest_set = {
            (e.event, e.matcher, e.adapter_path)
            for e in hm.currently_wired_entries()
        }
        missing = settings_set - manifest_set
        assert missing == set(), (
            f"settings.json wires these repo adapters that the manifest "
            f"does not declare: {sorted(missing)}"
        )

    def test_every_currently_wired_manifest_entry_is_in_settings_json(self):
        settings_set = _load_settings_repo_adapters()
        manifest_set = {
            (e.event, e.matcher, e.adapter_path)
            for e in hm.currently_wired_entries()
        }
        extra = manifest_set - settings_set
        assert extra == set(), (
            f"manifest declares currently-wired entries that settings.json "
            f"does not contain: {sorted(extra)}"
        )

    def test_manifest_is_exactly_30_entries_against_todays_settings(self):
        # Pin the overall count so any drift in settings.json forces
        # a deliberate manifest update. Phase 8 Slice 3 reduced this
        # from 33 to 32 by removing PreToolUse:EnterWorktree. Phase 8
        # Slice 10 further reduced it to 30 by removing the two tester
        # SubagentStop entries (check-tester.sh + post-task.sh).
        assert len(hm.HOOK_MANIFEST) == 30

    def test_active_plus_deprecated_counts_match(self):
        # Phase 8 Slice 3: WorktreeCreate un-deprecated (→ active),
        # PreToolUse:EnterWorktree removed. Phase 8 Slice 10: tester
        # SubagentStop entries removed. No deprecated entries remain.
        assert len(hm.active_entries()) == 30
        assert len(hm.deprecated_entries()) == 0
        assert len(hm.planned_entries()) == 0

    def test_no_subagent_stop_tester_entry(self):
        # Phase 8 Slice 10: tester SubagentStop wiring removed. The
        # role is retained as dead runtime code pending Bundle 2
        # cleanup, but no live hook producer may dispatch a tester
        # SubagentStop.
        for entry in hm.HOOK_MANIFEST:
            assert not (entry.event == "SubagentStop" and entry.matcher == "tester"), (
                f"SubagentStop:tester must not reappear — removed per "
                f"Phase 8 Slice 10 (Tester Bundle 1). Offender: {entry}"
            )


# ---------------------------------------------------------------------------
# 4. Active-only policy (Phase 8 Slice 3)
# ---------------------------------------------------------------------------


class TestActiveOnlyPolicy:
    """Phase 8 Slice 3 resolved the previously-deprecated block-worktree
    wiring. These tests pin the new invariant: every currently-wired
    manifest entry is ``active``, and ``hooks/block-worktree-create.sh``
    anchors exactly one active ``WorktreeCreate`` entry."""

    def test_block_worktree_create_has_exactly_one_active_entry(self):
        bwc_entries = hm.entries_for_adapter("hooks/block-worktree-create.sh")
        assert len(bwc_entries) == 1, (
            f"expected 1 block-worktree-create entry (WorktreeCreate), got "
            f"{len(bwc_entries)}"
        )
        entry = bwc_entries[0]
        assert entry.status == hm.STATUS_ACTIVE, (
            f"block-worktree-create entry must be active "
            f"(DEC-PHASE0-001, DEC-GUARD-WT-009); got {entry.status}"
        )
        assert entry.event == "WorktreeCreate"
        assert entry.matcher == ""

    def test_no_entry_references_enter_worktree_matcher(self):
        # DEC-PHASE0-002: EnterWorktree is not a documented Claude Code
        # event/matcher. It must not reappear in the manifest.
        for entry in hm.HOOK_MANIFEST:
            assert entry.matcher != "EnterWorktree", (
                f"EnterWorktree matcher must not reappear — removed per "
                f"DEC-PHASE0-002. Offender: {entry}"
            )

    def test_no_deprecated_entries_remain(self):
        assert hm.deprecated_entries() == (), (
            f"Phase 8 Slice 3 resolved all deprecated entries; none "
            f"should remain. Found: {hm.deprecated_entries()}"
        )

    def test_every_entry_is_active(self):
        for entry in hm.HOOK_MANIFEST:
            assert entry.status == hm.STATUS_ACTIVE, (
                f"entry {entry.event}/{entry.matcher} → "
                f"{entry.adapter_path} has non-active status "
                f"{entry.status!r}"
            )


# ---------------------------------------------------------------------------
# 5. Lookup helper semantics
# ---------------------------------------------------------------------------


class TestLookupHelpers:
    def test_entries_for_event_filters_correctly(self):
        pre_tool = hm.entries_for_event("PreToolUse")
        assert len(pre_tool) > 0
        for entry in pre_tool:
            assert entry.event == "PreToolUse"

    def test_entries_for_event_returns_empty_for_unknown_event(self):
        assert hm.entries_for_event("NotAnEvent") == ()

    def test_entries_for_event_handles_non_string(self):
        assert hm.entries_for_event(None) == ()  # type: ignore[arg-type]
        assert hm.entries_for_event(42) == ()  # type: ignore[arg-type]

    def test_entries_for_adapter_exact_match_only(self):
        post_task = hm.entries_for_adapter("hooks/post-task.sh")
        # post-task.sh wires under every SubagentStop matcher. Phase 8
        # Slice 10 removed the tester entry, leaving planner|Plan,
        # implementer, guardian, reviewer (4 roles).
        assert len(post_task) == 4
        for entry in post_task:
            assert entry.event == "SubagentStop"
            assert entry.adapter_path == "hooks/post-task.sh"

    def test_entries_for_adapter_does_not_prefix_match(self):
        # "hooks/pre-bash" is a prefix of "hooks/pre-bash.sh" but
        # must not match — lookups are exact.
        assert hm.entries_for_adapter("hooks/pre-bash") == ()

    def test_entries_for_adapter_does_not_suffix_match(self):
        # "pre-bash.sh" (without the hooks/ prefix) must not match.
        assert hm.entries_for_adapter("pre-bash.sh") == ()

    def test_entries_for_adapter_rejects_empty_and_non_string(self):
        assert hm.entries_for_adapter("") == ()
        assert hm.entries_for_adapter(None) == ()  # type: ignore[arg-type]

    def test_adapter_paths_default_includes_all_wired(self):
        # Phase 8 Slice 3: no deprecated entries remain, so the default
        # (include_deprecated=True) set equals the active-only set.
        paths = hm.adapter_paths()
        assert "hooks/pre-bash.sh" in paths
        assert "hooks/block-worktree-create.sh" in paths

    def test_adapter_paths_active_set_includes_block_worktree_create(self):
        # Phase 8 Slice 3: block-worktree-create.sh is now active and
        # must appear in the active-only set as well.
        active_only = hm.adapter_paths(include_deprecated=False)
        assert "hooks/pre-bash.sh" in active_only
        assert "hooks/block-worktree-create.sh" in active_only

    def test_is_manifest_adapter_matches_currently_wired(self):
        assert hm.is_manifest_adapter("hooks/pre-bash.sh") is True
        assert hm.is_manifest_adapter("hooks/block-worktree-create.sh") is True
        assert hm.is_manifest_adapter("hooks/does-not-exist.sh") is False
        assert hm.is_manifest_adapter("") is False
        assert hm.is_manifest_adapter(None) is False  # type: ignore[arg-type]

    def test_lookup_exact_triple(self):
        entry = hm.lookup(
            "PreToolUse", "Bash", "hooks/pre-bash.sh"
        )
        assert entry is not None
        assert entry.status == hm.STATUS_ACTIVE
        assert entry.event == "PreToolUse"

    def test_lookup_returns_none_for_mismatch(self):
        assert hm.lookup("PreToolUse", "Bash", "hooks/pre-write.sh") is None
        assert hm.lookup("PreToolUse", "Wrong", "hooks/pre-bash.sh") is None


# ---------------------------------------------------------------------------
# 6. Constructor validation
# ---------------------------------------------------------------------------


class TestEntryValidation:
    def test_unknown_event_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="NotAnEvent",
                matcher="",
                adapter_path="hooks/pre-bash.sh",
                status=hm.STATUS_ACTIVE,
                rationale="x",
            )

    def test_unknown_status_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="PreToolUse",
                matcher="Bash",
                adapter_path="hooks/pre-bash.sh",
                status="somewhere",
                rationale="x",
            )

    def test_absolute_adapter_path_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="PreToolUse",
                matcher="Bash",
                adapter_path="/Users/me/hooks/pre-bash.sh",
                status=hm.STATUS_ACTIVE,
                rationale="x",
            )

    def test_parent_traversal_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="PreToolUse",
                matcher="Bash",
                adapter_path="hooks/../escape.sh",
                status=hm.STATUS_ACTIVE,
                rationale="x",
            )

    def test_non_canonical_path_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="PreToolUse",
                matcher="Bash",
                adapter_path="hooks//pre-bash.sh",
                status=hm.STATUS_ACTIVE,
                rationale="x",
            )

    def test_non_hooks_rooted_path_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="PreToolUse",
                matcher="Bash",
                adapter_path="runtime/core/pre_bash.py",
                status=hm.STATUS_ACTIVE,
                rationale="x",
            )

    def test_empty_rationale_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="PreToolUse",
                matcher="Bash",
                adapter_path="hooks/pre-bash.sh",
                status=hm.STATUS_ACTIVE,
                rationale="",
            )

    def test_non_string_matcher_rejected(self):
        with pytest.raises(ValueError):
            hm.HookManifestEntry(
                event="PreToolUse",
                matcher=["Bash"],  # type: ignore[arg-type]
                adapter_path="hooks/pre-bash.sh",
                status=hm.STATUS_ACTIVE,
                rationale="x",
            )


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_hook_manifest_has_no_runtime_core_dependencies(self):
        imported = _imported_module_names(hm)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        assert runtime_core_imports == set(), (
            f"hook_manifest.py unexpectedly depends on {runtime_core_imports}"
        )

    def test_hook_manifest_does_not_import_live_modules(self):
        imported = _imported_module_names(hm)
        forbidden_substrings = (
            "dispatch_engine",
            "completions",
            "policy_engine",
            "enforcement_config",
            "settings",
            "hooks",
            "runtime.core.leases",
            "runtime.core.workflows",
            "runtime.core.policy_utils",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"hook_manifest.py imports {name!r} containing forbidden "
                    f"token {needle!r}"
                )

    def test_live_modules_do_not_import_hook_manifest(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "hook_manifest" not in name, (
                    f"{mod.__name__} imports {name!r} — hook_manifest must "
                    f"stay shadow-only this slice"
                )

    def test_cli_imports_hook_manifest_only_for_read_only_validator(self):
        # As of the Phase 2 validator slice
        # (DEC-CLAUDEX-HOOK-VALIDATOR-TESTS-001), cli.py is permitted
        # to import hook_manifest to power the read-only
        # ``cc-policy hook validate-settings`` command. What must NOT
        # happen is cli.py using the manifest for any write path or
        # any live enforcement: the handler is strictly read + report.
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        # hook_manifest_mod import is allowed; no other hook_manifest
        # alias is.
        hook_manifest_refs = {
            name for name in imported if "hook_manifest" in name
        }
        assert hook_manifest_refs <= {
            "runtime.core.hook_manifest",
        }, (
            f"cli.py has unexpected hook_manifest imports: {hook_manifest_refs}"
        )

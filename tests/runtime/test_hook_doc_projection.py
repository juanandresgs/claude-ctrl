"""Tests for runtime/core/hook_doc_projection.py.

@decision DEC-CLAUDEX-HOOK-DOC-PROJECTION-TESTS-001
Title: Pure hook-doc projection builder renders every manifest entry deterministically and surfaces deprecated entries distinctly
Status: proposed (shadow-mode, Phase 2 derived-surface bootstrap)
Rationale: The hook-doc projection builder is the first slice that
  consumes ``runtime.core.hook_manifest`` as an authority and emits
  a Phase 1 ``HookDocProjection`` record. Tests pin:

    1. ``render_hook_doc`` is non-empty, preserves event order in
       first-seen declaration order, and contains every manifest
       entry's adapter path and matcher (one row per entry).
    2. Deprecated entries carry a visible ``[DEPRECATED]`` marker;
       active entries do not.
    3. The returned ``HookDocProjection`` ``events``, ``matchers``,
       and ``content_hash`` are derived from the same rendered
       body: ``events`` matches the distinct manifest event set in
       first-seen order, ``matchers`` matches the distinct
       non-empty matchers in first-seen order, and ``content_hash``
       is a stable sha256 hash of the rendered text.
    4. ``content_hash`` is stable for identical input and changes
       when the rendered content changes (monkeypatch the manifest
       tuple with a different entry list).
    5. ``metadata.provenance`` covers every manifest entry exactly
       once and carries the correct ``source_kind`` / ``source_version``
       triple per :class:`SourceRef`.
    6. ``metadata.stale_condition.watched_authorities`` includes
       ``hook_wiring`` and ``watched_files`` lists the real
       constitution-level paths involved.
    7. Shadow-only discipline: the module imports only
       ``runtime.core.hook_manifest`` and
       ``runtime.core.projection_schemas``; no live routing /
       policy / CLI / hooks modules import it.
"""

from __future__ import annotations

import ast
import hashlib
import inspect

import pytest

from runtime.core import hook_doc_projection as hdp
from runtime.core import hook_manifest as hm
from runtime.core import projection_schemas as ps


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


# ---------------------------------------------------------------------------
# 1. render_hook_doc — structure + coverage
# ---------------------------------------------------------------------------


class TestRenderHookDoc:
    def test_render_returns_non_empty_string(self):
        text = hdp.render_hook_doc()
        assert isinstance(text, str)
        assert text.strip() != ""

    def test_render_ends_with_newline(self):
        text = hdp.render_hook_doc()
        assert text.endswith("\n")

    def test_render_contains_every_adapter_path_at_least_once(self):
        text = hdp.render_hook_doc()
        for entry in hm.HOOK_MANIFEST:
            assert f"`{entry.adapter_path}`" in text, (
                f"adapter_path {entry.adapter_path!r} missing from rendered body"
            )

    def test_render_contains_one_row_per_manifest_entry(self):
        # Each entry produces a bullet of the form
        # ``- matcher `<matcher>` → `<adapter_path>``` so the bullet
        # count must equal the manifest size.
        text = hdp.render_hook_doc()
        bullet_count = sum(
            1 for line in text.splitlines() if line.startswith("- matcher ")
        )
        assert bullet_count == len(hm.HOOK_MANIFEST), (
            f"expected {len(hm.HOOK_MANIFEST)} entry rows, got {bullet_count}"
        )

    def test_render_groups_by_event_in_first_seen_order(self):
        text = hdp.render_hook_doc()
        expected_events: list[str] = []
        for entry in hm.HOOK_MANIFEST:
            if entry.event not in expected_events:
                expected_events.append(entry.event)
        # Extract the H2 header order from the rendered text.
        seen_headers = [
            line[3:].strip()
            for line in text.splitlines()
            if line.startswith("## ")
        ]
        assert seen_headers == expected_events

    def test_render_marks_deprecated_entries(self):
        text = hdp.render_hook_doc()
        # The manifest currently has exactly 2 deprecated entries
        # (both pointing at hooks/block-worktree-create.sh).
        assert text.count(hdp.DEPRECATED_MARKER) == len(
            hm.deprecated_entries()
        )
        # And every deprecated entry's adapter path row must carry
        # the marker.
        lines = text.splitlines()
        for entry in hm.deprecated_entries():
            for i, line in enumerate(lines):
                if (
                    entry.adapter_path in line
                    and _matcher_display(entry.matcher) in line
                ):
                    assert hdp.DEPRECATED_MARKER in line, (
                        f"deprecated entry {entry.adapter_path!r} is not "
                        f"marked deprecated in its rendered row"
                    )
                    break

    def test_render_does_not_mark_active_entries_deprecated(self):
        text = hdp.render_hook_doc()
        lines = text.splitlines()
        for entry in hm.active_entries():
            for line in lines:
                if (
                    entry.adapter_path in line
                    and _matcher_display(entry.matcher) in line
                ):
                    assert hdp.DEPRECATED_MARKER not in line, (
                        f"active entry {entry.adapter_path!r} has been "
                        f"tagged deprecated in the rendered body"
                    )

    def test_render_renders_empty_matcher_as_unconditional(self):
        text = hdp.render_hook_doc()
        # Confirm we actually have unconditional entries to represent.
        unconditional = [e for e in hm.HOOK_MANIFEST if not e.matcher]
        assert unconditional, "test precondition failed: no unconditional entries"
        assert "(unconditional)" in text

    def test_render_accepts_custom_entries_tuple(self):
        subset = hm.HOOK_MANIFEST[:3]
        text = hdp.render_hook_doc(subset)
        assert isinstance(text, str)
        bullet_count = sum(
            1 for line in text.splitlines() if line.startswith("- matcher ")
        )
        assert bullet_count == 3

    def test_render_is_pure_deterministic(self):
        a = hdp.render_hook_doc()
        b = hdp.render_hook_doc()
        assert a == b


def _matcher_display(matcher: str) -> str:
    """Mirror of the module's private helper for use in tests."""
    return matcher if matcher else "(unconditional)"


# ---------------------------------------------------------------------------
# 2. build_hook_doc_projection — schema shape + derived fields
# ---------------------------------------------------------------------------


class TestBuildHookDocProjection:
    def test_returns_hook_doc_projection_instance(self):
        proj = hdp.build_hook_doc_projection(generated_at=1_700_000_000)
        assert isinstance(proj, ps.HookDocProjection)
        assert proj.SCHEMA_TYPE == "hook_doc_projection"

    def test_events_are_first_seen_order_from_manifest(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        expected: list[str] = []
        for entry in hm.HOOK_MANIFEST:
            if entry.event not in expected:
                expected.append(entry.event)
        assert proj.events == tuple(expected)

    def test_matchers_exclude_empty_strings(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        for matcher in proj.matchers:
            assert matcher != "", (
                "HookDocProjection.matchers must not carry empty strings "
                "(Phase 1 schema validator rejects them)"
            )

    def test_matchers_are_first_seen_order_of_non_empty_manifest_matchers(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        expected: list[str] = []
        for entry in hm.HOOK_MANIFEST:
            if entry.matcher and entry.matcher not in expected:
                expected.append(entry.matcher)
        assert proj.matchers == tuple(expected)

    def test_content_hash_matches_rendered_body_hash(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        rendered = hdp.render_hook_doc()
        expected_hash = (
            "sha256:" + hashlib.sha256(rendered.encode("utf-8")).hexdigest()
        )
        assert proj.content_hash == expected_hash

    def test_content_hash_is_stable_across_calls(self):
        a = hdp.build_hook_doc_projection(generated_at=1_700_000_000)
        b = hdp.build_hook_doc_projection(generated_at=1_700_000_000)
        assert a.content_hash == b.content_hash

    def test_content_hash_changes_when_manifest_changes(self, monkeypatch):
        before = hdp.build_hook_doc_projection(generated_at=1)
        # Drop the last manifest entry and rebuild — hash must differ.
        shortened = hm.HOOK_MANIFEST[:-1]
        monkeypatch.setattr(hm, "HOOK_MANIFEST", shortened)
        after = hdp.build_hook_doc_projection(generated_at=1)
        assert before.content_hash != after.content_hash
        assert len(after.events) <= len(before.events)


# ---------------------------------------------------------------------------
# 3. ProjectionMetadata contents
# ---------------------------------------------------------------------------


class TestProjectionMetadata:
    def test_generator_version_is_set(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        assert proj.metadata.generator_version == hdp.HOOK_DOC_GENERATOR_VERSION
        assert proj.metadata.generator_version != ""

    def test_generated_at_is_caller_supplied(self):
        proj = hdp.build_hook_doc_projection(generated_at=42_000)
        assert proj.metadata.generated_at == 42_000

    def test_source_versions_carries_hook_wiring(self):
        proj = hdp.build_hook_doc_projection(
            generated_at=1, manifest_version="7.7.7"
        )
        assert proj.metadata.source_versions == (("hook_wiring", "7.7.7"),)

    def test_stale_condition_watches_hook_wiring_authority(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        assert "hook_wiring" in proj.metadata.stale_condition.watched_authorities

    def test_stale_condition_watches_constitution_level_files(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        watched = proj.metadata.stale_condition.watched_files
        assert "runtime/core/hook_manifest.py" in watched
        assert "settings.json" in watched
        assert "hooks/HOOKS.md" in watched

    def test_stale_condition_watches_hook_manifest_source_authority(self):
        """Phase 7 Slice 9: the source manifest file is watched, not only
        the derived drift/projection surfaces. Without this entry, the
        projection metadata names its outputs but omits the input whose
        content actually stales the projection."""
        proj = hdp.build_hook_doc_projection(generated_at=1)
        assert (
            "runtime/core/hook_manifest.py"
            in proj.metadata.stale_condition.watched_files
        )

    def test_stale_condition_watched_files_are_deterministic(self):
        """Pin exact tuple + order: source authority first, then derived
        surfaces (settings.json drift, hooks/HOOKS.md projection)."""
        proj = hdp.build_hook_doc_projection(generated_at=1)
        assert proj.metadata.stale_condition.watched_files == (
            "runtime/core/hook_manifest.py",
            "settings.json",
            "hooks/HOOKS.md",
        )

    def test_stale_condition_rationale_is_non_empty(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        assert proj.metadata.stale_condition.rationale.strip() != ""

    def test_provenance_has_one_ref_per_manifest_entry(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        assert len(proj.metadata.provenance) == len(hm.HOOK_MANIFEST)

    def test_provenance_refs_are_distinct(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        ids = [ref.source_id for ref in proj.metadata.provenance]
        assert len(ids) == len(set(ids)), (
            "provenance contains duplicate source_ids — entries should be "
            "keyed on (event, matcher, adapter_path)"
        )

    def test_provenance_refs_carry_hook_wiring_source_kind(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        for ref in proj.metadata.provenance:
            assert ref.source_kind == "hook_wiring"

    def test_provenance_source_ids_encode_full_entry_identity(self):
        proj = hdp.build_hook_doc_projection(generated_at=1)
        expected = {
            f"{e.event}:{e.matcher}:{e.adapter_path}" for e in hm.HOOK_MANIFEST
        }
        actual = {ref.source_id for ref in proj.metadata.provenance}
        assert actual == expected

    def test_provenance_source_version_uses_manifest_version(self):
        proj = hdp.build_hook_doc_projection(
            generated_at=1, manifest_version="9.9.9"
        )
        for ref in proj.metadata.provenance:
            assert ref.source_version == "9.9.9"


# ---------------------------------------------------------------------------
# 4. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_hook_doc_projection_imports_only_allowed_modules(self):
        imported = _imported_module_names(hdp)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_bases = {"runtime.core", "runtime.core.hook_manifest"}
        permitted_prefixes = (
            "runtime.core.hook_manifest",
            "runtime.core.projection_schemas",
        )
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(permitted_prefixes), (
                f"hook_doc_projection.py has unexpected runtime.core import: {name!r}"
            )

    def test_hook_doc_projection_has_no_live_imports(self):
        imported = _imported_module_names(hdp)
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
                    f"hook_doc_projection.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_live_modules_do_not_import_hook_doc_projection(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "hook_doc_projection" not in name, (
                    f"{mod.__name__} imports {name!r} — hook_doc_projection "
                    f"must stay shadow-only this slice"
                )

    def test_cli_does_not_import_hook_doc_projection(self):
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        for name in imported:
            assert "hook_doc_projection" not in name, (
                f"cli.py imports {name!r} — hook_doc_projection must not "
                f"be exposed via CLI this slice"
            )

    def test_hook_manifest_does_not_import_hook_doc_projection(self):
        # Guard against a reverse dependency — the authority must not
        # depend on any of its projections.
        imported = _imported_module_names(hm)
        for name in imported:
            assert "hook_doc_projection" not in name

    def test_projection_schemas_does_not_import_hook_doc_projection(self):
        # The schema family must not depend on a specific projection
        # builder either.
        imported = _imported_module_names(ps)
        for name in imported:
            assert "hook_doc_projection" not in name

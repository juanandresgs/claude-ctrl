"""Tests for runtime/core/constitution_registry.py.

@decision DEC-CLAUDEX-CONSTITUTION-REGISTRY-TESTS-001
Title: Constitution-level file set, planned areas, and path matching are pinned by tests
Status: proposed (shadow-mode, Phase 1 constitutional kernel)
Rationale: The constitution registry is the mechanical answer to the
  Phase 1 exit criterion "constitution-level files are enumerated and
  validated". These tests pin:

    1. Exact set equality of the concrete entries to the files
       (public baseline + later promotions) in the runtime-owned closed
       authority surface — no more, no fewer. Drift in either direction
       must fail CI.
    2. Every concrete entry resolves to a real tracked repo path
       right now. If a constitution-level file is deleted, renamed, or
       typo'd in the registry, this test catches it before a later
       scope gate enforces against a phantom target.
    3. Planned areas are explicitly non-concrete with no path. They
       may never be accidentally treated as existing files.
    4. Path-matching (`normalize_repo_path` + `is_constitution_level`)
       is deterministic, handles common spellings (`./foo`), and
       refuses to overmatch unrelated paths, absolute paths, or
       parent-traversal inputs.
    5. The module stays shadow-only: no imports of live routing,
       policy engine, hooks, settings, or config machinery.
"""

from __future__ import annotations

import ast
import inspect
from pathlib import Path

import pytest

from runtime.core import constitution_registry as cr

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _imported_module_names(module) -> set[str]:
    """Return the set of dotted module names actually imported by ``module``.

    Uses ``ast`` to walk ``Import`` / ``ImportFrom`` nodes — this
    avoids false positives from docstring prose that mentions a
    forbidden module name without actually importing it.
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


# Runtime-owned closed constitution surface plus promotions. Pinning this
# set equality remains the primary invariant of the concrete-file surface.
CONCRETE_CONSTITUTION_FILES: frozenset[str] = frozenset(
    {
        "CLAUDE.md",
        "AGENTS.md",
        "settings.json",
        "MASTER_PLAN.md",
        "hooks/HOOKS.md",
        "runtime/cli.py",
        "runtime/schemas.py",
        "runtime/core/dispatch_engine.py",
        "runtime/core/completions.py",
        "runtime/core/policy_engine.py",
        # Phase 2 prompt-pack bootstrap promotion:
        "runtime/core/prompt_pack.py",
        # Phase 7 Slice 3 stage/capability authority promotions:
        "runtime/core/stage_registry.py",
        "runtime/core/authority_registry.py",
        # Phase 7 Slice 4 decision/work registry promotion:
        "runtime/core/decision_work_registry.py",
        # Phase 7 Slice 5 projection validation promotions:
        "runtime/core/projection_schemas.py",
        "runtime/core/hook_doc_projection.py",
        "runtime/core/hook_doc_validation.py",
        "runtime/core/prompt_pack_validation.py",
        # Phase 7 Slice 8 hook manifest authority:
        "runtime/core/hook_manifest.py",
        # Phase 7 Slice 10 prompt-pack resolver authority:
        "runtime/core/prompt_pack_resolver.py",
        # Phase 7 Slice 13 decision-digest projection generator:
        "runtime/core/decision_digest_projection.py",
        # Phase 7 Slice 16 projection reflow staleness planner:
        "runtime/core/projection_reflow.py",
        # Phase 7 Slice 17 memory/retrieval projection compiler:
        "runtime/core/memory_retrieval.py",
    }
)


# ---------------------------------------------------------------------------
# 1. Exact concrete set equality
# ---------------------------------------------------------------------------


class TestConcreteSetEquality:
    def test_concrete_paths_are_exactly_the_closed_authority_list(self):
        assert cr.CONCRETE_PATHS == CONCRETE_CONSTITUTION_FILES

    def test_concrete_entry_names_match_concrete_paths(self):
        # In this slice the canonical entry name for concrete files is
        # the path itself. This assertion pins that convention.
        assert cr.CONCRETE_ENTRY_NAMES == CONCRETE_CONSTITUTION_FILES

    def test_concrete_count_is_twenty_three(self):
        # 9 public baseline + 1 Phase 2 + 2 Phase 7 S3 +
        # 1 Phase 7 S4 + 4 Phase 7 S5 + 1 Phase 7 S8 (hook_manifest)
        # + 1 Phase 7 S10 (prompt_pack_resolver)
        # + 1 Phase 7 S13 (decision_digest_projection)
        # + 1 Phase 7 S16 (projection_reflow)
        # + 1 Phase 7 S17 (memory_retrieval).
        assert len(cr.concrete_entries()) == 23

    def test_all_concrete_paths_helper_returns_declaration_order(self):
        ordered = cr.all_concrete_paths()
        # The helper is expected to preserve declaration order: the
        # Public baseline first, followed by Phase 2
        # promotions in the order they were added.
        assert ordered == (
            "CLAUDE.md",
            "AGENTS.md",
            "settings.json",
            "MASTER_PLAN.md",
            "hooks/HOOKS.md",
            "runtime/cli.py",
            "runtime/schemas.py",
            "runtime/core/dispatch_engine.py",
            "runtime/core/completions.py",
            "runtime/core/policy_engine.py",
            "runtime/core/prompt_pack.py",
            "runtime/core/stage_registry.py",
            "runtime/core/authority_registry.py",
            "runtime/core/decision_work_registry.py",
            "runtime/core/projection_schemas.py",
            "runtime/core/hook_doc_projection.py",
            "runtime/core/hook_doc_validation.py",
            "runtime/core/prompt_pack_validation.py",
            "runtime/core/hook_manifest.py",
            "runtime/core/prompt_pack_resolver.py",
            "runtime/core/decision_digest_projection.py",
            "runtime/core/projection_reflow.py",
            "runtime/core/memory_retrieval.py",
        )

    def test_registry_is_tuple(self):
        # Frozen, ordered, immutable.
        assert isinstance(cr.CONSTITUTION_REGISTRY, tuple)
        # Concrete entries come first, planned after. Pin the layout.
        first_twenty_three = cr.CONSTITUTION_REGISTRY[:23]
        assert all(e.kind == cr.KIND_CONCRETE for e in first_twenty_three)
        remaining = cr.CONSTITUTION_REGISTRY[23:]
        assert all(e.kind == cr.KIND_PLANNED for e in remaining)

    def test_planned_area_set_is_empty_after_slice_17(self):
        # Phase 7 Slice 17 promoted the last planned area
        # (memory_retrieval_compiler_modules) to a concrete entry.
        # From this point forward the planned-area tuple must stay
        # empty unless a new planned area is explicitly added.
        assert cr.planned_areas() == ()
        assert cr.PLANNED_AREA_NAMES == frozenset()


# ---------------------------------------------------------------------------
# 2. Every concrete entry resolves to a real tracked repo path now
# ---------------------------------------------------------------------------


class TestConcreteEntriesResolveOnDisk:
    def test_every_concrete_path_exists_as_a_file_in_the_repo(self):
        missing = []
        for entry in cr.concrete_entries():
            full = _REPO_ROOT / entry.path  # type: ignore[operator]
            if not full.is_file():
                missing.append(entry.path)
        assert missing == [], (
            f"constitution_registry declares concrete entries that do "
            f"not exist on disk: {missing}"
        )

    def test_no_concrete_path_is_a_directory(self):
        for entry in cr.concrete_entries():
            full = _REPO_ROOT / entry.path  # type: ignore[operator]
            assert not full.is_dir(), (
                f"{entry.path} must be a file, not a directory"
            )

    def test_concrete_paths_are_all_under_the_repo_root(self):
        # Defensive: make sure the declared path, when joined, stays
        # under the repo root. No symlink traversal, no escape.
        for entry in cr.concrete_entries():
            full = (_REPO_ROOT / entry.path).resolve()  # type: ignore[operator]
            assert _REPO_ROOT in full.parents or full == _REPO_ROOT, (
                f"{entry.path} resolves outside the repo root"
            )


# ---------------------------------------------------------------------------
# 3. Planned areas are explicitly non-concrete
# ---------------------------------------------------------------------------


class TestPlannedAreas:
    def test_planned_areas_have_kind_planned(self):
        for entry in cr.planned_areas():
            assert entry.kind == cr.KIND_PLANNED

    def test_planned_areas_have_no_path(self):
        for entry in cr.planned_areas():
            assert entry.path is None, (
                f"planned area {entry.name!r} must not carry a path "
                f"(got {entry.path!r})"
            )

    def test_planned_area_names_do_not_overlap_concrete(self):
        assert cr.PLANNED_AREA_NAMES.isdisjoint(cr.CONCRETE_ENTRY_NAMES)

    def test_planned_areas_do_not_match_is_constitution_level(self):
        # Planned areas are identified by slug, not path. Passing a
        # slug through is_constitution_level must return False — the
        # helper only matches against concrete paths.
        for entry in cr.planned_areas():
            assert cr.is_constitution_level(entry.name) is False

    def test_planned_areas_have_non_empty_rationale(self):
        for entry in cr.planned_areas():
            assert entry.rationale.strip() != ""

    def test_entry_kinds_vocabulary_is_exactly_two(self):
        assert cr.ENTRY_KINDS == frozenset({"concrete", "planned"})

    def test_constructing_concrete_without_path_raises(self):
        with pytest.raises(ValueError):
            cr.ConstitutionEntry(
                name="bad",
                kind=cr.KIND_CONCRETE,
                path=None,
                rationale="x",
            )

    def test_constructing_planned_with_path_raises(self):
        with pytest.raises(ValueError):
            cr.ConstitutionEntry(
                name="bad",
                kind=cr.KIND_PLANNED,
                path="runtime/cli.py",
                rationale="x",
            )

    def test_constructing_with_unknown_kind_raises(self):
        with pytest.raises(ValueError):
            cr.ConstitutionEntry(
                name="bad",
                kind="mythical",
                path=None,
                rationale="x",
            )


# ---------------------------------------------------------------------------
# 4. normalize_repo_path determinism and edge cases
# ---------------------------------------------------------------------------


class TestNormalizeRepoPath:
    def test_plain_relative_path_returns_unchanged(self):
        assert cr.normalize_repo_path("runtime/cli.py") == "runtime/cli.py"

    def test_leading_dot_slash_is_stripped(self):
        assert cr.normalize_repo_path("./runtime/cli.py") == "runtime/cli.py"

    def test_backslashes_convert_to_forward_slashes(self):
        assert (
            cr.normalize_repo_path("runtime\\core\\dispatch_engine.py")
            == "runtime/core/dispatch_engine.py"
        )

    def test_double_slashes_collapse(self):
        assert (
            cr.normalize_repo_path("runtime//core//dispatch_engine.py")
            == "runtime/core/dispatch_engine.py"
        )

    def test_absolute_posix_path_is_rejected(self):
        assert cr.normalize_repo_path("/tmp/CLAUDE.md") is None
        assert cr.normalize_repo_path("/home/user/code/CLAUDE.md") is None

    def test_windows_drive_letter_path_is_rejected(self):
        assert cr.normalize_repo_path("C:/code/CLAUDE.md") is None
        assert cr.normalize_repo_path("D:\\code\\CLAUDE.md") is None

    def test_parent_traversal_is_rejected(self):
        assert cr.normalize_repo_path("../escape") is None
        assert cr.normalize_repo_path("runtime/../escape") is None
        assert cr.normalize_repo_path("runtime/core/../cli.py") is None

    def test_empty_and_none_inputs_return_none(self):
        assert cr.normalize_repo_path("") is None
        assert cr.normalize_repo_path(None) is None  # type: ignore[arg-type]
        assert cr.normalize_repo_path(42) is None  # type: ignore[arg-type]
        assert cr.normalize_repo_path([]) is None  # type: ignore[arg-type]

    def test_bare_dot_is_rejected(self):
        assert cr.normalize_repo_path(".") is None

    def test_normalize_never_raises(self):
        # Exhaustive fuzzing of bad inputs.
        for bad in ["", " ", "/", "//", "..", "../..", "./..", None, 0, {}]:
            cr.normalize_repo_path(bad)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# 5. is_constitution_level determinism — no overmatch
# ---------------------------------------------------------------------------


class TestIsConstitutionLevel:
    def test_exact_match_for_every_concrete_entry(self):
        for path in CONCRETE_CONSTITUTION_FILES:
            assert cr.is_constitution_level(path) is True, (
                f"{path} must match is_constitution_level"
            )

    def test_dot_slash_prefix_match_for_every_concrete_entry(self):
        for path in CONCRETE_CONSTITUTION_FILES:
            assert cr.is_constitution_level(f"./{path}") is True

    def test_backslash_spelling_matches_for_nested_entries(self):
        assert (
            cr.is_constitution_level("runtime\\core\\dispatch_engine.py")
            is True
        )

    def test_suffix_path_does_not_match_constitution(self):
        # "runtime/cli.py.bak" must not match "runtime/cli.py".
        assert cr.is_constitution_level("runtime/cli.py.bak") is False

    def test_prefix_path_does_not_match_constitution(self):
        # "runtime/cli" (no .py) must not match.
        assert cr.is_constitution_level("runtime/cli") is False

    def test_sibling_path_does_not_match(self):
        # A file in the same directory with a different name must not
        # match.
        assert cr.is_constitution_level("runtime/core/dispatch_engine_v2.py") is False
        assert cr.is_constitution_level("runtime/core/completions_legacy.py") is False

    def test_absolute_path_is_never_constitution(self):
        # Even if the absolute path ends in a constitution-level name.
        assert cr.is_constitution_level("/tmp/CLAUDE.md") is False
        assert (
            cr.is_constitution_level("/home/user/code/runtime/cli.py")
            is False
        )

    def test_parent_traversal_is_never_constitution(self):
        assert cr.is_constitution_level("../CLAUDE.md") is False
        assert cr.is_constitution_level("runtime/../cli.py") is False

    def test_unrelated_file_is_not_constitution(self):
        assert cr.is_constitution_level("README.md") is False
        assert cr.is_constitution_level("tests/runtime/test_cli.py") is False

    def test_empty_and_none_inputs_are_not_constitution(self):
        assert cr.is_constitution_level("") is False
        assert cr.is_constitution_level(None) is False  # type: ignore[arg-type]
        assert cr.is_constitution_level(42) is False  # type: ignore[arg-type]

    def test_planned_area_slug_is_not_constitution(self):
        # Planned areas never match even by their own name.
        assert (
            cr.is_constitution_level("decision_work_registry_modules") is False
        )


# ---------------------------------------------------------------------------
# 6. lookup / concrete_entries / planned_areas pure helpers
# ---------------------------------------------------------------------------


class TestLookupHelpers:
    def test_lookup_finds_concrete_entry_by_name(self):
        entry = cr.lookup("runtime/cli.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/cli.py"

    def test_lookup_returns_none_for_any_previously_planned_slug(self):
        # As of Phase 7 Slice 17 the planned-area tuple is empty —
        # every previously planned area has been promoted to a
        # concrete entry. Every previously-planned slug (including
        # the most recent ``memory_retrieval_compiler_modules``)
        # must now resolve to ``None`` via lookup.
        assert cr.lookup("memory_retrieval_compiler_modules") is None
        assert cr.lookup("projection_reflow_orchestrator_module") is None
        assert cr.lookup("decision_work_registry_modules") is None
        assert cr.lookup("stage_registry_capability_authority_modules") is None
        assert cr.lookup("prompt_pack_compiler_modules") is None
        assert cr.lookup("projection_reflow_engine_modules") is None

    def test_prompt_pack_compiler_slug_is_gone_from_planned(self):
        # The old planned slug must not resurface — its authority
        # lives in the concrete ``runtime/core/prompt_pack.py`` entry.
        assert cr.lookup("prompt_pack_compiler_modules") is None
        assert "prompt_pack_compiler_modules" not in cr.PLANNED_AREA_NAMES

    def test_prompt_pack_module_is_concrete(self):
        entry = cr.lookup("runtime/core/prompt_pack.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/prompt_pack.py"
        assert cr.is_constitution_level("runtime/core/prompt_pack.py") is True

    def test_stage_registry_capability_authority_slug_is_gone_from_planned(self):
        # The old planned slug must not resurface — its authority lives
        # in the concrete stage_registry + authority_registry entries.
        assert cr.lookup("stage_registry_capability_authority_modules") is None
        assert "stage_registry_capability_authority_modules" not in cr.PLANNED_AREA_NAMES

    def test_stage_registry_module_is_concrete(self):
        entry = cr.lookup("runtime/core/stage_registry.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/stage_registry.py"
        assert cr.is_constitution_level("runtime/core/stage_registry.py") is True

    def test_authority_registry_module_is_concrete(self):
        entry = cr.lookup("runtime/core/authority_registry.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/authority_registry.py"
        assert cr.is_constitution_level("runtime/core/authority_registry.py") is True

    def test_decision_work_registry_slug_is_gone_from_planned(self):
        # The old planned slug must not resurface — its authority lives
        # in the concrete decision_work_registry.py entry.
        assert cr.lookup("decision_work_registry_modules") is None
        assert "decision_work_registry_modules" not in cr.PLANNED_AREA_NAMES

    def test_decision_work_registry_module_is_concrete(self):
        entry = cr.lookup("runtime/core/decision_work_registry.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/decision_work_registry.py"
        assert cr.is_constitution_level("runtime/core/decision_work_registry.py") is True

    def test_projection_reflow_engine_slug_is_gone_from_planned(self):
        # The broad slug was split in Phase 7 Slice 5 — realized
        # validators promoted to concrete, only the orchestrator remains.
        assert cr.lookup("projection_reflow_engine_modules") is None
        assert "projection_reflow_engine_modules" not in cr.PLANNED_AREA_NAMES

    def test_projection_schemas_module_is_concrete(self):
        entry = cr.lookup("runtime/core/projection_schemas.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/projection_schemas.py"
        assert cr.is_constitution_level("runtime/core/projection_schemas.py") is True

    def test_hook_doc_projection_module_is_concrete(self):
        entry = cr.lookup("runtime/core/hook_doc_projection.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/hook_doc_projection.py"
        assert cr.is_constitution_level("runtime/core/hook_doc_projection.py") is True

    def test_hook_doc_validation_module_is_concrete(self):
        entry = cr.lookup("runtime/core/hook_doc_validation.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/hook_doc_validation.py"
        assert cr.is_constitution_level("runtime/core/hook_doc_validation.py") is True

    def test_prompt_pack_validation_module_is_concrete(self):
        entry = cr.lookup("runtime/core/prompt_pack_validation.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/prompt_pack_validation.py"
        assert cr.is_constitution_level("runtime/core/prompt_pack_validation.py") is True

    def test_hook_manifest_module_is_concrete(self):
        """Phase 7 Slice 8: hook_manifest is the runtime-owned authority
        backing settings validation and hook-doc projection."""
        entry = cr.lookup("runtime/core/hook_manifest.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/hook_manifest.py"
        assert cr.is_constitution_level("runtime/core/hook_manifest.py") is True

    def test_no_broad_hook_manifest_planned_slug(self):
        """No planned-area slug should refer to the hook manifest module —
        its authority lives in the concrete ``runtime/core/hook_manifest.py``."""
        for slug in cr.PLANNED_AREA_NAMES:
            assert "hook_manifest" not in slug, (
                f"planned slug {slug!r} suggests hook_manifest is still "
                f"future — but it is concrete as of Phase 7 Slice 8"
            )

    def test_prompt_pack_resolver_module_is_concrete(self):
        """Phase 7 Slice 10: prompt_pack_resolver is the canonical
        prompt-pack layer composition authority backing the
        ``prompt-pack compile`` CLI path."""
        entry = cr.lookup("runtime/core/prompt_pack_resolver.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/prompt_pack_resolver.py"
        assert (
            cr.is_constitution_level("runtime/core/prompt_pack_resolver.py")
            is True
        )

    def test_decision_digest_projection_module_is_concrete(self):
        """Phase 7 Slice 13: decision_digest_projection is the canonical
        decision-digest projection generator — pure builder that renders
        a decision-digest markdown body and constructs a DecisionDigest
        projection from caller-supplied DecisionRecord sequences."""
        entry = cr.lookup("runtime/core/decision_digest_projection.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/decision_digest_projection.py"
        assert (
            cr.is_constitution_level(
                "runtime/core/decision_digest_projection.py"
            )
            is True
        )

    def test_no_broad_decision_digest_projection_planned_slug(self):
        """No planned-area slug should refer to the decision-digest
        projection generator — its authority lives in the concrete
        ``runtime/core/decision_digest_projection.py`` (Phase 7 Slice 13)."""
        for slug in cr.PLANNED_AREA_NAMES:
            assert "decision_digest" not in slug, (
                f"planned slug {slug!r} suggests decision-digest "
                f"projection is still future — but it is concrete as of "
                f"Phase 7 Slice 13"
            )

    def test_projection_reflow_module_is_concrete(self):
        """Phase 7 Slice 16: projection_reflow is the pure staleness
        planner that answers which projections are stale given a set
        of changed authorities/files."""
        entry = cr.lookup("runtime/core/projection_reflow.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/projection_reflow.py"
        assert (
            cr.is_constitution_level("runtime/core/projection_reflow.py")
            is True
        )

    def test_projection_reflow_orchestrator_slug_is_gone_from_planned(self):
        """The old planned slug must not resurface — its authority lives
        in the concrete ``runtime/core/projection_reflow.py`` entry
        (Phase 7 Slice 16)."""
        assert cr.lookup("projection_reflow_orchestrator_module") is None
        assert (
            "projection_reflow_orchestrator_module" not in cr.PLANNED_AREA_NAMES
        )

    def test_memory_retrieval_module_is_concrete(self):
        """Phase 7 Slice 17: memory_retrieval is the pure memory +
        retrieval projection compiler that produces deterministic
        SearchIndexMetadata and GraphExport projections from
        caller-supplied MemorySource / GraphEdge records."""
        entry = cr.lookup("runtime/core/memory_retrieval.py")
        assert entry is not None
        assert entry.kind == cr.KIND_CONCRETE
        assert entry.path == "runtime/core/memory_retrieval.py"
        assert (
            cr.is_constitution_level("runtime/core/memory_retrieval.py")
            is True
        )

    def test_memory_retrieval_compiler_slug_is_gone_from_planned(self):
        """The old planned slug must not resurface — its authority lives
        in the concrete ``runtime/core/memory_retrieval.py`` entry
        (Phase 7 Slice 17)."""
        assert cr.lookup("memory_retrieval_compiler_modules") is None
        assert (
            "memory_retrieval_compiler_modules" not in cr.PLANNED_AREA_NAMES
        )

    def test_no_broad_memory_retrieval_planned_slug(self):
        """No planned-area slug should refer to the memory/retrieval
        compiler — its authority lives in the concrete
        ``runtime/core/memory_retrieval.py`` (Phase 7 Slice 17)."""
        for slug in cr.PLANNED_AREA_NAMES:
            assert "memory_retrieval" not in slug, (
                f"planned slug {slug!r} suggests memory_retrieval is "
                f"still future — but it is concrete as of Phase 7 Slice 17"
            )
            assert "retrieval_compiler" not in slug, (
                f"planned slug {slug!r} suggests a separate retrieval "
                f"compiler is still future — but the compiler authority "
                f"lives in runtime/core/memory_retrieval.py as of "
                f"Phase 7 Slice 17"
            )

    def test_no_broad_projection_reflow_planned_slug(self):
        """No planned-area slug should refer to the projection reflow
        planner or an orchestrator module — its authority lives in the
        concrete ``runtime/core/projection_reflow.py`` (Phase 7 Slice 16)."""
        for slug in cr.PLANNED_AREA_NAMES:
            assert "projection_reflow" not in slug, (
                f"planned slug {slug!r} suggests projection_reflow is "
                f"still future — but it is concrete as of Phase 7 Slice 16"
            )
            assert "reflow_orchestrator" not in slug, (
                f"planned slug {slug!r} suggests a separate reflow "
                f"orchestrator is still future — but the reflow authority "
                f"lives in runtime/core/projection_reflow.py as of "
                f"Phase 7 Slice 16"
            )

    def test_no_broad_prompt_pack_resolver_planned_slug(self):
        """No planned-area slug should refer to the prompt-pack resolver or
        its layer-composition layer — its authority lives in the concrete
        ``runtime/core/prompt_pack_resolver.py`` (Phase 7 Slice 10)."""
        for slug in cr.PLANNED_AREA_NAMES:
            assert "prompt_pack_resolver" not in slug, (
                f"planned slug {slug!r} suggests prompt_pack_resolver is "
                f"still future — but it is concrete as of Phase 7 Slice 10"
            )
            assert "layer_composition" not in slug, (
                f"planned slug {slug!r} suggests prompt-pack layer "
                f"composition is still future — but the authority lives "
                f"in the concrete runtime/core/prompt_pack_resolver.py "
                f"as of Phase 7 Slice 10"
            )

    def test_lookup_unknown_name_returns_none(self):
        assert cr.lookup("nothing_here") is None
        assert cr.lookup("") is None

    def test_concrete_entries_helper_matches_registry_slice(self):
        assert cr.concrete_entries() == tuple(
            e for e in cr.CONSTITUTION_REGISTRY if e.kind == cr.KIND_CONCRETE
        )

    def test_planned_areas_helper_matches_registry_slice(self):
        assert cr.planned_areas() == tuple(
            e for e in cr.CONSTITUTION_REGISTRY if e.kind == cr.KIND_PLANNED
        )

    def test_registry_is_fully_partitioned_into_concrete_and_planned(self):
        # Every entry is exactly one of the two kinds. No third kind
        # can sneak in.
        for entry in cr.CONSTITUTION_REGISTRY:
            assert entry.kind in (cr.KIND_CONCRETE, cr.KIND_PLANNED)
        total = len(cr.concrete_entries()) + len(cr.planned_areas())
        assert total == len(cr.CONSTITUTION_REGISTRY)


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline (AST inspection, not substring search)
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_constitution_registry_does_not_import_live_modules(self):
        imported = _imported_module_names(cr)
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
            "runtime.core.workflows",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"constitution_registry.py imports {name!r} which "
                    f"contains forbidden live-module token {needle!r}"
                )

    def test_core_routing_modules_do_not_import_constitution_registry(self):
        """Core routing modules (dispatch_engine, completions, policy_engine)
        must not import constitution_registry. Individual policy files
        (e.g. write_plan_guard) may import it as a read-only consumer."""
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "constitution_registry" not in name, (
                    f"{mod.__name__} imports {name!r} — core routing "
                    f"modules must not depend on constitution_registry"
                )

    def test_constitution_registry_has_no_runtime_core_dependencies(self):
        # Positive assertion: this module depends only on the Python
        # standard library (dataclasses, pathlib, typing). Any
        # runtime.core import would create an unexpected coupling.
        imported = _imported_module_names(cr)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        assert runtime_core_imports == set(), (
            f"constitution_registry.py unexpectedly depends on "
            f"{runtime_core_imports}"
        )

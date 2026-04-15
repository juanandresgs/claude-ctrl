"""Tests for runtime/core/prompt_pack.py.

@decision DEC-CLAUDEX-PROMPT-PACK-TESTS-001
Title: Prompt-pack compiler canonical layers, render determinism, and projection hash alignment are pinned
Status: proposed (shadow-mode, Phase 2 prompt-pack bootstrap)
Rationale: The prompt-pack compiler is the first Phase 2 slice that
  compiles a ``projection_schemas.PromptPack`` from explicit layer
  content. Tests pin:

    1. The canonical six-layer vocabulary and order are exactly as
       CUTOVER_PLAN §Prompt Pack Layers declares.
    2. Layer validation rejects missing, extra, non-string, empty,
       and whitespace-only values.
    3. Rendered text is deterministic, contains every layer body
       under a matching H2 heading in canonical order, and ends
       with exactly one trailing newline.
    4. ``PromptPack.layer_names`` equals the canonical tuple.
    5. ``PromptPack.content_hash`` is derived from the same rendered
       body and changes when any layer changes.
    6. ``metadata.provenance`` carries one ``SourceRef`` per
       canonical layer with the declared source_kind /
       source_version; ``stale_condition`` lists the declared
       authority facts and constitution files.
    7. Shadow-only discipline: imports only
       ``runtime.core.projection_schemas``; no live modules import
       it; ``runtime/cli.py`` does not import it.
"""

from __future__ import annotations

import ast
import hashlib
import inspect
import json

import pytest

from runtime.core import projection_schemas as ps
from runtime.core import prompt_pack as pp


def _imported_module_names(module) -> set[str]:
    """Return all imported names, including those inside function bodies."""
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


def _module_level_imported_names(module) -> set[str]:
    """Return only module-level (top-level statement) imported names.

    Excludes imports inside function or class bodies.  Used to guard
    against module-level circular dependencies while permitting the
    established function-local import pattern (used to break load-time
    cycles for modules that import from each other).
    """
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in tree.body:  # top-level statements only
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


def _default_layers(suffix: str = "") -> dict:
    """Return a fresh dict of valid layer content."""
    return {
        name: f"Body for {name} layer{suffix}."
        for name in pp.CANONICAL_LAYER_ORDER
    }


# ---------------------------------------------------------------------------
# 1. Canonical layer vocabulary
# ---------------------------------------------------------------------------


class TestCanonicalLayerVocabulary:
    def test_canonical_layer_order_is_exact(self):
        assert pp.CANONICAL_LAYER_ORDER == (
            "constitution",
            "stage_contract",
            "workflow_contract",
            "local_decision_pack",
            "runtime_state_pack",
            "next_actions",
        )

    def test_canonical_layer_order_has_six_items(self):
        assert len(pp.CANONICAL_LAYER_ORDER) == 6

    def test_canonical_layers_frozenset_matches_order(self):
        assert pp.CANONICAL_LAYERS == frozenset(pp.CANONICAL_LAYER_ORDER)

    def test_canonical_layers_frozenset_is_frozen(self):
        with pytest.raises(AttributeError):
            pp.CANONICAL_LAYERS.add("rogue")  # type: ignore[attr-defined]

    def test_individual_layer_constants_exist(self):
        assert pp.LAYER_CONSTITUTION == "constitution"
        assert pp.LAYER_STAGE_CONTRACT == "stage_contract"
        assert pp.LAYER_WORKFLOW_CONTRACT == "workflow_contract"
        assert pp.LAYER_LOCAL_DECISION_PACK == "local_decision_pack"
        assert pp.LAYER_RUNTIME_STATE_PACK == "runtime_state_pack"
        assert pp.LAYER_NEXT_ACTIONS == "next_actions"

    def test_no_duplicates_in_canonical_order(self):
        assert len(set(pp.CANONICAL_LAYER_ORDER)) == 6


# ---------------------------------------------------------------------------
# 2. Layer validation
# ---------------------------------------------------------------------------


class TestLayerValidation:
    def test_valid_layers_accepted(self):
        pp.render_prompt_pack(
            workflow_id="wf", stage_id="s", layers=_default_layers()
        )

    def test_missing_layer_rejected(self):
        layers = _default_layers()
        del layers["constitution"]
        with pytest.raises(ValueError, match="missing canonical entries"):
            pp.render_prompt_pack(workflow_id="wf", stage_id="s", layers=layers)

    def test_missing_multiple_layers_rejected(self):
        layers = _default_layers()
        del layers["constitution"]
        del layers["next_actions"]
        with pytest.raises(ValueError, match="missing canonical entries"):
            pp.render_prompt_pack(workflow_id="wf", stage_id="s", layers=layers)

    def test_extra_layer_rejected(self):
        layers = _default_layers()
        layers["rogue_layer"] = "surprise"
        with pytest.raises(ValueError, match="unknown entries"):
            pp.render_prompt_pack(workflow_id="wf", stage_id="s", layers=layers)

    def test_non_string_layer_value_rejected(self):
        layers = _default_layers()
        layers["constitution"] = 42  # type: ignore[assignment]
        with pytest.raises(ValueError, match="must be a string"):
            pp.render_prompt_pack(workflow_id="wf", stage_id="s", layers=layers)

    def test_empty_string_layer_value_rejected(self):
        layers = _default_layers()
        layers["stage_contract"] = ""
        with pytest.raises(ValueError, match="non-empty"):
            pp.render_prompt_pack(workflow_id="wf", stage_id="s", layers=layers)

    def test_whitespace_only_layer_value_rejected(self):
        layers = _default_layers()
        layers["workflow_contract"] = "   \n\t  "
        with pytest.raises(ValueError, match="non-empty"):
            pp.render_prompt_pack(workflow_id="wf", stage_id="s", layers=layers)

    def test_non_mapping_layers_rejected(self):
        with pytest.raises(ValueError, match="must be a mapping"):
            pp.render_prompt_pack(
                workflow_id="wf",
                stage_id="s",
                layers=["not", "a", "mapping"],  # type: ignore[arg-type]
            )

    def test_empty_workflow_id_rejected(self):
        with pytest.raises(ValueError, match="workflow_id"):
            pp.render_prompt_pack(
                workflow_id="", stage_id="s", layers=_default_layers()
            )

    def test_empty_stage_id_rejected(self):
        with pytest.raises(ValueError, match="stage_id"):
            pp.render_prompt_pack(
                workflow_id="wf", stage_id="", layers=_default_layers()
            )

    def test_non_string_workflow_id_rejected(self):
        with pytest.raises(ValueError, match="workflow_id"):
            pp.render_prompt_pack(
                workflow_id=123,  # type: ignore[arg-type]
                stage_id="s",
                layers=_default_layers(),
            )


# ---------------------------------------------------------------------------
# 3. Render determinism and ordering
# ---------------------------------------------------------------------------


class TestRenderPromptPack:
    def test_render_is_deterministic(self):
        layers = _default_layers()
        a = pp.render_prompt_pack(
            workflow_id="wf", stage_id="planner", layers=layers
        )
        b = pp.render_prompt_pack(
            workflow_id="wf", stage_id="planner", layers=layers
        )
        assert a == b

    def test_render_starts_with_h1_title(self):
        text = pp.render_prompt_pack(
            workflow_id="wf-123",
            stage_id="planner",
            layers=_default_layers(),
        )
        first_line = text.splitlines()[0]
        assert first_line == "# ClauDEX Prompt Pack: wf-123 @ planner"

    def test_render_contains_generator_version(self):
        text = pp.render_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=_default_layers(),
        )
        assert f"Generator: `{pp.PROMPT_PACK_GENERATOR_VERSION}`" in text

    def test_render_contains_every_layer_heading_in_canonical_order(self):
        text = pp.render_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=_default_layers(),
        )
        headings = [
            line[3:] for line in text.splitlines() if line.startswith("## ")
        ]
        assert headings == list(pp.CANONICAL_LAYER_ORDER)

    def test_render_contains_every_layer_body(self):
        layers = {
            name: f"UNIQUE_BODY_{name.upper()}"
            for name in pp.CANONICAL_LAYER_ORDER
        }
        text = pp.render_prompt_pack(
            workflow_id="wf", stage_id="s", layers=layers
        )
        for name in pp.CANONICAL_LAYER_ORDER:
            assert f"UNIQUE_BODY_{name.upper()}" in text

    def test_render_ends_with_single_trailing_newline(self):
        text = pp.render_prompt_pack(
            workflow_id="wf", stage_id="s", layers=_default_layers()
        )
        assert text.endswith("\n")
        assert not text.endswith("\n\n")

    def test_render_preserves_layer_body_verbatim(self):
        layers = _default_layers()
        layers["constitution"] = "LINE 1\nLINE 2\nLINE 3"
        text = pp.render_prompt_pack(
            workflow_id="wf", stage_id="s", layers=layers
        )
        assert "LINE 1\nLINE 2\nLINE 3" in text


# ---------------------------------------------------------------------------
# 4. build_prompt_pack — PromptPack shape + content hash
# ---------------------------------------------------------------------------


class TestBuildPromptPack:
    def test_returns_prompt_pack_instance(self):
        pack = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=_default_layers(),
            generated_at=1_700_000_000,
        )
        assert isinstance(pack, ps.PromptPack)
        assert pack.SCHEMA_TYPE == "prompt_pack"

    def test_layer_names_equals_canonical_order(self):
        pack = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=_default_layers(),
            generated_at=1,
        )
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER

    def test_workflow_and_stage_passthrough(self):
        pack = pp.build_prompt_pack(
            workflow_id="wf-42",
            stage_id="implementer",
            layers=_default_layers(),
            generated_at=1,
        )
        assert pack.workflow_id == "wf-42"
        assert pack.stage_id == "implementer"

    def test_content_hash_matches_rendered_body(self):
        layers = _default_layers()
        pack = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=layers,
            generated_at=1,
        )
        rendered = pp.render_prompt_pack(
            workflow_id="wf", stage_id="s", layers=layers
        )
        expected = (
            "sha256:" + hashlib.sha256(rendered.encode("utf-8")).hexdigest()
        )
        assert pack.content_hash == expected

    def test_content_hash_stable_across_calls(self):
        layers = _default_layers()
        a = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=layers,
            generated_at=1_700_000_000,
        )
        b = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=layers,
            generated_at=1_700_000_000,
        )
        assert a.content_hash == b.content_hash

    def test_content_hash_changes_when_any_layer_changes(self):
        base = _default_layers()
        base_pack = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=base,
            generated_at=1,
        )
        for layer in pp.CANONICAL_LAYER_ORDER:
            mutated = dict(base)
            mutated[layer] = mutated[layer] + " [edit]"
            mutated_pack = pp.build_prompt_pack(
                workflow_id="wf",
                stage_id="s",
                layers=mutated,
                generated_at=1,
            )
            assert mutated_pack.content_hash != base_pack.content_hash, (
                f"mutating {layer!r} did not change content_hash"
            )

    def test_content_hash_changes_when_workflow_id_changes(self):
        layers = _default_layers()
        a = pp.build_prompt_pack(
            workflow_id="wf-one",
            stage_id="s",
            layers=layers,
            generated_at=1,
        )
        b = pp.build_prompt_pack(
            workflow_id="wf-two",
            stage_id="s",
            layers=layers,
            generated_at=1,
        )
        assert a.content_hash != b.content_hash

    def test_content_hash_changes_when_stage_id_changes(self):
        layers = _default_layers()
        a = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="planner",
            layers=layers,
            generated_at=1,
        )
        b = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="reviewer",
            layers=layers,
            generated_at=1,
        )
        assert a.content_hash != b.content_hash

    def test_build_delegates_validation_to_render(self):
        layers = _default_layers()
        del layers["next_actions"]
        with pytest.raises(ValueError):
            pp.build_prompt_pack(
                workflow_id="wf",
                stage_id="s",
                layers=layers,
                generated_at=1,
            )


# ---------------------------------------------------------------------------
# 5. ProjectionMetadata contents
# ---------------------------------------------------------------------------


class TestProjectionMetadata:
    def _pack(self, **overrides):
        kwargs = {
            "workflow_id": "wf",
            "stage_id": "s",
            "layers": _default_layers(),
            "generated_at": 1,
        }
        kwargs.update(overrides)
        return pp.build_prompt_pack(**kwargs)

    def test_generator_version_is_populated(self):
        pack = self._pack()
        assert pack.metadata.generator_version == pp.PROMPT_PACK_GENERATOR_VERSION
        assert pack.metadata.generator_version != ""

    def test_generated_at_is_caller_supplied(self):
        pack = self._pack(generated_at=42_000)
        assert pack.metadata.generated_at == 42_000

    def test_source_versions_carries_prompt_pack_layers(self):
        pack = self._pack(manifest_version="9.9.9")
        assert pack.metadata.source_versions == (
            ("prompt_pack_layers", "9.9.9"),
        )

    def test_provenance_has_one_ref_per_canonical_layer(self):
        pack = self._pack()
        assert len(pack.metadata.provenance) == len(pp.CANONICAL_LAYER_ORDER)

    def test_provenance_ref_source_kinds_are_prompt_pack_layer(self):
        pack = self._pack()
        for ref in pack.metadata.provenance:
            assert ref.source_kind == "prompt_pack_layer"

    def test_provenance_source_ids_match_canonical_layer_names(self):
        pack = self._pack()
        ids = tuple(ref.source_id for ref in pack.metadata.provenance)
        assert ids == pp.CANONICAL_LAYER_ORDER

    def test_provenance_source_versions_use_manifest_version(self):
        pack = self._pack(manifest_version="7.0.0")
        for ref in pack.metadata.provenance:
            assert ref.source_version == "7.0.0"

    def test_stale_condition_rationale_is_non_empty(self):
        pack = self._pack()
        assert pack.metadata.stale_condition.rationale.strip() != ""

    def test_stale_condition_watched_authorities_includes_hook_wiring(self):
        pack = self._pack()
        assert "hook_wiring" in pack.metadata.stale_condition.watched_authorities

    def test_stale_condition_watched_authorities_include_expected_facts(self):
        pack = self._pack()
        watched = set(pack.metadata.stale_condition.watched_authorities)
        assert {
            "stage_transitions",
            "role_capabilities",
            "goal_contract_shape",
            "work_item_contract_shape",
            "hook_wiring",
        } <= watched

    def test_stale_condition_watched_files_direct_builder_default(self):
        """Phase 7 Slice 11: direct pure-builder callers (no ``watched_files``
        kwarg) still fall back to the minimal ``(CLAUDE.md, AGENTS.md)``
        pair. The registry-derived full set is populated only by the
        compile path, via
        ``prompt_pack_resolver.constitution_watched_files()``."""
        pack = self._pack()
        watched = pack.metadata.stale_condition.watched_files
        assert watched == ("CLAUDE.md", "AGENTS.md")

    def test_stale_condition_watched_files_override_is_honored(self):
        """Phase 7 Slice 11: the optional ``watched_files`` kwarg replaces
        the fallback so compile-path callers can pass the full concrete
        constitution set without mutating module state."""
        override = (
            "runtime/core/prompt_pack_resolver.py",
            "runtime/core/hook_manifest.py",
            "CLAUDE.md",
        )
        pack = self._pack(watched_files=override)
        assert pack.metadata.stale_condition.watched_files == override


# ---------------------------------------------------------------------------
# 6. JSON serialisation round-trip of identity fields
# ---------------------------------------------------------------------------


class TestJsonSerialisation:
    def test_identity_fields_are_json_serialisable(self):
        pack = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id="s",
            layers=_default_layers(),
            generated_at=1,
        )
        # Serialise the parts we expect future CLI output to carry.
        payload = {
            "workflow_id": pack.workflow_id,
            "stage_id": pack.stage_id,
            "layer_names": list(pack.layer_names),
            "content_hash": pack.content_hash,
            "generator_version": pack.metadata.generator_version,
            "generated_at": pack.metadata.generated_at,
        }
        encoded = json.dumps(payload)
        decoded = json.loads(encoded)
        assert decoded["workflow_id"] == "wf"
        assert decoded["layer_names"] == list(pp.CANONICAL_LAYER_ORDER)
        assert decoded["content_hash"].startswith("sha256:")


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_prompt_pack_imports_only_projection_schemas(self):
        imported = _imported_module_names(pp)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        # The capstone ``compile_prompt_pack_for_stage`` chains the
        # other shadow-kernel prompt-pack helpers via function-level
        # imports, which the AST walker still detects. Permit those
        # exact names — every other ``runtime.core`` import remains
        # forbidden so the compiler cannot quietly grow live routing
        # / CLI / hook / policy-engine dependencies. The id-mode
        # branch of ``compile_prompt_pack_for_stage`` adds a
        # function-scope import of ``workflow_contract_capture``
        # (DEC-CLAUDEX-PROMPT-PACK-COMPILE-MODE-SELECTION-001),
        # which the walker also picks up.
        # prompt_pack_validation is also permitted: build_subagent_start_prompt_pack_response
        # uses a function-local import to call the canonical request validator
        # (avoids module-level load cycle — prompt_pack_validation imports from
        # prompt_pack at module level).
        permitted_prefixes = (
            "runtime.core.contracts",
            "runtime.core.projection_schemas",
            "runtime.core.prompt_pack_decisions",
            "runtime.core.prompt_pack_resolver",
            "runtime.core.prompt_pack_state",
            "runtime.core.prompt_pack_validation",
            "runtime.core.workflow_contract_capture",
        )
        permitted_bases = {"runtime.core"}
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(permitted_prefixes), (
                f"prompt_pack.py has unexpected runtime.core import: {name!r}"
            )

    def test_prompt_pack_has_no_live_imports(self):
        imported = _imported_module_names(pp)
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
                    f"prompt_pack.py imports {name!r} containing forbidden "
                    f"token {needle!r}"
                )

    def test_live_modules_do_not_import_prompt_pack(self):
        # Exact-module match (plus dotted-submodule check) so that
        # sibling modules like ``runtime.core.prompt_pack_validation``
        # — which also contain the substring ``prompt_pack`` — are
        # not accidentally forbidden by a too-loose substring scan.
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert name != "runtime.core.prompt_pack" and not name.startswith(
                    "runtime.core.prompt_pack."
                ), (
                    f"{mod.__name__} imports {name!r} — prompt_pack must "
                    f"stay shadow-only this slice"
                )

    def test_cli_imports_prompt_pack_only_via_function_scope(self):
        # Architecture invariant after the prompt-pack compile CLI
        # slice (DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001):
        # ``runtime/cli.py`` may import ``runtime.core.prompt_pack``
        # — but only via a function-scope import inside the
        # ``compile`` branch of ``_handle_prompt_pack``. At module
        # level the CLI must continue to reach the compiler only
        # transitively through ``runtime.core.prompt_pack_validation``.
        #
        # The guard therefore walks ``tree.body`` (the top-level
        # module statements) rather than the full AST, mirroring
        # the same pattern used for
        # ``test_prompt_pack_module_imports_resolver_only_via_capstone_helper``
        # and
        # ``test_prompt_pack_imports_capture_helper_only_via_function_scope``.
        import runtime.cli as cli

        tree = ast.parse(inspect.getsource(cli))
        module_level_imports: set[str] = set()
        for node in tree.body:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    module_level_imports.add(alias.name)
            elif isinstance(node, ast.ImportFrom):
                base = node.module or ""
                if base:
                    module_level_imports.add(base)
                    for alias in node.names:
                        module_level_imports.add(f"{base}.{alias.name}")
        for name in module_level_imports:
            assert name != "runtime.core.prompt_pack" and not name.startswith(
                "runtime.core.prompt_pack."
            ), (
                f"cli.py imports {name!r} at module level — "
                f"prompt_pack may only be reached transitively via "
                f"prompt_pack_validation or via the function-scope "
                f"import in the ``compile`` branch of _handle_prompt_pack"
            )

    def test_projection_schemas_does_not_import_prompt_pack(self):
        imported = _imported_module_names(ps)
        for name in imported:
            assert name != "runtime.core.prompt_pack" and not name.startswith(
                "runtime.core.prompt_pack."
            ), (
                f"projection_schemas.py imports {name!r} — the schema "
                f"family must not depend on a specific compiler"
            )


# ---------------------------------------------------------------------------
# 8. Capstone end-to-end compile helper
# ---------------------------------------------------------------------------


import sqlite3  # noqa: E402

from runtime.core import approvals as _approvals  # noqa: E402
from runtime.core import contracts as _contracts  # noqa: E402
from runtime.core import decision_work_registry as _dwr  # noqa: E402
from runtime.core import leases as _leases  # noqa: E402
from runtime.core import prompt_pack_resolver as _ppr  # noqa: E402
from runtime.core import reviewer_findings as _rf  # noqa: E402
from runtime.core import stage_registry as _sr  # noqa: E402
from runtime.core import workflows as _workflows  # noqa: E402
from runtime.schemas import ensure_schema as _ensure_schema  # noqa: E402


@pytest.fixture
def compile_conn():
    """Fresh in-memory SQLite connection with the runtime schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    _ensure_schema(c)
    yield c
    c.close()


def _seed_workflow_binding(
    conn,
    *,
    workflow_id: str = "wf-cap",
    branch: str = "feature/wf-cap",
    worktree_path: str = "/tmp/wf-cap",
) -> None:
    _workflows.bind_workflow(
        conn,
        workflow_id=workflow_id,
        worktree_path=worktree_path,
        branch=branch,
    )


def _seed_decision(
    conn,
    *,
    decision_id: str,
    scope: str = "kernel",
    status: str = "accepted",
    created_at: int = 100,
    superseded_by: str | None = None,
    supersedes: str | None = None,
) -> None:
    record = _dwr.DecisionRecord(
        decision_id=decision_id,
        title=f"Title {decision_id}",
        status=status,
        rationale=f"Rationale for {decision_id}",
        version=1,
        author="planner",
        scope=scope,
        supersedes=supersedes,
        superseded_by=superseded_by,
        created_at=created_at,
        updated_at=created_at,
    )
    _dwr.insert_decision(conn, record)


def _make_goal(goal_id: str = "GOAL-CAP-1") -> _contracts.GoalContract:
    return _contracts.GoalContract(
        goal_id=goal_id,
        desired_end_state="ship the capstone helper",
        status="active",
    )


def _make_work_item(
    *, goal_id: str = "GOAL-CAP-1", title: str = "Capstone slice"
) -> _contracts.WorkItemContract:
    return _contracts.WorkItemContract(
        work_item_id="WI-CAP-1",
        goal_id=goal_id,
        title=title,
        scope=_contracts.ScopeManifest(
            allowed_paths=("runtime/core/prompt_pack.py",),
            required_paths=("tests/runtime/test_prompt_pack.py",),
            forbidden_paths=("runtime/cli.py",),
            state_domains=("decisions", "workflow_bindings"),
        ),
        evaluation=_contracts.EvaluationContract(
            required_tests=("pytest tests/runtime/test_prompt_pack.py",),
            required_evidence=("verbatim pytest footer",),
            rollback_boundary="git restore runtime/core/prompt_pack.py",
            acceptance_notes="capstone helper covered end-to-end",
        ),
        status="in_progress",
    )


def _compile(conn, **overrides):
    """Compile a prompt pack using the capstone helper with sensible defaults."""
    kwargs = dict(
        workflow_id="wf-cap",
        stage_id=_sr.PLANNER,
        goal=_make_goal(),
        work_item=_make_work_item(),
        decision_scope="kernel",
        generated_at=1_700_000_000,
    )
    kwargs.update(overrides)
    return pp.compile_prompt_pack_for_stage(conn, **kwargs)


class TestCompilePromptPackForStage:
    def test_returns_prompt_pack_instance(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        pack = _compile(compile_conn)
        assert isinstance(pack, ps.PromptPack)
        assert pack.workflow_id == "wf-cap"
        assert pack.stage_id == _sr.PLANNER
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER
        assert pack.content_hash.startswith("sha256:")

    def test_empty_decision_scope_still_compiles(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        # No decisions seeded — capture returns empty tuple, the
        # bridge degrades to a default LocalDecisionSummary, and the
        # capstone still produces a valid PromptPack.
        pack = _compile(compile_conn, decision_scope="completely-empty-scope")
        assert isinstance(pack, ps.PromptPack)
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER

    def test_decision_change_flows_through_content_hash(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        _seed_decision(
            compile_conn, decision_id="DEC-CAP-A", scope="kernel", created_at=100
        )
        base_pack = _compile(compile_conn)

        # Adding another decision under the captured scope changes
        # the local_decision_pack body, which must propagate into
        # the rendered prompt pack's content hash.
        _seed_decision(
            compile_conn, decision_id="DEC-CAP-B", scope="kernel", created_at=200
        )
        mutated_pack = _compile(compile_conn)

        assert base_pack.content_hash != mutated_pack.content_hash

    def test_state_change_flows_through_content_hash(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        base_pack = _compile(compile_conn)

        # Granting an approval mutates the runtime_state_pack layer
        # via capture_runtime_state_snapshot. The content hash must
        # change in response.
        _approvals.grant(compile_conn, "wf-cap", "push")
        mutated_pack = _compile(compile_conn)

        assert base_pack.content_hash != mutated_pack.content_hash

    def test_lease_change_flows_through_content_hash(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        base_pack = _compile(compile_conn)

        _leases.issue(
            compile_conn,
            role="implementer",
            workflow_id="wf-cap",
            worktree_path="/tmp/wf-cap",
        )
        mutated_pack = _compile(compile_conn)

        assert base_pack.content_hash != mutated_pack.content_hash

    def test_explicit_branch_override_takes_precedence(self, compile_conn):
        _seed_workflow_binding(
            compile_conn, branch="feature/from-binding"
        )
        binding_pack = _compile(compile_conn)
        override_pack = _compile(
            compile_conn, current_branch="feature/explicit-override"
        )
        # The branch flows into the runtime_state_pack layer, so
        # the override path must produce a different content hash.
        assert binding_pack.content_hash != override_pack.content_hash

    def test_explicit_worktree_override_takes_precedence(self, compile_conn):
        _seed_workflow_binding(
            compile_conn, worktree_path="/tmp/wf-cap-binding"
        )
        binding_pack = _compile(compile_conn)
        override_pack = _compile(
            compile_conn, worktree_path="/tmp/wf-cap-explicit-override"
        )
        assert binding_pack.content_hash != override_pack.content_hash

    def test_unresolved_findings_passthrough_changes_hash(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        base_pack = _compile(compile_conn)
        with_findings_pack = _compile(
            compile_conn, unresolved_findings=("finding-x", "finding-y")
        )
        assert base_pack.content_hash != with_findings_pack.content_hash

    def test_helper_is_read_only(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        _seed_decision(compile_conn, decision_id="DEC-RO", scope="kernel")
        _leases.issue(
            compile_conn,
            role="implementer",
            workflow_id="wf-cap",
            worktree_path="/tmp/wf-cap",
        )
        _approvals.grant(compile_conn, "wf-cap", "push")

        before = compile_conn.total_changes
        assert compile_conn.in_transaction is False
        _compile(compile_conn)
        after = compile_conn.total_changes
        assert after == before, (
            f"compile_prompt_pack_for_stage is not read-only; "
            f"total_changes went from {before} to {after}"
        )
        assert compile_conn.in_transaction is False

    def test_compile_path_watched_files_match_constitution_registry(
        self, compile_conn
    ):
        """Phase 7 Slice 11: the compile path's ``stale_condition.watched_files``
        is the full concrete constitution-level path set, sourced from
        ``constitution_registry`` (not a hardcoded pair). Test does not
        duplicate the file list — it asks the registry."""
        from runtime.core import constitution_registry as cr

        _seed_workflow_binding(compile_conn)
        pack = _compile(compile_conn)
        watched = pack.metadata.stale_condition.watched_files
        # Authority-derived, not hardcoded: the full concrete set in
        # deterministic registry order.
        assert watched == cr.all_concrete_paths()
        # At least two known Phase 7 promotions must be present — these
        # are the specific ones the instruction pins.
        assert "runtime/core/prompt_pack_resolver.py" in watched
        assert "runtime/core/hook_manifest.py" in watched

    def test_repeat_compile_is_byte_identical(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        _seed_decision(
            compile_conn, decision_id="DEC-DET-A", scope="kernel", created_at=100
        )
        a = _compile(compile_conn)
        b = _compile(compile_conn)
        assert a.content_hash == b.content_hash
        assert a.workflow_id == b.workflow_id
        assert a.stage_id == b.stage_id
        assert a.layer_names == b.layer_names
        assert a.metadata.generated_at == b.metadata.generated_at

    def test_missing_binding_with_no_override_raises(self, compile_conn):
        # No binding for ``wf-ghost`` and no explicit branch / worktree
        # → capture_runtime_state_snapshot raises, and the helper
        # surfaces that error verbatim.
        with pytest.raises(ValueError, match="current_branch"):
            _compile(compile_conn, workflow_id="wf-ghost")

    def test_goal_work_item_id_mismatch_raises(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="goal_id"):
            _compile(
                compile_conn,
                goal=_make_goal(goal_id="GOAL-A"),
                work_item=_make_work_item(goal_id="GOAL-B"),
            )

    def test_invalid_goal_type_raises(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="GoalContract"):
            _compile(compile_conn, goal="not-a-goal")  # type: ignore[arg-type]

    def test_invalid_decision_scope_raises(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="non-empty"):
            _compile(compile_conn, decision_scope="   ")

    def test_capstone_compile_matches_manual_chain(self, compile_conn):
        # Building the prompt pack by hand through every helper must
        # produce a content hash byte-identical to the capstone's,
        # for identical inputs against identical SQLite state.
        _seed_workflow_binding(compile_conn)
        _seed_decision(
            compile_conn, decision_id="DEC-MATCH", scope="kernel", created_at=100
        )

        capstone = _compile(compile_conn)

        # Manual chain.
        from runtime.core import prompt_pack_decisions as _ppd
        from runtime.core import prompt_pack_state as _pps

        wf_summary = _ppr.workflow_summary_from_contracts(
            workflow_id="wf-cap",
            goal=_make_goal(),
            work_item=_make_work_item(),
        )
        records = _ppd.capture_relevant_decisions(compile_conn, scope="kernel")
        dec_summary = _ppr.local_decision_summary_from_records(decisions=records)
        snap = _pps.capture_runtime_state_snapshot(
            compile_conn, workflow_id="wf-cap"
        )
        rt_summary = _ppr.runtime_state_summary_from_snapshot(snapshot=snap)
        layers = _ppr.resolve_prompt_pack_layers(
            stage=_sr.PLANNER,
            workflow_summary=wf_summary,
            decision_summary=dec_summary,
            runtime_state_summary=rt_summary,
        )
        manual = pp.build_prompt_pack(
            workflow_id="wf-cap",
            stage_id=_sr.PLANNER,
            layers=layers,
            generated_at=1_700_000_000,
        )

        assert capstone.content_hash == manual.content_hash
        assert capstone.layer_names == manual.layer_names


# ---------------------------------------------------------------------------
# 9. Compile helper mode selection (explicit vs id mode)
# ---------------------------------------------------------------------------


from runtime.core import goal_contract_codec as _gcc  # noqa: E402


def _insert_goal_record(conn, *, goal_id: str = "GOAL-CAP-1") -> None:
    """Seed ``goal_contracts`` with an encoded row matching _make_goal()."""
    from runtime.core import decision_work_registry as dwr

    record = _gcc.encode_goal_contract(_make_goal(goal_id=goal_id))
    dwr.insert_goal(conn, record)


def _insert_work_item_record(
    conn,
    *,
    work_item_id: str = "WI-CAP-1",
    goal_id: str = "GOAL-CAP-1",
    title: str = "Capstone slice",
    status: str = "in_progress",
) -> None:
    """Seed ``work_items`` so Mode B can resolve the work item by id.

    Direct record construction (there is no ``encode_work_item_contract``
    by design — WorkItemRecord's provenance fields have no contract
    owner).
    """
    from runtime.core import decision_work_registry as dwr

    record = dwr.WorkItemRecord(
        work_item_id=work_item_id,
        goal_id=goal_id,
        title=title,
        status=status,
        version=1,
        author="planner",
        scope_json=(
            '{"allowed_paths":["runtime/core/prompt_pack.py"],'
            '"required_paths":["tests/runtime/test_prompt_pack.py"],'
            '"forbidden_paths":["runtime/cli.py"],'
            '"state_domains":["decisions","workflow_bindings"]}'
        ),
        evaluation_json=(
            '{"required_tests":["pytest tests/runtime/test_prompt_pack.py"],'
            '"required_evidence":["verbatim pytest footer"],'
            '"rollback_boundary":"git restore runtime/core/prompt_pack.py",'
            '"acceptance_notes":"capstone helper covered end-to-end"}'
        ),
        head_sha=None,
        reviewer_round=0,
    )
    dwr.insert_work_item(conn, record)


class TestCompilePromptPackForStageModeSelection:
    """Pin the Mode A / Mode B validation and the id-mode resolution path."""

    # -- Mode A still works (backwards-compatible) -----------------------

    def test_mode_a_explicit_contracts_still_compile(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        pack = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-cap",
            stage_id=_sr.PLANNER,
            goal=_make_goal(),
            work_item=_make_work_item(),
            decision_scope="kernel",
            generated_at=1_700_000_000,
        )
        assert isinstance(pack, ps.PromptPack)
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER

    # -- Mode B against SQLite-backed rows -------------------------------

    def test_mode_b_id_resolution_compiles(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        _insert_goal_record(compile_conn, goal_id="GOAL-CAP-1")
        _insert_work_item_record(
            compile_conn,
            work_item_id="WI-CAP-1",
            goal_id="GOAL-CAP-1",
        )

        pack = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-cap",
            stage_id=_sr.PLANNER,
            goal_id="GOAL-CAP-1",
            work_item_id="WI-CAP-1",
            decision_scope="kernel",
            generated_at=1_700_000_000,
        )
        assert isinstance(pack, ps.PromptPack)
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER

    def test_mode_b_matches_mode_a_byte_for_byte(self, compile_conn):
        # Encoding a goal via the codec, inserting it, and resolving
        # via id mode must produce a byte-identical content hash to
        # passing the same goal + work item as explicit contracts.
        _seed_workflow_binding(compile_conn)
        _insert_goal_record(compile_conn, goal_id="GOAL-CAP-1")
        _insert_work_item_record(
            compile_conn,
            work_item_id="WI-CAP-1",
            goal_id="GOAL-CAP-1",
        )

        mode_a_pack = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-cap",
            stage_id=_sr.PLANNER,
            goal=_make_goal(),
            work_item=_make_work_item(),
            decision_scope="kernel",
            generated_at=1_700_000_000,
        )
        mode_b_pack = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-cap",
            stage_id=_sr.PLANNER,
            goal_id="GOAL-CAP-1",
            work_item_id="WI-CAP-1",
            decision_scope="kernel",
            generated_at=1_700_000_000,
        )
        assert mode_a_pack.content_hash == mode_b_pack.content_hash

    def test_mode_b_missing_goal_raises_lookup_error(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        _insert_work_item_record(compile_conn)
        # No goal seeded → capture helper raises LookupError,
        # surfaces verbatim through the capstone.
        with pytest.raises(LookupError, match="goal_id"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                goal_id="GOAL-ghost",
                work_item_id="WI-CAP-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    def test_mode_b_missing_work_item_raises_lookup_error(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        _insert_goal_record(compile_conn)
        with pytest.raises(LookupError, match="work_item_id"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                goal_id="GOAL-CAP-1",
                work_item_id="WI-ghost",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    def test_mode_b_cross_check_mismatch_raises_value_error(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        _insert_goal_record(compile_conn, goal_id="GOAL-CALLER")
        _insert_goal_record(compile_conn, goal_id="GOAL-WRONG")
        _insert_work_item_record(
            compile_conn,
            work_item_id="WI-MISMATCH",
            goal_id="GOAL-WRONG",  # work item belongs to GOAL-WRONG
        )
        with pytest.raises(ValueError):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                goal_id="GOAL-CALLER",
                work_item_id="WI-MISMATCH",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    # -- Partial Mode A rejection ----------------------------------------

    def test_partial_mode_a_goal_only_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="explicit-contract mode"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                goal=_make_goal(),
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    def test_partial_mode_a_work_item_only_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="explicit-contract mode"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                work_item=_make_work_item(),
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    # -- Partial Mode B rejection ----------------------------------------

    def test_partial_mode_b_goal_id_only_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="id mode"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                goal_id="GOAL-CAP-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    def test_partial_mode_b_work_item_id_only_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="id mode"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                work_item_id="WI-CAP-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    # -- Mixed-mode rejection --------------------------------------------

    def test_mixed_goal_plus_work_item_id_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="cannot mix"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                goal=_make_goal(),
                work_item_id="WI-CAP-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    def test_mixed_work_item_plus_goal_id_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="cannot mix"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                work_item=_make_work_item(),
                goal_id="GOAL-CAP-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    def test_mixed_all_four_fields_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="cannot mix"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                goal=_make_goal(),
                work_item=_make_work_item(),
                goal_id="GOAL-CAP-1",
                work_item_id="WI-CAP-1",
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    # -- No mode supplied ------------------------------------------------

    def test_no_mode_supplied_rejected(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError, match="exactly one"):
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )

    def test_no_mode_error_names_both_modes(self, compile_conn):
        _seed_workflow_binding(compile_conn)
        with pytest.raises(ValueError) as exc_info:
            pp.compile_prompt_pack_for_stage(
                compile_conn,
                workflow_id="wf-cap",
                stage_id=_sr.PLANNER,
                decision_scope="kernel",
                generated_at=1_700_000_000,
            )
        msg = str(exc_info.value)
        assert "goal" in msg
        assert "work_item" in msg
        assert "goal_id" in msg
        assert "work_item_id" in msg


# ---------------------------------------------------------------------------
# 9b. Mode A live findings scoped by work_item.work_item_id
# ---------------------------------------------------------------------------


class TestModeALiveFindingsScopedByWorkItemId:
    """Mode A (explicit-contract) must scope live findings to
    ``work_item.work_item_id``, not the raw ``work_item_id``
    function parameter (which is ``None`` in Mode A).
    """

    def test_mode_a_captures_finding_for_own_work_item(self, compile_conn):
        """A finding tagged with the work item's id changes the hash
        (i.e. it was captured into the runtime-state layer)."""
        _seed_workflow_binding(compile_conn)
        baseline = _compile(compile_conn)

        _rf.insert(
            compile_conn,
            workflow_id="wf-cap",
            severity="blocking",
            title="Target finding",
            detail="Should appear",
            work_item_id="WI-CAP-1",  # matches _make_work_item().work_item_id
        )
        with_finding = _compile(compile_conn)
        assert with_finding.content_hash != baseline.content_hash

    def test_mode_a_excludes_finding_for_other_work_item(self, compile_conn):
        """A finding tagged with a *different* work item id must NOT
        change the hash — it was correctly filtered out."""
        _seed_workflow_binding(compile_conn)
        baseline = _compile(compile_conn)

        _rf.insert(
            compile_conn,
            workflow_id="wf-cap",
            severity="blocking",
            title="Other finding",
            detail="Should NOT appear",
            work_item_id="WI-OTHER-99",
        )
        with_other = _compile(compile_conn)
        assert with_other.content_hash == baseline.content_hash


# ---------------------------------------------------------------------------
# 10. SubagentStart delivery envelope
# ---------------------------------------------------------------------------


def _sample_envelope_inputs(**overrides) -> dict:
    """Build a fresh set of valid envelope inputs with optional overrides."""
    base = dict(
        workflow_id="wf-sse-1",
        stage_id="planner",
        content_hash="sha256:abcdef0123456789",
        rendered_body=pp.render_prompt_pack(
            workflow_id="wf-sse-1",
            stage_id="planner",
            layers=_default_layers(),
        ),
    )
    base.update(overrides)
    return base


class TestSubagentStartEnvelope:
    # -- Top-level envelope shape ----------------------------------------

    def test_returns_dict(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        assert isinstance(env, dict)

    def test_top_level_has_exactly_hook_specific_output_key(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        assert list(env.keys()) == ["hookSpecificOutput"]

    def test_hook_specific_output_has_exact_keys(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        inner = env["hookSpecificOutput"]
        assert set(inner.keys()) == {"hookEventName", "additionalContext"}

    def test_hook_event_name_is_subagent_start(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        assert (
            env["hookSpecificOutput"]["hookEventName"]
            == "SubagentStart"
        )

    def test_hook_event_name_matches_module_constant(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        assert (
            env["hookSpecificOutput"]["hookEventName"]
            == pp.SUBAGENT_START_HOOK_EVENT
        )

    def test_additional_context_is_string(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        assert isinstance(
            env["hookSpecificOutput"]["additionalContext"], str
        )

    def test_envelope_is_json_serialisable(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        encoded = json.dumps(env)
        decoded = json.loads(encoded)
        assert decoded == env

    # -- additionalContext content ---------------------------------------

    def test_additional_context_starts_with_preamble_tag(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        ctx = env["hookSpecificOutput"]["additionalContext"]
        assert ctx.startswith(pp.PROMPT_PACK_PREAMBLE_TAG)

    def test_additional_context_preamble_tag_is_first_line(self):
        env = pp.build_subagent_start_envelope(**_sample_envelope_inputs())
        ctx = env["hookSpecificOutput"]["additionalContext"]
        assert ctx.splitlines()[0] == pp.PROMPT_PACK_PREAMBLE_TAG

    def test_additional_context_contains_workflow_id_line(self):
        env = pp.build_subagent_start_envelope(
            **_sample_envelope_inputs(workflow_id="wf-echo")
        )
        ctx = env["hookSpecificOutput"]["additionalContext"]
        assert "workflow_id: wf-echo" in ctx

    def test_additional_context_contains_stage_id_line(self):
        env = pp.build_subagent_start_envelope(
            **_sample_envelope_inputs(stage_id="guardian:land")
        )
        ctx = env["hookSpecificOutput"]["additionalContext"]
        assert "stage_id: guardian:land" in ctx

    def test_additional_context_contains_content_hash_line(self):
        env = pp.build_subagent_start_envelope(
            **_sample_envelope_inputs(content_hash="sha256:deadbeef")
        )
        ctx = env["hookSpecificOutput"]["additionalContext"]
        assert "content_hash: sha256:deadbeef" in ctx

    def test_additional_context_preamble_line_order(self):
        # Pin the exact line order: tag → workflow_id → stage_id →
        # content_hash → blank → body. Tests index directly so a
        # reshuffle in the builder shows up immediately.
        inputs = _sample_envelope_inputs(
            workflow_id="wf-order",
            stage_id="planner",
            content_hash="sha256:abc",
            rendered_body="BODY LINE 1\nBODY LINE 2\n",
        )
        env = pp.build_subagent_start_envelope(**inputs)
        lines = env["hookSpecificOutput"]["additionalContext"].split("\n")
        assert lines[0] == pp.PROMPT_PACK_PREAMBLE_TAG
        assert lines[1] == "workflow_id: wf-order"
        assert lines[2] == "stage_id: planner"
        assert lines[3] == "content_hash: sha256:abc"
        assert lines[4] == ""
        # Body is appended verbatim after the blank line.
        assert lines[5] == "BODY LINE 1"
        assert lines[6] == "BODY LINE 2"

    def test_additional_context_contains_full_rendered_body(self):
        inputs = _sample_envelope_inputs()
        env = pp.build_subagent_start_envelope(**inputs)
        assert inputs["rendered_body"] in env["hookSpecificOutput"]["additionalContext"]

    def test_additional_context_preserves_body_bytes_verbatim(self):
        # A rendered body with multiple newlines must round-trip
        # byte-for-byte — the builder must not normalize whitespace.
        body = "LINE A\n\nLINE B\n\n\nLINE C\n"
        inputs = _sample_envelope_inputs(rendered_body=body)
        env = pp.build_subagent_start_envelope(**inputs)
        ctx = env["hookSpecificOutput"]["additionalContext"]
        assert ctx.endswith(body)

    # -- Determinism -----------------------------------------------------

    def test_deterministic_output_for_identical_inputs(self):
        inputs = _sample_envelope_inputs()
        a = pp.build_subagent_start_envelope(**inputs)
        b = pp.build_subagent_start_envelope(**inputs)
        assert a == b
        # Byte-identical when serialised too.
        assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)

    def test_changing_only_content_hash_changes_only_the_content_hash_line(self):
        base = _sample_envelope_inputs(content_hash="sha256:aaa")
        mutated = dict(base, content_hash="sha256:bbb")
        a = pp.build_subagent_start_envelope(**base)
        b = pp.build_subagent_start_envelope(**mutated)

        a_lines = a["hookSpecificOutput"]["additionalContext"].split("\n")
        b_lines = b["hookSpecificOutput"]["additionalContext"].split("\n")

        # Same length — no inserted / deleted lines.
        assert len(a_lines) == len(b_lines)

        # Only the content_hash line differs.
        diff_indices = [
            i for i, (x, y) in enumerate(zip(a_lines, b_lines)) if x != y
        ]
        assert diff_indices == [3], (
            f"expected only line 3 (content_hash) to differ; "
            f"got diff at {diff_indices}"
        )
        assert a_lines[3] == "content_hash: sha256:aaa"
        assert b_lines[3] == "content_hash: sha256:bbb"

        # Framing lines (tag, workflow, stage, blank) and body must be
        # byte-identical between the two envelopes.
        assert a_lines[0] == b_lines[0] == pp.PROMPT_PACK_PREAMBLE_TAG
        assert a_lines[1] == b_lines[1]
        assert a_lines[2] == b_lines[2]
        assert a_lines[4] == b_lines[4] == ""
        assert a_lines[5:] == b_lines[5:]

    # -- Input validation ------------------------------------------------

    @pytest.mark.parametrize(
        "field", ["workflow_id", "stage_id", "content_hash"]
    )
    def test_empty_identifier_rejected(self, field):
        inputs = _sample_envelope_inputs(**{field: ""})
        with pytest.raises(ValueError, match=field):
            pp.build_subagent_start_envelope(**inputs)

    @pytest.mark.parametrize(
        "field", ["workflow_id", "stage_id", "content_hash"]
    )
    def test_non_string_identifier_rejected(self, field):
        inputs = _sample_envelope_inputs(**{field: 42})
        with pytest.raises(ValueError, match=field):
            pp.build_subagent_start_envelope(**inputs)

    def test_empty_rendered_body_rejected(self):
        inputs = _sample_envelope_inputs(rendered_body="")
        with pytest.raises(ValueError, match="rendered_body"):
            pp.build_subagent_start_envelope(**inputs)

    def test_whitespace_only_rendered_body_rejected(self):
        inputs = _sample_envelope_inputs(rendered_body="   \n\t  ")
        with pytest.raises(ValueError, match="rendered_body"):
            pp.build_subagent_start_envelope(**inputs)

    def test_non_string_rendered_body_rejected(self):
        inputs = _sample_envelope_inputs(rendered_body=123)
        with pytest.raises(ValueError, match="rendered_body"):
            pp.build_subagent_start_envelope(**inputs)

    # -- Preamble tag constant -------------------------------------------

    def test_preamble_tag_is_stable_literal(self):
        # Pin the exact string so a future cosmetic change is a
        # deliberate decision, not a drift.
        assert pp.PROMPT_PACK_PREAMBLE_TAG == "[runtime-compiled prompt pack]"

    def test_subagent_start_hook_event_is_stable_literal(self):
        assert pp.SUBAGENT_START_HOOK_EVENT == "SubagentStart"

    # -- End-to-end integration with the compiler ------------------------

    def test_envelope_accepts_real_compile_output(self, compile_conn):
        # Full integration path: compile a prompt pack via the
        # single compiler authority, then feed its content_hash +
        # the re-rendered body into the envelope builder. Pins
        # that the envelope's inputs are shape-compatible with
        # what the compiler produces.
        _seed_workflow_binding(compile_conn)
        pack = _compile(compile_conn)

        # Re-render the body from the same canonical layer
        # resolution the compiler used. The compiler stores the
        # hash of this body on the PromptPack, so the two must
        # agree.
        from runtime.core import prompt_pack_decisions as _ppd2
        from runtime.core import prompt_pack_state as _pps2

        wf_summary = _ppr.workflow_summary_from_contracts(
            workflow_id="wf-cap",
            goal=_make_goal(),
            work_item=_make_work_item(),
        )
        records = _ppd2.capture_relevant_decisions(compile_conn, scope="kernel")
        dec_summary = _ppr.local_decision_summary_from_records(decisions=records)
        snap = _pps2.capture_runtime_state_snapshot(
            compile_conn, workflow_id="wf-cap"
        )
        rt_summary = _ppr.runtime_state_summary_from_snapshot(snapshot=snap)
        layers = _ppr.resolve_prompt_pack_layers(
            stage=_sr.PLANNER,
            workflow_summary=wf_summary,
            decision_summary=dec_summary,
            runtime_state_summary=rt_summary,
        )
        rendered = pp.render_prompt_pack(
            workflow_id=pack.workflow_id,
            stage_id=pack.stage_id,
            layers=layers,
        )

        env = pp.build_subagent_start_envelope(
            workflow_id=pack.workflow_id,
            stage_id=pack.stage_id,
            content_hash=pack.content_hash,
            rendered_body=rendered,
        )
        assert env["hookSpecificOutput"]["hookEventName"] == "SubagentStart"
        ctx = env["hookSpecificOutput"]["additionalContext"]
        assert f"workflow_id: {pack.workflow_id}" in ctx
        assert f"stage_id: {pack.stage_id}" in ctx
        assert f"content_hash: {pack.content_hash}" in ctx
        assert rendered in ctx

    # -- Shadow-only discipline for the envelope helper ------------------

    def test_envelope_helper_is_defined_in_prompt_pack_module(self):
        # The instruction says the helper must live in
        # runtime/core/prompt_pack.py, not a sibling module.
        assert pp.build_subagent_start_envelope.__module__ == "runtime.core.prompt_pack"

    def test_envelope_helper_does_not_introduce_new_imports(self):
        # The shadow-only discipline guard
        # ``test_prompt_pack_imports_only_projection_schemas`` is
        # already the canonical check for the module's import
        # surface. This test simply pins that the envelope helper
        # did not drag in any new runtime.core dependency beyond
        # what the compiler capstone already needed.
        # prompt_pack_validation is also permitted: build_subagent_start_prompt_pack_response
        # uses a function-local import to call the canonical request validator.
        imported = _imported_module_names(pp)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_prefixes = (
            "runtime.core.contracts",
            "runtime.core.projection_schemas",
            "runtime.core.prompt_pack_decisions",
            "runtime.core.prompt_pack_resolver",
            "runtime.core.prompt_pack_state",
            "runtime.core.prompt_pack_validation",
            "runtime.core.workflow_contract_capture",
        )
        permitted_bases = {"runtime.core"}
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"prompt_pack.py grew an unexpected runtime.core import "
                f"after the SubagentStart envelope slice: {name!r}"
            )


# ---------------------------------------------------------------------------
# 11. SubagentStart prompt-pack composition response helper
# ---------------------------------------------------------------------------


@pytest.fixture
def response_conn():
    """Fresh in-memory SQLite connection with the runtime schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    _ensure_schema(c)
    yield c
    c.close()


def _seed_for_response(conn) -> None:
    """Seed all state needed for a valid Mode-B response compilation."""
    _seed_workflow_binding(
        conn,
        workflow_id="wf-resp",
        branch="feature/wf-resp",
        worktree_path="/tmp/wf-resp",
    )
    _insert_goal_record(conn, goal_id="GOAL-RESP-1")
    _insert_work_item_record(
        conn, work_item_id="WI-RESP-1", goal_id="GOAL-RESP-1"
    )


def _valid_response_payload(**overrides) -> dict:
    p = {
        "workflow_id": "wf-resp",
        "stage_id": _sr.PLANNER,
        "goal_id": "GOAL-RESP-1",
        "work_item_id": "WI-RESP-1",
        "decision_scope": "kernel",
        "generated_at": 1_700_000_000,
    }
    p.update(overrides)
    return p


EXPECTED_RESPONSE_REPORT_KEYS = {"status", "healthy", "violations", "envelope"}


# -- 11a. Happy path -------------------------------------------------------


class TestBuildSubagentStartPromptPackResponseHappyPath:
    def test_valid_payload_returns_ok(self, response_conn):
        _seed_for_response(response_conn)
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        assert report["status"] == "ok"
        assert report["healthy"] is True
        assert report["violations"] == []

    def test_report_shape_is_stable(self, response_conn):
        _seed_for_response(response_conn)
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        assert set(report.keys()) == EXPECTED_RESPONSE_REPORT_KEYS

    def test_envelope_is_present_and_well_formed(self, response_conn):
        _seed_for_response(response_conn)
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        env = report["envelope"]
        assert env is not None
        assert isinstance(env, dict)
        assert set(env.keys()) == {"hookSpecificOutput"}
        hso = env["hookSpecificOutput"]
        assert hso["hookEventName"] == pp.SUBAGENT_START_HOOK_EVENT
        assert isinstance(hso["additionalContext"], str)
        assert pp.PROMPT_PACK_PREAMBLE_TAG in hso["additionalContext"]

    def test_envelope_preamble_echoes_workflow_and_stage(self, response_conn):
        _seed_for_response(response_conn)
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        ctx = report["envelope"]["hookSpecificOutput"]["additionalContext"]
        assert "workflow_id: wf-resp" in ctx
        assert f"stage_id: {_sr.PLANNER}" in ctx

    def test_envelope_content_hash_is_sha256(self, response_conn):
        _seed_for_response(response_conn)
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        ctx = report["envelope"]["hookSpecificOutput"]["additionalContext"]
        hash_line = next(
            ln for ln in ctx.split("\n") if ln.startswith("content_hash: ")
        )
        hash_val = hash_line[len("content_hash: "):]
        assert hash_val.startswith("sha256:")
        assert len(hash_val) == len("sha256:") + 64

    def test_report_is_json_serialisable(self, response_conn):
        _seed_for_response(response_conn)
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_report_is_deterministic(self, response_conn):
        _seed_for_response(response_conn)
        a = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        b = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        assert a == b

    def test_extra_payload_fields_are_tolerated(self, response_conn):
        _seed_for_response(response_conn)
        payload = _valid_response_payload()
        payload["session_id"] = "sess-extra"
        payload["hook_event_name"] = "SubagentStart"
        payload["model"] = "claude-sonnet-4-6"
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, payload
        )
        assert report["status"] == "ok"
        assert report["healthy"] is True


# -- 11b. Invalid path short-circuits compilation -------------------------


class TestBuildSubagentStartPromptPackResponseInvalidPath:
    def test_non_mapping_returns_invalid_report(self, response_conn):
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, "not a dict"
        )
        assert report["status"] == "invalid"
        assert report["healthy"] is False
        assert report["envelope"] is None
        assert any("mapping" in v for v in report["violations"])

    def test_none_payload_returns_invalid_report(self, response_conn):
        report = pp.build_subagent_start_prompt_pack_response(response_conn, None)
        assert report["status"] == "invalid"
        assert report["envelope"] is None

    def test_missing_field_short_circuits_compilation(self, response_conn):
        # Database is NOT seeded — if compilation ran it would fail
        # differently (LookupError). The invalid path must return
        # before touching the database.
        payload = _valid_response_payload()
        del payload["goal_id"]
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert report["status"] == "invalid"
        assert report["envelope"] is None
        assert any("goal_id" in v for v in report["violations"])

    def test_wrong_type_field_short_circuits_compilation(self, response_conn):
        payload = _valid_response_payload(stage_id=42)
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert report["status"] == "invalid"
        assert report["envelope"] is None

    def test_empty_string_field_short_circuits_compilation(self, response_conn):
        payload = _valid_response_payload(workflow_id="")
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert report["status"] == "invalid"
        assert report["envelope"] is None

    def test_whitespace_only_field_short_circuits_compilation(self, response_conn):
        payload = _valid_response_payload(decision_scope="   ")
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert report["status"] == "invalid"
        assert report["envelope"] is None

    def test_float_generated_at_short_circuits_compilation(self, response_conn):
        payload = _valid_response_payload(generated_at=1_700_000_000.0)
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert report["status"] == "invalid"
        assert report["envelope"] is None
        assert any("generated_at" in v for v in report["violations"])

    def test_bool_generated_at_short_circuits_compilation(self, response_conn):
        # bool is a subclass of int in Python but must be rejected.
        payload = _valid_response_payload(generated_at=True)
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert report["status"] == "invalid"
        assert report["envelope"] is None

    def test_string_generated_at_short_circuits_compilation(self, response_conn):
        payload = _valid_response_payload(generated_at="1700000000")
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert report["status"] == "invalid"
        assert report["envelope"] is None

    def test_cumulative_violations_all_fields_missing(self, response_conn):
        report = pp.build_subagent_start_prompt_pack_response(response_conn, {})
        assert len(report["violations"]) == 6
        assert report["status"] == "invalid"

    def test_two_bad_fields_produce_two_violations(self, response_conn):
        payload = _valid_response_payload(workflow_id="", goal_id=123)
        report = pp.build_subagent_start_prompt_pack_response(response_conn, payload)
        assert len(report["violations"]) >= 2

    def test_invalid_report_shape_is_stable(self, response_conn):
        report = pp.build_subagent_start_prompt_pack_response(response_conn, None)
        assert set(report.keys()) == EXPECTED_RESPONSE_REPORT_KEYS

    def test_invalid_report_is_json_serialisable(self, response_conn):
        report = pp.build_subagent_start_prompt_pack_response(response_conn, None)
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report


# -- 11c. Read-only guarantee ---------------------------------------------


class TestBuildSubagentStartPromptPackResponseReadOnly:
    def test_helper_is_read_only(self, response_conn):
        _seed_for_response(response_conn)
        before = response_conn.total_changes
        assert response_conn.in_transaction is False
        pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        after = response_conn.total_changes
        assert after == before, (
            "build_subagent_start_prompt_pack_response wrote to the database: "
            f"total_changes went from {before} to {after}"
        )
        assert response_conn.in_transaction is False


# -- 11d. Envelope round-trip with envelope validator ---------------------


class TestBuildSubagentStartPromptPackResponseRoundTrip:
    def test_produced_envelope_passes_envelope_validator(self, response_conn):
        # The envelope produced by the response helper must validate clean
        # against the pure envelope validator. This is the key integration
        # guard: if the builder and validator ever drift, this test breaks.
        from runtime.core import prompt_pack_validation as ppv

        _seed_for_response(response_conn)
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, _valid_response_payload()
        )
        assert report["healthy"] is True
        validation_report = ppv.validate_subagent_start_envelope(
            report["envelope"]
        )
        assert validation_report["status"] == ppv.VALIDATION_STATUS_OK
        assert validation_report["healthy"] is True
        assert validation_report["violations"] == []
        assert validation_report["workflow_id"] == "wf-resp"
        assert validation_report["stage_id"] == _sr.PLANNER

    def test_content_hash_matches_compile_output(self, response_conn):
        # The content_hash embedded in the envelope must equal what
        # compile_prompt_pack_for_stage (Mode A, equivalent inputs) returns.
        _seed_for_response(response_conn)
        _insert_goal_record(response_conn, goal_id="GOAL-CAP-1")
        _insert_work_item_record(
            response_conn, work_item_id="WI-CAP-1", goal_id="GOAL-CAP-1"
        )
        _seed_workflow_binding(
            response_conn,
            workflow_id="wf-cap2",
            branch="feature/wf-cap2",
            worktree_path="/tmp/wf-cap2",
        )

        # Mode A compile with same data
        mode_a_pack = pp.compile_prompt_pack_for_stage(
            response_conn,
            workflow_id="wf-cap2",
            stage_id=_sr.PLANNER,
            goal=_make_goal(goal_id="GOAL-CAP-1"),
            work_item=_make_work_item(goal_id="GOAL-CAP-1"),
            decision_scope="kernel",
            generated_at=1_700_000_000,
        )

        # Response helper with Mode B (id mode) resolves same rows
        response_payload = {
            "workflow_id": "wf-cap2",
            "stage_id": _sr.PLANNER,
            "goal_id": "GOAL-CAP-1",
            "work_item_id": "WI-CAP-1",
            "decision_scope": "kernel",
            "generated_at": 1_700_000_000,
        }
        report = pp.build_subagent_start_prompt_pack_response(
            response_conn, response_payload
        )
        assert report["healthy"] is True

        ctx = report["envelope"]["hookSpecificOutput"]["additionalContext"]
        hash_line = next(
            ln for ln in ctx.split("\n") if ln.startswith("content_hash: ")
        )
        envelope_hash = hash_line[len("content_hash: "):]
        assert envelope_hash == mode_a_pack.content_hash


# -- 11e. Shadow discipline -----------------------------------------------


class TestBuildSubagentStartPromptPackResponseShadowDiscipline:
    def test_helper_is_defined_in_prompt_pack_module(self):
        assert (
            pp.build_subagent_start_prompt_pack_response.__module__
            == "runtime.core.prompt_pack"
        )

    def test_helper_is_exported(self):
        assert "build_subagent_start_prompt_pack_response" in pp.__all__
        assert callable(pp.build_subagent_start_prompt_pack_response)

    def test_helper_does_not_import_prompt_pack_validation_at_module_level(self):
        # Module-level circular-dependency guard: prompt_pack.py must NOT
        # import prompt_pack_validation at module level.  prompt_pack_validation
        # imports from prompt_pack at module level — a module-level import in
        # the reverse direction would create a load-time cycle and prevent
        # either module from initialising.
        #
        # Function-local imports (inside build_subagent_start_prompt_pack_response)
        # are intentionally permitted: by the time the function is called both
        # modules are fully loaded.  This mirrors the established pattern for
        # _ppd/_ppr/_pps/_wcap in the same function.
        module_level = _module_level_imported_names(pp)
        for name in module_level:
            assert "prompt_pack_validation" not in name, (
                f"prompt_pack.py has a module-level import of {name!r} — "
                "this creates a circular load-time dependency since "
                "prompt_pack_validation imports from prompt_pack at module level."
            )

    def test_response_helper_does_not_widen_imports(self):
        # The composition helper must not import any runtime.core module
        # beyond what the envelope slice already permitted.
        # prompt_pack_validation is explicitly permitted: build_subagent_start_prompt_pack_response
        # uses a function-local import to call the canonical request validator
        # without introducing a module-level load cycle.
        imported = _imported_module_names(pp)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_prefixes = (
            "runtime.core.contracts",
            "runtime.core.projection_schemas",
            "runtime.core.prompt_pack_decisions",
            "runtime.core.prompt_pack_resolver",
            "runtime.core.prompt_pack_state",
            "runtime.core.prompt_pack_validation",
            "runtime.core.workflow_contract_capture",
        )
        permitted_bases = {"runtime.core"}
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"prompt_pack.py grew an unexpected runtime.core import "
                f"after the response composition slice: {name!r}"
            )

    # -- Single-authority pin for validate_subagent_start_prompt_pack_request --

    def test_request_validator_is_defined_in_prompt_pack_validation(self):
        # Authority is in prompt_pack_validation (DEC-CLAUDEX-PROMPT-PACK-REQUEST-VALIDATION-001).
        # build_subagent_start_prompt_pack_response calls it via a function-local
        # import to avoid the module-level load cycle (prompt_pack_validation
        # imports from prompt_pack at module level). There is no private copy.
        from runtime.core import prompt_pack_validation as ppv

        assert (
            ppv.validate_subagent_start_prompt_pack_request.__module__
            == "runtime.core.prompt_pack_validation"
        )

    def test_request_validator_not_in_prompt_pack_all(self):
        # validate_subagent_start_prompt_pack_request is no longer a public
        # export of prompt_pack — it lives in prompt_pack_validation only.
        assert "validate_subagent_start_prompt_pack_request" not in pp.__all__

    def test_request_validator_not_accessible_on_prompt_pack(self):
        # validate_subagent_start_prompt_pack_request is not an attribute of
        # prompt_pack — it is imported function-locally inside
        # build_subagent_start_prompt_pack_response and is not bound at module scope.
        assert not hasattr(pp, "validate_subagent_start_prompt_pack_request")

    def test_request_validator_is_callable_from_prompt_pack_validation(self):
        # The public API surface ppv.validate_subagent_start_prompt_pack_request
        # must remain callable so callers of prompt_pack_validation are unaffected.
        from runtime.core import prompt_pack_validation as ppv

        assert "validate_subagent_start_prompt_pack_request" in ppv.__all__
        assert callable(ppv.validate_subagent_start_prompt_pack_request)

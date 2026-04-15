"""Tests for runtime/core/memory_retrieval.py.

@decision DEC-CLAUDEX-MEMORY-RETRIEVAL-TESTS-001
Title: Pure memory/retrieval projection compiler determinism, validation, and shadow-only import discipline are pinned
Status: proposed (shadow-mode, Phase 7 Slice 17 memory/retrieval compiler)
Rationale: The memory/retrieval compiler is the last remaining planned
  area from CUTOVER_PLAN Phase 7. These tests pin:

    1. :class:`MemorySource` and :class:`GraphEdge` field-level
       validation (non-empty strings, tuple-of-string tags, no
       duplicates, no self-loops).
    2. Duplicate source ids and duplicate directed-edge triples are
       rejected — silent dedupe would hide caller bugs.
    3. Manifest rendering is deterministic regardless of input
       iteration order: sorting happens inside the compiler.
    4. ``content_hash`` flips on any source/edge field change but
       stays constant under input reordering.
    5. ``SearchIndexMetadata`` carries ``document_count``,
       ``index_name``, ``source_versions``, ``provenance``, and
       ``stale_condition`` shaped exactly as
       :mod:`runtime.core.projection_schemas` requires.
    6. ``GraphExport`` carries ``node_count`` / ``edge_count`` /
       deterministic edge ordering; unknown endpoints raise;
       duplicate edge triples raise.
    7. Empty corpus / empty edge list is deterministic and valid.
    8. Caller-supplied ``watched_authorities`` / ``watched_files``
       reach :attr:`ProjectionMetadata.stale_condition` and round-trip
       through :func:`runtime.core.projection_reflow.plan_projection_reflow`.
    9. Bare ``str`` / ``bytes`` in ``watched_*`` is rejected (the same
       trap :mod:`runtime.core.projection_reflow` closed in Slice 16
       correction).
   10. Shadow-only AST import discipline: depends only on
       stdlib + :mod:`runtime.core.projection_schemas`. No live
       routing / policy / hook / DB / CLI import at module scope.
"""

from __future__ import annotations

import ast
import inspect
import json

import pytest

from runtime.core import memory_retrieval as mr
from runtime.core import projection_reflow as pr
from runtime.core import projection_schemas as ps


# ---------------------------------------------------------------------------
# AST helper for shadow-only discipline tests
# ---------------------------------------------------------------------------


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
# Canonical sample records used by many tests
# ---------------------------------------------------------------------------


def _source(
    source_id: str = "mem-1",
    *,
    source_kind: str = "memory_document",
    source_version: str = "v1",
    path: str = "notes/alpha.md",
    title: str = "Alpha",
    body: str = "Alpha body",
    tags: tuple = (),
) -> mr.MemorySource:
    return mr.MemorySource(
        source_id=source_id,
        source_kind=source_kind,
        source_version=source_version,
        path=path,
        title=title,
        body=body,
        tags=tags,
    )


# ---------------------------------------------------------------------------
# 1. MemorySource validation
# ---------------------------------------------------------------------------


class TestMemorySourceValidation:
    def test_valid_source_roundtrips_fields(self):
        src = _source(tags=("alpha", "beta"))
        assert src.source_id == "mem-1"
        assert src.source_kind == "memory_document"
        assert src.source_version == "v1"
        assert src.path == "notes/alpha.md"
        assert src.title == "Alpha"
        assert src.body == "Alpha body"
        assert src.tags == ("alpha", "beta")

    @pytest.mark.parametrize(
        "field",
        [
            "source_id",
            "source_kind",
            "source_version",
            "path",
            "title",
        ],
    )
    def test_empty_required_string_field_raises(self, field):
        kwargs = dict(
            source_id="mem-1",
            source_kind="memory_document",
            source_version="v1",
            path="notes/alpha.md",
            title="Alpha",
            body="body",
        )
        kwargs[field] = ""
        with pytest.raises(ValueError):
            mr.MemorySource(**kwargs)

    @pytest.mark.parametrize(
        "field",
        [
            "source_id",
            "source_kind",
            "source_version",
            "path",
            "title",
            "body",
        ],
    )
    def test_non_string_field_raises(self, field):
        kwargs = dict(
            source_id="mem-1",
            source_kind="memory_document",
            source_version="v1",
            path="notes/alpha.md",
            title="Alpha",
            body="body",
        )
        kwargs[field] = 42
        with pytest.raises(ValueError):
            mr.MemorySource(**kwargs)

    def test_empty_body_is_allowed(self):
        # Empty body is legal; an empty-body note is a legitimate
        # canonical record (mirrors the module docstring contract).
        src = _source(body="")
        assert src.body == ""

    def test_tags_must_be_tuple(self):
        with pytest.raises(ValueError):
            mr.MemorySource(
                source_id="mem-1",
                source_kind="memory_document",
                source_version="v1",
                path="p",
                title="t",
                body="b",
                tags=["alpha"],  # type: ignore[arg-type]
            )

    def test_tag_entries_must_be_non_empty_strings(self):
        with pytest.raises(ValueError):
            _source(tags=("alpha", ""))
        with pytest.raises(ValueError):
            _source(tags=("alpha", 42))  # type: ignore[arg-type]

    def test_duplicate_tags_are_rejected(self):
        with pytest.raises(ValueError):
            _source(tags=("alpha", "alpha"))

    def test_tags_are_canonicalised_to_sorted_order(self):
        # Constructing with unsorted tags must yield a record whose
        # ``tags`` tuple is sorted ascending. This is the canonical
        # label-set shape: caller iteration order cannot leak into
        # downstream projections.
        src = _source(tags=("beta", "alpha"))
        assert src.tags == ("alpha", "beta")

    def test_tags_three_way_canonicalisation(self):
        src = _source(tags=("gamma", "alpha", "beta"))
        assert src.tags == ("alpha", "beta", "gamma")

    def test_already_sorted_tags_pass_through_unchanged(self):
        src = _source(tags=("alpha", "beta", "gamma"))
        assert src.tags == ("alpha", "beta", "gamma")

    def test_tag_order_does_not_change_search_index_content_hash(self):
        a = _source(source_id="x", tags=("alpha", "beta"))
        b = _source(source_id="x", tags=("beta", "alpha"))
        m_a = mr.build_search_index_metadata(
            (a,), index_name="idx", generated_at=0
        )
        m_b = mr.build_search_index_metadata(
            (b,), index_name="idx", generated_at=0
        )
        assert m_a.content_hash == m_b.content_hash

    def test_tag_order_does_not_change_graph_export_content_hash(self):
        # Graph nodes carry the same source manifest entries used by
        # the search index, so tag canonicalisation has to flow
        # through to the graph export too.
        a = _source(source_id="x", tags=("alpha", "beta"))
        b = _source(source_id="x", tags=("beta", "alpha"))
        gx_a = mr.build_graph_export((a,), (), generated_at=0)
        gx_b = mr.build_graph_export((b,), (), generated_at=0)
        assert gx_a.content_hash == gx_b.content_hash

    def test_memory_source_is_frozen(self):
        src = _source()
        import dataclasses

        assert dataclasses.is_dataclass(src)
        assert mr.MemorySource.__dataclass_params__.frozen is True
        with pytest.raises(dataclasses.FrozenInstanceError):
            src.source_id = "other"  # type: ignore[misc]


# ---------------------------------------------------------------------------
# 2. GraphEdge validation
# ---------------------------------------------------------------------------


class TestGraphEdgeValidation:
    def test_valid_edge_roundtrips_fields(self):
        edge = mr.GraphEdge(
            source_id="a",
            target_id="b",
            relation="cites",
            evidence_version="sha:deadbeef",
        )
        assert edge.source_id == "a"
        assert edge.target_id == "b"
        assert edge.relation == "cites"
        assert edge.evidence_version == "sha:deadbeef"

    @pytest.mark.parametrize(
        "field",
        ["source_id", "target_id", "relation", "evidence_version"],
    )
    def test_empty_field_raises(self, field):
        kwargs = dict(
            source_id="a",
            target_id="b",
            relation="cites",
            evidence_version="v1",
        )
        kwargs[field] = ""
        with pytest.raises(ValueError):
            mr.GraphEdge(**kwargs)

    @pytest.mark.parametrize(
        "field",
        ["source_id", "target_id", "relation", "evidence_version"],
    )
    def test_non_string_field_raises(self, field):
        kwargs = dict(
            source_id="a",
            target_id="b",
            relation="cites",
            evidence_version="v1",
        )
        kwargs[field] = 42
        with pytest.raises(ValueError):
            mr.GraphEdge(**kwargs)

    def test_self_loop_is_rejected(self):
        with pytest.raises(ValueError):
            mr.GraphEdge(
                source_id="a",
                target_id="a",
                relation="cites",
                evidence_version="v1",
            )

    def test_graph_edge_is_frozen(self):
        import dataclasses

        assert dataclasses.is_dataclass(mr.GraphEdge)
        assert mr.GraphEdge.__dataclass_params__.frozen is True


# ---------------------------------------------------------------------------
# 3. Search index — determinism, document_count, provenance, hash changes
# ---------------------------------------------------------------------------


class TestSearchIndexMetadata:
    def _corpus(self):
        return (
            _source("mem-b", title="Beta", body="Beta body"),
            _source("mem-a", title="Alpha", body="Alpha body"),
            _source("mem-c", title="Gamma", body="Gamma body"),
        )

    def test_document_count_equals_len_of_sources(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="claudex-memory",
            generated_at=1000,
        )
        assert meta.document_count == 3

    def test_index_name_is_preserved(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="claudex-memory",
            generated_at=1000,
        )
        assert meta.index_name == "claudex-memory"

    def test_schema_type_matches_projection_schema(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="claudex-memory",
            generated_at=1000,
        )
        assert isinstance(meta, ps.SearchIndexMetadata)
        assert meta.SCHEMA_TYPE == "search_index_metadata"

    def test_content_hash_is_sha256_prefixed_hex(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="claudex-memory",
            generated_at=1000,
        )
        assert meta.content_hash.startswith("sha256:")
        # hex digest length is 64.
        assert len(meta.content_hash) == len("sha256:") + 64

    def test_deterministic_across_reorder(self):
        a, b, c = self._corpus()
        m1 = mr.build_search_index_metadata(
            (a, b, c),
            index_name="idx",
            generated_at=1000,
        )
        m2 = mr.build_search_index_metadata(
            (c, b, a),
            index_name="idx",
            generated_at=1000,
        )
        assert m1.content_hash == m2.content_hash
        assert m1.document_count == m2.document_count
        assert m1.metadata.provenance == m2.metadata.provenance

    def test_provenance_is_one_ref_per_source_sorted_by_id(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="idx",
            generated_at=1000,
        )
        ids = [ref.source_id for ref in meta.metadata.provenance]
        assert ids == sorted(ids)
        assert ids == ["mem-a", "mem-b", "mem-c"]
        for ref in meta.metadata.provenance:
            assert ref.source_kind == mr.MEMORY_SOURCE_KIND
            assert ref.source_version == "v1"

    def test_source_versions_declares_memory_sources_kind(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="idx",
            generated_at=1000,
        )
        assert meta.metadata.source_versions == (
            (mr.MEMORY_SOURCE_KIND, mr.MANIFEST_VERSION),
        )

    def test_stale_condition_has_non_empty_rationale_and_watched_sets(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="idx",
            generated_at=1000,
            watched_authorities=("decision_records", "decision_records"),
            watched_files=("CLAUDE.md",),
        )
        cond = meta.metadata.stale_condition
        assert cond.rationale.strip() != ""
        assert cond.watched_authorities == ("decision_records",)
        assert cond.watched_files == ("CLAUDE.md",)

    def test_watched_authorities_and_files_are_sorted_deduped(self):
        meta = mr.build_search_index_metadata(
            self._corpus(),
            index_name="idx",
            generated_at=1000,
            watched_authorities=("zeta", "alpha", "alpha"),
            watched_files=("b.md", "a.md"),
        )
        assert meta.metadata.stale_condition.watched_authorities == (
            "alpha",
            "zeta",
        )
        assert meta.metadata.stale_condition.watched_files == ("a.md", "b.md")

    def test_body_change_flips_hash(self):
        base = mr.build_search_index_metadata(
            self._corpus(),
            index_name="idx",
            generated_at=1000,
        )
        modified_corpus = (
            _source("mem-a", title="Alpha", body="Alpha body EDITED"),
            _source("mem-b", title="Beta", body="Beta body"),
            _source("mem-c", title="Gamma", body="Gamma body"),
        )
        modified = mr.build_search_index_metadata(
            modified_corpus,
            index_name="idx",
            generated_at=1000,
        )
        assert base.content_hash != modified.content_hash

    def test_source_version_change_flips_hash(self):
        base = mr.build_search_index_metadata(
            self._corpus(),
            index_name="idx",
            generated_at=1000,
        )
        bumped_corpus = (
            _source("mem-a", title="Alpha", body="Alpha body", source_version="v2"),
            _source("mem-b", title="Beta", body="Beta body"),
            _source("mem-c", title="Gamma", body="Gamma body"),
        )
        bumped = mr.build_search_index_metadata(
            bumped_corpus,
            index_name="idx",
            generated_at=1000,
        )
        assert base.content_hash != bumped.content_hash

    def test_tags_change_flips_hash(self):
        base_corpus = (_source("mem-a"),)
        tagged_corpus = (_source("mem-a", tags=("alpha",)),)
        base = mr.build_search_index_metadata(
            base_corpus, index_name="idx", generated_at=1000
        )
        tagged = mr.build_search_index_metadata(
            tagged_corpus, index_name="idx", generated_at=1000
        )
        assert base.content_hash != tagged.content_hash

    def test_title_change_flips_hash(self):
        base = mr.build_search_index_metadata(
            (_source("mem-a", title="Alpha"),),
            index_name="idx",
            generated_at=1000,
        )
        modified = mr.build_search_index_metadata(
            (_source("mem-a", title="Alpha-Prime"),),
            index_name="idx",
            generated_at=1000,
        )
        assert base.content_hash != modified.content_hash

    def test_path_change_flips_hash(self):
        base = mr.build_search_index_metadata(
            (_source("mem-a", path="a.md"),),
            index_name="idx",
            generated_at=1000,
        )
        modified = mr.build_search_index_metadata(
            (_source("mem-a", path="a-renamed.md"),),
            index_name="idx",
            generated_at=1000,
        )
        assert base.content_hash != modified.content_hash

    def test_index_name_change_flips_hash(self):
        corpus = self._corpus()
        m1 = mr.build_search_index_metadata(
            corpus, index_name="idx-a", generated_at=1000
        )
        m2 = mr.build_search_index_metadata(
            corpus, index_name="idx-b", generated_at=1000
        )
        assert m1.content_hash != m2.content_hash

    def test_generated_at_does_not_flip_hash(self):
        # ``generated_at`` belongs to metadata but is intentionally
        # NOT part of the content manifest — the hash tracks logical
        # corpus identity, not emission time.
        corpus = self._corpus()
        m1 = mr.build_search_index_metadata(
            corpus, index_name="idx", generated_at=1000
        )
        m2 = mr.build_search_index_metadata(
            corpus, index_name="idx", generated_at=9999
        )
        assert m1.content_hash == m2.content_hash
        assert m1.metadata.generated_at != m2.metadata.generated_at

    def test_empty_corpus_is_deterministic_and_valid(self):
        meta = mr.build_search_index_metadata(
            (), index_name="idx", generated_at=0
        )
        assert meta.document_count == 0
        assert meta.metadata.provenance == ()
        # Same inputs produce byte-identical content hash.
        again = mr.build_search_index_metadata(
            [], index_name="idx", generated_at=0
        )
        assert meta.content_hash == again.content_hash


# ---------------------------------------------------------------------------
# 4. Search index — input validation
# ---------------------------------------------------------------------------


class TestSearchIndexInputValidation:
    def test_sources_must_be_list_or_tuple(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                {_source()},  # type: ignore[arg-type]
                index_name="idx",
                generated_at=0,
            )

    def test_sources_entry_must_be_memory_source(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                ({"source_id": "x"},),  # type: ignore[arg-type]
                index_name="idx",
                generated_at=0,
            )

    def test_duplicate_source_id_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (_source("mem-a"), _source("mem-a", title="Alpha-Dup")),
                index_name="idx",
                generated_at=0,
            )

    def test_empty_index_name_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (), index_name="", generated_at=0
            )

    def test_non_string_index_name_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (), index_name=42, generated_at=0  # type: ignore[arg-type]
            )

    def test_bool_generated_at_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (), index_name="idx", generated_at=True  # type: ignore[arg-type]
            )

    def test_negative_generated_at_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (), index_name="idx", generated_at=-1
            )

    def test_bare_str_watched_authorities_raises(self):
        with pytest.raises(ValueError) as exc:
            mr.build_search_index_metadata(
                (),
                index_name="idx",
                generated_at=0,
                watched_authorities="decision_records",  # type: ignore[arg-type]
            )
        assert "bare" in str(exc.value)

    def test_bare_bytes_watched_files_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (),
                index_name="idx",
                generated_at=0,
                watched_files=b"CLAUDE.md",  # type: ignore[arg-type]
            )

    def test_non_string_watched_entry_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (),
                index_name="idx",
                generated_at=0,
                watched_authorities=("ok", 42),  # type: ignore[arg-type]
            )

    def test_empty_watched_entry_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (),
                index_name="idx",
                generated_at=0,
                watched_files=("",),
            )

    def test_empty_manifest_version_raises(self):
        with pytest.raises(ValueError):
            mr.build_search_index_metadata(
                (),
                index_name="idx",
                generated_at=0,
                manifest_version="",
            )


# ---------------------------------------------------------------------------
# 5. Graph export — determinism, counts, ordering, validation
# ---------------------------------------------------------------------------


class TestGraphExport:
    def _sources(self):
        return (
            _source("a"),
            _source("b"),
            _source("c"),
        )

    def _edges(self):
        return (
            mr.GraphEdge(
                source_id="b",
                target_id="c",
                relation="cites",
                evidence_version="v1",
            ),
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="cites",
                evidence_version="v1",
            ),
        )

    def test_node_count_equals_len_sources(self):
        export = mr.build_graph_export(
            self._sources(), self._edges(), generated_at=1000
        )
        assert export.node_count == 3

    def test_edge_count_equals_len_edges(self):
        export = mr.build_graph_export(
            self._sources(), self._edges(), generated_at=1000
        )
        assert export.edge_count == 2

    def test_schema_type_matches_projection_schema(self):
        export = mr.build_graph_export(
            self._sources(), self._edges(), generated_at=1000
        )
        assert isinstance(export, ps.GraphExport)
        assert export.SCHEMA_TYPE == "graph_export"

    def test_content_hash_is_sha256_prefixed(self):
        export = mr.build_graph_export(
            self._sources(), self._edges(), generated_at=1000
        )
        assert export.content_hash.startswith("sha256:")
        assert len(export.content_hash) == len("sha256:") + 64

    def test_deterministic_across_reorder(self):
        a, b, c = self._sources()
        e1, e2 = self._edges()
        x = mr.build_graph_export(
            (a, b, c), (e1, e2), generated_at=1000
        )
        y = mr.build_graph_export(
            (c, a, b), (e2, e1), generated_at=1000
        )
        assert x.content_hash == y.content_hash
        assert x.node_count == y.node_count
        assert x.edge_count == y.edge_count
        assert x.metadata.provenance == y.metadata.provenance

    def test_provenance_includes_sources_then_edges(self):
        export = mr.build_graph_export(
            self._sources(), self._edges(), generated_at=1000
        )
        provenance = export.metadata.provenance
        # Sources come first, sorted by id.
        source_refs = [
            r for r in provenance if r.source_kind == mr.MEMORY_SOURCE_KIND
        ]
        edge_refs = [
            r for r in provenance if r.source_kind == mr.GRAPH_EDGE_KIND
        ]
        assert [r.source_id for r in source_refs] == ["a", "b", "c"]
        # Edge refs use composite ids.
        edge_ids = sorted(r.source_id for r in edge_refs)
        assert edge_ids == ["a->b:cites", "b->c:cites"]
        # Provenance layout: all source refs before any edge refs.
        kinds_in_order = [r.source_kind for r in provenance]
        first_edge_index = kinds_in_order.index(mr.GRAPH_EDGE_KIND)
        assert all(
            k == mr.MEMORY_SOURCE_KIND for k in kinds_in_order[:first_edge_index]
        )

    def test_source_versions_declares_both_kinds(self):
        export = mr.build_graph_export(
            self._sources(), self._edges(), generated_at=1000
        )
        kinds = {k for k, _ in export.metadata.source_versions}
        assert kinds == {mr.MEMORY_SOURCE_KIND, mr.GRAPH_EDGE_KIND}

    def test_unknown_source_endpoint_raises(self):
        edges = (
            mr.GraphEdge(
                source_id="ghost",
                target_id="a",
                relation="cites",
                evidence_version="v1",
            ),
        )
        with pytest.raises(ValueError):
            mr.build_graph_export(
                self._sources(), edges, generated_at=1000
            )

    def test_unknown_target_endpoint_raises(self):
        edges = (
            mr.GraphEdge(
                source_id="a",
                target_id="ghost",
                relation="cites",
                evidence_version="v1",
            ),
        )
        with pytest.raises(ValueError):
            mr.build_graph_export(
                self._sources(), edges, generated_at=1000
            )

    def test_duplicate_edge_triple_raises(self):
        edges = (
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="cites",
                evidence_version="v1",
            ),
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="cites",
                evidence_version="v2",
            ),
        )
        with pytest.raises(ValueError):
            mr.build_graph_export(
                self._sources(), edges, generated_at=1000
            )

    def test_different_relation_between_same_pair_is_legal(self):
        edges = (
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="cites",
                evidence_version="v1",
            ),
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="supersedes",
                evidence_version="v1",
            ),
        )
        export = mr.build_graph_export(
            self._sources(), edges, generated_at=1000
        )
        assert export.edge_count == 2

    def test_evidence_version_change_flips_hash(self):
        edges = self._edges()
        bumped = (
            mr.GraphEdge(
                source_id=edges[0].source_id,
                target_id=edges[0].target_id,
                relation=edges[0].relation,
                evidence_version="v-next",
            ),
            edges[1],
        )
        base = mr.build_graph_export(
            self._sources(), edges, generated_at=1000
        )
        shifted = mr.build_graph_export(
            self._sources(), bumped, generated_at=1000
        )
        assert base.content_hash != shifted.content_hash

    def test_relation_change_flips_hash(self):
        edges = (
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="cites",
                evidence_version="v1",
            ),
        )
        alt = (
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="supersedes",
                evidence_version="v1",
            ),
        )
        x = mr.build_graph_export(self._sources(), edges, generated_at=1000)
        y = mr.build_graph_export(self._sources(), alt, generated_at=1000)
        assert x.content_hash != y.content_hash

    def test_empty_edges_is_valid(self):
        export = mr.build_graph_export(
            self._sources(), (), generated_at=1000
        )
        assert export.edge_count == 0
        assert export.node_count == 3

    def test_empty_corpus_and_empty_edges_is_deterministic(self):
        x = mr.build_graph_export((), (), generated_at=0)
        y = mr.build_graph_export((), [], generated_at=0)
        assert x.node_count == 0
        assert x.edge_count == 0
        assert x.content_hash == y.content_hash

    def test_sources_must_be_list_or_tuple(self):
        with pytest.raises(ValueError):
            mr.build_graph_export(
                {_source("a")},  # type: ignore[arg-type]
                (),
                generated_at=0,
            )

    def test_edges_must_be_list_or_tuple(self):
        with pytest.raises(ValueError):
            mr.build_graph_export(
                self._sources(),
                iter(()),  # type: ignore[arg-type]
                generated_at=0,
            )

    def test_edge_entry_must_be_graph_edge(self):
        with pytest.raises(ValueError):
            mr.build_graph_export(
                self._sources(),
                ({"source_id": "a"},),  # type: ignore[arg-type]
                generated_at=0,
            )

    def test_bare_str_watched_authorities_raises(self):
        with pytest.raises(ValueError):
            mr.build_graph_export(
                (),
                (),
                generated_at=0,
                watched_authorities="memory_sources",  # type: ignore[arg-type]
            )

    def test_duplicate_source_id_raises(self):
        with pytest.raises(ValueError):
            mr.build_graph_export(
                (_source("a"), _source("a", title="A-dup")),
                (),
                generated_at=0,
            )


# ---------------------------------------------------------------------------
# 6. Manifest renderers — direct JSON shape pins
# ---------------------------------------------------------------------------


class TestManifestRenderers:
    def test_search_index_manifest_is_sorted_keys_json(self):
        payload = mr.render_search_index_manifest(
            (_source("b"), _source("a")),
            index_name="idx",
        )
        parsed = json.loads(payload)
        assert parsed["document_count"] == 2
        assert [d["source_id"] for d in parsed["documents"]] == ["a", "b"]
        assert parsed["index_name"] == "idx"
        assert parsed["generator_version"] == mr.MEMORY_RETRIEVAL_GENERATOR_VERSION

    def test_graph_export_manifest_is_sorted_keys_json(self):
        sources = (_source("a"), _source("b"))
        edges = (
            mr.GraphEdge(
                source_id="b",
                target_id="a",
                relation="cites",
                evidence_version="v1",
            ),
            mr.GraphEdge(
                source_id="a",
                target_id="b",
                relation="cites",
                evidence_version="v1",
            ),
        )
        payload = mr.render_graph_export_manifest(sources, edges)
        parsed = json.loads(payload)
        assert parsed["node_count"] == 2
        assert parsed["edge_count"] == 2
        # Edges are sorted by (source_id, target_id, relation, evidence_version).
        edge_keys = [
            (e["source_id"], e["target_id"], e["relation"]) for e in parsed["edges"]
        ]
        assert edge_keys == sorted(edge_keys)

    def test_manifest_renderers_are_deterministic(self):
        sources = (_source("a"), _source("b"))
        m1 = mr.render_search_index_manifest(sources, index_name="idx")
        m2 = mr.render_search_index_manifest(
            list(reversed(sources)), index_name="idx"
        )
        assert m1 == m2


# ---------------------------------------------------------------------------
# 7. Integration with projection_reflow.plan_projection_reflow
# ---------------------------------------------------------------------------


class TestReflowIntegration:
    def _search_projection(self):
        return mr.build_search_index_metadata(
            (_source("a"),),
            index_name="idx",
            generated_at=1000,
            watched_authorities=("decision_records",),
            watched_files=("CLAUDE.md",),
        )

    def _graph_projection(self):
        return mr.build_graph_export(
            (_source("a"), _source("b")),
            (
                mr.GraphEdge(
                    source_id="a",
                    target_id="b",
                    relation="cites",
                    evidence_version="v1",
                ),
            ),
            generated_at=1000,
            watched_authorities=("memory_sources",),
            watched_files=("notes/alpha.md",),
        )

    def test_search_index_is_fresh_when_no_change_overlaps(self):
        proj = self._search_projection()
        assessment = pr.assess_projection_freshness(
            "search-1",
            proj,
            changed_authorities=("unrelated",),
            changed_files=("README.md",),
        )
        assert assessment.status == pr.REFLOW_STATUS_FRESH
        assert assessment.healthy is True
        assert assessment.schema_type == "search_index_metadata"

    def test_search_index_is_stale_when_watched_authority_changes(self):
        proj = self._search_projection()
        assessment = pr.assess_projection_freshness(
            "search-1",
            proj,
            changed_authorities=("decision_records",),
            changed_files=(),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_authorities == ("decision_records",)

    def test_search_index_is_stale_when_watched_file_changes(self):
        proj = self._search_projection()
        assessment = pr.assess_projection_freshness(
            "search-1",
            proj,
            changed_authorities=(),
            changed_files=("CLAUDE.md",),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_files == ("CLAUDE.md",)

    def test_graph_export_is_stale_when_watched_file_changes(self):
        proj = self._graph_projection()
        assessment = pr.assess_projection_freshness(
            "graph-1",
            proj,
            changed_authorities=(),
            changed_files=("notes/alpha.md",),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_files == ("notes/alpha.md",)
        assert assessment.schema_type == "graph_export"

    def test_batch_plan_over_search_and_graph_is_fresh_with_no_overlap(self):
        plan = pr.plan_projection_reflow(
            [
                ("search-1", self._search_projection()),
                ("graph-1", self._graph_projection()),
            ],
            changed_authorities=("unrelated",),
            changed_files=("README.md",),
        )
        assert plan.fresh_count == 2
        assert plan.stale_count == 0
        assert plan.affected_projection_ids() == ()

    def test_batch_plan_marks_both_stale_when_watched_authority_matches(self):
        plan = pr.plan_projection_reflow(
            [
                ("search-1", self._search_projection()),
                ("graph-1", self._graph_projection()),
            ],
            changed_authorities=("decision_records", "memory_sources"),
            changed_files=(),
        )
        assert plan.stale_count == 2
        assert plan.fresh_count == 0
        assert set(plan.affected_projection_ids()) == {"search-1", "graph-1"}


# ---------------------------------------------------------------------------
# 8. Module surface
# ---------------------------------------------------------------------------


class TestModuleSurface:
    def test_all_exports_match_expected_surface(self):
        assert set(mr.__all__) == {
            "MEMORY_RETRIEVAL_GENERATOR_VERSION",
            "MANIFEST_VERSION",
            "MEMORY_SOURCE_KIND",
            "GRAPH_EDGE_KIND",
            "MemorySource",
            "GraphEdge",
            "render_search_index_manifest",
            "render_graph_export_manifest",
            "build_search_index_metadata",
            "build_graph_export",
        }

    def test_generator_version_is_non_empty_string(self):
        assert isinstance(mr.MEMORY_RETRIEVAL_GENERATOR_VERSION, str)
        assert mr.MEMORY_RETRIEVAL_GENERATOR_VERSION

    def test_memory_source_kind_and_graph_edge_kind_differ(self):
        assert mr.MEMORY_SOURCE_KIND != mr.GRAPH_EDGE_KIND


# ---------------------------------------------------------------------------
# 9. Shadow-only discipline (AST inspection)
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_memory_retrieval_does_not_import_live_modules(self):
        imported = _imported_module_names(mr)
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
            "decision_work_registry",
            "decision_digest_projection",
            "hook_manifest",
            "hook_doc_projection",
            "hook_doc_validation",
            "prompt_pack",
            "prompt_pack_resolver",
            "prompt_pack_validation",
            "stage_registry",
            "authority_registry",
            "constitution_registry",
            "projection_reflow",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"memory_retrieval.py imports {name!r} which contains "
                    f"forbidden token {needle!r}"
                )

    def test_memory_retrieval_only_depends_on_projection_schemas(self):
        imported = _imported_module_names(mr)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        allowed_prefix = "runtime.core.projection_schemas"
        for name in runtime_core_imports:
            assert name.startswith(allowed_prefix), (
                f"memory_retrieval.py imports unexpected runtime.core "
                f"module {name!r}"
            )

    def test_memory_retrieval_has_no_filesystem_or_process_imports(self):
        imported = _imported_module_names(mr)
        forbidden = (
            "subprocess",
            "sqlite3",
            "os.path",
            "pathlib",
            "shutil",
        )
        for name in imported:
            for needle in forbidden:
                assert needle not in name, (
                    f"memory_retrieval.py imports {name!r} which contains "
                    f"forbidden side-effect token {needle!r}"
                )

    def test_core_routing_modules_do_not_import_memory_retrieval(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "memory_retrieval" not in name, (
                    f"{mod.__name__} imports {name!r} — memory_retrieval "
                    f"must stay shadow-only in Slice 17"
                )

    def test_cli_does_not_import_memory_retrieval(self):
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        for name in imported:
            assert "memory_retrieval" not in name, (
                f"runtime/cli.py imports {name!r} — memory_retrieval has "
                f"no CLI adapter in Slice 17"
            )

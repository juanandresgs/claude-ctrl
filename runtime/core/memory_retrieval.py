"""Pure memory/retrieval projection compiler (shadow-only).

@decision DEC-CLAUDEX-MEMORY-RETRIEVAL-001
Title: runtime/core/memory_retrieval.py is the sole runtime authority that compiles deterministic search-index and graph-export projections from caller-supplied canonical memory/source records
Status: proposed (shadow-mode, Phase 7 Slice 17 memory/retrieval compiler)
Rationale: CUTOVER_PLAN §Canonical Memory with Derived Retrieval +
  §Constitution-Level Files name a planned
  ``memory_retrieval_compiler_modules`` area. This slice delivers
  that authority as a pure, minimal projection compiler: given a
  caller-supplied sequence of canonical :class:`MemorySource`
  records (and optional :class:`GraphEdge` records), it compiles
  typed :class:`SearchIndexMetadata` and :class:`GraphExport`
  projections whose metadata, provenance, and content hash make
  staleness mechanically checkable by
  :mod:`runtime.core.projection_reflow`.

  Scope discipline (pinned by tests):

    * **Pure.** No filesystem I/O, no ``open()``, no DB access, no
      subprocess, no CLI wiring, no daemon, no scheduler, no live
      routing/policy/hook imports. Callers supply memory sources
      and edges explicitly — the compiler never scans the repo,
      never opens a markdown file, and never reaches a vector DB
      or search engine.
    * **Single memory authority.** CUTOVER_PLAN is explicit that
      retrieval and graph layers are derived read models, never
      canonical truth. This module reinforces that by refusing to
      *be* the memory store: canonical source identity stays with
      the caller (a future slice may wire a SQLite-backed memory
      registry; it will thread records through this compiler, not
      replace it).
    * **Deterministic.** For the same
      ``(sources, edges, index_name, generated_at,
      watched_authorities, watched_files, manifest_version)``
      inputs, both compilers produce byte-identical
      ``SearchIndexMetadata`` / ``GraphExport`` records — including
      ``content_hash``, ``source_versions`` ordering, and
      ``provenance`` ordering. Iteration order of caller inputs
      never leaks into output bytes.
    * **Declarative staleness.** ``watched_authorities`` and
      ``watched_files`` are caller-supplied and normalised
      deterministically (sorted, deduplicated, non-empty strings).
      The compiler does not infer staleness from filesystem state;
      it merely records the declarative predicate callers want the
      reflow planner to evaluate later.
    * **No second authority.** :mod:`runtime.core.projection_schemas`
      already owns the typed :class:`SearchIndexMetadata` /
      :class:`GraphExport` / :class:`ProjectionMetadata` /
      :class:`SourceRef` / :class:`StaleCondition` shapes; this
      module builds those shapes, never re-defines them. Tests pin
      that the built records round-trip through
      :func:`runtime.core.projection_reflow.plan_projection_reflow`
      as ordinary projections.

  Hashing rule (pinned by tests):

    The manifest renderer (:func:`render_search_index_manifest` /
    :func:`render_graph_export_manifest`) produces a canonical
    UTF-8 string encoding of the compiled corpus. ``content_hash``
    is ``sha256:<hex>`` of those bytes. Hash equality is a strict
    content-plus-order invariant: changing any
    ``source_id`` / ``source_kind`` / ``source_version`` /
    ``path`` / ``title`` / ``body`` / ``tags`` of any source — or
    any ``source_id`` / ``target_id`` / ``relation`` /
    ``evidence_version`` of any edge — flips the hash. Re-ordering
    the caller's input does not (the compiler re-sorts
    internally).

  Public contract:

    * :class:`MemorySource` — frozen dataclass for a single
      canonical memory/source record. Fields: ``source_id``,
      ``source_kind``, ``source_version``, ``path``, ``title``,
      ``body``, ``tags`` (tuple of non-empty strings). Tags are
      deduplicated at construction time (duplicates raise
      :class:`ValueError`).
    * :class:`GraphEdge` — frozen dataclass for a typed relation
      between two source ids. Fields: ``source_id``,
      ``target_id``, ``relation``, ``evidence_version``.
    * :func:`render_search_index_manifest` /
      :func:`render_graph_export_manifest` — pure helpers that
      render deterministic canonical manifests (JSON-shaped
      strings) for hashing and test-shape pins.
    * :func:`build_search_index_metadata` —
      ``(sources, *, index_name, generated_at, watched_authorities,
      watched_files, manifest_version) -> SearchIndexMetadata``.
    * :func:`build_graph_export` —
      ``(sources, edges, *, generated_at, watched_authorities,
      watched_files, manifest_version) -> GraphExport``.

  What this module deliberately does NOT do:

    * It does not run a full-text search, embedding, or graph
      database — those are live retrieval engines outside the
      cutover scope.
    * It does not perform schema migration on :class:`MemorySource`
      or :class:`GraphEdge`; a future slice that adds/removes
      fields must bump :data:`MEMORY_RETRIEVAL_GENERATOR_VERSION`
      and refresh the hash-stability tests in the same bundle.
    * It does not reach
      :mod:`runtime.core.decision_work_registry`,
      :mod:`runtime.core.decision_digest_projection`, or any other
      authority module. Memory sources are a distinct input family
      from decisions; any future cross-projection link would live
      in a separate slice with explicit scope.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Iterable, List, Mapping, Sequence, Tuple

from runtime.core.projection_schemas import (
    GraphExport,
    ProjectionMetadata,
    SearchIndexMetadata,
    SourceRef,
    StaleCondition,
)

# ---------------------------------------------------------------------------
# Version constants
# ---------------------------------------------------------------------------

#: Version of this compiler. Bumping it is a deliberate change to the
#: output format and must be accompanied by matching hash-stability
#: test updates so byte-equal baselines are refreshed.
MEMORY_RETRIEVAL_GENERATOR_VERSION: str = "1.0.0"

#: Default manifest version stamped into ``ProjectionMetadata``'s
#: ``source_versions`` tuple. A future slice that introduces a
#: registry-level memory schema version will bump this.
MANIFEST_VERSION: str = "1.0.0"

#: Canonical ``source_kind`` vocabulary for memory sources fed through
#: this compiler. Mirrors the naming used elsewhere in the projection
#: family (``decision_records``, ``hook_wiring``, …).
MEMORY_SOURCE_KIND: str = "memory_sources"

#: Canonical ``source_kind`` vocabulary for graph edges.
GRAPH_EDGE_KIND: str = "graph_edges"


# ---------------------------------------------------------------------------
# Input shapes
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class MemorySource:
    """A single caller-supplied canonical memory / retrieval source record.

    ``source_id`` is the caller's canonical identifier (opaque to this
    module). ``source_kind`` is the authority vocabulary the record
    belongs to (e.g. ``"memory_document"``, ``"workflow_note"``);
    tests do not pin a closed vocabulary for it. ``source_version``
    is the version string or content hash the caller wants recorded
    as provenance so the reflow planner can detect upstream
    staleness.

    ``path`` is the caller-supplied locator (e.g. a repo-relative
    path, a doc-id URI, or any stable string). It is part of the
    manifest payload so changing it flips ``content_hash``.

    ``title`` and ``body`` are the searchable fields. Both are
    incorporated into the manifest verbatim; editing either
    produces a new content hash so a reflow consumer can force
    regeneration.

    ``tags`` is an unordered label set expressed as a tuple of
    non-empty strings. Validation runs in two passes: first the
    entries are checked to be non-empty strings and duplicates are
    rejected, then the tuple is canonicalised to ascending sorted
    order and stored back on the frozen instance via
    ``object.__setattr__``. This means two callers that pass the
    same label set in different orders produce byte-identical
    ``MemorySource`` records (and therefore byte-identical
    ``SearchIndexMetadata`` / ``GraphExport`` content hashes). The
    duplicate-rejection rule remains: silent dedupe would mask
    caller bugs, and sorting alone is not enough to absorb
    duplicates without losing information.
    """

    source_id: str
    source_kind: str
    source_version: str
    path: str
    title: str
    body: str
    tags: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        for attr in (
            "source_id",
            "source_kind",
            "source_version",
            "path",
            "title",
        ):
            value = getattr(self, attr)
            if not isinstance(value, str) or not value:
                raise ValueError(
                    f"MemorySource.{attr} must be a non-empty string; "
                    f"got {value!r}"
                )
        # ``body`` is allowed to be empty (an empty-body note is a
        # legitimate canonical record) but must still be a str so
        # downstream hashing is well-defined.
        if not isinstance(self.body, str):
            raise ValueError(
                f"MemorySource.body must be a str; got {type(self.body).__name__}"
            )
        if not isinstance(self.tags, tuple):
            raise ValueError(
                f"MemorySource.tags must be a tuple; got {type(self.tags).__name__}"
            )
        seen: set[str] = set()
        for tag in self.tags:
            if not isinstance(tag, str) or not tag:
                raise ValueError(
                    f"MemorySource.tags entries must be non-empty strings; "
                    f"got {tag!r}"
                )
            if tag in seen:
                raise ValueError(
                    f"MemorySource.tags contains duplicate {tag!r}; each tag "
                    f"may appear at most once"
                )
            seen.add(tag)
        # Canonicalise tags to sorted order so caller iteration order
        # cannot leak into the search-index / graph-export content
        # hash. ``object.__setattr__`` is the standard escape hatch
        # for mutating a field inside ``__post_init__`` on a frozen
        # dataclass.
        canonical_tags = tuple(sorted(self.tags))
        if canonical_tags != self.tags:
            object.__setattr__(self, "tags", canonical_tags)


@dataclass(frozen=True)
class GraphEdge:
    """A typed relation between two :class:`MemorySource` records.

    ``source_id`` and ``target_id`` reference the ``source_id``
    values on :class:`MemorySource` records passed alongside the
    edge into :func:`build_graph_export`. The graph compiler
    validates that both endpoints resolve; unknown endpoints raise
    :class:`ValueError`.

    ``relation`` is a free-form vocabulary string (e.g.
    ``"cites"``, ``"supersedes"``). Tests do not pin a closed set
    — callers declare the vocabulary they need.

    ``evidence_version`` is the version/hash of the evidence that
    justifies the edge (e.g. a commit SHA, a decision version).
    """

    source_id: str
    target_id: str
    relation: str
    evidence_version: str

    def __post_init__(self) -> None:
        for attr in ("source_id", "target_id", "relation", "evidence_version"):
            value = getattr(self, attr)
            if not isinstance(value, str) or not value:
                raise ValueError(
                    f"GraphEdge.{attr} must be a non-empty string; got {value!r}"
                )
        if self.source_id == self.target_id:
            raise ValueError(
                f"GraphEdge source_id and target_id must differ; "
                f"got self-loop on {self.source_id!r}"
            )


# ---------------------------------------------------------------------------
# Hash + normalisation helpers
# ---------------------------------------------------------------------------


def _hash_content(content: str) -> str:
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def _normalise_watched(
    items: Iterable[str], *, label: str
) -> Tuple[str, ...]:
    """Deduplicate, validate, and sort a caller-supplied watch set.

    Rejects a top-level ``str`` / ``bytes`` / ``bytearray`` /
    ``memoryview`` for the same reason
    :func:`runtime.core.projection_reflow._normalise_change_set`
    does: those types are iterable over characters and would
    silently produce a false-match surface.
    """
    if items is None:
        raise ValueError(f"{label} must be an iterable of non-empty strings, got None")
    if isinstance(items, (str, bytes, bytearray, memoryview)):
        raise ValueError(
            f"{label} must be an iterable collection of non-empty strings, "
            f"not a bare {type(items).__name__}. Wrap the value in a "
            f"tuple/list (e.g. ('CLAUDE.md',)) or pass an empty collection."
        )
    try:
        iterator = iter(items)
    except TypeError as exc:  # pragma: no cover - defensive
        raise ValueError(
            f"{label} must be an iterable of non-empty strings; "
            f"got {type(items).__name__}"
        ) from exc
    seen: set[str] = set()
    for item in iterator:
        if not isinstance(item, str) or not item:
            raise ValueError(
                f"{label} entries must be non-empty strings; got {item!r}"
            )
        seen.add(item)
    return tuple(sorted(seen))


def _validate_sources_input(
    sources: Sequence[MemorySource],
) -> Tuple[MemorySource, ...]:
    """Reject malformed inputs and return the ordered tuple.

    Ordering: ascending ``source_id``. Duplicate ids are rejected so
    the manifest's source list never contains two entries for the
    same canonical identifier (that would be a caller bug; silent
    merge would hide it).
    """
    if not isinstance(sources, (list, tuple)):
        raise ValueError(
            f"sources must be a list or tuple of MemorySource; "
            f"got {type(sources).__name__}"
        )
    seen: set[str] = set()
    for rec in sources:
        if not isinstance(rec, MemorySource):
            raise ValueError(
                f"sources entries must be MemorySource; "
                f"got {type(rec).__name__}"
            )
        if rec.source_id in seen:
            raise ValueError(
                f"sources contains duplicate source_id {rec.source_id!r}; "
                f"each source may appear at most once"
            )
        seen.add(rec.source_id)
    return tuple(sorted(sources, key=lambda s: s.source_id))


def _validate_edges_input(
    edges: Sequence[GraphEdge],
    known_source_ids: frozenset[str],
) -> Tuple[GraphEdge, ...]:
    """Reject unknown endpoints / duplicate directed edges and return ordered.

    Duplicate (source_id, target_id, relation) triples are rejected
    rather than silently deduped — two edges with the same triple
    but different ``evidence_version`` is a caller bug; two
    identical edges is redundant caller input; both should fail
    loudly. Edges with different ``relation`` values between the
    same pair remain legal.
    """
    if not isinstance(edges, (list, tuple)):
        raise ValueError(
            f"edges must be a list or tuple of GraphEdge; "
            f"got {type(edges).__name__}"
        )
    seen: set[Tuple[str, str, str]] = set()
    for edge in edges:
        if not isinstance(edge, GraphEdge):
            raise ValueError(
                f"edges entries must be GraphEdge; got {type(edge).__name__}"
            )
        if edge.source_id not in known_source_ids:
            raise ValueError(
                f"GraphEdge.source_id {edge.source_id!r} is not a known "
                f"source in the supplied corpus"
            )
        if edge.target_id not in known_source_ids:
            raise ValueError(
                f"GraphEdge.target_id {edge.target_id!r} is not a known "
                f"source in the supplied corpus"
            )
        triple = (edge.source_id, edge.target_id, edge.relation)
        if triple in seen:
            raise ValueError(
                f"edges contains duplicate (source_id, target_id, relation) "
                f"triple {triple!r}; each directed relation may appear at "
                f"most once"
            )
        seen.add(triple)
    return tuple(
        sorted(
            edges,
            key=lambda e: (e.source_id, e.target_id, e.relation, e.evidence_version),
        )
    )


def _validate_positive_non_empty(value: object, *, label: str) -> None:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a non-empty string; got {value!r}")


def _validate_generated_at(generated_at: int) -> None:
    if isinstance(generated_at, bool) or not isinstance(generated_at, int):
        raise ValueError(
            f"generated_at must be an int (unix epoch seconds); "
            f"got {type(generated_at).__name__}"
        )
    if generated_at < 0:
        raise ValueError("generated_at must be non-negative")


# ---------------------------------------------------------------------------
# Manifest renderers
# ---------------------------------------------------------------------------


def _source_manifest_entry(source: MemorySource) -> Mapping[str, object]:
    """Canonical JSON-serialisable view of a single source for hashing."""
    return {
        "source_id": source.source_id,
        "source_kind": source.source_kind,
        "source_version": source.source_version,
        "path": source.path,
        "title": source.title,
        "body": source.body,
        "tags": list(source.tags),
    }


def _edge_manifest_entry(edge: GraphEdge) -> Mapping[str, object]:
    return {
        "source_id": edge.source_id,
        "target_id": edge.target_id,
        "relation": edge.relation,
        "evidence_version": edge.evidence_version,
    }


def render_search_index_manifest(
    sources: Sequence[MemorySource],
    *,
    index_name: str,
    manifest_version: str = MANIFEST_VERSION,
) -> str:
    """Return a deterministic JSON manifest string for ``sources``.

    Ordering: sources sorted ascending by ``source_id``. Each source
    is emitted via :func:`_source_manifest_entry` so the manifest
    encodes exactly the fields that flip the content hash. The
    returned string is pure-ASCII-safe JSON with sorted keys and no
    platform-dependent whitespace.
    """
    _validate_positive_non_empty(index_name, label="index_name")
    _validate_positive_non_empty(manifest_version, label="manifest_version")
    ordered = _validate_sources_input(sources)
    payload = {
        "generator_version": MEMORY_RETRIEVAL_GENERATOR_VERSION,
        "manifest_version": manifest_version,
        "index_name": index_name,
        "document_count": len(ordered),
        "documents": [_source_manifest_entry(s) for s in ordered],
    }
    return json.dumps(payload, sort_keys=True, ensure_ascii=False, indent=None)


def render_graph_export_manifest(
    sources: Sequence[MemorySource],
    edges: Sequence[GraphEdge],
    *,
    manifest_version: str = MANIFEST_VERSION,
) -> str:
    """Return a deterministic JSON manifest string for the graph export.

    Nodes are sorted ascending by ``source_id``; edges are sorted
    by ``(source_id, target_id, relation, evidence_version)``. The
    manifest carries the full node/edge payloads so any change to
    a source or edge field flips the content hash.
    """
    _validate_positive_non_empty(manifest_version, label="manifest_version")
    ordered_sources = _validate_sources_input(sources)
    known_ids = frozenset(s.source_id for s in ordered_sources)
    ordered_edges = _validate_edges_input(edges, known_ids)
    payload = {
        "generator_version": MEMORY_RETRIEVAL_GENERATOR_VERSION,
        "manifest_version": manifest_version,
        "node_count": len(ordered_sources),
        "edge_count": len(ordered_edges),
        "nodes": [_source_manifest_entry(s) for s in ordered_sources],
        "edges": [_edge_manifest_entry(e) for e in ordered_edges],
    }
    return json.dumps(payload, sort_keys=True, ensure_ascii=False, indent=None)


# ---------------------------------------------------------------------------
# Provenance + staleness helpers
# ---------------------------------------------------------------------------


def _source_provenance(
    ordered_sources: Tuple[MemorySource, ...],
) -> Tuple[SourceRef, ...]:
    refs: List[SourceRef] = []
    for rec in ordered_sources:
        refs.append(
            SourceRef(
                source_kind=MEMORY_SOURCE_KIND,
                source_id=rec.source_id,
                source_version=rec.source_version,
            )
        )
    return tuple(refs)


def _edge_provenance(
    ordered_edges: Tuple[GraphEdge, ...],
) -> Tuple[SourceRef, ...]:
    refs: List[SourceRef] = []
    for edge in ordered_edges:
        refs.append(
            SourceRef(
                source_kind=GRAPH_EDGE_KIND,
                source_id=f"{edge.source_id}->{edge.target_id}:{edge.relation}",
                source_version=edge.evidence_version,
            )
        )
    return tuple(refs)


def _stale_condition(
    rationale: str,
    watched_authorities: Tuple[str, ...],
    watched_files: Tuple[str, ...],
) -> StaleCondition:
    return StaleCondition(
        rationale=rationale,
        watched_authorities=watched_authorities,
        watched_files=watched_files,
    )


# ---------------------------------------------------------------------------
# Projection builders
# ---------------------------------------------------------------------------


def build_search_index_metadata(
    sources: Sequence[MemorySource],
    *,
    index_name: str,
    generated_at: int,
    watched_authorities: Iterable[str] = (),
    watched_files: Iterable[str] = (),
    manifest_version: str = MANIFEST_VERSION,
) -> SearchIndexMetadata:
    """Compile a :class:`SearchIndexMetadata` from a supplied corpus.

    ``index_name`` is a caller-chosen identifier for the search
    index and is part of the hashed manifest (two indexes that
    differ only in name produce different hashes).

    ``watched_authorities`` / ``watched_files`` are caller-supplied
    declarative staleness inputs. They are normalised here
    (sorted, deduplicated, non-empty strings; no bare ``str``) and
    written into :attr:`ProjectionMetadata.stale_condition`. The
    reflow planner
    (:func:`runtime.core.projection_reflow.plan_projection_reflow`)
    reads exactly these fields.

    Deterministic: two calls with the same inputs produce
    byte-identical :class:`SearchIndexMetadata` records.
    """
    _validate_positive_non_empty(index_name, label="index_name")
    _validate_positive_non_empty(manifest_version, label="manifest_version")
    _validate_generated_at(generated_at)
    ordered = _validate_sources_input(sources)
    normalised_authorities = _normalise_watched(
        watched_authorities, label="watched_authorities"
    )
    normalised_files = _normalise_watched(
        watched_files, label="watched_files"
    )

    manifest = render_search_index_manifest(
        ordered,
        index_name=index_name,
        manifest_version=manifest_version,
    )
    content_hash = _hash_content(manifest)

    provenance = _source_provenance(ordered)
    stale_condition = _stale_condition(
        rationale=(
            "Regenerate the search-index projection when any canonical "
            "memory source changes, or when the caller-declared "
            "authorities or files listed below change."
        ),
        watched_authorities=normalised_authorities,
        watched_files=normalised_files,
    )

    metadata = ProjectionMetadata(
        generator_version=MEMORY_RETRIEVAL_GENERATOR_VERSION,
        generated_at=generated_at,
        stale_condition=stale_condition,
        source_versions=((MEMORY_SOURCE_KIND, manifest_version),),
        provenance=provenance,
    )

    return SearchIndexMetadata(
        metadata=metadata,
        index_name=index_name,
        document_count=len(ordered),
        content_hash=content_hash,
    )


def build_graph_export(
    sources: Sequence[MemorySource],
    edges: Sequence[GraphEdge],
    *,
    generated_at: int,
    watched_authorities: Iterable[str] = (),
    watched_files: Iterable[str] = (),
    manifest_version: str = MANIFEST_VERSION,
) -> GraphExport:
    """Compile a :class:`GraphExport` from a supplied corpus + edges.

    Unknown edge endpoints raise :class:`ValueError` at manifest
    render time — the compiler refuses to emit a graph whose
    integrity references the caller cannot resolve.

    Duplicate directed edges (same ``source_id``, ``target_id``,
    ``relation`` triple) are rejected rather than silently deduped
    so caller bugs fail loudly. Edges between the same pair with
    *different* ``relation`` values remain legal.
    """
    _validate_positive_non_empty(manifest_version, label="manifest_version")
    _validate_generated_at(generated_at)
    normalised_authorities = _normalise_watched(
        watched_authorities, label="watched_authorities"
    )
    normalised_files = _normalise_watched(
        watched_files, label="watched_files"
    )

    ordered_sources = _validate_sources_input(sources)
    known_ids = frozenset(s.source_id for s in ordered_sources)
    ordered_edges = _validate_edges_input(edges, known_ids)

    manifest = render_graph_export_manifest(
        ordered_sources, ordered_edges, manifest_version=manifest_version
    )
    content_hash = _hash_content(manifest)

    provenance = _source_provenance(ordered_sources) + _edge_provenance(ordered_edges)
    stale_condition = _stale_condition(
        rationale=(
            "Regenerate the graph-export projection when any canonical "
            "memory source or graph edge changes, or when the "
            "caller-declared authorities or files listed below change."
        ),
        watched_authorities=normalised_authorities,
        watched_files=normalised_files,
    )

    metadata = ProjectionMetadata(
        generator_version=MEMORY_RETRIEVAL_GENERATOR_VERSION,
        generated_at=generated_at,
        stale_condition=stale_condition,
        source_versions=(
            (MEMORY_SOURCE_KIND, manifest_version),
            (GRAPH_EDGE_KIND, manifest_version),
        ),
        provenance=provenance,
    )

    return GraphExport(
        metadata=metadata,
        node_count=len(ordered_sources),
        edge_count=len(ordered_edges),
        content_hash=content_hash,
    )


__all__ = [
    # Version constants
    "MEMORY_RETRIEVAL_GENERATOR_VERSION",
    "MANIFEST_VERSION",
    "MEMORY_SOURCE_KIND",
    "GRAPH_EDGE_KIND",
    # Input shapes
    "MemorySource",
    "GraphEdge",
    # Renderers
    "render_search_index_manifest",
    "render_graph_export_manifest",
    # Compilers
    "build_search_index_metadata",
    "build_graph_export",
]

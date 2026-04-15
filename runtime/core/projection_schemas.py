"""ClauDEX projection schema family (shadow-only).

@decision DEC-CLAUDEX-PROJECTION-SCHEMAS-001
Title: runtime/core/projection_schemas.py is the sole declarative schema family for derived ClauDEX artifacts
Status: proposed (shadow-mode, Phase 1 constitutional kernel)
Rationale: CUTOVER_PLAN §Schema Contract Stack identifies three schema
  families that must exist before later cutover slices can depend on
  them: state, interaction, and projection. The state family is
  covered by ``runtime/core/contracts.py`` (GoalContract,
  WorkItemContract, ScopeManifest, EvaluationContract). This module
  delivers the **projection** family — the typed shapes of derived
  artifacts such as prompt packs, rendered ``MASTER_PLAN.md``,
  decision digests, hook-doc projections, graph exports, and
  search-index metadata.

  CUTOVER_PLAN §Schema Contract Stack §3 lines 933-939 require every
  projection schema to carry:

      * generator version
      * source versions or hashes
      * generated timestamp
      * stale condition
      * provenance links to upstream records

  This module encodes all five as fields on the shared
  ``ProjectionMetadata`` dataclass. Every concrete projection type
  composes that metadata with its own type-specific fields so the
  required-field set cannot drift per-projection.

  Scope discipline:

    * This module is **purely declarative**. It does not generate any
      projection, does not read any upstream source, does not enforce
      staleness, and does not write any derived file.
    * There is no reflow engine in this slice. ``StaleCondition`` is a
      typed declaration, not a runtime trigger.
    * The module depends only on the Python standard library. It
      imports nothing from ``runtime.core`` (including
      ``authority_registry`` or ``constitution_registry``) — the
      projection schemas must stay consumable by future SQLite,
      serialization, or test machinery without pulling in the entire
      shadow kernel. Tests pin this invariant via AST inspection.

  Family versioning:

    * ``SCHEMA_FAMILY = "projection"`` identifies the family.
    * ``SCHEMA_FAMILY_VERSION`` is a semver string attached to the
      family as a whole. Bumping it is a deliberate CUTOVER_PLAN-level
      change and MUST be accompanied by a matching test update.
    * Each concrete projection class carries its own ``SCHEMA_TYPE``
      class attribute so serialized records can self-identify.

  Immutability:

    * Every dataclass in this module is ``frozen=True``.
    * Fields that would otherwise be mutable collections (mappings,
      lists) are modelled as tuples. ``source_versions`` is a tuple
      of ``(source_kind, version)`` pairs rather than a ``dict`` so
      the whole record is hashable and resistant to accidental
      mutation; a ``source_versions_dict()`` helper is provided for
      convenient read access.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import ClassVar, Dict, FrozenSet, Tuple, Type

# ---------------------------------------------------------------------------
# Family version constants
#
# These are runtime attributes, not just docstring text. Tests pin them so
# any deliberate family-level change has to land as a coordinated bundle.
# ---------------------------------------------------------------------------

SCHEMA_FAMILY: str = "projection"
SCHEMA_FAMILY_VERSION: str = "1.0.0"


# ---------------------------------------------------------------------------
# Source reference — a single upstream record contributing to a projection
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SourceRef:
    """A typed link from a projection to one upstream canonical record.

    ``source_kind`` is the authority vocabulary the reference belongs to
    (e.g. ``"stage_transitions"``, ``"role_capabilities"``,
    ``"decision"``, ``"work_item"``, ``"goal_contract"``). The string
    is intentionally free-form because the projection family has to
    outlive individual authority modules; tests do not pin a closed
    vocabulary for ``source_kind``.

    ``source_id`` is the canonical id within the source kind (e.g. a
    decision id, a work-item id, a stage name). ``source_version`` is
    the version string or content hash the projection was built
    against — this is what the reflow engine will later compare to
    current upstream versions to detect staleness.
    """

    source_kind: str
    source_id: str
    source_version: str

    def __post_init__(self) -> None:
        for attr in ("source_kind", "source_id", "source_version"):
            value = getattr(self, attr)
            if not isinstance(value, str) or not value:
                raise ValueError(
                    f"SourceRef.{attr} must be a non-empty string; got {value!r}"
                )


# ---------------------------------------------------------------------------
# Stale condition — declaration of what invalidates a projection
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class StaleCondition:
    """Declarative predicate describing when a projection becomes stale.

    ``watched_authorities`` lists operational-fact names (as declared
    in ``runtime.core.authority_registry.AUTHORITY_TABLE``) whose
    changes must force this projection to be regenerated. The reflow
    engine (future slice) will walk this list to decide invalidation.

    ``watched_files`` lists repo-relative paths (as declared in
    ``runtime.core.constitution_registry``) whose content changes
    must force regeneration. This is separate from
    ``watched_authorities`` because some projections depend on
    human-edited documents (e.g. CLAUDE.md) that are not operational
    facts.

    ``rationale`` is a one-sentence explanation used by diagnostics
    and error messages when the reflow engine blocks landing on a
    stale projection. Tests pin that it is non-empty.

    Both ``watched_*`` tuples are allowed to be empty, because some
    projections may explicitly opt out of staleness tracking (e.g. a
    diagnostic snapshot that is always valid at emission time).
    """

    rationale: str
    watched_authorities: Tuple[str, ...] = ()
    watched_files: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not isinstance(self.rationale, str) or not self.rationale.strip():
            raise ValueError("StaleCondition.rationale must be a non-empty string")
        for attr_name in ("watched_authorities", "watched_files"):
            value = getattr(self, attr_name)
            if not isinstance(value, tuple):
                raise ValueError(
                    f"StaleCondition.{attr_name} must be a tuple; got {type(value).__name__}"
                )
            for item in value:
                if not isinstance(item, str) or not item:
                    raise ValueError(
                        f"StaleCondition.{attr_name} entries must be non-empty strings"
                    )


# ---------------------------------------------------------------------------
# Shared metadata — every projection carries one of these
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ProjectionMetadata:
    """Shared provenance / freshness / versioning metadata for every projection.

    Encodes exactly the five fields required by CUTOVER_PLAN §Schema
    Contract Stack §3 lines 933-939. Every concrete projection type in
    this module composes an instance of this class.

    Fields:

      * ``generator_version`` — semver or commit-hash string identifying
        the exact generator code that produced the projection.
      * ``generated_at`` — unix epoch seconds at generation time.
      * ``stale_condition`` — a :class:`StaleCondition` instance
        declaring what upstream changes invalidate this projection.
      * ``source_versions`` — tuple of ``(source_kind, version)``
        pairs capturing the versions/hashes of the upstream records
        that contributed to this projection. This is the "source
        versions or hashes" field from the CUTOVER_PLAN. A helper
        :meth:`source_versions_dict` returns it as a dict for
        callers that need key-based lookup.
      * ``provenance`` — tuple of :class:`SourceRef` instances
        resolving to the specific upstream records this projection
        was built from. This is the "provenance links to upstream
        records" field.
    """

    generator_version: str
    generated_at: int
    stale_condition: StaleCondition
    source_versions: Tuple[Tuple[str, str], ...] = field(default_factory=tuple)
    provenance: Tuple[SourceRef, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        if not isinstance(self.generator_version, str) or not self.generator_version:
            raise ValueError("generator_version must be a non-empty string")
        # bool is a subclass of int in Python; reject it explicitly to
        # avoid silently accepting True/False as a timestamp.
        if isinstance(self.generated_at, bool) or not isinstance(self.generated_at, int):
            raise ValueError("generated_at must be an int (unix epoch seconds)")
        if self.generated_at < 0:
            raise ValueError("generated_at must be non-negative")
        if not isinstance(self.stale_condition, StaleCondition):
            raise ValueError(
                "stale_condition must be a StaleCondition instance"
            )
        if not isinstance(self.source_versions, tuple):
            raise ValueError("source_versions must be a tuple of (kind, version) pairs")
        seen_kinds: set[str] = set()
        for pair in self.source_versions:
            if not (isinstance(pair, tuple) and len(pair) == 2):
                raise ValueError(
                    "source_versions entries must be 2-tuples of (kind, version)"
                )
            kind, version = pair
            if not isinstance(kind, str) or not kind:
                raise ValueError("source_versions kind must be a non-empty string")
            if not isinstance(version, str) or not version:
                raise ValueError("source_versions version must be a non-empty string")
            if kind in seen_kinds:
                raise ValueError(
                    f"source_versions has duplicate kind {kind!r}; each kind "
                    f"may appear at most once"
                )
            seen_kinds.add(kind)
        if not isinstance(self.provenance, tuple):
            raise ValueError("provenance must be a tuple of SourceRef")
        for ref in self.provenance:
            if not isinstance(ref, SourceRef):
                raise ValueError("provenance entries must be SourceRef instances")

    def source_versions_dict(self) -> Dict[str, str]:
        """Return ``source_versions`` as a plain ``dict`` for lookup-style reads."""
        return dict(self.source_versions)


# ---------------------------------------------------------------------------
# Concrete projection schemas
#
# Every concrete projection carries:
#   * ``SCHEMA_TYPE`` class attribute so serialized records are
#     self-identifying.
#   * ``SCHEMA_FAMILY_VERSION`` class attribute inherited semantically
#     from the module-level constant (checked by tests).
#   * ``metadata`` instance attribute of type :class:`ProjectionMetadata`.
#
# These are **shapes**, not content generators. A future slice will
# add an emitter module that takes runtime state and produces
# instances of these types.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PromptPack:
    """Runtime-compiled prompt pack delivered to an active session/subagent.

    Per CUTOVER_PLAN §Runtime-Compiled Prompt Packs → §Prompt Pack
    Layers, each pack is composed from six runtime-owned layers:
    constitution, stage contract, workflow contract, local decision
    pack, runtime state pack, and next actions. This schema records
    the identities / versions of those layers; the full compiled text
    is a separate content_hash-addressable blob outside this schema.
    """

    SCHEMA_TYPE: ClassVar[str] = "prompt_pack"

    metadata: ProjectionMetadata
    workflow_id: str
    stage_id: str
    layer_names: Tuple[str, ...]
    content_hash: str

    def __post_init__(self) -> None:
        _require_metadata(self.metadata)
        _require_non_empty(self, "workflow_id")
        _require_non_empty(self, "stage_id")
        _require_non_empty(self, "content_hash")
        if not isinstance(self.layer_names, tuple):
            raise ValueError("layer_names must be a tuple")
        if not self.layer_names:
            raise ValueError("PromptPack must declare at least one layer")
        for layer in self.layer_names:
            if not isinstance(layer, str) or not layer:
                raise ValueError("layer_names entries must be non-empty strings")


@dataclass(frozen=True)
class RenderedMasterPlan:
    """Rendered / validated ``MASTER_PLAN.md`` projection.

    CUTOVER_PLAN §Decision and Work Record Architecture explicitly
    calls for ``MASTER_PLAN.md`` to become a rendered roadmap view
    rather than the sole canonical decision log. This schema tracks
    the output of that render: section ids, total section count, and
    a content hash of the rendered bytes.
    """

    SCHEMA_TYPE: ClassVar[str] = "rendered_master_plan"

    metadata: ProjectionMetadata
    content_hash: str
    section_ids: Tuple[str, ...]
    section_count: int

    def __post_init__(self) -> None:
        _require_metadata(self.metadata)
        _require_non_empty(self, "content_hash")
        if not isinstance(self.section_ids, tuple):
            raise ValueError("section_ids must be a tuple")
        for sid in self.section_ids:
            if not isinstance(sid, str) or not sid:
                raise ValueError("section_ids entries must be non-empty strings")
        if not isinstance(self.section_count, int) or isinstance(self.section_count, bool):
            raise ValueError("section_count must be an int")
        if self.section_count < 0:
            raise ValueError("section_count must be non-negative")
        if self.section_count != len(self.section_ids):
            raise ValueError(
                "section_count must equal len(section_ids); got "
                f"count={self.section_count} ids={len(self.section_ids)}"
            )


@dataclass(frozen=True)
class DecisionDigest:
    """Rendered decision digest projection.

    CUTOVER_PLAN §Human Projections lists "decision digest" as a
    canonical projection alongside the rendered MASTER_PLAN. The
    digest is a read-only rollup of canonical decisions within a time
    window. This schema pins the identity of the decisions included
    and the cutoff window.
    """

    SCHEMA_TYPE: ClassVar[str] = "decision_digest"

    metadata: ProjectionMetadata
    decision_ids: Tuple[str, ...]
    cutoff_epoch: int
    content_hash: str

    def __post_init__(self) -> None:
        _require_metadata(self.metadata)
        _require_non_empty(self, "content_hash")
        if not isinstance(self.decision_ids, tuple):
            raise ValueError("decision_ids must be a tuple")
        for did in self.decision_ids:
            if not isinstance(did, str) or not did:
                raise ValueError("decision_ids entries must be non-empty strings")
        if isinstance(self.cutoff_epoch, bool) or not isinstance(self.cutoff_epoch, int):
            raise ValueError("cutoff_epoch must be an int")
        if self.cutoff_epoch < 0:
            raise ValueError("cutoff_epoch must be non-negative")


@dataclass(frozen=True)
class HookDocProjection:
    """Hook-doc projection generated from the runtime hook manifest.

    CUTOVER_PLAN §Derived-Surface Validation requires ``hooks/HOOKS.md``
    and related hook docs to be generated from or validated against
    the runtime hook manifest. This schema captures the identity of
    that projection: which events are documented, which matchers, and
    a content hash of the rendered doc.
    """

    SCHEMA_TYPE: ClassVar[str] = "hook_doc_projection"

    metadata: ProjectionMetadata
    events: Tuple[str, ...]
    matchers: Tuple[str, ...]
    content_hash: str

    def __post_init__(self) -> None:
        _require_metadata(self.metadata)
        _require_non_empty(self, "content_hash")
        if not isinstance(self.events, tuple):
            raise ValueError("events must be a tuple")
        if not self.events:
            raise ValueError("HookDocProjection must declare at least one event")
        for evt in self.events:
            if not isinstance(evt, str) or not evt:
                raise ValueError("events entries must be non-empty strings")
        if not isinstance(self.matchers, tuple):
            raise ValueError("matchers must be a tuple")
        for matcher in self.matchers:
            if not isinstance(matcher, str) or not matcher:
                raise ValueError("matchers entries must be non-empty strings")


@dataclass(frozen=True)
class GraphExport:
    """Derived knowledge-graph export projection.

    CUTOVER_PLAN §Canonical Memory with Derived Retrieval lists graph
    exports as a derived read model, never canonical truth. This
    schema captures the identity of a single export snapshot: node
    count, edge count, and a content hash of the export payload.
    """

    SCHEMA_TYPE: ClassVar[str] = "graph_export"

    metadata: ProjectionMetadata
    node_count: int
    edge_count: int
    content_hash: str

    def __post_init__(self) -> None:
        _require_metadata(self.metadata)
        _require_non_empty(self, "content_hash")
        for attr in ("node_count", "edge_count"):
            value = getattr(self, attr)
            if isinstance(value, bool) or not isinstance(value, int):
                raise ValueError(f"{attr} must be an int")
            if value < 0:
                raise ValueError(f"{attr} must be non-negative")


@dataclass(frozen=True)
class SearchIndexMetadata:
    """Search-index metadata projection.

    CUTOVER_PLAN §Projection Schemas explicitly lists search-index
    metadata as a projection type. This schema captures the identity
    of an index: name, indexed document count, and a content hash of
    the index manifest.
    """

    SCHEMA_TYPE: ClassVar[str] = "search_index_metadata"

    metadata: ProjectionMetadata
    index_name: str
    document_count: int
    content_hash: str

    def __post_init__(self) -> None:
        _require_metadata(self.metadata)
        _require_non_empty(self, "index_name")
        _require_non_empty(self, "content_hash")
        if isinstance(self.document_count, bool) or not isinstance(self.document_count, int):
            raise ValueError("document_count must be an int")
        if self.document_count < 0:
            raise ValueError("document_count must be non-negative")


# ---------------------------------------------------------------------------
# Registry of concrete projection types
# ---------------------------------------------------------------------------

PROJECTION_TYPES: Tuple[Type, ...] = (
    PromptPack,
    RenderedMasterPlan,
    DecisionDigest,
    HookDocProjection,
    GraphExport,
    SearchIndexMetadata,
)

PROJECTION_TYPE_NAMES: FrozenSet[str] = frozenset(t.SCHEMA_TYPE for t in PROJECTION_TYPES)


# ---------------------------------------------------------------------------
# Private validation helpers
# ---------------------------------------------------------------------------


def _require_metadata(metadata: object) -> None:
    if not isinstance(metadata, ProjectionMetadata):
        raise ValueError(
            "projection must carry a ProjectionMetadata instance in its "
            "`metadata` field"
        )


def _require_non_empty(obj: object, attr: str) -> None:
    value = getattr(obj, attr)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{type(obj).__name__}.{attr} must be a non-empty string")


# ---------------------------------------------------------------------------
# Pure lookup helpers
# ---------------------------------------------------------------------------


def projection_type_for(schema_type: str) -> Type:
    """Return the concrete projection class for ``schema_type``.

    Raises ``KeyError`` if ``schema_type`` is not a declared projection
    type. Callers that want a soft lookup should catch the exception or
    use ``schema_type in PROJECTION_TYPE_NAMES`` first.
    """
    for cls in PROJECTION_TYPES:
        if cls.SCHEMA_TYPE == schema_type:
            return cls
    raise KeyError(f"unknown projection schema type: {schema_type!r}")


__all__ = [
    # Family versioning
    "SCHEMA_FAMILY",
    "SCHEMA_FAMILY_VERSION",
    # Shared shapes
    "SourceRef",
    "StaleCondition",
    "ProjectionMetadata",
    # Concrete projections
    "PromptPack",
    "RenderedMasterPlan",
    "DecisionDigest",
    "HookDocProjection",
    "GraphExport",
    "SearchIndexMetadata",
    # Registry
    "PROJECTION_TYPES",
    "PROJECTION_TYPE_NAMES",
    # Helpers
    "projection_type_for",
]

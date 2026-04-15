"""Pure projection reflow staleness planner (shadow-only).

@decision DEC-CLAUDEX-PROJECTION-REFLOW-001
Title: runtime/core/projection_reflow.py is the sole runtime authority that answers, for a given projection and a set of changed authorities/files, whether the projection is stale and why
Status: proposed (shadow-mode, Phase 7 Slice 16 reflow primitive)
Rationale: CUTOVER_PLAN §Reflow and Freshness + §"Constitution-Level
  Files" require a projection reflow orchestration layer. That area
  was represented as the planned slug
  ``projection_reflow_orchestrator_module`` in
  :mod:`runtime.core.constitution_registry`. This slice delivers the
  first minimal reflow enforcement primitive as a pure runtime
  authority, promoting the planned slug to a concrete module in the
  same bundle.

  Scope discipline (pinned by tests):

    * **Pure.** The module has no filesystem reads, no ``open()``
      calls, no subprocess invocation, no database access, no CLI
      wiring, no daemon, no scheduler, no hook adapter.
    * **No live-module imports.** Depends only on the Python
      standard library plus
      :mod:`runtime.core.projection_schemas` (itself stdlib-only)
      for the :class:`ProjectionMetadata` /
      :class:`StaleCondition` type contracts. AST tests pin that
      no routing / policy / hook / leases / settings / enforcement
      module is reached.
    * **Non-mutating.** The planner never writes to or reads from
      any projection; it does not itself regenerate anything. It
      answers "is this stale, and why?" against inputs the caller
      provides. A future slice may wrap this in a scheduler or CI
      gate; those are explicitly out of scope here.
    * **Deterministic.** Result shapes depend only on the supplied
      inputs. Watched-authority and changed-authority sets are
      normalised into sorted tuples so iteration order of the
      caller's inputs does not change output bytes. Two calls with
      the same inputs produce byte-identical assessments and
      plans.

  Public contract:

    * :data:`REFLOW_STATUS_FRESH` / :data:`REFLOW_STATUS_STALE` —
      closed status vocabulary the planner emits. Test pins equality.
    * :class:`ProjectionAssessment` — single-projection freshness
      verdict. Frozen dataclass, JSON-serialisable via the
      :meth:`as_dict` helper.
    * :class:`ReflowPlan` — batch planner output covering an
      ordered set of projections. Frozen dataclass with stable
      ordering (by ``projection_id``) and ``stale_count`` /
      ``fresh_count`` invariants.
    * :func:`assess_projection_freshness` — assess one projection
      given its id, metadata (or any object exposing ``.metadata``
      typed as :class:`ProjectionMetadata`), and the sets of
      changed authorities and changed files. Returns a
      :class:`ProjectionAssessment`.
    * :func:`plan_projection_reflow` — assess an iterable of
      ``(projection_id, metadata_or_projection)`` pairs against a
      single pair of changed sets. Returns a :class:`ReflowPlan`.
    * :func:`extract_projection_metadata` — pure helper that maps
      a :class:`ProjectionMetadata`, or any object carrying a
      ``metadata`` attribute of that type, to the underlying
      :class:`ProjectionMetadata` instance. Exposed so callers can
      reuse the same resolution rule.

  Staleness rule (pinned by tests):

    A projection is ``"stale"`` iff at least one of the following
    intersections is non-empty:

        * ``metadata.stale_condition.watched_authorities`` ∩
          ``changed_authorities``
        * ``metadata.stale_condition.watched_files`` ∩
          ``changed_files``

    Otherwise it is ``"fresh"``. Projections with empty
    ``watched_authorities`` and empty ``watched_files`` are always
    ``"fresh"`` (they explicitly opt out of staleness tracking;
    this matches the :class:`StaleCondition` invariant).

    The assessment always reports ``matched_authorities`` and
    ``matched_files`` as the sorted intersections, so callers can
    surface *why* the projection is stale without re-running the
    match.

  What this module does NOT do:

    * It does not decide *who* may edit or regenerate projections
      — that is the role of the policy engine's write gates.
    * It does not touch the filesystem. If a caller wants to know
      whether a derived file is missing on disk, that is a
      separate concern; this planner answers a purely logical
      question from in-memory inputs.
    * It does not reach for canonical decision / work-item state.
      Inputs are the caller's responsibility.
    * It does not know what to *do* with a stale verdict —
      regenerating, failing CI, blocking a landing, etc. are each
      a wrapping layer's job.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Iterable, Optional, Tuple

from runtime.core.projection_schemas import ProjectionMetadata, StaleCondition

# ---------------------------------------------------------------------------
# Status vocabulary
# ---------------------------------------------------------------------------

REFLOW_STATUS_FRESH: str = "fresh"
REFLOW_STATUS_STALE: str = "stale"

#: Closed set of legal status strings. Tests pin set equality so a
#: future slice cannot silently add a third status without updating
#: this module and the test invariants together.
REFLOW_STATUSES: Tuple[str, ...] = (REFLOW_STATUS_FRESH, REFLOW_STATUS_STALE)


# ---------------------------------------------------------------------------
# Frozen result shapes
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ProjectionAssessment:
    """Single-projection freshness verdict.

    ``projection_id`` is the caller-supplied identifier for the
    projection instance being assessed. It is opaque to this module
    — e.g. a projection name, a projection uuid, or the composite
    ``"{schema_type}:{workflow_id}"`` pattern — but must be a
    non-empty string.

    ``schema_type`` is the ``SCHEMA_TYPE`` class attribute read from
    the supplied projection object when available, or ``None`` if
    the caller passed a bare :class:`ProjectionMetadata`.

    ``status`` is one of :data:`REFLOW_STATUS_FRESH` /
    :data:`REFLOW_STATUS_STALE`. ``healthy`` is ``True`` iff
    ``status == "fresh"``.

    ``matched_authorities`` and ``matched_files`` are the sorted
    intersections of the watched sets with the changed sets — i.e.
    the concrete reasons this projection was judged stale. Both
    empty when the verdict is fresh.

    ``watched_authorities``, ``watched_files`` and
    ``stale_rationale`` are copied verbatim from
    ``metadata.stale_condition`` so consumers need not re-resolve
    the metadata. ``generator_version``, ``generated_at`` and
    ``source_versions`` are copied from the metadata itself so the
    assessment is a self-contained audit record.
    """

    projection_id: str
    schema_type: Optional[str]
    status: str
    healthy: bool
    matched_authorities: Tuple[str, ...]
    matched_files: Tuple[str, ...]
    watched_authorities: Tuple[str, ...]
    watched_files: Tuple[str, ...]
    stale_rationale: str
    generator_version: str
    generated_at: int
    source_versions: Tuple[Tuple[str, str], ...]

    def as_dict(self) -> Dict[str, Any]:
        """Return a JSON-serialisable dict of this assessment.

        Tuples become lists, ``source_versions`` pairs become
        two-element lists, and no other transformation is applied.
        """
        return {
            "projection_id": self.projection_id,
            "schema_type": self.schema_type,
            "status": self.status,
            "healthy": self.healthy,
            "matched_authorities": list(self.matched_authorities),
            "matched_files": list(self.matched_files),
            "watched_authorities": list(self.watched_authorities),
            "watched_files": list(self.watched_files),
            "stale_rationale": self.stale_rationale,
            "generator_version": self.generator_version,
            "generated_at": self.generated_at,
            "source_versions": [list(pair) for pair in self.source_versions],
        }


@dataclass(frozen=True)
class ReflowPlan:
    """Batch reflow plan for an ordered set of projections.

    ``assessments`` is sorted by ``projection_id`` so the plan has
    a deterministic on-the-wire shape regardless of the order the
    caller's iterable yields.

    ``changed_authorities`` and ``changed_files`` record the
    normalised change sets the planner assessed against, so callers
    can verify they supplied the inputs they meant to.

    ``stale_count`` / ``fresh_count`` / ``total`` are invariant:
    ``stale_count + fresh_count == total == len(assessments)``. A
    dedicated :meth:`affected_projection_ids` helper returns the
    ids of the stale projections only, in plan order.
    """

    total: int
    fresh_count: int
    stale_count: int
    assessments: Tuple[ProjectionAssessment, ...]
    changed_authorities: Tuple[str, ...]
    changed_files: Tuple[str, ...]

    def __post_init__(self) -> None:
        if self.total != len(self.assessments):
            raise ValueError(
                f"ReflowPlan.total ({self.total}) must equal "
                f"len(assessments) ({len(self.assessments)})"
            )
        if self.fresh_count + self.stale_count != self.total:
            raise ValueError(
                "ReflowPlan fresh_count + stale_count must equal total; "
                f"got fresh={self.fresh_count} stale={self.stale_count} "
                f"total={self.total}"
            )

    def affected_projection_ids(self) -> Tuple[str, ...]:
        """Return projection ids that were judged stale, in plan order."""
        return tuple(
            a.projection_id
            for a in self.assessments
            if a.status == REFLOW_STATUS_STALE
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "total": self.total,
            "fresh_count": self.fresh_count,
            "stale_count": self.stale_count,
            "assessments": [a.as_dict() for a in self.assessments],
            "changed_authorities": list(self.changed_authorities),
            "changed_files": list(self.changed_files),
            "affected_projection_ids": list(self.affected_projection_ids()),
        }


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


def extract_projection_metadata(projection_or_metadata: object) -> ProjectionMetadata:
    """Return the :class:`ProjectionMetadata` for ``projection_or_metadata``.

    Accepts either a :class:`ProjectionMetadata` instance directly,
    or any object carrying a ``metadata`` attribute whose value is
    a :class:`ProjectionMetadata` instance (which every concrete
    projection dataclass in :mod:`runtime.core.projection_schemas`
    satisfies).

    Raises :class:`ValueError` if neither shape applies so callers
    fail loudly when given unexpected inputs rather than producing
    a silent "always fresh" verdict.
    """
    if isinstance(projection_or_metadata, ProjectionMetadata):
        return projection_or_metadata
    candidate = getattr(projection_or_metadata, "metadata", None)
    if isinstance(candidate, ProjectionMetadata):
        return candidate
    raise ValueError(
        "projection_or_metadata must be a ProjectionMetadata instance or "
        "expose a `.metadata` attribute of type ProjectionMetadata; "
        f"got {type(projection_or_metadata).__name__}"
    )


def _normalise_change_set(items: Iterable[object], *, label: str) -> Tuple[str, ...]:
    """Deduplicate, validate, and sort a change set into a tuple of strings.

    * Rejects ``None`` and non-iterables at the top level.
    * Rejects a bare ``str`` / ``bytes`` / ``bytearray`` / ``memoryview``
      at the top level, even though those types are iterable. The public
      contract is "iterable of non-empty strings"; silently treating a
      bare string as a character-iterable hides caller bugs (e.g.
      ``changed_files="CLAUDE.md"`` would otherwise decompose to
      ``("C","L","A",...)`` and never match any watched-file entry).
    * Rejects non-string / empty items with a precise :class:`ValueError`.
    * Returns a sorted tuple with no duplicates.
    """
    if items is None:
        raise ValueError(f"{label} must be an iterable of non-empty strings, got None")
    if isinstance(items, (str, bytes, bytearray, memoryview)):
        raise ValueError(
            f"{label} must be an iterable collection of non-empty strings, "
            f"not a bare {type(items).__name__}. A bare string is iterable "
            f"over characters, which would silently decompose "
            f"e.g. 'CLAUDE.md' into ('C','L','A',...) and produce a false "
            f"'fresh' verdict. Wrap the value in a tuple/list "
            f"(e.g. ('CLAUDE.md',)) or pass an empty collection."
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


def _extract_schema_type(projection_or_metadata: object) -> Optional[str]:
    """Return the ``SCHEMA_TYPE`` class attribute if present, else ``None``."""
    schema_type = getattr(projection_or_metadata, "SCHEMA_TYPE", None)
    if isinstance(schema_type, str) and schema_type:
        return schema_type
    return None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def assess_projection_freshness(
    projection_id: str,
    projection_or_metadata: object,
    *,
    changed_authorities: Iterable[str],
    changed_files: Iterable[str],
) -> ProjectionAssessment:
    """Assess a single projection's freshness against supplied change sets.

    Rules are documented on the module docstring. Returns a frozen
    :class:`ProjectionAssessment`. Raises :class:`ValueError` on
    any malformed input.
    """
    if not isinstance(projection_id, str) or not projection_id:
        raise ValueError(
            f"projection_id must be a non-empty string; got {projection_id!r}"
        )
    metadata = extract_projection_metadata(projection_or_metadata)
    schema_type = _extract_schema_type(projection_or_metadata)

    normalised_authorities = _normalise_change_set(
        changed_authorities, label="changed_authorities"
    )
    normalised_files = _normalise_change_set(
        changed_files, label="changed_files"
    )

    condition: StaleCondition = metadata.stale_condition
    watched_authorities = tuple(sorted(set(condition.watched_authorities)))
    watched_files = tuple(sorted(set(condition.watched_files)))

    matched_authorities = tuple(
        a for a in watched_authorities if a in set(normalised_authorities)
    )
    matched_files = tuple(
        f for f in watched_files if f in set(normalised_files)
    )

    stale = bool(matched_authorities) or bool(matched_files)
    status = REFLOW_STATUS_STALE if stale else REFLOW_STATUS_FRESH

    return ProjectionAssessment(
        projection_id=projection_id,
        schema_type=schema_type,
        status=status,
        healthy=not stale,
        matched_authorities=matched_authorities,
        matched_files=matched_files,
        watched_authorities=watched_authorities,
        watched_files=watched_files,
        stale_rationale=condition.rationale,
        generator_version=metadata.generator_version,
        generated_at=metadata.generated_at,
        source_versions=tuple(metadata.source_versions),
    )


def plan_projection_reflow(
    projections: Iterable[Tuple[str, object]],
    *,
    changed_authorities: Iterable[str],
    changed_files: Iterable[str],
) -> ReflowPlan:
    """Assess a batch of projections and return a :class:`ReflowPlan`.

    ``projections`` is an iterable of ``(projection_id, projection_or_metadata)``
    pairs. Duplicate ``projection_id`` values raise :class:`ValueError`
    so callers cannot accidentally plan the same projection twice.

    The returned :class:`ReflowPlan` sorts assessments by
    ``projection_id`` so iteration order is deterministic regardless
    of the order the caller's iterable yields.
    """
    if projections is None:
        raise ValueError("projections must be an iterable of (id, metadata) pairs")

    # Normalise the change sets once so every assessment sees the
    # same inputs and the plan can echo them back verbatim.
    normalised_authorities = _normalise_change_set(
        changed_authorities, label="changed_authorities"
    )
    normalised_files = _normalise_change_set(
        changed_files, label="changed_files"
    )

    seen_ids: set[str] = set()
    assessments: list[ProjectionAssessment] = []
    for entry in projections:
        if not (isinstance(entry, tuple) and len(entry) == 2):
            raise ValueError(
                "projections entries must be 2-tuples of (projection_id, "
                f"metadata_or_projection); got {entry!r}"
            )
        projection_id, projection_or_metadata = entry
        if not isinstance(projection_id, str) or not projection_id:
            raise ValueError(
                f"projection_id must be a non-empty string; got {projection_id!r}"
            )
        if projection_id in seen_ids:
            raise ValueError(
                f"duplicate projection_id {projection_id!r} in projections"
            )
        seen_ids.add(projection_id)
        assessments.append(
            assess_projection_freshness(
                projection_id,
                projection_or_metadata,
                changed_authorities=normalised_authorities,
                changed_files=normalised_files,
            )
        )

    assessments.sort(key=lambda a: a.projection_id)
    stale_count = sum(1 for a in assessments if a.status == REFLOW_STATUS_STALE)
    fresh_count = len(assessments) - stale_count

    return ReflowPlan(
        total=len(assessments),
        fresh_count=fresh_count,
        stale_count=stale_count,
        assessments=tuple(assessments),
        changed_authorities=normalised_authorities,
        changed_files=normalised_files,
    )


__all__ = [
    # Status vocabulary
    "REFLOW_STATUS_FRESH",
    "REFLOW_STATUS_STALE",
    "REFLOW_STATUSES",
    # Result shapes
    "ProjectionAssessment",
    "ReflowPlan",
    # Helpers
    "extract_projection_metadata",
    # Public API
    "assess_projection_freshness",
    "plan_projection_reflow",
]

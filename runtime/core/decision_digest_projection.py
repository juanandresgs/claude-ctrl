"""Pure decision-digest projection builder (shadow-only).

@decision DEC-CLAUDEX-DECISION-DIGEST-PROJECTION-001
Title: runtime/core/decision_digest_projection.py renders the decision-digest projection from canonical DecisionRecord objects
Status: proposed (shadow-mode, Phase 7 Slice 13 — decision-digest projection bootstrap)
Rationale: CUTOVER_PLAN Phase 7 exit criteria include "render or
  validate `MASTER_PLAN.md` and decision digests from the canonical
  registry" and "stale decision/plan projections must fail landing."
  ``runtime.core.projection_schemas.DecisionDigest`` already declares
  the typed shape of a decision-digest projection (Phase 1 slice), and
  ``runtime.core.decision_work_registry.DecisionRecord`` is now the
  concrete canonical authority for decisions (Phase 7 Slice 4). This
  module is the pure builder + validator that compiles a supplied
  sequence of ``DecisionRecord`` instances into a ``DecisionDigest``
  instance (:func:`build_decision_digest_projection`), renders the
  markdown body (:func:`render_decision_digest`), and validates a
  candidate body against the projection
  (:func:`validate_decision_digest`, Phase 7 Slice 15). The CLI
  adapters ``cc-policy decision digest`` (Phase 7 Slice 14) and
  ``cc-policy decision digest-check`` (Phase 7 Slice 15) live in
  ``runtime/cli.py`` and are the sole callers that fetch decisions
  from the registry and thread them through this builder/validator.

  Scope discipline:

    * **Purely declarative / pure functions.** ``render_decision_digest``
      renders a markdown body from the supplied decision records.
      ``build_decision_digest_projection`` builds a
      ``DecisionDigest`` dataclass. ``validate_decision_digest``
      compares a candidate body against the projection and returns a
      stable report dict. No filesystem I/O, no DB access, no
      subprocess, no CLI wiring, no live routing imports, no hook
      imports.
    * **Deterministic.** Given the same ``(decisions, generated_at,
      cutoff_epoch, manifest_version)`` inputs, the rendered body and
      ``content_hash`` are byte-identical across calls.
    * **Caller-supplied inputs.** Decisions are passed in explicitly
      — the builder/validator do NOT open
      ``runtime.core.decision_work_registry`` or read from SQLite. The
      CLI adapter in ``runtime/cli.py _handle_decision`` performs the
      read-only DB query via a function-scope import and threads the
      resulting records through the pure surfaces defined here; this
      module never reaches back into the canonical store.
    * **Cutoff semantics.** ``cutoff_epoch`` is the lower bound of
      the rendering window: only decisions with ``updated_at >=
      cutoff_epoch`` are included, matching the "within a time
      window" language on the schema docstring. Records older than
      the cutoff are silently dropped from the projection body and
      from ``decision_ids`` / ``provenance`` — they cannot be
      partially represented.
    * **Determinism of order.** Decisions are rendered in descending
      ``updated_at`` order (most-recent first); ties break by
      ``decision_id`` ascending. This is declarative, testable, and
      independent of the iteration order the caller passes in.
    * **Zero live-module imports.** The module depends only on
      ``runtime.core.decision_work_registry`` (for ``DecisionRecord``)
      and ``runtime.core.projection_schemas`` (for typed output
      shapes). Tests pin this invariant via AST walk.

  Derived fields:

    * ``decision_ids`` — tuple of the included ``decision_id`` values
      in rendered order. Duplicates are rejected at input validation
      time (a ValueError is raised).
    * ``cutoff_epoch`` — echoed back verbatim onto the projection.
    * ``content_hash`` — ``sha256:`` + hex digest of the UTF-8 bytes
      of the rendered markdown body. Derived from the SAME string
      ``render_decision_digest`` produces, so the three fields cannot
      drift from the rendered content.
    * ``metadata.provenance`` — one :class:`SourceRef` per included
      decision. ``source_kind="decision_records"``,
      ``source_id=<decision_id>``,
      ``source_version="<version>:<status>"`` so the projection
      carries stable upstream identity (version + status) without
      embedding the decision body. A future reflow engine compares
      ``source_version`` to detect supersession drift.
    * ``metadata.stale_condition`` — watches the ``decision_records``
      authority (the operational-fact name) and the
      ``runtime/core/decision_work_registry.py`` source file (the
      registry shape authority). If either changes, the digest must
      be regenerated.

  What this module deliberately does NOT do:

    * It does not read any decision from SQLite or any other store.
      Callers supply records; the read-only DB query and filter
      pass-through live in the CLI adapter (``runtime/cli.py
      _handle_decision``), which uses a function-scope import to
      reach the registry without extending this module's authority.
    * It does not write any digest file (no ``docs/DECISIONS.md``,
      no ``MASTER_PLAN.md`` touch). Those are future projection
      write targets owned by separate slices with explicit user
      approval.
    * It does not change ``DecisionRecord`` or registry behavior in
      any way. The module is a strictly read-over-input builder and
      pure validator.
"""

from __future__ import annotations

import hashlib
from typing import Iterable, List, Optional, Sequence, Tuple

from runtime.core.decision_work_registry import DecisionRecord
from runtime.core.projection_schemas import (
    DecisionDigest,
    ProjectionMetadata,
    SourceRef,
    StaleCondition,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Version of this renderer. Bumping it is a deliberate change to the
#: output format and must be accompanied by matching test updates so
#: ``content_hash`` stability tests pick up the new baseline.
DECISION_DIGEST_GENERATOR_VERSION: str = "1.0.0"

#: Default manifest version stamped into ``ProjectionMetadata``'s
#: ``source_versions`` tuple. The decision-work registry does not
#: currently carry its own semver string; this constant keeps the
#: projection self-consistent until a registry-level version is
#: introduced.
MANIFEST_VERSION: str = "1.0.0"

#: Canonical authority name for the decisions source. Mirrors the
#: vocabulary ``source_kind`` strings use elsewhere in the projection
#: family (``hook_wiring``, ``stage_transitions``, …).
DECISIONS_SOURCE_KIND: str = "decision_records"

#: Repo-relative path of the registry module whose shape/source
#: authority backs this projection. Kept as a module-level constant
#: so tests can assert it without hardcoding the string twice.
DECISION_REGISTRY_SOURCE_FILE: str = "runtime/core/decision_work_registry.py"


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


def _hash_content(content: str) -> str:
    """Return a stable, prefixed content hash for ``content``."""
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def _validate_decisions_input(decisions: Sequence[DecisionRecord]) -> None:
    """Reject malformed inputs before rendering or building."""
    if not isinstance(decisions, (list, tuple)):
        raise ValueError(
            f"decisions must be a list or tuple of DecisionRecord; "
            f"got {type(decisions).__name__}"
        )
    seen: set[str] = set()
    for rec in decisions:
        if not isinstance(rec, DecisionRecord):
            raise ValueError(
                f"decisions entries must be DecisionRecord; "
                f"got {type(rec).__name__}"
            )
        if rec.decision_id in seen:
            raise ValueError(
                f"decisions contains duplicate decision_id "
                f"{rec.decision_id!r}; each decision may appear at most once"
            )
        seen.add(rec.decision_id)


def _validate_cutoff(cutoff_epoch: int) -> None:
    if isinstance(cutoff_epoch, bool) or not isinstance(cutoff_epoch, int):
        raise ValueError(
            f"cutoff_epoch must be an int; got {type(cutoff_epoch).__name__}"
        )
    if cutoff_epoch < 0:
        raise ValueError("cutoff_epoch must be non-negative")


def _filter_and_sort(
    decisions: Sequence[DecisionRecord],
    cutoff_epoch: int,
) -> Tuple[DecisionRecord, ...]:
    """Return decisions at or after ``cutoff_epoch`` in render order.

    Sort: descending ``updated_at`` (most-recent first), ties broken
    by ``decision_id`` ascending for byte-deterministic output.
    """
    filtered = [rec for rec in decisions if rec.updated_at >= cutoff_epoch]
    filtered.sort(key=lambda r: (-r.updated_at, r.decision_id))
    return tuple(filtered)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render_decision_digest(
    decisions: Sequence[DecisionRecord],
    *,
    cutoff_epoch: int,
) -> str:
    """Render the decision-digest projection body as markdown text.

    Output shape:

      * H1 title + preamble paragraph naming the canonical authority
      * Generator version line
      * Cutoff window line (``Cutoff: epoch=<int>``)
      * When no decisions are in-window: a ``_No decisions within
        cutoff window._`` line — rendered output stays non-empty and
        deterministic for the empty case.
      * Otherwise: one bullet per included decision in render order,
        formatted as
        ``- `<decision_id>` v<version> [<status>] — <title>`` with a
        sub-bullet carrying the truncated rationale.

    The function is pure: no filesystem I/O, no time calls, no
    mutation of the input sequence.
    """
    _validate_decisions_input(decisions)
    _validate_cutoff(cutoff_epoch)

    ordered = _filter_and_sort(decisions, cutoff_epoch)

    lines: List[str] = []
    lines.append("# Canonical Decision Digest")
    lines.append("")
    lines.append(
        "This document is a derived projection of the canonical decision "
        "records (authority: `runtime.core.decision_work_registry`). Do "
        "not hand-edit — regenerate from the registry via the projection "
        "builder in `runtime.core.decision_digest_projection`."
    )
    lines.append("")
    lines.append(f"Generator version: `{DECISION_DIGEST_GENERATOR_VERSION}`")
    lines.append(f"Cutoff: epoch={cutoff_epoch}")
    lines.append("")

    if not ordered:
        lines.append("_No decisions within cutoff window._")
    else:
        for rec in ordered:
            lines.append(
                f"- `{rec.decision_id}` v{rec.version} [{rec.status}] — "
                f"{rec.title}"
            )
            lines.append(f"  - _{rec.rationale}_")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Projection builder
# ---------------------------------------------------------------------------


def _build_provenance(
    ordered: Tuple[DecisionRecord, ...],
) -> Tuple[SourceRef, ...]:
    """Return a SourceRef per included decision in render order.

    ``source_version`` encodes both the decision's structural version
    and its status (``"<version>:<status>"``) so a future reflow
    engine can detect supersession drift — a decision whose status
    flipped to ``superseded`` since the digest was rendered is
    legitimately stale even if ``version`` did not move.
    """
    refs: List[SourceRef] = []
    for rec in ordered:
        refs.append(
            SourceRef(
                source_kind=DECISIONS_SOURCE_KIND,
                source_id=rec.decision_id,
                source_version=f"{rec.version}:{rec.status}",
            )
        )
    return tuple(refs)


def build_decision_digest_projection(
    decisions: Sequence[DecisionRecord],
    *,
    generated_at: int,
    cutoff_epoch: int,
    manifest_version: str = MANIFEST_VERSION,
) -> DecisionDigest:
    """Build a :class:`DecisionDigest` from a supplied decision sequence.

    ``generated_at`` is required (and unix-epoch seconds) so callers
    decide the timestamp explicitly; this keeps the builder pure and
    deterministic — two calls with the same ``(decisions,
    generated_at, cutoff_epoch, manifest_version)`` produce
    byte-identical records.

    ``cutoff_epoch`` selects which decisions are included (lower
    bound, inclusive). Decisions with ``updated_at < cutoff_epoch``
    are silently dropped from the projection; they never appear in
    ``decision_ids`` / ``provenance`` / rendered body.

    ``manifest_version`` defaults to :data:`MANIFEST_VERSION` and
    controls the ``source_versions`` entry for
    ``"decision_records"``.

    The returned projection's ``decision_ids`` and ``content_hash``
    fields are derived from the SAME rendered markdown body (via
    :func:`render_decision_digest`), so the three fields cannot drift
    from the emitted content.
    """
    # Both helpers below validate; call them here so the builder fails
    # at the builder boundary rather than inside the renderer when
    # callers only want the projection object.
    _validate_decisions_input(decisions)
    _validate_cutoff(cutoff_epoch)

    ordered = _filter_and_sort(decisions, cutoff_epoch)
    rendered = render_decision_digest(decisions, cutoff_epoch=cutoff_epoch)
    content_hash = _hash_content(rendered)

    decision_ids = tuple(rec.decision_id for rec in ordered)

    stale_condition = StaleCondition(
        rationale=(
            "Regenerate the decision-digest projection when the canonical "
            "decision records change, or when the decision-work registry "
            "module shape changes. CUTOVER_PLAN §Derived-Surface Validation."
        ),
        watched_authorities=(DECISIONS_SOURCE_KIND,),
        watched_files=(DECISION_REGISTRY_SOURCE_FILE,),
    )

    provenance = _build_provenance(ordered)

    metadata = ProjectionMetadata(
        generator_version=DECISION_DIGEST_GENERATOR_VERSION,
        generated_at=generated_at,
        stale_condition=stale_condition,
        source_versions=((DECISIONS_SOURCE_KIND, manifest_version),),
        provenance=provenance,
    )

    return DecisionDigest(
        metadata=metadata,
        decision_ids=decision_ids,
        cutoff_epoch=cutoff_epoch,
        content_hash=content_hash,
    )


# ---------------------------------------------------------------------------
# Drift validation (Phase 7 Slice 15)
# ---------------------------------------------------------------------------

#: Stable status constants for :func:`validate_decision_digest` return shape.
#: Mirror the ``VALIDATION_STATUS_*`` vocabulary used by
#: :mod:`runtime.core.hook_doc_validation` so the projection family speaks
#: with one voice about "healthy vs. drifted" outcomes.
VALIDATION_STATUS_OK: str = "ok"
VALIDATION_STATUS_DRIFT: str = "drift"


def _trailing_newline_count(text: str) -> int:
    """Return the number of contiguous trailing ``\\n`` characters in ``text``."""
    return len(text) - len(text.rstrip("\n"))


def _normalise_trailing_newline(candidate: str, expected: str) -> str:
    """Pad the candidate's trailing newlines to match the expected count.

    Only appends; never removes. If the candidate already has at
    least as many trailing newlines as the expected body, it is
    returned unchanged (leaving "extra trailing newlines" as real
    drift). This mirrors the tolerant rule used by
    :func:`runtime.core.hook_doc_validation.validate_hook_doc`: forgive
    editors that strip trailing whitespace, but never silently repair
    missing or modified content.
    """
    expected_trailing = _trailing_newline_count(expected)
    candidate_trailing = _trailing_newline_count(candidate)
    if candidate_trailing >= expected_trailing:
        return candidate
    return candidate + "\n" * (expected_trailing - candidate_trailing)


def _first_mismatch(
    expected_lines: List[str],
    candidate_lines: List[str],
) -> Optional[dict]:
    """Return the first line-level mismatch between two line lists.

    Walks both lists in parallel. If a pair of lines at the same
    index differs, that position (1-indexed) is the mismatch. If no
    pair differs but the lists have different lengths, the first
    line past the shorter list is the mismatch:

      * ``len(expected) > len(candidate)`` → expected has an extra
        line the candidate is missing; ``candidate`` field is ``None``.
      * ``len(candidate) > len(expected)`` → candidate has an extra
        line; ``expected`` is ``None``.

    Returns ``None`` when the two lists are identical.
    """
    for i, (exp, cand) in enumerate(
        zip(expected_lines, candidate_lines), start=1
    ):
        if exp != cand:
            return {"line": i, "expected": exp, "candidate": cand}

    if len(expected_lines) > len(candidate_lines):
        missing_idx = len(candidate_lines)
        return {
            "line": missing_idx + 1,
            "expected": expected_lines[missing_idx],
            "candidate": None,
        }
    if len(candidate_lines) > len(expected_lines):
        extra_idx = len(expected_lines)
        return {
            "line": extra_idx + 1,
            "expected": None,
            "candidate": candidate_lines[extra_idx],
        }
    return None


def validate_decision_digest(
    candidate: str,
    decisions: Sequence[DecisionRecord],
    *,
    cutoff_epoch: int,
) -> dict:
    """Validate a candidate decision-digest body against the projection.

    Parameters:

      * ``candidate`` — the candidate markdown/text body. Must be a
        ``str``; may be empty. An empty candidate against a
        non-empty expected body reports drift.
      * ``decisions`` — canonical decision records the expected body
        is rendered from (same sequence shape accepted by
        :func:`render_decision_digest` and
        :func:`build_decision_digest_projection`).
      * ``cutoff_epoch`` — inclusive lower bound on
        ``DecisionRecord.updated_at`` (same semantics as the renderer).

    Comparison rule (pinned by tests):

      **Strict byte-for-byte equality after padding the candidate's
      trailing newlines to match the expected body's trailing-newline
      count, never removing content.** Extra trailing newlines on the
      candidate are treated as real drift.

    Returns a JSON-serialisable report dict with the following stable
    shape:

      .. code-block:: python

          {
              "status":                  "ok" | "drift",
              "healthy":                 bool,
              "expected_content_hash":   "sha256:<hex>",
              "candidate_content_hash":  "sha256:<hex>",
              "exact_match":             bool,
              "expected_line_count":     int,
              "candidate_line_count":    int,
              "first_mismatch":          None | {
                  "line": int,             # 1-indexed
                  "expected": str | None,
                  "candidate": str | None,
              },
              "decision_ids":            list[str],
              "cutoff_epoch":            int,
              "generator_version":       str,
          }

    The function is pure: no filesystem I/O, no DB access, no
    subprocess, no clock calls, no CLI wiring. It re-uses the same
    :func:`render_decision_digest` renderer that the projection
    builder uses so ``expected_content_hash`` is guaranteed to equal
    :attr:`DecisionDigest.content_hash` for the same inputs.
    """
    if not isinstance(candidate, str):
        raise ValueError(
            f"candidate must be a str; got {type(candidate).__name__}"
        )
    # ``render_decision_digest`` itself validates decisions + cutoff,
    # so bad input surfaces as ValueError from the renderer. We do not
    # repeat those checks here — a single validator for a single input
    # shape.
    expected = render_decision_digest(decisions, cutoff_epoch=cutoff_epoch)
    expected_hash = _hash_content(expected)

    ordered = _filter_and_sort(decisions, cutoff_epoch)
    decision_ids = [rec.decision_id for rec in ordered]

    normalised_candidate = _normalise_trailing_newline(candidate, expected)
    candidate_hash = _hash_content(normalised_candidate)

    exact_match = candidate_hash == expected_hash

    expected_lines = expected.splitlines()
    candidate_lines = normalised_candidate.splitlines()
    first_mismatch = (
        None if exact_match else _first_mismatch(expected_lines, candidate_lines)
    )

    status = VALIDATION_STATUS_OK if exact_match else VALIDATION_STATUS_DRIFT

    return {
        "status": status,
        "healthy": exact_match,
        "expected_content_hash": expected_hash,
        "candidate_content_hash": candidate_hash,
        "exact_match": exact_match,
        "expected_line_count": len(expected_lines),
        "candidate_line_count": len(candidate_lines),
        "first_mismatch": first_mismatch,
        "decision_ids": decision_ids,
        "cutoff_epoch": cutoff_epoch,
        "generator_version": DECISION_DIGEST_GENERATOR_VERSION,
    }


__all__ = [
    "DECISION_DIGEST_GENERATOR_VERSION",
    "MANIFEST_VERSION",
    "DECISIONS_SOURCE_KIND",
    "DECISION_REGISTRY_SOURCE_FILE",
    "VALIDATION_STATUS_OK",
    "VALIDATION_STATUS_DRIFT",
    "render_decision_digest",
    "build_decision_digest_projection",
    "validate_decision_digest",
]

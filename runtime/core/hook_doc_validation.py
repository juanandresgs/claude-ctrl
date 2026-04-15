"""Pure hook-doc drift validator (shadow-only).

@decision DEC-CLAUDEX-HOOK-DOC-VALIDATION-001
Title: runtime/core/hook_doc_validation.py is the pure drift checker that compares a candidate hook-doc text against the runtime-generated projection
Status: proposed (shadow-mode, Phase 2 derived-surface validation)
Rationale: CUTOVER_PLAN §Derived-Surface Validation (lines 1020-1024)
  says hook docs must be generated from or validated against the
  runtime authority layer, and §Invariants Rule 12 says derived
  projections fail validation when upstream canonical state
  changed without reflow. The previous slice delivered the
  generator (:mod:`runtime.core.hook_doc_projection`); this slice
  delivers the pure drift checker that answers "does this candidate
  text match the projection the runtime would emit right now?"

  Scope discipline:

    * **Pure function.** ``validate_hook_doc`` takes the candidate
      text as a string argument and returns a dict. No filesystem
      reads, no ``open()`` calls on ``hooks/HOOKS.md``, no CLI
      invocation, no subprocess, no database access.
    * **No CLI wiring in this slice.** A future slice may expose
      this helper via ``cc-policy hook doc-check`` or similar, but
      that is out of scope here.
    * **Zero live-module imports.** The module depends on
      ``runtime.core.hook_doc_projection`` only (which itself
      depends on ``hook_manifest`` + ``projection_schemas``). AST
      tests pin that nothing live reaches this module, that this
      module reaches nothing live, and that ``runtime/cli.py`` does
      not import it.
    * **Deterministic.** ``generated_at`` is a required
      caller-supplied int; two calls with the same ``generated_at``
      against unchanged manifest state produce byte-identical
      reports. The ``content_hash`` in the report always matches
      the projection's ``content_hash`` field so there is a single
      authority for the expected digest.

  Comparison rule (pinned by tests):

    **Strict byte-for-byte equality after padding the candidate's
    trailing newlines to match the expected trailing-newline count,
    never removing content.**

    Concretely:

    1. Count the contiguous trailing ``\\n`` characters in the
       expected rendered body (``render_hook_doc()`` currently
       produces two because each event section ends with a blank
       spacer line).
    2. Count the contiguous trailing ``\\n`` characters in the
       candidate.
    3. If the candidate has fewer trailing ``\\n`` characters than
       the expected body, append exactly enough ``\\n`` characters
       to match. This forgives editors that strip any number of
       trailing blank lines.
    4. Never remove content. If the candidate has *more* trailing
       ``\\n`` characters than expected, that is real drift — the
       candidate is compared as-is and reported as drift.
    5. The normalised candidate is hashed with the same
       ``sha256:<hex>`` format the projection builder uses and
       compared to ``build_hook_doc_projection().content_hash``.
    6. If the hashes differ, the normalised candidate and the
       rendered expected content are split via ``str.splitlines()``
       and walked line-by-line to produce a first-mismatch record.

  Report shape (stable, pinned by tests):

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
                "expected": str | None,  # None when the candidate has an extra line
                "candidate": str | None, # None when the expected has an extra line
            },
            "generator_version":       str,
        }

    ``first_mismatch`` is ``None`` iff ``exact_match`` is True.
"""

from __future__ import annotations

import hashlib
from typing import List, Optional

from runtime.core.hook_doc_projection import (
    HOOK_DOC_GENERATOR_VERSION,
    MANIFEST_VERSION,
    build_hook_doc_projection,
    render_hook_doc,
)


# ---------------------------------------------------------------------------
# Status constants
# ---------------------------------------------------------------------------

VALIDATION_STATUS_OK: str = "ok"
VALIDATION_STATUS_DRIFT: str = "drift"


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _trailing_newline_count(text: str) -> int:
    """Return the number of contiguous trailing ``\\n`` characters in ``text``."""
    return len(text) - len(text.rstrip("\n"))


def _normalise_trailing_newline(candidate: str, expected: str) -> str:
    """Pad the candidate's trailing newlines to match the expected count.

    Only appends; never removes. If the candidate already has at
    least as many trailing newlines as the expected body, it is
    returned unchanged (leaving "extra trailing newlines" as real
    drift). Empty candidate against non-empty expected gets padded
    with a trailing-newline tail that still cannot match the
    expected body's content — the hash comparison correctly
    classifies that as drift.
    """
    expected_trailing = _trailing_newline_count(expected)
    candidate_trailing = _trailing_newline_count(candidate)
    if candidate_trailing >= expected_trailing:
        return candidate
    return candidate + "\n" * (expected_trailing - candidate_trailing)


def _hash_content(content: str) -> str:
    """Return the ``sha256:<hex>`` digest of ``content`` as UTF-8 bytes.

    This uses the same hash format the projection builder embeds in
    ``HookDocProjection.content_hash`` so hash comparisons between
    this validator and the projection are directly meaningful.
    Tests pin that the two stay aligned by feeding the builder's
    rendered output through this function and comparing to
    ``projection.content_hash``.
    """
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def _first_mismatch(
    expected_lines: List[str],
    candidate_lines: List[str],
) -> Optional[dict]:
    """Return the first line-level mismatch between two line lists.

    Walks both lists in parallel. If a pair of lines at the same
    index differs, that position (1-indexed) is the mismatch. If no
    pair differs but the lists have different lengths, the first
    line past the shorter list is the mismatch:

      * ``len(expected) > len(candidate)`` → expected has an
        "extra" line the candidate is missing; ``candidate`` field
        in the returned dict is ``None``.
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
        missing_idx = len(candidate_lines)  # zero-indexed position of first missing
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


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def validate_hook_doc(
    candidate: str,
    *,
    generated_at: int,
    manifest_version: str = MANIFEST_VERSION,
) -> dict:
    """Validate a candidate hook-doc text against the runtime projection.

    Parameters:

      * ``candidate`` — the candidate markdown/text body. May be
        empty; an empty candidate against a non-empty expected body
        reports drift.
      * ``generated_at`` — unix epoch seconds passed through to the
        projection builder so the result is deterministic.
      * ``manifest_version`` — manifest version tag for the
        projection's provenance. Does not affect the rendered body
        or its hash (the body is built from ``HOOK_MANIFEST`` which
        is currently unversioned at the entry level).

    Returns a JSON-serialisable dict whose shape is documented in
    the module docstring. The function never raises — ``candidate``
    is treated as opaque text and any unusual input is classified
    as drift rather than an exception.
    """
    # Build expected content and projection from the authority layer.
    expected = render_hook_doc()
    projection = build_hook_doc_projection(
        generated_at=generated_at,
        manifest_version=manifest_version,
    )
    expected_hash = projection.content_hash

    # Pad the candidate's trailing newlines to match the expected
    # body so editors that strip trailing whitespace don't produce
    # false drift. Never removes content.
    normalised_candidate = _normalise_trailing_newline(candidate, expected)
    candidate_hash = _hash_content(normalised_candidate)

    exact_match = candidate_hash == expected_hash

    # Line-by-line mismatch detection. ``splitlines()`` naturally
    # handles trailing newlines so both sides use the same shape.
    expected_lines = expected.splitlines()
    candidate_lines = normalised_candidate.splitlines()
    first_mismatch = None if exact_match else _first_mismatch(
        expected_lines, candidate_lines
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
        "generator_version": HOOK_DOC_GENERATOR_VERSION,
    }


__all__ = [
    "VALIDATION_STATUS_OK",
    "VALIDATION_STATUS_DRIFT",
    "validate_hook_doc",
]

"""Pure prompt-pack drift validator (shadow-only).

@decision DEC-CLAUDEX-PROMPT-PACK-VALIDATION-001
Title: runtime/core/prompt_pack_validation.py is the pure drift checker that compares a candidate prompt-pack body against the runtime-compiled projection
Status: proposed (shadow-mode, Phase 2 prompt-pack drift validation)
Rationale: CUTOVER_PLAN §Runtime-Compiled Prompt Packs says prompt
  packs are derived runtime projections delivered to sessions /
  subagents. §Phase 2 exit criterion says "hook-delivered guidance
  comes from compiled runtime context rather than hand-maintained
  local prompt fragments." §Invariant 12 says "derived projections
  fail validation when upstream canonical state changed without
  reflow."

  The previous slice delivered the compiler
  (:mod:`runtime.core.prompt_pack`); this slice delivers the pure
  drift checker that answers "does this candidate prompt-pack text
  match the compiler output for the same (workflow_id, stage_id,
  layers) inputs?"

  Scope discipline:

    * **Pure function.** ``validate_prompt_pack`` takes the candidate
      text as a plain ``str`` and returns a dict. No filesystem I/O,
      no DB access, no subprocess, no CLI surface.
    * **Explicit caller inputs for the expected body.** Unlike
      :mod:`runtime.core.hook_doc_validation`, which consults a
      single canonical authority
      (``runtime.core.hook_manifest.HOOK_MANIFEST``), prompt packs
      are per-session / per-stage artifacts. The caller supplies
      ``(workflow_id, stage_id, layers, generated_at,
      manifest_version)`` and the validator delegates to
      :func:`runtime.core.prompt_pack.render_prompt_pack` +
      :func:`runtime.core.prompt_pack.build_prompt_pack` to compute
      the expected body and hash. This keeps the validator pure
      while still letting callers key off any prompt-pack identity.
    * **Deterministic.** ``generated_at`` is required (unix epoch
      seconds). Two calls with the same inputs produce
      byte-identical reports — the embedded ``expected_content_hash``
      matches ``build_prompt_pack(...).content_hash`` exactly.
    * **Zero live-module imports.** The module depends only on
      ``runtime.core.prompt_pack``. AST tests pin that nothing live
      reaches this module, that this module reaches nothing live,
      and that ``runtime/cli.py`` does not import it.

  Comparison rule (pinned by tests) — same as
  :mod:`runtime.core.hook_doc_validation`:

    **Strict byte-for-byte equality after padding the candidate's
    trailing newlines to match the expected trailing-newline count,
    never removing content.**

    1. Count contiguous trailing ``\\n`` in the expected body.
       (``render_prompt_pack`` currently produces exactly one, but
       the rule tolerates future renderer changes.)
    2. Count contiguous trailing ``\\n`` in the candidate.
    3. If the candidate has fewer, append enough ``\\n`` characters
       to match. Never remove content.
    4. Hash the normalised candidate with the same
       ``sha256:<hex>`` format as ``build_prompt_pack.content_hash``
       and compare.
    5. On mismatch, split both sides via ``str.splitlines()`` and
       walk line-by-line to produce a 1-indexed ``first_mismatch``.

  Report shape (stable, pinned by tests):

    .. code-block:: python

        {
            "status":                 "ok" | "drift",
            "healthy":                bool,
            "expected_content_hash":  "sha256:<hex>",
            "candidate_content_hash": "sha256:<hex>",
            "exact_match":            bool,
            "expected_line_count":    int,
            "candidate_line_count":   int,
            "first_mismatch":         None | {
                "line": int,             # 1-indexed
                "expected": str | None,  # None when candidate has extra line
                "candidate": str | None, # None when expected has extra line
            },
            "generator_version":      str,
            "workflow_id":            str,  # caller identity, for traceability
            "stage_id":               str,
        }

    The extra ``workflow_id`` and ``stage_id`` fields (vs the
    hook-doc validator report) make the output self-describing when
    many prompt packs are validated in sequence.

  Delegation: layer / identifier validation is handled by
  :mod:`runtime.core.prompt_pack`. This validator calls
  ``render_prompt_pack`` which raises ``ValueError`` on bad inputs,
  and the exception is propagated to the caller unchanged — the
  validator is a drift checker, not an input sanitizer.
"""

from __future__ import annotations

import hashlib
from typing import Any, List, Mapping, Optional, Tuple

from runtime.core.prompt_pack import (
    MANIFEST_VERSION,
    PROMPT_PACK_GENERATOR_VERSION,
    PROMPT_PACK_PREAMBLE_TAG,
    SUBAGENT_START_HOOK_EVENT,
    build_prompt_pack,
    render_prompt_pack,
)

# ---------------------------------------------------------------------------
# Status constants (mirror hook_doc_validation for consistent CLI output)
# ---------------------------------------------------------------------------

VALIDATION_STATUS_OK: str = "ok"
VALIDATION_STATUS_DRIFT: str = "drift"

#: Status constant for the SubagentStart envelope validator. Distinct
#: from ``"drift"`` because an invalid envelope is a structural /
#: framing bug, not a byte-level divergence from an expected body.
VALIDATION_STATUS_INVALID: str = "invalid"


# ---------------------------------------------------------------------------
# Private helpers
#
# These are intentional narrow duplicates of the helpers in
# runtime.core.hook_doc_validation. Each validator stays
# self-contained so a later refactor can extract a shared drift-helper
# module without rippling changes through consumers. Duplication is
# small (~30 lines) and the behavior is pinned by mirroring tests.
# ---------------------------------------------------------------------------


def _trailing_newline_count(text: str) -> int:
    """Return the number of contiguous trailing ``\\n`` characters."""
    return len(text) - len(text.rstrip("\n"))


def _normalise_trailing_newline(candidate: str, expected: str) -> str:
    """Pad the candidate's trailing newlines to match the expected count.

    Only appends; never removes. If the candidate already has at
    least as many trailing newlines as the expected body, it is
    returned unchanged (leaving "extra trailing newlines" as real
    drift). This keeps the validator permissive of editors that
    strip trailing whitespace while rejecting real content
    divergence.
    """
    expected_trailing = _trailing_newline_count(expected)
    candidate_trailing = _trailing_newline_count(candidate)
    if candidate_trailing >= expected_trailing:
        return candidate
    return candidate + "\n" * (expected_trailing - candidate_trailing)


def _hash_content(content: str) -> str:
    """Return the ``sha256:<hex>`` digest of ``content`` as UTF-8 bytes.

    This matches the hash format embedded in
    ``PromptPack.content_hash`` so the validator's hashes are
    directly comparable to a ``build_prompt_pack`` record without
    extra transformation.
    """
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def _first_mismatch(
    expected_lines: List[str],
    candidate_lines: List[str],
) -> Optional[dict]:
    """Return the first line-level mismatch between two line lists.

    Walks both lists in parallel. The first unequal pair sets the
    mismatch. If both lists are a common prefix of one another but
    have different lengths, the first line past the shorter list is
    the mismatch:

      * ``len(expected) > len(candidate)`` → expected has a line the
        candidate is missing; ``candidate`` field is ``None``.
      * ``len(candidate) > len(expected)`` → candidate has an extra
        line; ``expected`` is ``None``.

    Returns ``None`` when both lists are byte-identical.
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


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def validate_prompt_pack(
    candidate: str,
    *,
    workflow_id: str,
    stage_id: str,
    layers: Mapping[str, str],
    generated_at: int,
    manifest_version: str = MANIFEST_VERSION,
) -> dict:
    """Validate a candidate prompt-pack body against the compiler output.

    Parameters:

      * ``candidate`` — the candidate prompt-pack body text. Treated
        as opaque; any divergence from the expected rendered body is
        classified as drift rather than raised.
      * ``workflow_id``, ``stage_id``, ``layers`` — identity + layer
        content passed through to
        :func:`runtime.core.prompt_pack.render_prompt_pack` and
        :func:`runtime.core.prompt_pack.build_prompt_pack`.
      * ``generated_at`` — unix epoch seconds, required so the
        embedded expected projection is deterministic.
      * ``manifest_version`` — passed through to the builder's
        provenance metadata.

    Returns the stable report dict documented in the module
    docstring. ``workflow_id`` and ``stage_id`` are echoed back in
    the report for traceability when many packs are validated in a
    batch.

    Raises ``ValueError`` (from the compiler) if the caller supplies
    invalid ``workflow_id`` / ``stage_id`` / ``layers``. The
    validator deliberately does not catch these: a malformed input
    is a caller bug, not drift.
    """
    # Build expected content and projection from the compiler. The
    # compiler validates identifiers and layers; any caller-input
    # error raises ValueError here and propagates to the caller.
    expected = render_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
    )
    projection = build_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
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
        "generator_version": PROMPT_PACK_GENERATOR_VERSION,
        "workflow_id": workflow_id,
        "stage_id": stage_id,
    }


# ---------------------------------------------------------------------------
# Metadata validator (Phase 7 Slice 12)
#
# @decision DEC-CLAUDEX-PROMPT-PACK-METADATA-VALIDATION-001
# Title: validate_prompt_pack_metadata is the pure metadata/freshness drift checker for compiled prompt packs
# Status: proposed (Phase 7 Slice 12 — compiled-metadata freshness gate)
# Rationale: After Phase 7 Slice 11, compiled prompt-pack
#   ``metadata.stale_condition.watched_files`` is meaningful — it is
#   derived from the full concrete constitution set via
#   ``prompt_pack_resolver.constitution_watched_files()``. But body-
#   level drift (``validate_prompt_pack``) cannot detect a candidate
#   whose body is current while its metadata envelope has been
#   tampered with, silently stripped, or left stale relative to a
#   newer constitution set. CUTOVER_PLAN §Invariant 12 (derived
#   projections fail validation when upstream canonical state changed
#   without reflow) requires the metadata envelope to be validated
#   explicitly.
#
#   Scope discipline:
#
#     * **Pure function, no I/O.** Takes a candidate metadata dict and
#       returns a report dict. No filesystem, DB, subprocess, time
#       calls, or live resolver import. The caller pre-resolves the
#       ``watched_files`` tuple — the validator does not reach into
#       ``constitution_registry`` or ``prompt_pack_resolver``, so the
#       shadow-only invariant is preserved.
#     * **Rebuild-via-compiler model.** The expected metadata is
#       produced by calling
#       :func:`runtime.core.prompt_pack.build_prompt_pack` with the
#       caller-supplied ``watched_files`` and serialising the result's
#       metadata into the same JSON-shaped dict the compile CLI
#       emits. This makes the validator symmetric with the compile
#       payload without duplicating the CLI's serialisation rules —
#       a single serialiser helper is shared.
#     * **Stable report contract.** The report carries
#       ``status``, ``healthy``, ``exact_match``, ``expected_metadata``,
#       ``candidate_metadata``, ``first_mismatch``, and the identity
#       echo fields (``workflow_id``, ``stage_id``).
#     * **No input coercion.** Missing / wrong-type candidate fields
#       surface as drift, not exceptions, because the validator is a
#       drift checker. Malformed ``layers`` / ``workflow_id`` /
#       ``stage_id`` on the compiler-input side still raises ``ValueError``
#       from ``build_prompt_pack`` — those are caller bugs, not drift.
# ---------------------------------------------------------------------------


def serialise_prompt_pack_metadata(metadata: Any) -> dict:
    """Return the JSON-shaped metadata dict that the compile CLI emits.

    Public single-authority serialiser for the ``metadata`` object
    of a compiled :class:`runtime.core.prompt_pack.PromptPack`.
    Both :mod:`runtime.cli` (compile action) and
    :func:`validate_prompt_pack_metadata` must route through this
    helper so the on-wire metadata shape has exactly one owner and
    cannot silently drift between producer and validator.

    The returned dict preserves the field names and ordering the
    compile CLI has historically emitted:

      * ``generator_version`` (str)
      * ``generated_at`` (int)
      * ``source_versions`` (list[list[str, str]])
      * ``provenance`` (list[{source_kind, source_id, source_version}])
      * ``stale_condition`` (dict with ``rationale``,
        ``watched_authorities``, ``watched_files``)

    Any future change to the metadata JSON shape must land here.
    """
    return {
        "generator_version": metadata.generator_version,
        "generated_at": metadata.generated_at,
        "source_versions": [list(pair) for pair in metadata.source_versions],
        "provenance": [
            {
                "source_kind": ref.source_kind,
                "source_id": ref.source_id,
                "source_version": ref.source_version,
            }
            for ref in metadata.provenance
        ],
        "stale_condition": {
            "rationale": metadata.stale_condition.rationale,
            "watched_authorities": list(
                metadata.stale_condition.watched_authorities
            ),
            "watched_files": list(
                metadata.stale_condition.watched_files
            ),
        },
    }


#: Backwards-compatible private alias retained for intra-module
#: readability; external callers must use the public name
#: :func:`serialise_prompt_pack_metadata`.
_serialise_metadata_to_compile_shape = serialise_prompt_pack_metadata


def _first_metadata_mismatch(
    expected: Any,
    candidate: Any,
    path: str = "",
) -> Optional[dict]:
    """Return the first structural mismatch between two JSON values.

    Walks expected / candidate in parallel; returns a dict
    ``{"path": "<dotted.path>", "expected": ..., "candidate": ...}``
    on the first divergence, or ``None`` when they are equal.
    ``path`` uses dotted notation for dict keys and ``[i]`` for list
    indices (e.g. ``"stale_condition.watched_files[3]"``).
    """
    if type(expected) != type(candidate):  # noqa: E721 — exact type match
        return {"path": path or "<root>", "expected": expected, "candidate": candidate}
    if isinstance(expected, dict):
        # Report missing/extra keys before descending so a missing key
        # is not mis-reported as a sub-path divergence.
        exp_keys = set(expected.keys())
        cand_keys = set(candidate.keys())
        missing = sorted(exp_keys - cand_keys)
        extra = sorted(cand_keys - exp_keys)
        if missing:
            key = missing[0]
            sub_path = f"{path}.{key}" if path else key
            return {
                "path": sub_path,
                "expected": expected[key],
                "candidate": None,
            }
        if extra:
            key = extra[0]
            sub_path = f"{path}.{key}" if path else key
            return {
                "path": sub_path,
                "expected": None,
                "candidate": candidate[key],
            }
        for key in expected:
            sub_path = f"{path}.{key}" if path else key
            sub = _first_metadata_mismatch(expected[key], candidate[key], sub_path)
            if sub is not None:
                return sub
        return None
    if isinstance(expected, list):
        if len(expected) != len(candidate):
            return {
                "path": path or "<root>",
                "expected": expected,
                "candidate": candidate,
            }
        for idx, (e, c) in enumerate(zip(expected, candidate)):
            sub_path = f"{path}[{idx}]"
            sub = _first_metadata_mismatch(e, c, sub_path)
            if sub is not None:
                return sub
        return None
    if expected != candidate:
        return {"path": path or "<root>", "expected": expected, "candidate": candidate}
    return None


def validate_prompt_pack_metadata(
    candidate_metadata: Mapping[str, Any],
    *,
    workflow_id: str,
    stage_id: str,
    layers: Mapping[str, str],
    generated_at: int,
    watched_files: Tuple[str, ...],
    manifest_version: str = MANIFEST_VERSION,
) -> dict:
    """Validate a candidate prompt-pack metadata object against the compiler.

    Parameters:

      * ``candidate_metadata`` — the metadata mapping as it appears in
        the compile CLI's output (JSON-shaped dict, not a live
        ``ProjectionMetadata`` dataclass). Treated as opaque; any
        structural or value divergence is classified as drift.
      * ``workflow_id``, ``stage_id``, ``layers``, ``generated_at`` —
        passed through to :func:`runtime.core.prompt_pack.build_prompt_pack`
        so the expected metadata is rebuilt from the same compiler
        authority that produced the original artifact.
      * ``watched_files`` — the constitution-level path tuple the
        caller asserts was used at compile time (resolved from
        ``constitution_registry`` by the CLI, not by this helper).
      * ``manifest_version`` — defaults to the module manifest version.

    Returns a stable report dict:

    .. code-block:: python

        {
            "status":             "ok" | "drift",
            "healthy":            bool,
            "exact_match":        bool,
            "expected_metadata":  dict,
            "candidate_metadata": dict,  # echoed back verbatim
            "first_mismatch":     None | {
                "path": str,             # dotted path, e.g.
                                         # "stale_condition.watched_files[3]"
                "expected": Any,
                "candidate": Any,
            },
            "workflow_id":        str,
            "stage_id":           str,
        }

    Raises ``ValueError`` only when the compiler-side inputs
    (``workflow_id``, ``stage_id``, ``layers``) are themselves
    invalid — those are caller bugs, not drift. Missing or
    wrong-type candidate metadata fields surface as drift.
    """
    # Accept both a live Mapping and any JSON-derived dict. Copy to a
    # plain dict so later equality/serialisation is JSON-clean.
    candidate_dict: dict = dict(candidate_metadata) if candidate_metadata else {}

    projection = build_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
        generated_at=generated_at,
        manifest_version=manifest_version,
        watched_files=tuple(watched_files),
    )
    expected_metadata = _serialise_metadata_to_compile_shape(projection.metadata)

    first_mismatch = _first_metadata_mismatch(expected_metadata, candidate_dict)
    exact_match = first_mismatch is None
    status = VALIDATION_STATUS_OK if exact_match else VALIDATION_STATUS_DRIFT

    return {
        "status": status,
        "healthy": exact_match,
        "exact_match": exact_match,
        "expected_metadata": expected_metadata,
        "candidate_metadata": candidate_dict,
        "first_mismatch": first_mismatch,
        "workflow_id": workflow_id,
        "stage_id": stage_id,
    }


# ---------------------------------------------------------------------------
# SubagentStart envelope validator
#
# @decision DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-VALIDATION-001
# Title: validate_subagent_start_envelope is the pure structural / framing validator for the SubagentStart hook envelope
# Status: proposed (shadow-mode, Phase 2 prompt-pack hook contract)
# Rationale: The previous slice
#   (DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-DELIVERY-001) added the
#   pure envelope builder
#   :func:`runtime.core.prompt_pack.build_subagent_start_envelope`.
#   This slice adds the symmetric pure validator so the runtime
#   owns both the producer and the contract checker before any live
#   hook wiring lands. A future hook-adapter slice can invoke this
#   validator at the boundary and refuse to emit a malformed
#   envelope — the runtime is the single authority for the shape,
#   not the shell script.
#
#   Scope discipline:
#
#     * **Pure function, no I/O.** The validator takes a mapping
#       and returns a dict. No filesystem, no DB, no subprocess,
#       no time calls, no RNG. Same inputs → byte-identical output.
#     * **Cumulative violation reporting, not short-circuit.** The
#       validator keeps walking after the first violation whenever
#       it can still inspect subsequent layers safely, so a
#       single call surfaces every structural problem at once.
#       Short-circuit only happens when later checks literally
#       cannot run (e.g. ``additionalContext`` is not a string, so
#       line-level preamble parsing is impossible).
#     * **Extraction fields are best-effort.** ``workflow_id``,
#       ``stage_id``, and ``content_hash`` are extracted from the
#       preamble only when that specific line parses cleanly. If
#       the line is missing, malformed, or carries an empty value,
#       the extracted field is ``None`` and the violation list
#       explains why.
#     * **No new authority.** The validator references the
#       module-level constants
#       :data:`runtime.core.prompt_pack.PROMPT_PACK_PREAMBLE_TAG`
#       and
#       :data:`runtime.core.prompt_pack.SUBAGENT_START_HOOK_EVENT`
#       directly so the producer and validator cannot disagree
#       about either literal.
#     * **No edits to hook wiring.** This slice formalises the
#       response contract only.
#
#   Report shape (stable, pinned by tests):
#
#     .. code-block:: python
#
#         {
#             "status":          "ok" | "invalid",
#             "healthy":         bool,
#             "violations":      [str, ...],      # empty on ok
#             "workflow_id":     str | None,      # parsed from preamble
#             "stage_id":        str | None,
#             "content_hash":    str | None,
#             "body_line_count": int,             # lines after the blank separator
#         }
#
#   ``status`` is ``"ok"`` iff ``violations`` is empty. ``healthy``
#   mirrors the boolean equivalent so callers can branch on either
#   the string or the bool.
#
# ---------------------------------------------------------------------------


_WORKFLOW_ID_PREFIX = "workflow_id: "
_STAGE_ID_PREFIX = "stage_id: "
_CONTENT_HASH_PREFIX = "content_hash: "


def _build_envelope_report(
    violations: List[str],
    *,
    workflow_id: Optional[str],
    stage_id: Optional[str],
    content_hash: Optional[str],
    body_line_count: int,
) -> dict:
    """Assemble the stable SubagentStart envelope validation report."""
    healthy = not violations
    return {
        "status": VALIDATION_STATUS_OK if healthy else VALIDATION_STATUS_INVALID,
        "healthy": healthy,
        "violations": list(violations),
        "workflow_id": workflow_id,
        "stage_id": stage_id,
        "content_hash": content_hash,
        "body_line_count": body_line_count,
    }


def validate_subagent_start_envelope(envelope: Any) -> dict:
    """Validate a SubagentStart prompt-pack hook envelope.

    Accepts the exact dict shape produced by
    :func:`runtime.core.prompt_pack.build_subagent_start_envelope`
    and returns a stable report dict (see module docstring for
    the shape).

    Validation rules:

      1. Top-level must be a ``dict`` with exactly one key,
         ``"hookSpecificOutput"``.
      2. ``hookSpecificOutput`` must be a ``dict`` with exactly
         two keys: ``"hookEventName"`` and ``"additionalContext"``.
      3. ``hookEventName`` must equal
         :data:`runtime.core.prompt_pack.SUBAGENT_START_HOOK_EVENT`
         (``"SubagentStart"``).
      4. ``additionalContext`` must be a non-empty, non-whitespace-
         only string.
      5. The preamble must be exactly four lines in this order:

            line 0: :data:`PROMPT_PACK_PREAMBLE_TAG`
            line 1: ``"workflow_id: <non-empty>"``
            line 2: ``"stage_id: <non-empty>"``
            line 3: ``"content_hash: <non-empty>"``

      6. Line 4 must be an empty blank separator line.
      7. At least one non-whitespace body line must exist after
         the blank separator.

    The validator collects all applicable violations into the
    report rather than stopping at the first failure. Later checks
    that literally cannot run (e.g. preamble line parsing when
    ``additionalContext`` is not a string) are skipped, but
    earlier independent checks always report. The ``workflow_id``,
    ``stage_id``, and ``content_hash`` extraction fields are
    best-effort and set to ``None`` when the corresponding line is
    missing or malformed.

    The function is deterministic and has no side effects.
    """
    violations: List[str] = []
    workflow_id: Optional[str] = None
    stage_id: Optional[str] = None
    content_hash: Optional[str] = None
    body_line_count: int = 0

    # --- Top-level shape ------------------------------------------------
    if not isinstance(envelope, Mapping):
        violations.append(
            "envelope must be a mapping (dict); "
            f"got {type(envelope).__name__}"
        )
        return _build_envelope_report(
            violations,
            workflow_id=workflow_id,
            stage_id=stage_id,
            content_hash=content_hash,
            body_line_count=body_line_count,
        )

    top_keys = set(envelope.keys())
    if top_keys != {"hookSpecificOutput"}:
        violations.append(
            "envelope top-level keys must be exactly "
            "{'hookSpecificOutput'}; "
            f"got {sorted(top_keys)}"
        )
    inner = envelope.get("hookSpecificOutput")
    if not isinstance(inner, Mapping):
        violations.append(
            "hookSpecificOutput must be a mapping (dict); "
            f"got {type(inner).__name__}"
        )
        return _build_envelope_report(
            violations,
            workflow_id=workflow_id,
            stage_id=stage_id,
            content_hash=content_hash,
            body_line_count=body_line_count,
        )

    # --- Inner shape ----------------------------------------------------
    inner_keys = set(inner.keys())
    if inner_keys != {"hookEventName", "additionalContext"}:
        violations.append(
            "hookSpecificOutput keys must be exactly "
            "{'hookEventName', 'additionalContext'}; "
            f"got {sorted(inner_keys)}"
        )

    hook_event = inner.get("hookEventName")
    if hook_event != SUBAGENT_START_HOOK_EVENT:
        violations.append(
            f"hookEventName must be {SUBAGENT_START_HOOK_EVENT!r}; "
            f"got {hook_event!r}"
        )

    # --- additionalContext ---------------------------------------------
    context = inner.get("additionalContext")
    if not isinstance(context, str):
        violations.append(
            "additionalContext must be a string; "
            f"got {type(context).__name__}"
        )
        return _build_envelope_report(
            violations,
            workflow_id=workflow_id,
            stage_id=stage_id,
            content_hash=content_hash,
            body_line_count=body_line_count,
        )
    if not context:
        violations.append("additionalContext must be a non-empty string")
        return _build_envelope_report(
            violations,
            workflow_id=workflow_id,
            stage_id=stage_id,
            content_hash=content_hash,
            body_line_count=body_line_count,
        )
    if not context.strip():
        violations.append(
            "additionalContext must be a non-empty, non-whitespace-only string"
        )
        return _build_envelope_report(
            violations,
            workflow_id=workflow_id,
            stage_id=stage_id,
            content_hash=content_hash,
            body_line_count=body_line_count,
        )

    # --- Preamble + body -----------------------------------------------
    lines = context.split("\n")
    if len(lines) < 6:
        violations.append(
            "additionalContext must have at least 6 lines "
            "(tag, workflow_id, stage_id, content_hash, blank, body); "
            f"got {len(lines)}"
        )
        return _build_envelope_report(
            violations,
            workflow_id=workflow_id,
            stage_id=stage_id,
            content_hash=content_hash,
            body_line_count=body_line_count,
        )

    # Line 0: preamble tag
    if lines[0] != PROMPT_PACK_PREAMBLE_TAG:
        violations.append(
            f"additionalContext line 0 must be the preamble tag "
            f"{PROMPT_PACK_PREAMBLE_TAG!r}; got {lines[0]!r}"
        )

    # Line 1: workflow_id
    if not lines[1].startswith(_WORKFLOW_ID_PREFIX):
        violations.append(
            f"additionalContext line 1 must start with "
            f"{_WORKFLOW_ID_PREFIX!r}; got {lines[1]!r}"
        )
    else:
        value = lines[1][len(_WORKFLOW_ID_PREFIX):]
        if not value.strip():
            violations.append(
                "additionalContext workflow_id value is empty"
            )
        else:
            workflow_id = value

    # Line 2: stage_id
    if not lines[2].startswith(_STAGE_ID_PREFIX):
        violations.append(
            f"additionalContext line 2 must start with "
            f"{_STAGE_ID_PREFIX!r}; got {lines[2]!r}"
        )
    else:
        value = lines[2][len(_STAGE_ID_PREFIX):]
        if not value.strip():
            violations.append(
                "additionalContext stage_id value is empty"
            )
        else:
            stage_id = value

    # Line 3: content_hash
    if not lines[3].startswith(_CONTENT_HASH_PREFIX):
        violations.append(
            f"additionalContext line 3 must start with "
            f"{_CONTENT_HASH_PREFIX!r}; got {lines[3]!r}"
        )
    else:
        value = lines[3][len(_CONTENT_HASH_PREFIX):]
        if not value.strip():
            violations.append(
                "additionalContext content_hash value is empty"
            )
        else:
            content_hash = value

    # Line 4: blank separator
    if lines[4] != "":
        violations.append(
            "additionalContext line 4 must be a blank separator; "
            f"got {lines[4]!r}"
        )

    # Lines 5..: body. At least one non-whitespace body line must
    # exist. The split on "\n" of a body that ends with "\n" produces
    # a trailing empty element, so the body_line_count informational
    # field reflects the raw split count, but the "non-empty body"
    # check walks for at least one meaningful line.
    body_lines = lines[5:]
    body_line_count = len(body_lines)
    if not any(ln.strip() for ln in body_lines):
        violations.append(
            "additionalContext must have at least one non-whitespace "
            "body line after the blank separator"
        )

    return _build_envelope_report(
        violations,
        workflow_id=workflow_id,
        stage_id=stage_id,
        content_hash=content_hash,
        body_line_count=body_line_count,
    )


# ---------------------------------------------------------------------------
# SubagentStart prompt-pack request validator
#
# @decision DEC-CLAUDEX-PROMPT-PACK-REQUEST-VALIDATION-001
# Title: validate_subagent_start_prompt_pack_request is the single canonical
#        authority for the SubagentStart payload request contract
# Status: proposed (shadow-mode, Phase 2 prompt-pack request validation)
# Rationale: The compile_prompt_pack_for_stage Mode-B entry point accepts
#   (workflow_id, stage_id, goal_id, work_item_id, decision_scope,
#   generated_at) as the caller-light hook-adapter signature. Before a hook
#   adapter invokes that pipeline it must verify the incoming SubagentStart
#   payload actually carries those six fields with the correct types. This
#   validator is the pure boundary check: it accepts the decoded hook payload
#   mapping and returns a stable report that the adapter can key off.
#
#   Authority placement (single-authority rule):
#     This function is DEFINED HERE, in runtime.core.prompt_pack_validation,
#     as the single public authority.  runtime.core.prompt_pack uses a private
#     internal copy (_validate_subagent_start_request) inside
#     build_subagent_start_prompt_pack_response to avoid the circular import
#     that would result from prompt_pack importing prompt_pack_validation (which
#     itself imports from prompt_pack at module level).  Any change to the
#     contract must update BOTH this function and the matching private copy in
#     prompt_pack.py in the same bundle — they must stay behaviorally identical.
#
#   Pinned nested path: all six required contract fields live at the TOP LEVEL
#   of the payload mapping. The validator does not guess alternates.
#
#   Report shape (stable, pinned by tests):
#
#     .. code-block:: python
#
#         {
#             "status":         "ok" | "invalid",
#             "healthy":        bool,
#             "violations":     [str, ...],
#             "workflow_id":    str | None,
#             "stage_id":       str | None,
#             "goal_id":        str | None,
#             "work_item_id":   str | None,
#             "decision_scope": str | None,
#             "generated_at":   int | None,
#         }
#
# ---------------------------------------------------------------------------

#: Required non-empty-string fields in a SubagentStart prompt-pack request.
_REQUEST_STRING_FIELDS: Tuple[str, ...] = (
    "workflow_id",
    "stage_id",
    "goal_id",
    "work_item_id",
    "decision_scope",
)


def validate_subagent_start_prompt_pack_request(payload: object) -> dict:
    """Validate and extract the SubagentStart hook payload prompt-pack contract.

    Single public authority for SubagentStart request contract validation.
    Accepts the decoded hook payload mapping and returns a stable report dict.
    All six required contract fields are expected at the TOP LEVEL of
    ``payload``. Extra top-level keys are allowed.

    Validation rules:

      1. ``payload`` must be a mapping. Non-mapping is an immediate fatal
         violation — subsequent checks cannot run.
      2. ``workflow_id``, ``stage_id``, ``goal_id``, ``work_item_id``,
         ``decision_scope`` must each be a non-empty string.
      3. ``generated_at`` must be a non-bool ``int`` (``bool`` is excluded —
         ``isinstance(True, int)`` is true in Python but a boolean is not a
         valid epoch timestamp).
      4. Violations are accumulated across all six fields (cumulative).

    Returns the stable report dict. Pure function — no I/O, no side effects.
    """
    violations: List[str] = []
    extracted: dict = {field: None for field in _REQUEST_STRING_FIELDS}
    extracted["generated_at"] = None

    if not isinstance(payload, Mapping):
        violations.append(
            "payload must be a mapping (dict); "
            f"got {type(payload).__name__}"
        )
        return {
            "status": "invalid",
            "healthy": False,
            "violations": violations,
            **extracted,
        }

    for field in _REQUEST_STRING_FIELDS:
        if field not in payload:
            violations.append(
                f"required field {field!r} is missing from payload"
            )
            continue
        value = payload[field]
        if not isinstance(value, str):
            violations.append(
                f"{field!r} must be a non-empty string; "
                f"got {type(value).__name__}"
            )
            continue
        if not value.strip():
            violations.append(
                f"{field!r} must be a non-empty, non-whitespace-only string"
            )
            continue
        extracted[field] = value

    field = "generated_at"
    if field not in payload:
        violations.append(
            f"required field {field!r} is missing from payload"
        )
    else:
        value = payload[field]
        # Exclude bool: bool is a subclass of int in Python, but True/False
        # are not valid unix epoch timestamps.
        if isinstance(value, bool) or not isinstance(value, int):
            violations.append(
                f"{field!r} must be an int (unix epoch seconds); "
                f"got {type(value).__name__}"
            )
        else:
            extracted[field] = value

    healthy = not violations
    return {
        "status": "ok" if healthy else "invalid",
        "healthy": healthy,
        "violations": violations,
        **extracted,
    }


__all__ = [
    "VALIDATION_STATUS_OK",
    "VALIDATION_STATUS_DRIFT",
    "VALIDATION_STATUS_INVALID",
    "serialise_prompt_pack_metadata",
    "validate_prompt_pack",
    "validate_prompt_pack_metadata",
    "validate_subagent_start_envelope",
    "validate_subagent_start_prompt_pack_request",
]

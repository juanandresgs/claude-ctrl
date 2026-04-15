"""Pure hook-doc projection builder (shadow-only).

@decision DEC-CLAUDEX-HOOK-DOC-PROJECTION-001
Title: runtime/core/hook_doc_projection.py renders hook-doc projection content from the runtime hook manifest
Status: proposed (shadow-mode, Phase 2 — derived-surface validation bootstrap)
Rationale: CUTOVER_PLAN §Derived-Surface Validation (lines 1020-1024)
  requires ``settings.json``, ``hooks/HOOKS.md``, and other
  declarative surfaces to be generated from or validated against the
  runtime authority layer. §Projection Schemas §3 explicitly names
  "hook-doc projection" as a projection type, and
  ``runtime.core.projection_schemas.HookDocProjection`` already
  declares its typed shape (Phase 1 slice). This module is the pure
  builder that compiles the existing ``runtime.core.hook_manifest``
  authority into a ``HookDocProjection`` instance so later slices
  can either validate ``hooks/HOOKS.md`` against the projection or
  replace it with a generated surface.

  Scope discipline:

    * **Purely declarative.** This module renders the projection
      content to an in-memory string and returns a typed
      ``HookDocProjection`` record. It does NOT read from or write
      to ``hooks/HOOKS.md``. It does NOT touch any file on disk. It
      does NOT open a database connection, does NOT query any CLI,
      does NOT fork any subprocess.
    * **Pure function composition.** ``render_hook_doc`` and
      ``build_hook_doc_projection`` are deterministic: same input →
      same output. ``generated_at`` is a caller-supplied int so the
      builder stays reproducible in tests.
    * **No CLI wiring in this slice.** No
      ``cc-policy hook render-doc`` command, no writes. A future
      slice can add CLI exposure once the content and hash model
      are locked by tests.
    * **Zero live-module imports.** The module depends only on
      ``runtime.core.hook_manifest`` (authority input) and
      ``runtime.core.projection_schemas`` (typed output shape).
      AST tests pin this invariant.
    * **Deprecation visibility.** Deprecated manifest entries are
      surfaced with an inline ``[DEPRECATED]`` marker in the
      rendered output and are NOT silently folded into active rows,
      matching the same surface-it-distinctly policy that the
      ``validate_settings`` CLI uses for ``deprecated_still_wired``.

  Derived fields:

    * ``events`` — the set of event names that appear in the
      manifest, in **first-seen declaration order** so the
      projection preserves the authoring sequence.
    * ``matchers`` — the set of distinct **declared non-empty**
      matcher tokens, in first-seen declaration order. Empty-string
      matchers (harness-level "unconditional" entries such as
      ``SessionStart``, ``UserPromptSubmit``, ``Stop``) are
      deliberately filtered out because the Phase 1
      ``HookDocProjection`` schema pins
      ``matchers entries must be non-empty strings``. Their
      presence is instead encoded via the rendered body, which
      shows ``(unconditional)`` for empty matchers, and via the
      ``events`` tuple, which lists every event that fires
      regardless of matcher. This keeps the slice inside the
      Phase 1 schema contract without silently collapsing
      information about unconditional hooks.
    * ``content_hash`` — ``sha256:`` + hex digest of the UTF-8
      bytes of the rendered markdown body. Derived from the SAME
      string ``render_hook_doc`` produces, so the three fields
      cannot drift from the rendered content.
    * ``metadata.provenance`` — one :class:`SourceRef` per manifest
      entry so the projection carries full upstream identity.

  What this module deliberately does NOT do:

    * It does not compare the rendered content against the real
      ``hooks/HOOKS.md`` on disk. That is a future
      ``cc-policy hook doc-check`` slice, not this one.
    * It does not regenerate ``hooks/HOOKS.md``. Only a later slice
      with explicit user approval may modify that constitution-level
      file.
    * It does not watch for manifest changes at runtime. The
      ``StaleCondition`` it embeds is declarative — a future reflow
      engine will consume it.
"""

from __future__ import annotations

import hashlib
from typing import Dict, Iterable, List, Tuple

from runtime.core import hook_manifest as hm
from runtime.core.projection_schemas import (
    HookDocProjection,
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
HOOK_DOC_GENERATOR_VERSION: str = "1.0.0"

#: Default manifest version stamped into ``ProjectionMetadata``'s
#: ``source_versions`` and per-entry ``SourceRef``. The hook manifest
#: does not currently carry its own semver string; this constant keeps
#: the projection self-consistent until a manifest-level version is
#: introduced.
MANIFEST_VERSION: str = "1.0.0"

#: Marker text used to flag deprecated entries in the rendered body.
#: Extracted as a constant so tests can assert on it without coupling
#: to formatting details.
DEPRECATED_MARKER: str = "[DEPRECATED]"

#: Marker used for planned entries (none today, but reserved).
PLANNED_MARKER: str = "[PLANNED]"


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


def _unique_preserve_order(values: Iterable[str]) -> Tuple[str, ...]:
    """Return the distinct values from ``values`` in first-seen order."""
    seen: set[str] = set()
    out: List[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return tuple(out)


def _matcher_display(matcher: str) -> str:
    """Render a matcher string for the rendered body.

    Empty matchers (unconditional events) are displayed as
    ``(unconditional)`` so readers don't see a bare pair of
    backticks. Non-empty matchers are inlined verbatim.
    """
    return matcher if matcher else "(unconditional)"


def _status_marker(status: str) -> str:
    """Return an inline marker string for a non-active status, or ''."""
    if status == hm.STATUS_DEPRECATED:
        return f" **{DEPRECATED_MARKER}**"
    if status == hm.STATUS_PLANNED:
        return f" **{PLANNED_MARKER}**"
    return ""


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render_hook_doc(
    entries: Tuple[hm.HookManifestEntry, ...] | None = None,
) -> str:
    """Render the hook-doc projection body as markdown text.

    ``entries`` defaults to ``runtime.core.hook_manifest.HOOK_MANIFEST``
    when omitted; tests can pass a custom tuple to exercise edge
    cases without monkey-patching the module.

    Output shape:

      * H1 title + preamble paragraph
      * One H2 heading per event in first-seen declaration order
      * One bullet per manifest entry under its event, in the same
        declaration order
      * Each bullet is ``- matcher `<matcher>` → `<adapter_path>` [marker]``
        followed by a sub-bullet carrying the entry rationale
      * Deprecated entries get an inline ``**[DEPRECATED]**`` marker

    The function is pure: no filesystem I/O, no time calls, no
    mutation of the input tuple.
    """
    if entries is None:
        entries = hm.HOOK_MANIFEST

    # Group entries by event in first-seen order so the rendered
    # output preserves the authoring sequence.
    by_event: Dict[str, List[hm.HookManifestEntry]] = {}
    event_order: List[str] = []
    for entry in entries:
        if entry.event not in by_event:
            event_order.append(entry.event)
            by_event[entry.event] = []
        by_event[entry.event].append(entry)

    lines: List[str] = []
    lines.append("# ClauDEX Hook Adapter Manifest")
    lines.append("")
    lines.append(
        "This document is a derived projection of "
        "`runtime.core.hook_manifest.HOOK_MANIFEST` "
        "(CUTOVER_PLAN §Authority Map: `hook_wiring`)."
    )
    lines.append(
        "Do not hand-edit — regenerate from the runtime manifest via the "
        "projection builder in `runtime.core.hook_doc_projection`."
    )
    lines.append("")
    lines.append(f"Generator version: `{HOOK_DOC_GENERATOR_VERSION}`")
    lines.append("")

    for event in event_order:
        lines.append(f"## {event}")
        lines.append("")
        for entry in by_event[event]:
            matcher = _matcher_display(entry.matcher)
            marker = _status_marker(entry.status)
            lines.append(
                f"- matcher `{matcher}` → `{entry.adapter_path}`{marker}"
            )
            lines.append(f"  - _{entry.rationale}_")
        lines.append("")

    # Join + trailing newline so the rendered file ends cleanly.
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Projection builder
# ---------------------------------------------------------------------------


def _hash_content(content: str) -> str:
    """Return a stable, prefixed content hash for ``content``."""
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def _build_provenance(
    entries: Tuple[hm.HookManifestEntry, ...],
    manifest_version: str,
) -> Tuple[SourceRef, ...]:
    """Return a SourceRef per manifest entry.

    The ``source_id`` encodes the full entry identity as
    ``"<event>:<matcher>:<adapter_path>"`` so two different entries
    that share an event or matcher still resolve to distinct refs.
    An empty matcher produces an empty middle segment, which is
    still a valid non-empty string overall.
    """
    refs: List[SourceRef] = []
    for entry in entries:
        refs.append(
            SourceRef(
                source_kind="hook_wiring",
                source_id=f"{entry.event}:{entry.matcher}:{entry.adapter_path}",
                source_version=manifest_version,
            )
        )
    return tuple(refs)


def build_hook_doc_projection(
    *,
    generated_at: int,
    manifest_version: str = MANIFEST_VERSION,
) -> HookDocProjection:
    """Build a :class:`HookDocProjection` from the live runtime hook manifest.

    ``generated_at`` is required (and unix-epoch seconds) so callers
    decide the timestamp explicitly; this keeps the builder pure and
    deterministic — two calls with the same ``generated_at`` against
    an unchanged manifest produce byte-identical records.

    ``manifest_version`` defaults to :data:`MANIFEST_VERSION`. Tests
    override it to exercise provenance and stale-condition shape.

    The returned projection's ``events``, ``matchers``, and
    ``content_hash`` fields are all derived from the same rendered
    markdown body (via :func:`render_hook_doc`), so the three fields
    cannot drift from the emitted content.
    """
    entries = hm.HOOK_MANIFEST
    rendered = render_hook_doc(entries)

    events = _unique_preserve_order(entry.event for entry in entries)
    # Filter out empty-string matchers: the Phase 1 HookDocProjection
    # validator rejects empty strings in the ``matchers`` tuple. The
    # builder docstring above explains why we do not widen the Phase 1
    # schema here; instead, unconditional entries are represented by
    # their event name in the ``events`` tuple and by the
    # ``(unconditional)`` token in the rendered body.
    matchers = _unique_preserve_order(
        entry.matcher for entry in entries if entry.matcher
    )
    content_hash = _hash_content(rendered)

    stale_condition = StaleCondition(
        rationale=(
            "Regenerate the hook-doc projection when the runtime hook "
            "manifest changes, or when settings.json drifts from it. "
            "CUTOVER_PLAN §Derived-Surface Validation."
        ),
        watched_authorities=("hook_wiring",),
        # Deterministic order: source authority first, then derived
        # surfaces (settings.json drift and hooks/HOOKS.md projection).
        # runtime/core/hook_manifest.py is the realized source authority
        # backing this projection (promoted to constitution-level in
        # Phase 7 Slice 8); settings.json and hooks/HOOKS.md are the
        # derived surfaces whose drift is what this projection detects.
        # Phase 7 Slice 9 adds the source file so stale-condition
        # metadata names the *input* it depends on, not just its derived
        # outputs.
        watched_files=(
            "runtime/core/hook_manifest.py",
            "settings.json",
            "hooks/HOOKS.md",
        ),
    )

    provenance = _build_provenance(entries, manifest_version)

    metadata = ProjectionMetadata(
        generator_version=HOOK_DOC_GENERATOR_VERSION,
        generated_at=generated_at,
        stale_condition=stale_condition,
        source_versions=(("hook_wiring", manifest_version),),
        provenance=provenance,
    )

    return HookDocProjection(
        metadata=metadata,
        events=events,
        matchers=matchers,
        content_hash=content_hash,
    )


__all__ = [
    "HOOK_DOC_GENERATOR_VERSION",
    "MANIFEST_VERSION",
    "DEPRECATED_MARKER",
    "PLANNED_MARKER",
    "render_hook_doc",
    "build_hook_doc_projection",
]

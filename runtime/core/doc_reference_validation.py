"""Validate hook-surface references in markdown docs against HOOK_MANIFEST.

Closes CUTOVER_PLAN Invariant #8 ("Docs that claim harness behavior are
either generated, validated, or clearly marked as non-authoritative
reference") for the high-traffic docs that enumerate hook adapter files
and hook event matchers: ``MASTER_PLAN.md`` and ``AGENTS.md``.

Unlike ``hook_doc_projection`` / ``hook_doc_validation`` (which own
``hooks/HOOKS.md`` as a generated surface), this module is a one-way
*reference validator*: it does not generate markdown; it scans prose
for hook-surface reference patterns and diffs them against
``runtime.core.hook_manifest``.

Two reference kinds are validated:

1. **Adapter-path references** — any token matching ``hooks/<name>.sh``
   in the scanned text. Each must resolve to either:
     - an ``adapter_path`` in ``HOOK_MANIFEST`` (active, deprecated, or
       planned — any of the three declared states is accepted), OR
     - a file that exists on disk under ``<repo>/hooks/`` (a library
       helper sourced by other hooks but not itself wired in
       ``settings.json``; e.g. ``hooks/context-lib.sh``), OR
     - a documented retirement in ``RETIRED_ADAPTER_PATHS`` (e.g.
       ``hooks/auto-review.sh`` was retired in Phase 8 Slice 2 but
       legitimately appears in historical narrative in MASTER_PLAN.md).
   Ghost adapter names not in any of those three sets are caught as
   drift — they are either typos, hallucinations, or retirements that
   were never recorded in ``RETIRED_ADAPTER_PATHS``.

2. **Event-matcher references** — tokens matching ``<Event>:<matcher>``
   where the event is one of the harness event names and the matcher is
   a non-empty token. For each, the validator asserts:
     - event appears in at least one manifest entry (or retirement
       registry), AND
     - (event, matcher) resolves against the manifest: the matcher
       token is a member of some manifest entry's pipe-split matcher set
       for that event. An empty-matcher event (``SubagentStart:``) is
       accepted iff the manifest declares an empty-matcher entry for
       that event.
   Retired role matchers (``SubagentStop:tester``) and retired event
   names are caught via the retirement registry. **Unknown events are
   flagged as drift** — a doc inventing a new event name
   (``NeverHeardOf:planner``) must be caught.

   Known false-positive shapes are stripped before extraction to keep
   unknown-event detection meaningful:
     - ``*** (Update|Add|Delete) File:path`` — apply_patch markers.
   These specific non-event tokens are removed by
   ``_strip_known_non_event_shapes`` before the event regex runs; the
   extraction never sees them as candidate matches, so unknown-event
   detection retains full precision elsewhere.

The validator is deliberately strict on adapter paths and event-matcher
pairs, and lenient on everything else (prose narrative, code blocks in
other languages, etc.): anything that does not structurally look like a
hook-surface reference is ignored.

@decision DEC-DOC-REF-VALIDATION-001
@title Invariant #8 enforcement for hook-surface references in markdown docs
@status accepted
@rationale Phase 7 Slice 1 made ``hooks/HOOKS.md`` a derived projection
  of ``HOOK_MANIFEST``. ``MASTER_PLAN.md`` and ``AGENTS.md`` are the next
  highest-traffic docs that name hook adapter files and hook event
  matchers in prose. Without a mechanical cross-check, ghost references
  (from retired hooks or renamed events) accumulate silently. This
  module provides a pure-Python drift detector that reuses
  ``HOOK_MANIFEST`` as its sole vocabulary source; no second hook-name
  or event-name authority is introduced.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from runtime.core.hook_manifest import (
    HOOK_MANIFEST,
    HookManifestEntry,
    all_entries,
)


# ---------------------------------------------------------------------------
# Retirement registry — single authority for documented retirements
# ---------------------------------------------------------------------------
#
# Each entry is a ``hooks/<name>.sh`` path (or ``<Event>:<matcher>`` pair)
# that once existed but was deliberately retired in a phase slice. These
# references remain legitimate in historical narrative (MASTER_PLAN.md,
# retirement-closeout sections of CURRENT_STATE.md, etc.) and must not
# trigger drift alarms.
#
# Adding a new retirement: when retiring a hook, append its path to this
# set and record the retiring decision inline. The unit test
# ``test_retired_sets_have_retirement_decisions`` ensures each entry has a
# decision reference, so silent registry growth is caught.

RETIRED_ADAPTER_PATHS: frozenset[str] = frozenset(
    {
        # Phase 8 Slice 2 (2026-04-13) — MASTER_PLAN DEC-PHASE0-003 / P0-C.
        "hooks/auto-review.sh",
        # Phase 8 Slice 10 (2026-04-13) — tester retirement; check-tester
        # was the SubagentStop:tester adapter. DEC-PHASE8-SLICE10-001.
        "hooks/check-tester.sh",
        # PE-W3 (policy-engine consolidation) — guard.sh's 13 inline checks
        # were migrated to per-policy modules under runtime/core/policies/.
        # DEC-HOOK-004.
        "hooks/guard.sh",
    }
)

# Retired event-matcher pairs. Entries are ``(event, matcher)`` tuples.
RETIRED_EVENT_MATCHERS: frozenset[tuple[str, str]] = frozenset(
    {
        # Phase 8 Slice 3 (2026-04-13) — DEC-PHASE0-002. EnterWorktree is
        # not a documented Claude Code event; matcher was removed from
        # settings.json and hook_manifest.py.
        ("PreToolUse", "EnterWorktree"),
        # Phase 8 Slice 10 (2026-04-13) — tester role retirement.
        # SubagentStop:tester matcher was removed from settings.json and
        # hook_manifest.py when check-tester.sh was retired; the role
        # references remain legitimate in retirement narrative.
        ("SubagentStop", "tester"),
    }
)


# ---------------------------------------------------------------------------
# Extraction regexes
# ---------------------------------------------------------------------------

# Match adapter paths: ``hooks/<name>.sh`` with <name> of letters, digits,
# dashes, underscores, dots. Negative-lookahead on trailing identifier chars
# to avoid matching substrings inside longer paths like ``hooks/xxx.sh.bak``.
_ADAPTER_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])(hooks/[A-Za-z0-9_.-]+\.sh)(?![A-Za-z0-9_/])"
)

# Match event:matcher references. The event token must start with an
# uppercase letter (harness event names are PascalCase: PreToolUse,
# SubagentStop, etc.). The matcher token is backtick-delimited or bare
# word-boundary-delimited — both forms appear in the wild.
#
# We accept matcher tokens that contain '|' (alternation within a single
# manifest entry's matcher), '-' (e.g. ``dispatch-stall``), alphanumerics,
# and underscores.
_EVENT_MATCHER_RE = re.compile(
    r"(?<![A-Za-z0-9_])([A-Z][A-Za-z]+):([A-Za-z_][A-Za-z0-9_|-]*)(?![A-Za-z0-9_])"
)

# Known non-event token shapes that match ``[A-Z][A-Za-z]+:<ident>`` but
# are definitively not harness events. Stripped before event-regex
# extraction so unknown-event detection retains precision elsewhere.
#
# Each entry MUST have a documented non-event rationale. Do not add
# shapes for arbitrary unknown events — those must continue to fail as
# drift via the unknown-event branch of validate_doc_references.
_KNOWN_NON_EVENT_SHAPES: tuple[tuple[str, re.Pattern], ...] = (
    (
        # apply_patch markers: ``*** Update File:path``,
        # ``*** Add File:path``, ``*** Delete File:path``.
        "apply_patch_file_marker",
        re.compile(
            r"\*\*\*\s+(?:Update|Add|Delete)\s+File:\S*",
            flags=re.MULTILINE,
        ),
    ),
    (
        # Table-cell ``File:line`` header / column references.
        # ``File`` is not and has never been a Claude Code harness
        # event name (documented surface set: SessionStart,
        # UserPromptSubmit, WorktreeCreate, PreToolUse, PostToolUse,
        # Notification, SubagentStart, SubagentStop, PreCompact, Stop,
        # SessionEnd). Any ``File:<ident>`` shape is prose, not a hook
        # reference.
        "file_colon_prose",
        re.compile(r"\bFile:[A-Za-z_][A-Za-z0-9_|-]*"),
    ),
)


def _strip_known_non_event_shapes(text: str) -> str:
    """Remove token shapes that match the event regex but are not events.

    Currently strips two shapes (see ``_KNOWN_NON_EVENT_SHAPES``):
      - apply_patch ``*** Update|Add|Delete File:path`` markers
      - ``File:<ident>`` prose / table-cell references

    Each shape must be documented as a specific known non-event
    pattern. This is not a general denylist for unknown events — those
    must continue to fail as drift.
    """
    for _name, pattern in _KNOWN_NON_EVENT_SHAPES:
        text = pattern.sub("", text)
    return text


# ---------------------------------------------------------------------------
# Drift report
# ---------------------------------------------------------------------------


@dataclass
class DriftReport:
    """Structured report from ``validate_doc_references``.

    Fields:
        path: the scanned path (str form)
        references_checked: total references the validator inspected
            (adapter paths + event:matcher pairs)
        unknown_adapters: list of ``hooks/<name>.sh`` references that
            do not appear as any ``adapter_path`` in the manifest.
        unknown_events: list of event names (the event half of
            ``Event:matcher``) that do not appear in the manifest.
        unknown_matchers: list of ``(event, matcher)`` pairs where the
            event is known but the matcher is not a member of any
            manifest entry's pipe-split matcher set for that event.
        healthy: True iff all three unknown-* lists are empty.
    """

    path: str
    references_checked: int
    unknown_adapters: list[str] = field(default_factory=list)
    unknown_events: list[str] = field(default_factory=list)
    unknown_matchers: list[tuple[str, str]] = field(default_factory=list)

    @property
    def healthy(self) -> bool:
        return (
            not self.unknown_adapters
            and not self.unknown_events
            and not self.unknown_matchers
        )

    def as_dict(self) -> dict:
        """Return a JSON-serializable dict (matcher tuples become lists)."""
        return {
            "path": self.path,
            "references_checked": self.references_checked,
            "unknown_adapters": list(self.unknown_adapters),
            "unknown_events": list(self.unknown_events),
            "unknown_matchers": [[e, m] for (e, m) in self.unknown_matchers],
            "healthy": self.healthy,
        }


# ---------------------------------------------------------------------------
# Vocabulary (derived from HOOK_MANIFEST — no second authority)
# ---------------------------------------------------------------------------


def _known_adapter_paths(
    entries: Iterable[HookManifestEntry],
) -> set[str]:
    return {e.adapter_path for e in entries}


# Repo root anchor for on-disk hook-library lookups. Resolved relative to
# this module's location: runtime/core/doc_reference_validation.py → two
# parents up = repo root.
_REPO_ROOT = Path(__file__).resolve().parents[2]


def _on_disk_hook_files(repo_root: Path = _REPO_ROOT) -> set[str]:
    """Return the set of ``hooks/<name>.sh`` paths that exist on disk.

    Includes library helpers (e.g. ``hooks/context-lib.sh``) that are not
    wired in ``settings.json`` but are part of the hook-subsystem source
    tree and therefore legitimate references in prose.

    Resolved from the repo root rather than a hard-coded path so worktrees
    pick up their own sibling files correctly. Missing directory returns
    an empty set (validation still functions against the manifest alone).
    """
    hooks_dir = repo_root / "hooks"
    if not hooks_dir.is_dir():
        return set()
    found: set[str] = set()
    for p in hooks_dir.rglob("*.sh"):
        rel = p.relative_to(repo_root).as_posix()
        found.add(rel)
    return found


def _event_matcher_set(
    entries: Iterable[HookManifestEntry],
) -> dict[str, set[str]]:
    """Return ``{event: {matcher_alt, ...}}`` derived from manifest entries.

    Each manifest entry's ``matcher`` may be a pipe-separated list
    (``"planner|Plan"``); each alternative becomes an acceptable token.
    An empty matcher is represented as the empty string ``""`` in the
    set — this lets references with an explicit empty matcher still
    resolve without special-casing.
    """
    by_event: dict[str, set[str]] = {}
    for e in entries:
        bucket = by_event.setdefault(e.event, set())
        if e.matcher == "":
            bucket.add("")
        else:
            for part in e.matcher.split("|"):
                bucket.add(part)
    return by_event


# ---------------------------------------------------------------------------
# Extraction + validation
# ---------------------------------------------------------------------------


def _extract_adapter_paths(text: str) -> list[str]:
    return [m.group(1) for m in _ADAPTER_PATH_RE.finditer(text)]


def _extract_event_matcher_pairs(text: str) -> list[tuple[str, str]]:
    """Return ``[(event, matcher), ...]`` tokens from the text.

    Event-matcher pairs where the event is not a manifest-known event
    are returned unfiltered — the caller classifies them against the
    manifest vocabulary.

    Known non-event shapes (apply_patch ``*** Update File:path``
    markers) are stripped first so they never become candidate matches.
    """
    stripped = _strip_known_non_event_shapes(text)
    return [(m.group(1), m.group(2)) for m in _EVENT_MATCHER_RE.finditer(stripped)]


def validate_doc_references(text: str, path: str = "<inline>") -> DriftReport:
    """Scan ``text`` for hook-surface references and diff against the manifest.

    ``path`` is used only for reporting; the function does not read the
    filesystem.
    """
    entries = all_entries()
    known_adapters = _known_adapter_paths(entries)
    on_disk = _on_disk_hook_files()
    event_matchers = _event_matcher_set(entries)
    known_events = set(event_matchers.keys())

    adapter_refs = _extract_adapter_paths(text)
    event_matcher_refs = _extract_event_matcher_pairs(text)

    unknown_adapters: list[str] = []
    for adapter in adapter_refs:
        if (
            adapter not in known_adapters
            and adapter not in on_disk
            and adapter not in RETIRED_ADAPTER_PATHS
            and adapter not in unknown_adapters
        ):
            unknown_adapters.append(adapter)

    unknown_events: list[str] = []
    unknown_matchers: list[tuple[str, str]] = []
    # Events that belong to the retirement registry are also valid even if
    # they are not (or are no longer) in HOOK_MANIFEST.
    retired_events: set[str] = {e for (e, _) in RETIRED_EVENT_MATCHERS}
    valid_event_vocabulary = known_events | retired_events
    for event, matcher in event_matcher_refs:
        if (event, matcher) in RETIRED_EVENT_MATCHERS:
            # Documented retirement — historical narrative reference is
            # legitimate; do not flag as drift.
            continue
        if event not in valid_event_vocabulary:
            # Invented event name that is not in HOOK_MANIFEST and not
            # in the retirement registry. This IS drift — ghost events
            # must be caught (the apply_patch ``File:path`` shape is
            # stripped upstream in _strip_known_non_event_shapes so it
            # never reaches this branch).
            if event not in unknown_events:
                unknown_events.append(event)
            continue
        if event not in known_events:
            # Event is a retired-only event (appeared in RETIRED but
            # not in HOOK_MANIFEST). The specific (event, matcher) pair
            # didn't match above, so the matcher is unknown for this
            # retired event — flag as drift.
            pair = (event, matcher)
            if pair not in unknown_matchers:
                unknown_matchers.append(pair)
            continue
        bucket = event_matchers[event]
        # Accept the reference when the matcher token matches any known
        # alternative for that event. The manifest uses pipe-split sets
        # already expanded in event_matchers[event].
        if matcher in bucket:
            continue
        # Also accept when the matcher token is itself a pipe expression
        # whose every alternative appears in the known bucket (``planner|Plan``
        # references should validate even though the manifest stores them
        # as the same entry's ``|``-joined matcher string).
        parts = matcher.split("|") if "|" in matcher else [matcher]
        if all(part in bucket for part in parts):
            continue
        pair = (event, matcher)
        if pair not in unknown_matchers:
            unknown_matchers.append(pair)

    return DriftReport(
        path=path,
        references_checked=len(adapter_refs) + len(event_matcher_refs),
        unknown_adapters=unknown_adapters,
        unknown_events=unknown_events,
        unknown_matchers=unknown_matchers,
    )


def validate_doc_references_file(path: Path | str) -> DriftReport:
    """Read ``path`` and call :func:`validate_doc_references` on its text.

    The path must exist; callers that want to tolerate missing files
    should check beforehand. Binary files (non-UTF-8) are decoded
    leniently with ``errors="replace"``.
    """
    p = Path(path)
    text = p.read_text(encoding="utf-8", errors="replace")
    return validate_doc_references(text, path=str(p))

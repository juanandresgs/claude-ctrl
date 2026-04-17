"""ClauDEX runtime hook manifest authority (shadow-only).

@decision DEC-CLAUDEX-HOOK-MANIFEST-001
Title: runtime/core/hook_manifest.py is the sole declarative authority for the repo-local hook adapter surface
Status: proposed (shadow-mode, Phase 2 bootstrap)
Rationale: CUTOVER_PLAN §Phase 2 "Hook Adapter Reduction" requires the
  runtime to own the hook manifest so ``settings.json`` and
  ``hooks/HOOKS.md`` can be generated from or validated against it
  (§Derived-Surface Validation, lines 1020-1024; §Authority Map line
  515). Until this slice, the hook surface had no runtime-owned
  authority — ``settings.json`` was the de facto source of truth and
  drift between wiring and scripts could only be caught by reading
  bash.

  This module establishes the authority shape. It is **purely
  declarative**: no generator, no enforcement, no rewrite of
  ``settings.json``, no hook-path behavior change. A later Phase 2
  slice will add a validator that cross-checks ``settings.json``
  against this manifest and fails on drift; another slice will add a
  ``hooks/HOOKS.md`` projection schema consumer. Both depend on this
  slice existing first.

  Scope:

    * The manifest catalogs every repo-owned hook adapter that is
      currently wired in ``settings.json`` and backed by a tracked
      file under ``hooks/``.
    * Non-repo-owned entries are deliberately excluded: bare bash
      passthroughs such as ``{ cat; echo; } >> dispatch-debug.jsonl``
      and plugin-owned scripts such as
      ``node $HOME/.claude/plugins/marketplaces/openai-codex/.../
      stop-review-gate-hook.mjs`` are not part of the repo's hook
      adapter surface and are not this module's concern.
    * Phase 8 Slice 3 resolved the previously-deprecated block-worktree
      wiring (DEC-PHASE0-001, DEC-PHASE0-002, DEC-GUARD-WT-009):
        - ``WorktreeCreate`` → ``hooks/block-worktree-create.sh`` is
          **active** — it is a verified-live fail-closed safety adapter
          forcing all worktree creation through Guardian.
        - ``PreToolUse:EnterWorktree`` was removed entirely. Official
          Claude Code docs do not list ``EnterWorktree`` as a tool, and
          the JSONL capture window contains zero events matching that
          matcher; the wiring was unreachable and has been deleted from
          both ``settings.json`` and this manifest.
      No entries are currently marked ``deprecated``. The
      ``STATUS_DEPRECATED`` vocabulary entry is retained because a
      future slice may flag another entry for coordinated removal.
    * No ``planned`` entries are declared in this slice. The
      instruction explicitly forbids inventing future hook entries
      that do not correspond to current code or current CUTOVER_PLAN
      text, and no CUTOVER_PLAN-named future repo-owned hook lacks a
      current adapter today. The ``STATUS_PLANNED`` vocabulary entry
      exists for future slices that do introduce such hooks.

  Shadow-only discipline:

    * This module is not imported by ``dispatch_engine``,
      ``completions``, ``policy_engine``, ``cli.py``, or any hook
      script. AST tests pin that invariant.
    * The module depends only on the Python standard library —
      ``dataclasses``, ``pathlib.PurePosixPath``, and ``typing``. It
      does not import any other ``runtime.core`` module so the
      manifest stays consumable by future validators without pulling
      in the rest of the shadow kernel.
    * No side effects at import time: the manifest is a module-level
      tuple, not a builder function.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any, FrozenSet, List, Mapping, Optional, Tuple

# ---------------------------------------------------------------------------
# Status vocabulary
# ---------------------------------------------------------------------------

STATUS_ACTIVE: str = "active"
STATUS_DEPRECATED: str = "deprecated"
STATUS_PLANNED: str = "planned"

#: Closed set of legal entry statuses. Tests pin set equality so a
#: future slice cannot silently introduce a fourth status without
#: updating this vocabulary deliberately.
HOOK_ENTRY_STATUSES: FrozenSet[str] = frozenset(
    {STATUS_ACTIVE, STATUS_DEPRECATED, STATUS_PLANNED}
)


# ---------------------------------------------------------------------------
# Known hook events
#
# This is the vocabulary the manifest commits to. Anything outside
# this set is either unsupported (and should be rejected) or
# speculative (and should be resolved before wiring). The set is
# drawn from Claude Code's documented hook event surface.
# ``WorktreeCreate`` is a verified-live event (DEC-PHASE0-001) and
# anchors the active fail-closed worktree-safety adapter.
# ---------------------------------------------------------------------------

KNOWN_HOOK_EVENTS: FrozenSet[str] = frozenset(
    {
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "Stop",
        "SessionEnd",
        # Verified-live per DEC-PHASE0-001 — real Claude Code event
        # anchoring the active fail-closed worktree-safety adapter.
        "WorktreeCreate",
    }
)


# ---------------------------------------------------------------------------
# Entry shape
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class HookManifestEntry:
    """A single runtime-declared hook adapter entry.

    ``event`` is one of the strings in :data:`KNOWN_HOOK_EVENTS`.

    ``matcher`` is the harness matcher / selector. It is a string,
    possibly empty. For ``PreToolUse``/``PostToolUse`` it names the
    tool(s) using harness alternation syntax (``Write|Edit``,
    ``Bash``, ``Agent``). For ``SubagentStop`` it names the subagent
    role(s). For ``SessionStart`` it names the startup modes
    (``startup|resume|clear|compact``). For events that fire
    unconditionally (``UserPromptSubmit``, ``SubagentStart``,
    ``PreCompact``, ``Stop``, ``SessionEnd``, ``Notification`` in
    some modes, ``WorktreeCreate``) it is the empty string.

    ``adapter_path`` is a POSIX-style repo-relative path to the
    adapter script, always rooted at ``hooks/`` for repo-owned
    adapters. Constructor validation rejects absolute paths, parent
    traversal, and non-``hooks/`` prefixes.

    ``status`` is one of :data:`HOOK_ENTRY_STATUSES`. Currently wired
    entries (in ``settings.json`` today) are either ``active`` or
    ``deprecated``; ``planned`` is reserved for future slices that
    add entries not yet in ``settings.json``.

    ``rationale`` is a one-sentence explanation used by diagnostics
    and future validators. Tests assert it is non-empty.
    """

    event: str
    matcher: str
    adapter_path: str
    status: str
    rationale: str

    def __post_init__(self) -> None:
        if not isinstance(self.event, str) or not self.event:
            raise ValueError("HookManifestEntry.event must be a non-empty string")
        if self.event not in KNOWN_HOOK_EVENTS:
            raise ValueError(
                f"HookManifestEntry.event {self.event!r} is not in KNOWN_HOOK_EVENTS; "
                f"add it to the vocabulary deliberately if intended"
            )
        if not isinstance(self.matcher, str):
            raise ValueError(
                f"HookManifestEntry.matcher must be a string (possibly empty); "
                f"got {type(self.matcher).__name__}"
            )
        if not isinstance(self.status, str) or self.status not in HOOK_ENTRY_STATUSES:
            raise ValueError(
                f"HookManifestEntry.status {self.status!r} must be one of "
                f"{sorted(HOOK_ENTRY_STATUSES)}"
            )
        if not isinstance(self.rationale, str) or not self.rationale.strip():
            raise ValueError(
                "HookManifestEntry.rationale must be a non-empty string"
            )
        # adapter_path validation: non-empty POSIX path under hooks/.
        if not isinstance(self.adapter_path, str) or not self.adapter_path:
            raise ValueError(
                "HookManifestEntry.adapter_path must be a non-empty string"
            )
        if self.adapter_path.startswith("/"):
            raise ValueError(
                f"HookManifestEntry.adapter_path {self.adapter_path!r} must be "
                f"repo-relative, not absolute"
            )
        if ".." in self.adapter_path.split("/"):
            raise ValueError(
                f"HookManifestEntry.adapter_path {self.adapter_path!r} must not "
                f"contain parent-directory components"
            )
        # Canonicalise via PurePosixPath and require the stored string
        # to already be canonical — this prevents declaring the same
        # file as ``hooks/pre-bash.sh`` and ``hooks//pre-bash.sh``.
        canonical = str(PurePosixPath(self.adapter_path))
        if canonical != self.adapter_path:
            raise ValueError(
                f"HookManifestEntry.adapter_path {self.adapter_path!r} must be "
                f"in canonical POSIX form (expected {canonical!r})"
            )
        # Repo-owned adapters must live under ``hooks/``. This prevents
        # accidentally adding a plugin path or a runtime/ path to the
        # manifest.
        if not self.adapter_path.startswith("hooks/"):
            raise ValueError(
                f"HookManifestEntry.adapter_path {self.adapter_path!r} must be "
                f"rooted at 'hooks/' — the manifest only covers repo-owned adapters"
            )


# ---------------------------------------------------------------------------
# Manifest contents
#
# Grounded in ``settings.json`` as of the slice's landing. Every
# currently-wired repo-owned adapter is declared here exactly once per
# (event, matcher, adapter_path) triple. Non-repo-owned commands
# (bash passthroughs, plugin scripts) are deliberately excluded.
#
# Ordering matches the ``settings.json`` layout so a human reader can
# diff the two surfaces side-by-side.
# ---------------------------------------------------------------------------


def _e(
    event: str,
    matcher: str,
    adapter_path: str,
    status: str,
    rationale: str,
) -> HookManifestEntry:
    return HookManifestEntry(
        event=event,
        matcher=matcher,
        adapter_path=adapter_path,
        status=status,
        rationale=rationale,
    )


HOOK_MANIFEST: Tuple[HookManifestEntry, ...] = (
    # --- SessionStart ---------------------------------------------------
    _e(
        "SessionStart",
        "startup|resume|clear|compact",
        "hooks/session-init.sh",
        STATUS_ACTIVE,
        "Session bootstrap + context injection (CUTOVER_PLAN H3).",
    ),
    # --- UserPromptSubmit -----------------------------------------------
    _e(
        "UserPromptSubmit",
        "",
        "hooks/prompt-submit.sh",
        STATUS_ACTIVE,
        "Prompt preprocessing and context injection (CUTOVER_PLAN H3).",
    ),
    # --- WorktreeCreate (active fail-closed safety — DEC-PHASE0-001) ----
    _e(
        "WorktreeCreate",
        "",
        "hooks/block-worktree-create.sh",
        STATUS_ACTIVE,
        "Fail-closed worktree safety adapter (DEC-GUARD-WT-009, "
        "DEC-PHASE0-001). Denies harness-managed worktree creation so "
        "Guardian remains the sole worktree authority.",
    ),
    # --- PreToolUse -----------------------------------------------------
    _e(
        "PreToolUse",
        "Write|Edit",
        "hooks/test-gate.sh",
        STATUS_ACTIVE,
        "Pre-write test gate (part of the PostToolUse write pipeline — CUTOVER_PLAN P7).",
    ),
    _e(
        "PreToolUse",
        "Write|Edit",
        "hooks/mock-gate.sh",
        STATUS_ACTIVE,
        "Pre-write mock detector (CUTOVER_PLAN P7).",
    ),
    _e(
        "PreToolUse",
        "Write|Edit",
        "hooks/pre-write.sh",
        STATUS_ACTIVE,
        "Thin pre-write adapter — source WHO + workflow scope enforcement "
        "(CUTOVER_PLAN H1).",
    ),
    _e(
        "PreToolUse",
        "Write|Edit",
        "hooks/doc-gate.sh",
        STATUS_ACTIVE,
        "Docs-vs-code consistency gate (CUTOVER_PLAN P7).",
    ),
    _e(
        "PreToolUse",
        "Bash",
        "hooks/pre-bash.sh",
        STATUS_ACTIVE,
        "Thin pre-bash adapter — command-intent + git WHO enforcement "
        "(CUTOVER_PLAN H1).",
    ),
    _e(
        "PreToolUse",
        "Task",
        "hooks/pre-agent.sh",
        STATUS_ACTIVE,
        "Pre-agent guard for subagent isolation bypass (CUTOVER_PLAN H2).",
    ),
    _e(
        "PreToolUse",
        "Agent",
        "hooks/pre-agent.sh",
        STATUS_ACTIVE,
        "Pre-agent guard (Agent tool alias of Task) — CUTOVER_PLAN H2.",
    ),
    # --- PostToolUse ----------------------------------------------------
    _e(
        "PostToolUse",
        "Write|Edit",
        "hooks/lint.sh",
        STATUS_ACTIVE,
        "Post-write lint pipeline (CUTOVER_PLAN H4).",
    ),
    _e(
        "PostToolUse",
        "Write|Edit",
        "hooks/track.sh",
        STATUS_ACTIVE,
        "Post-write source-change tracking + readiness invalidation "
        "(CUTOVER_PLAN H4).",
    ),
    _e(
        "PostToolUse",
        "Write|Edit",
        "hooks/code-review.sh",
        STATUS_ACTIVE,
        "Advisory post-write code review (CUTOVER_PLAN H4, Partial).",
    ),
    _e(
        "PostToolUse",
        "Write|Edit",
        "hooks/plan-validate.sh",
        STATUS_ACTIVE,
        "Plan-scope validation on source writes (CUTOVER_PLAN H4).",
    ),
    _e(
        "PostToolUse",
        "Write|Edit",
        "hooks/test-runner.sh",
        STATUS_ACTIVE,
        "Post-write test runner (CUTOVER_PLAN H4 / P7).",
    ),
    _e(
        "PostToolUse",
        "Bash",
        "hooks/post-bash.sh",
        STATUS_ACTIVE,
        "Post-bash source-mutation readiness invalidation (Invariant #15, DEC-EVAL-006).",
    ),
    # --- Notification ---------------------------------------------------
    _e(
        "Notification",
        "permission_prompt|idle_prompt",
        "hooks/notify.sh",
        STATUS_ACTIVE,
        "User-facing notifications for permission and idle prompts "
        "(CUTOVER_PLAN O5 Later, currently active).",
    ),
    # --- SubagentStart --------------------------------------------------
    _e(
        "SubagentStart",
        "",
        "hooks/subagent-start.sh",
        STATUS_ACTIVE,
        "Subagent lifecycle marker + context injection (CUTOVER_PLAN H2 / H3).",
    ),
    # --- SubagentStop (per-role) ----------------------------------------
    _e(
        "SubagentStop",
        "planner|Plan",
        "hooks/check-planner.sh",
        STATUS_ACTIVE,
        "Planner completion assessment (CUTOVER_PLAN W1).",
    ),
    _e(
        "SubagentStop",
        "planner|Plan",
        "hooks/post-task.sh",
        STATUS_ACTIVE,
        "Thin post-task adapter — routes to dispatch_engine.process_agent_stop "
        "(DEC-DISPATCH-ENGINE-001).",
    ),
    _e(
        "SubagentStop",
        "implementer",
        "hooks/check-implementer.sh",
        STATUS_ACTIVE,
        "Implementer completion assessment (CUTOVER_PLAN W2).",
    ),
    _e(
        "SubagentStop",
        "implementer",
        "hooks/post-task.sh",
        STATUS_ACTIVE,
        "Thin post-task adapter for implementer stops.",
    ),
    _e(
        "SubagentStop",
        "guardian",
        "hooks/check-guardian.sh",
        STATUS_ACTIVE,
        "Guardian completion assessment (CUTOVER_PLAN W5 / W6).",
    ),
    _e(
        "SubagentStop",
        "guardian",
        "hooks/post-task.sh",
        STATUS_ACTIVE,
        "Thin post-task adapter for guardian stops.",
    ),
    _e(
        "SubagentStop",
        "reviewer",
        "hooks/check-reviewer.sh",
        STATUS_ACTIVE,
        "Phase 4 reviewer completion assessment — parses REVIEW_* trailers "
        "and submits structured completion record (DEC-CHECK-REVIEWER-001).",
    ),
    _e(
        "SubagentStop",
        "reviewer",
        "hooks/post-task.sh",
        STATUS_ACTIVE,
        "Thin post-task adapter for reviewer stops.",
    ),
    # --- PreCompact -----------------------------------------------------
    _e(
        "PreCompact",
        "",
        "hooks/compact-preserve.sh",
        STATUS_ACTIVE,
        "Context preservation before auto-compact.",
    ),
    # --- Stop -----------------------------------------------------------
    _e(
        "Stop",
        "",
        "hooks/surface.sh",
        STATUS_ACTIVE,
        "Surface diagnostics at turn end (CUTOVER_PLAN O2 read-only).",
    ),
    _e(
        "Stop",
        "",
        "hooks/session-summary.sh",
        STATUS_ACTIVE,
        "Stop-time summarization (CUTOVER_PLAN H5 Partial).",
    ),
    _e(
        "Stop",
        "",
        "hooks/forward-motion.sh",
        STATUS_ACTIVE,
        "Stop-time forward-motion hint (CUTOVER_PLAN H5 Partial).",
    ),
    # --- SessionEnd -----------------------------------------------------
    _e(
        "SessionEnd",
        "",
        "hooks/session-end.sh",
        STATUS_ACTIVE,
        "Session teardown diagnostics.",
    ),
)


# ---------------------------------------------------------------------------
# Pure lookup helpers
# ---------------------------------------------------------------------------


def all_entries() -> Tuple[HookManifestEntry, ...]:
    """Return every declared manifest entry (active + deprecated + planned)."""
    return HOOK_MANIFEST


def active_entries() -> Tuple[HookManifestEntry, ...]:
    """Return entries with ``status == STATUS_ACTIVE`` in declaration order."""
    return tuple(e for e in HOOK_MANIFEST if e.status == STATUS_ACTIVE)


def deprecated_entries() -> Tuple[HookManifestEntry, ...]:
    """Return entries with ``status == STATUS_DEPRECATED`` in declaration order."""
    return tuple(e for e in HOOK_MANIFEST if e.status == STATUS_DEPRECATED)


def planned_entries() -> Tuple[HookManifestEntry, ...]:
    """Return entries with ``status == STATUS_PLANNED`` in declaration order."""
    return tuple(e for e in HOOK_MANIFEST if e.status == STATUS_PLANNED)


def currently_wired_entries() -> Tuple[HookManifestEntry, ...]:
    """Return entries that ``settings.json`` is expected to carry right now.

    This is the union of ``active`` and ``deprecated`` — deprecated
    entries are still wired, just flagged for future removal.
    Planned entries are excluded because, by definition, they are not
    yet in ``settings.json``.
    """
    return tuple(
        e
        for e in HOOK_MANIFEST
        if e.status in (STATUS_ACTIVE, STATUS_DEPRECATED)
    )


def entries_for_event(event: str) -> Tuple[HookManifestEntry, ...]:
    """Return all manifest entries for ``event``, in declaration order.

    Returns an empty tuple for unknown events. Does not raise on bad
    input — it is a pure lookup.
    """
    if not isinstance(event, str):
        return ()
    return tuple(e for e in HOOK_MANIFEST if e.event == event)


def entries_for_adapter(adapter_path: str) -> Tuple[HookManifestEntry, ...]:
    """Return all manifest entries that reference ``adapter_path``.

    Match is exact on the POSIX repo-relative path. A single adapter
    may appear in multiple entries (e.g. ``hooks/post-task.sh`` runs
    under every SubagentStop matcher).
    """
    if not isinstance(adapter_path, str) or not adapter_path:
        return ()
    return tuple(e for e in HOOK_MANIFEST if e.adapter_path == adapter_path)


def adapter_paths(*, include_deprecated: bool = True) -> FrozenSet[str]:
    """Return the set of repo-relative adapter paths declared by the manifest.

    If ``include_deprecated`` is True (the default) the set covers
    every currently-wired entry. If False, only ``active`` entries
    contribute.
    """
    if include_deprecated:
        source = currently_wired_entries()
    else:
        source = active_entries()
    return frozenset(e.adapter_path for e in source)


def is_manifest_adapter(adapter_path: str) -> bool:
    """Return True iff ``adapter_path`` is declared by any currently-wired entry."""
    if not isinstance(adapter_path, str) or not adapter_path:
        return False
    return adapter_path in adapter_paths(include_deprecated=True)


def lookup(
    event: str, matcher: str, adapter_path: str
) -> Optional[HookManifestEntry]:
    """Return the entry matching ``(event, matcher, adapter_path)`` or ``None``.

    This is an exact-match lookup. The manifest's uniqueness invariant
    (pinned by tests) guarantees at most one match.
    """
    for entry in HOOK_MANIFEST:
        if (
            entry.event == event
            and entry.matcher == matcher
            and entry.adapter_path == adapter_path
        ):
            return entry
    return None


# ---------------------------------------------------------------------------
# settings.json parser (pure)
#
# The validator takes a parsed settings.json dict and asks "which
# repo-owned adapter commands are wired here?". Repo-owned means the
# command is a single invocation of ``$HOME/.claude/hooks/<script>``
# with no additional arguments — ``$HOME/.claude/hooks/`` is the
# symlinked view of the repo's ``hooks/`` directory. Bare bash
# passthroughs and plugin-owned scripts are deliberately excluded
# because they are not part of the repo's hook adapter surface and
# are not this module's concern.
# ---------------------------------------------------------------------------

_REPO_HOOKS_PREFIX: str = "$HOME/.claude/hooks/"


def extract_repo_owned_entries(
    settings: Mapping[str, Any],
) -> FrozenSet[Tuple[str, str, str]]:
    """Return the set of ``(event, matcher, adapter_path)`` triples from a settings dict.

    ``settings`` is a parsed ``settings.json`` mapping. Non-repo-owned
    commands (bash passthroughs such as ``{ cat; echo; } >> ...``
    and plugin scripts such as ``node $HOME/.claude/plugins/...``)
    are skipped.

    The function is pure: it does not read from the filesystem, does
    not mutate the input, and never raises on malformed shape — it
    simply skips entries that are not well-formed dicts.
    """
    result: set[Tuple[str, str, str]] = set()
    if not isinstance(settings, Mapping):
        return frozenset(result)
    hooks_block = settings.get("hooks")
    if not isinstance(hooks_block, Mapping):
        return frozenset(result)

    for event, matcher_entries in hooks_block.items():
        if not isinstance(event, str) or not isinstance(matcher_entries, list):
            continue
        for matcher_entry in matcher_entries:
            if not isinstance(matcher_entry, Mapping):
                continue
            matcher_raw = matcher_entry.get("matcher", "")
            matcher = matcher_raw if isinstance(matcher_raw, str) else ""
            hook_list = matcher_entry.get("hooks")
            if not isinstance(hook_list, list):
                continue
            for hook in hook_list:
                if not isinstance(hook, Mapping):
                    continue
                cmd_raw = hook.get("command", "")
                if not isinstance(cmd_raw, str):
                    continue
                cmd = cmd_raw.strip()
                if not cmd:
                    continue
                # Skip bare bash passthroughs and plugin scripts.
                if "{ cat; echo;" in cmd:
                    continue
                if "plugins/marketplaces" in cmd:
                    continue
                # Must be a single invocation of
                # ``$HOME/.claude/hooks/<script>`` with no arguments.
                if _REPO_HOOKS_PREFIX not in cmd:
                    continue
                idx = cmd.find(_REPO_HOOKS_PREFIX)
                # Anything non-whitespace before the prefix disqualifies
                # this entry (e.g. ``node $HOME/.claude/hooks/x.sh``
                # would be a node invocation, not a shell adapter).
                prefix_context = cmd[:idx].strip()
                if prefix_context:
                    continue
                tail = cmd[idx + len(_REPO_HOOKS_PREFIX) :].strip().strip("'\"")
                if not tail or " " in tail:
                    continue
                result.add((event, matcher, f"hooks/{tail}"))
    return frozenset(result)


# ---------------------------------------------------------------------------
# Drift validation (pure)
# ---------------------------------------------------------------------------

#: Status codes returned by :func:`validate_settings`. Stable contract:
#: the CLI exit code keys off these values.
VALIDATION_STATUS_OK: str = "ok"
VALIDATION_STATUS_OK_WITH_DEPRECATED: str = "ok_with_deprecated"
VALIDATION_STATUS_DRIFT: str = "drift"
VALIDATION_STATUS_INVALID: str = "invalid"

#: The two statuses that mean "no fatal drift / no invalid file"; the
#: CLI returns exit 0 for either.
HEALTHY_VALIDATION_STATUSES: FrozenSet[str] = frozenset(
    {VALIDATION_STATUS_OK, VALIDATION_STATUS_OK_WITH_DEPRECATED}
)


def _entry_to_dict(entry: HookManifestEntry) -> dict:
    return {
        "event": entry.event,
        "matcher": entry.matcher,
        "adapter_path": entry.adapter_path,
        "status": entry.status,
        "rationale": entry.rationale,
    }


def _triple_to_dict(triple: Tuple[str, str, str]) -> dict:
    event, matcher, adapter_path = triple
    return {
        "event": event,
        "matcher": matcher,
        "adapter_path": adapter_path,
    }


def validate_settings(
    settings: Mapping[str, Any],
    *,
    missing_files: Tuple[str, ...] = (),
) -> dict:
    """Pure drift comparison between a settings dict and the manifest.

    Parameters:

      * ``settings`` — parsed ``settings.json`` mapping. Never
        mutated. May have a missing / non-mapping ``hooks`` block;
        the function treats that as "zero repo-owned entries".
      * ``missing_files`` — optional tuple of repo-relative adapter
        paths that the caller has already determined to be missing
        on disk. Kept as a parameter rather than a filesystem walk
        so the helper stays pure; the CLI layer owns the I/O.

    Returns a JSON-serialisable dict with these stable keys:

      * ``status`` (one of ``ok`` / ``ok_with_deprecated`` / ``drift``
        / ``invalid``)
      * ``healthy`` (bool — True iff status is ``ok`` or
        ``ok_with_deprecated``)
      * ``settings_repo_entry_count`` (int)
      * ``manifest_wired_entry_count`` (int)
      * ``missing_in_manifest`` (list of {event,matcher,adapter_path})
      * ``missing_in_settings`` (list of manifest entry dicts)
      * ``deprecated_still_wired`` (list of manifest entry dicts)
      * ``invalid_adapter_files`` (list of repo-relative path strings)

    Status computation:

      * ``invalid`` — any entry in ``missing_files`` (overrides all
        other categories; an invalid file is the most severe drift).
      * ``drift`` — ``missing_in_manifest`` or ``missing_in_settings``
        non-empty (and no invalid files).
      * ``ok_with_deprecated`` — no drift and no invalid files, but
        ``deprecated_still_wired`` is non-empty. Distinct from ``ok``
        so a human reader can see the deprecation surface without CI
        failing on it.
      * ``ok`` — none of the above. Every active entry is wired, no
        deprecated entries remain in settings.json, no invalid files.

    The CLI wrapper maps ``healthy=True`` to exit code 0 and
    ``healthy=False`` to exit code 1.
    """
    settings_triples = extract_repo_owned_entries(settings)

    manifest_wired: List[HookManifestEntry] = list(currently_wired_entries())
    manifest_triples = {
        (e.event, e.matcher, e.adapter_path) for e in manifest_wired
    }

    # Drift: settings has it, manifest doesn't.
    missing_in_manifest_triples = sorted(settings_triples - manifest_triples)
    # Drift: manifest has it, settings doesn't.
    missing_in_settings_triples = sorted(manifest_triples - settings_triples)
    # Deprecated entries still wired: intersection of settings ∩ manifest
    # restricted to manifest entries with status == STATUS_DEPRECATED.
    deprecated_lookup = {
        (e.event, e.matcher, e.adapter_path): e
        for e in manifest_wired
        if e.status == STATUS_DEPRECATED
    }
    deprecated_still_wired_triples = sorted(
        t for t in settings_triples if t in deprecated_lookup
    )

    # Map drift triples back to full manifest dicts where possible so
    # the report carries rationale / status for missing_in_settings
    # entries.
    wired_index = {
        (e.event, e.matcher, e.adapter_path): e for e in manifest_wired
    }

    missing_in_manifest = [_triple_to_dict(t) for t in missing_in_manifest_triples]
    missing_in_settings = [
        _entry_to_dict(wired_index[t]) for t in missing_in_settings_triples
    ]
    deprecated_still_wired = [
        _entry_to_dict(deprecated_lookup[t]) for t in deprecated_still_wired_triples
    ]

    invalid_adapter_files = sorted(missing_files)

    # Status computation — order matters.
    if invalid_adapter_files:
        status = VALIDATION_STATUS_INVALID
    elif missing_in_manifest or missing_in_settings:
        status = VALIDATION_STATUS_DRIFT
    elif deprecated_still_wired:
        status = VALIDATION_STATUS_OK_WITH_DEPRECATED
    else:
        status = VALIDATION_STATUS_OK

    return {
        "status": status,
        "healthy": status in HEALTHY_VALIDATION_STATUSES,
        "settings_repo_entry_count": len(settings_triples),
        "manifest_wired_entry_count": len(manifest_triples),
        "missing_in_manifest": missing_in_manifest,
        "missing_in_settings": missing_in_settings,
        "deprecated_still_wired": deprecated_still_wired,
        "invalid_adapter_files": list(invalid_adapter_files),
    }


__all__ = [
    # Status vocabulary
    "STATUS_ACTIVE",
    "STATUS_DEPRECATED",
    "STATUS_PLANNED",
    "HOOK_ENTRY_STATUSES",
    # Event vocabulary
    "KNOWN_HOOK_EVENTS",
    # Entry shape
    "HookManifestEntry",
    # Manifest data
    "HOOK_MANIFEST",
    # Pure helpers
    "all_entries",
    "active_entries",
    "deprecated_entries",
    "planned_entries",
    "currently_wired_entries",
    "entries_for_event",
    "entries_for_adapter",
    "adapter_paths",
    "is_manifest_adapter",
    "lookup",
    # Validation
    "VALIDATION_STATUS_OK",
    "VALIDATION_STATUS_OK_WITH_DEPRECATED",
    "VALIDATION_STATUS_DRIFT",
    "VALIDATION_STATUS_INVALID",
    "HEALTHY_VALIDATION_STATUSES",
    "extract_repo_owned_entries",
    "validate_settings",
]

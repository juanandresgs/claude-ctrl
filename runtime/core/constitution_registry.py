"""ClauDEX constitution-level file registry (shadow-only).

@decision DEC-CLAUDEX-CONSTITUTION-REGISTRY-001
Title: runtime/core/constitution_registry.py is the sole declarative registry of constitution-level files and planned areas for the Phase 1 kernel
Status: proposed (shadow-mode, Phase 1 constitutional kernel)
Rationale: The control plane requires an explicit, mechanically checkable
  declaration of which files and areas are constitution-level. The Phase 1
  exit criterion "constitution-level files are enumerated and validated"
  can only be satisfied by a closed list that lives in runtime-owned code,
  not in prose.

  This module is that closed list. It is intentionally pure and
  declarative:

    * No SQLite. No filesystem writes. No subprocess. No imports of
      live policy / routing / hooks / settings code.
    * The concrete-file set is the closed runtime-owned list pinned by
      tests, so any later slice that tries to widen or narrow the list
      must update this module and its invariant coverage in the same
      bundle.
    * Planned areas are represented as explicitly NON-concrete
      entries with no filesystem path. As of Phase 7 Slice 17 the
      planned-area set is empty: every previously named planned
      area has been promoted to a concrete entry. Previously
      planned areas that have been promoted to concrete entries:
        - prompt-pack compiler → ``runtime/core/prompt_pack.py``
          (Phase 2)
        - stage-registry/capability-authority →
          ``runtime/core/stage_registry.py`` and
          ``runtime/core/authority_registry.py`` (Phase 7 Slice 3)
        - decision/work registry →
          ``runtime/core/decision_work_registry.py``
          (Phase 7 Slice 4)
        - projection validators →
          ``runtime/core/projection_schemas.py``,
          ``runtime/core/hook_doc_projection.py``,
          ``runtime/core/hook_doc_validation.py``,
          ``runtime/core/prompt_pack_validation.py``
          (Phase 7 Slice 5)
        - hook manifest authority →
          ``runtime/core/hook_manifest.py`` (Phase 7 Slice 8)
        - prompt-pack layer composition authority →
          ``runtime/core/prompt_pack_resolver.py`` (Phase 7 Slice 10)
        - decision-digest projection generator →
          ``runtime/core/decision_digest_projection.py``
          (Phase 7 Slice 13)
        - projection reflow staleness planner →
          ``runtime/core/projection_reflow.py`` (Phase 7 Slice 16)
        - memory/retrieval projection compiler →
          ``runtime/core/memory_retrieval.py`` (Phase 7 Slice 17;
          last remaining planned area)
      Promoted entries cannot be mistaken for planned areas by any
      helper.

  Live consumers:

    * ``runtime/core/policies/write_plan_guard.py`` imports
      ``is_constitution_level`` and ``normalize_repo_path`` to deny
      writes to constitution-level files from actors lacking
      ``CAN_WRITE_GOVERNANCE`` (Phase 7 Slice 6).

  What this module does NOT do:

    * It does not decide who may edit a constitution-level file — that
      decision is made by the policy engine's ``plan_guard`` policy,
      which reads this registry.
    * It does not enforce anything at hook time directly. Enforcement
      flows through the policy engine evaluation path.
    * It does not read constitution-level file contents. The registry
      only stores repo-relative path identifiers and the planned-area
      descriptors.
    * It does not mutate the filesystem. ``path_exists`` is a pure
      read-only helper intended for test invariants, not enforcement.

  Public contract:

    * ``ConstitutionEntry``: frozen dataclass with ``name``, ``kind``
      ("concrete" | "planned"), ``path`` (Optional[str], POSIX-style
      repo-relative, present iff kind == "concrete"), and
      ``rationale`` describing why the entry is constitution-level.
    * ``CONSTITUTION_REGISTRY``: tuple of all entries in declaration
      order (concrete first, then planned).
    * ``CONCRETE_PATHS``: frozenset of the concrete paths for O(1)
      membership testing.
    * ``CONCRETE_ENTRY_NAMES``, ``PLANNED_AREA_NAMES``: frozensets of
      entry names for each kind.
    * ``normalize_repo_path(candidate)``: pure POSIX normalization
      that rejects absolute paths, rejects ``..`` escapes, strips a
      leading ``./``, and normalises separator characters. Returns
      the normalised string on success or ``None`` on rejection.
    * ``is_constitution_level(candidate)``: returns True iff
      ``normalize_repo_path(candidate)`` matches a concrete entry
      path. Planned areas have no path and never match.
    * ``lookup(name)``: returns the ``ConstitutionEntry`` with the
      given ``name``, or ``None``.
    * ``concrete_entries()`` / ``planned_areas()``: return the
      ``ConstitutionEntry`` tuples filtered by kind.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import FrozenSet, Optional, Tuple

# ---------------------------------------------------------------------------
# Entry kinds
# ---------------------------------------------------------------------------

KIND_CONCRETE: str = "concrete"
KIND_PLANNED: str = "planned"

#: Legal kind strings. Test assertions pin set equality so a future
#: slice cannot silently add a third kind.
ENTRY_KINDS: FrozenSet[str] = frozenset({KIND_CONCRETE, KIND_PLANNED})


# ---------------------------------------------------------------------------
# Entry dataclass
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ConstitutionEntry:
    """A single constitution-level file or planned area.

    ``name`` is the canonical identifier used by lookup helpers and by
    any future ``cc-policy constitution list`` CLI. For concrete files
    it is the POSIX-style repo-relative path (e.g. ``runtime/cli.py``);
    for planned areas it is a short stable slug (e.g.
    ``decision_work_registry``).

    ``kind`` is either ``KIND_CONCRETE`` or ``KIND_PLANNED``.

    ``path`` is the POSIX-style repo-relative path for concrete
    entries and ``None`` for planned areas. This is the field helpers
    key off when deciding whether a filesystem path is
    constitution-level.

    ``rationale`` is a one-sentence explanation of why the entry is
    constitution-level. It is informational — tests do not pin the exact
    string.
    """

    name: str
    kind: str
    path: Optional[str]
    rationale: str

    def __post_init__(self) -> None:
        if self.kind not in ENTRY_KINDS:
            raise ValueError(
                f"unknown constitution entry kind {self.kind!r}; "
                f"valid: {sorted(ENTRY_KINDS)}"
            )
        if self.kind == KIND_CONCRETE:
            if not self.path:
                raise ValueError(
                    f"concrete constitution entry {self.name!r} must carry a path"
                )
            # Concrete paths are stored normalised so direct frozenset
            # membership works for is_constitution_level().
            if self.path != _static_normalise(self.path):
                raise ValueError(
                    f"concrete constitution entry {self.name!r} path "
                    f"{self.path!r} is not in canonical POSIX form"
                )
        elif self.kind == KIND_PLANNED and self.path is not None:
            raise ValueError(
                f"planned constitution area {self.name!r} must not have a "
                f"concrete path; got {self.path!r}"
            )


def _static_normalise(path: str) -> str:
    """Pure normalisation used to validate declared concrete paths.

    Keeps the registry constructor honest so a later slice cannot
    declare the same file under two different spellings
    (e.g. ``runtime/cli.py`` vs ``./runtime/cli.py``).
    """
    return str(PurePosixPath(path.replace("\\", "/")))


# ---------------------------------------------------------------------------
# Registry contents
#
# The concrete list below is a closed authority surface. Do NOT reorder,
# add, or remove entries without updating the set-equality test in
# tests/runtime/test_constitution_registry.py.
# ---------------------------------------------------------------------------

_CONCRETE: Tuple[ConstitutionEntry, ...] = (
    ConstitutionEntry(
        name="CLAUDE.md",
        kind=KIND_CONCRETE,
        path="CLAUDE.md",
        rationale=(
            "Canonical Claude-facing doctrine: identity, dispatch rules, "
            "sacred practices. Changes here reshape every agent's working "
            "context."
        ),
    ),
    ConstitutionEntry(
        name="AGENTS.md",
        kind=KIND_CONCRETE,
        path="AGENTS.md",
        rationale=(
            "Role contracts for every stage in the dispatch graph. Edits "
            "ripple through planner/implementer/reviewer/guardian behaviour."
        ),
    ),
    ConstitutionEntry(
        name="settings.json",
        kind=KIND_CONCRETE,
        path="settings.json",
        rationale=(
            "Harness hook wiring and policy-engine entrypoints. A single "
            "wrong line can disable the control plane."
        ),
    ),
    ConstitutionEntry(
        name="MASTER_PLAN.md",
        kind=KIND_CONCRETE,
        path="MASTER_PLAN.md",
        rationale=(
            "Living project record of decisions and workflows. Replaced "
            "by the canonical decision/work registry at end state but "
            "still load-bearing during Phase 1."
        ),
    ),
    ConstitutionEntry(
        name="hooks/HOOKS.md",
        kind=KIND_CONCRETE,
        path="hooks/HOOKS.md",
        rationale=(
            "Repo-local hook behaviour documentation. Must stay aligned "
            "with runtime hook manifest and official harness docs."
        ),
    ),
    ConstitutionEntry(
        name="runtime/cli.py",
        kind=KIND_CONCRETE,
        path="runtime/cli.py",
        rationale=(
            "Sole external entry point into the runtime (cc-policy). "
            "Argparse + JSON + dispatch to domain handlers; edits change "
            "every scripted consumer's contract."
        ),
    ),
    ConstitutionEntry(
        name="runtime/schemas.py",
        kind=KIND_CONCRETE,
        path="runtime/schemas.py",
        rationale=(
            "Canonical SQLite DDL and status vocabularies. Changes here "
            "require schema migration planning across every runtime module."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/dispatch_engine.py",
        kind=KIND_CONCRETE,
        path="runtime/core/dispatch_engine.py",
        rationale=(
            "Authoritative live dispatch state machine. Changes here "
            "affect every SubagentStop routing decision in production."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/completions.py",
        kind=KIND_CONCRETE,
        path="runtime/core/completions.py",
        rationale=(
            "Live routing table via determine_next_role() plus role "
            "completion validation schemas. Sole authority for live "
            "(role, verdict) -> next_role transitions."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/policy_engine.py",
        kind=KIND_CONCRETE,
        path="runtime/core/policy_engine.py",
        rationale=(
            "Live policy evaluation authority — the heart of enforcement. "
            "Changes here reshape permission boundaries for every tool call."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/prompt_pack.py",
        kind=KIND_CONCRETE,
        path="runtime/core/prompt_pack.py",
        rationale=(
            "Runtime-compiled prompt-pack bootstrap compiler. Promoted from the "
            "`prompt_pack_compiler_modules` planned area in the Phase 2 "
            "prompt-pack bootstrap slice once the module landed as a "
            "pure shadow-kernel authority for the six canonical prompt "
            "layers."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/stage_registry.py",
        kind=KIND_CONCRETE,
        path="runtime/core/stage_registry.py",
        rationale=(
            "Target workflow graph authority — canonical stage definitions "
            "and transition edges. Promoted from the "
            "`stage_registry_capability_authority_modules` planned area in "
            "Phase 7 Slice 3 once the module was realized and test-backed."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/authority_registry.py",
        kind=KIND_CONCRETE,
        path="runtime/core/authority_registry.py",
        rationale=(
            "Capability-gate authority — maps roles to explicit capability "
            "sets that policy keys off. Promoted from the "
            "`stage_registry_capability_authority_modules` planned area in "
            "Phase 7 Slice 3 once the module was realized and test-backed."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/decision_work_registry.py",
        kind=KIND_CONCRETE,
        path="runtime/core/decision_work_registry.py",
        rationale=(
            "Canonical decision, goal, and work-item authority — owns "
            "DecisionRecord/GoalRecord/WorkItemRecord schemas and the "
            "Phase 6 goal-continuation budget/status surface. Promoted "
            "from the `decision_work_registry_modules` planned area in "
            "Phase 7 Slice 4 once the module was realized and load-bearing."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/projection_schemas.py",
        kind=KIND_CONCRETE,
        path="runtime/core/projection_schemas.py",
        rationale=(
            "Projection schema family and metadata/stale-condition shape "
            "authority. Defines the canonical schema contracts for all "
            "projection validators. Promoted from the "
            "`projection_reflow_engine_modules` planned area in Phase 7 "
            "Slice 5."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/hook_doc_projection.py",
        kind=KIND_CONCRETE,
        path="runtime/core/hook_doc_projection.py",
        rationale=(
            "Hook-doc projection renderer/builder — sole authority for "
            "generating hooks/HOOKS.md from the hook manifest. Promoted "
            "from the `projection_reflow_engine_modules` planned area in "
            "Phase 7 Slice 5."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/hook_doc_validation.py",
        kind=KIND_CONCRETE,
        path="runtime/core/hook_doc_validation.py",
        rationale=(
            "Hook-doc drift validator used by `cc-policy hook doc-check`. "
            "Promoted from the `projection_reflow_engine_modules` planned "
            "area in Phase 7 Slice 5."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/prompt_pack_validation.py",
        kind=KIND_CONCRETE,
        path="runtime/core/prompt_pack_validation.py",
        rationale=(
            "Prompt-pack drift validator used by `cc-policy prompt-pack "
            "check` and SubagentStart request validation authority. "
            "Promoted from the `projection_reflow_engine_modules` planned "
            "area in Phase 7 Slice 5."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/hook_manifest.py",
        kind=KIND_CONCRETE,
        path="runtime/core/hook_manifest.py",
        rationale=(
            "Runtime-owned hook manifest authority — the source of truth "
            "backing settings.json hook-wiring validation and the "
            "hooks/HOOKS.md projection. Added as concrete in Phase 7 "
            "Slice 8 to close the one-authority model: its derived "
            "consumers (hook_doc_projection, hook_doc_validation) and "
            "derived surfaces (settings.json, hooks/HOOKS.md) are already "
            "constitution-level."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/prompt_pack_resolver.py",
        kind=KIND_CONCRETE,
        path="runtime/core/prompt_pack_resolver.py",
        rationale=(
            "Canonical prompt-pack layer composition authority — composes "
            "the six canonical prompt-pack layers, renders the constitution "
            "layer from constitution_registry.CONCRETE_PATHS, renders stage "
            "contracts from stage_registry, and backs the `prompt-pack "
            "compile` CLI path. Added as concrete in Phase 7 Slice 10 to "
            "close the one-authority gap: `runtime/core/prompt_pack.py` "
            "(bootstrap compiler) was already constitution-level, but the "
            "realized layer-composition authority that produces compiled "
            "guidance was not, so derived guidance could change without "
            "the write-scope gate and constitution CLI seeing the source."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/decision_digest_projection.py",
        kind=KIND_CONCRETE,
        path="runtime/core/decision_digest_projection.py",
        rationale=(
            "Canonical decision-digest projection generator — pure builder "
            "that renders a decision-digest markdown body and constructs a "
            "DecisionDigest projection from caller-supplied DecisionRecord "
            "sequences drawn from runtime/core/decision_work_registry.py. "
            "Added as concrete in Phase 7 Slice 13 so the generator that "
            "turns canonical decision records into a derived digest surface "
            "is itself constitution-level, matching the already-concrete "
            "source authority (decision_work_registry) and the projection "
            "schema contract (projection_schemas)."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/projection_reflow.py",
        kind=KIND_CONCRETE,
        path="runtime/core/projection_reflow.py",
        rationale=(
            "Pure projection reflow staleness planner — single runtime "
            "authority that answers, for a given projection metadata and a "
            "set of changed authorities/files, whether the projection is "
            "stale and which watched entries triggered it. Promoted from "
            "the `projection_reflow_orchestrator_module` planned area in "
            "Phase 7 Slice 16 as the first minimal reflow enforcement "
            "primitive (no daemon, no scheduler, no CLI — those remain "
            "future wrapping layers that will build on this authority)."
        ),
    ),
    ConstitutionEntry(
        name="runtime/core/memory_retrieval.py",
        kind=KIND_CONCRETE,
        path="runtime/core/memory_retrieval.py",
        rationale=(
            "Pure memory/retrieval projection compiler — single runtime "
            "authority that compiles deterministic SearchIndexMetadata and "
            "GraphExport projections from caller-supplied canonical "
            "MemorySource and GraphEdge records. Promoted from the "
            "`memory_retrieval_compiler_modules` planned area in Phase 7 "
            "Slice 17 as the canonical memory with derived retrieval "
            "authority (no search engine, no vector DB, "
            "no CLI — those remain future wrapping layers that will build "
            "on this compiler)."
        ),
    ),
)


# Planned areas that do not yet resolve to concrete files on disk are
# represented here as explicitly non-concrete entries so helpers never
# confuse them with existing paths, and so a future slice can enumerate
# them when planning new authority modules.
_PLANNED: Tuple[ConstitutionEntry, ...] = (
    # Phase 7 Slice 17 reached the empty-planned-set milestone:
    # every previously named planned area has been promoted to a
    # concrete entry above. The previous planned slugs and their
    # promotions are recorded here as inline comments so a future
    # slice cannot accidentally re-add one.
    #
    # * ``decision_work_registry_modules`` → concrete
    #   ``runtime/core/decision_work_registry.py`` (Phase 7 Slice 4).
    # * ``prompt_pack_compiler_modules`` → concrete
    #   ``runtime/core/prompt_pack.py`` (Phase 2 prompt-pack bootstrap).
    # * ``projection_reflow_engine_modules`` was split in Phase 7
    #   Slice 5: realized validators (``projection_schemas``,
    #   ``hook_doc_projection``, ``hook_doc_validation``,
    #   ``prompt_pack_validation``) promoted to concrete; the reflow
    #   orchestration layer itself promoted to concrete
    #   (``runtime/core/projection_reflow.py``) in Phase 7 Slice 16.
    # * ``projection_reflow_orchestrator_module`` → concrete
    #   ``runtime/core/projection_reflow.py`` (Phase 7 Slice 16).
    # * ``memory_retrieval_compiler_modules`` → concrete
    #   ``runtime/core/memory_retrieval.py`` (Phase 7 Slice 17).
    # * ``stage_registry_capability_authority_modules`` → concrete
    #   ``runtime/core/stage_registry.py`` +
    #   ``runtime/core/authority_registry.py`` (Phase 7 Slice 3).
    #
    # Do not re-add any of the above slugs here — the concrete entries
    # in ``_CONCRETE`` are the sole live owners of those authorities.
)


CONSTITUTION_REGISTRY: Tuple[ConstitutionEntry, ...] = _CONCRETE + _PLANNED

#: Frozenset of concrete repo-relative paths (POSIX form) for O(1)
#: membership checks in ``is_constitution_level``.
CONCRETE_PATHS: FrozenSet[str] = frozenset(
    entry.path for entry in _CONCRETE if entry.path is not None
)

#: Frozenset of concrete entry names (identical to CONCRETE_PATHS in
#: practice, but exposed separately so tests can key off the name
#: vocabulary without assuming name == path).
CONCRETE_ENTRY_NAMES: FrozenSet[str] = frozenset(
    entry.name for entry in _CONCRETE
)

PLANNED_AREA_NAMES: FrozenSet[str] = frozenset(
    entry.name for entry in _PLANNED
)


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


def normalize_repo_path(candidate: object) -> Optional[str]:
    """Normalise an arbitrary input to a POSIX-style repo-relative path.

    Rules (deterministic, pure):

      * ``None``, non-strings, and empty strings return ``None``.
      * Backslashes are converted to forward slashes so Windows-style
        inputs normalise consistently.
      * A single leading ``./`` is stripped.
      * Absolute paths (leading ``/`` or Windows drive letter) return
        ``None`` — constitution-level identity is always repo-relative.
      * Paths containing any ``..`` component return ``None`` — we do
        not resolve parents, and we refuse to treat path-traversal
        inputs as in-scope.
      * Multi-slash runs collapse to a single slash (via PurePosixPath).
      * A trailing slash is stripped except for the root (which is
        rejected above).

    Returns the normalised string on success, ``None`` on any form of
    rejection. Never raises.
    """
    if not isinstance(candidate, str):
        return None
    if not candidate:
        return None

    # Unify separators so a Windows-style input lands in POSIX space.
    unified = candidate.replace("\\", "/")

    # Reject absolute POSIX and Windows-drive-letter paths.
    if unified.startswith("/"):
        return None
    if len(unified) >= 2 and unified[1] == ":":
        return None

    # Strip a single leading ``./`` to normalise ``./foo`` == ``foo``.
    if unified.startswith("./"):
        unified = unified[2:]
    elif unified == ".":
        return None

    if not unified:
        return None

    # Reject any parent-directory component. PurePosixPath normalises
    # ``a//b`` -> ``a/b`` but does not collapse ``..``; we check parts
    # directly before and after normalisation to be safe.
    pre_parts = unified.split("/")
    if any(part == ".." for part in pre_parts):
        return None

    normalised = PurePosixPath(unified)
    parts = normalised.parts
    if any(part == ".." for part in parts):
        return None
    if not parts:
        return None

    return str(normalised)


def is_constitution_level(candidate: object) -> bool:
    """Return True iff ``candidate`` resolves to a concrete constitution file.

    Planned areas have no path and therefore never match. Unknown,
    malformed, absolute, or parent-traversal inputs return False.
    """
    normalised = normalize_repo_path(candidate)
    if normalised is None:
        return False
    return normalised in CONCRETE_PATHS


def lookup(name: str) -> Optional[ConstitutionEntry]:
    """Return the entry matching ``name`` (concrete or planned), or ``None``."""
    for entry in CONSTITUTION_REGISTRY:
        if entry.name == name:
            return entry
    return None


def concrete_entries() -> Tuple[ConstitutionEntry, ...]:
    """Return the concrete constitution entries in declaration order."""
    return _CONCRETE


def planned_areas() -> Tuple[ConstitutionEntry, ...]:
    """Return the planned (non-concrete) constitution areas in declaration order."""
    return _PLANNED


def all_concrete_paths() -> Tuple[str, ...]:
    """Return the concrete repo-relative paths in declaration order."""
    return tuple(entry.path for entry in _CONCRETE if entry.path is not None)


__all__ = [
    # Kinds
    "KIND_CONCRETE",
    "KIND_PLANNED",
    "ENTRY_KINDS",
    # Entry
    "ConstitutionEntry",
    # Registry data
    "CONSTITUTION_REGISTRY",
    "CONCRETE_PATHS",
    "CONCRETE_ENTRY_NAMES",
    "PLANNED_AREA_NAMES",
    # Helpers
    "normalize_repo_path",
    "is_constitution_level",
    "lookup",
    "concrete_entries",
    "planned_areas",
    "all_concrete_paths",
]

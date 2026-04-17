"""Invariants that pin the lane-local handoff-artifact path authority.

Active operator surfaces (Codex prompts and ClauDEX operator docs) must
name lane-local artifact paths under ``$CLAUDEX_STATE_DIR`` and must
not reintroduce pre-fix repo-global ``.claude/claudex/`` phrasing as
active instructions. Two sibling artifacts are governed:

- ``$CLAUDEX_STATE_DIR/pending-review.json`` (primary handoff artifact;
  every governed surface owns authority for this one).
- ``$CLAUDEX_STATE_DIR/relay-prompt-recovery.state.json`` (secondary
  recovery artifact; surfaces that mention it at all must use the
  lane-local form).

Historical references inside ``## Open Soak Issues`` sections are
intentionally preserved and are excluded from active-region checks.

Rationale: repo-global vs lane-local handoff-path drift is a recurring
class of documentation drift (see SUPERVISOR_HANDOFF.md Open Soak
Issues). This guard makes re-introduction detectable in CI rather than
relying on reviewer memory.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

# Active operator surfaces governed by this invariant.
SURFACES: tuple[Path, ...] = (
    REPO_ROOT / ".codex" / "prompts" / "claudex_handoff.txt",
    REPO_ROOT / ".codex" / "prompts" / "claudex_supervisor.txt",
    REPO_ROOT / "ClauDEX" / "SUPERVISOR_HANDOFF.md",
    REPO_ROOT / "ClauDEX" / "OVERNIGHT_RUNBOOK.md",
)


@dataclass(frozen=True)
class Artifact:
    """A lane-local handoff artifact governed by this invariant."""

    basename: str
    lane_local_token: str
    repo_global_path: str
    # True: every governed surface must include the lane-local token.
    # False: surfaces that mention the basename at all must also
    #   include the lane-local token (conditional presence).
    required_on_every_surface: bool


ARTIFACTS: tuple[Artifact, ...] = (
    Artifact(
        basename="pending-review.json",
        lane_local_token="$CLAUDEX_STATE_DIR/pending-review.json",
        repo_global_path=".claude/claudex/pending-review.json",
        required_on_every_surface=True,
    ),
    Artifact(
        basename="relay-prompt-recovery.state.json",
        lane_local_token="$CLAUDEX_STATE_DIR/relay-prompt-recovery.state.json",
        repo_global_path=".claude/claudex/relay-prompt-recovery.state.json",
        required_on_every_surface=False,
    ),
)

# Markdown surfaces split their content at ``## Open Soak Issues``.
# Everything under that heading (up to the next top-level ``## ``
# heading) is historical and is excluded from active-region checks.
HISTORICAL_SECTION_HEADING = "## Open Soak Issues"

# Words/phrases (case-insensitive) that, when they appear in the ~60
# characters before a repo-global path reference in an active region,
# mark the reference as an intentional negated anchor rather than an
# active instruction.
NEGATION_MARKERS: tuple[str, ...] = (
    "repo-global",
    "never",
    "do not",
    "not the",
    "must not",
    "instead of",
)

# Pre-fix active-instruction phrasings. If any of these reappears in an
# active region, it is a direct regression. This list is
# intentionally pending-review-only: the pre-fix relay-prompt-recovery
# guidance never had canonical phrasings outside historical Open Soak
# Issues quotes, so only the bare-repo-global rejection check guards
# that artifact.
LEGACY_ACTIVE_PHRASES: tuple[str, ...] = (
    # claudex_handoff.txt pre-fix declaration:
    "The active bridge handoff artifact is `.claude/claudex/pending-review.json`.",
    # claudex_supervisor.txt step 3 pre-fix bullet:
    "- `.claude/claudex/pending-review.json` is absent",
    # claudex_supervisor.txt step 4 pre-fix opener:
    "read `.claude/claudex/pending-review.json` when present",
    # OVERNIGHT_RUNBOOK pre-fix recovery-artifact line (whitespace-normalised
    # form, to stay robust against line-wrap changes):
    "recovery artifact is `.claude/claudex/pending-review.json`",
)


def _active_region(path: Path) -> str:
    """Return the file text with the ``## Open Soak Issues`` section
    stripped out. For files without that heading, the full text is
    returned.
    """
    text = path.read_text()
    if HISTORICAL_SECTION_HEADING not in text:
        return text
    pre, rest = text.split(HISTORICAL_SECTION_HEADING, 1)
    next_section = re.search(r"\n## (?!#)", rest)
    if next_section is None:
        return pre
    return pre + rest[next_section.start():]


def _has_negation_context(text: str, occurrence_start: int, window: int = 60) -> bool:
    pre = text[max(0, occurrence_start - window):occurrence_start].lower()
    return any(marker in pre for marker in NEGATION_MARKERS)


def _normalised(text: str) -> str:
    """Collapse whitespace so the legacy-phrase check is robust against
    line-wrap differences.
    """
    return re.sub(r"\s+", " ", text)


def _basename_mentioned(active: str, artifact: Artifact) -> bool:
    """True if the active region mentions the artifact basename at all,
    under any path prefix (repo-global, lane-local, or bare).
    """
    return artifact.basename in active


def test_active_surfaces_include_lane_local_handoff_artifact_guidance() -> None:
    """For each governed artifact, every surface that is required to own
    authority for it must include the lane-local token. For conditional
    artifacts, any surface that mentions the basename at all must also
    include the lane-local token.
    """
    missing: list[str] = []
    for surface in SURFACES:
        active = _active_region(surface)
        surface_label = str(surface.relative_to(REPO_ROOT))
        for artifact in ARTIFACTS:
            if artifact.lane_local_token in active:
                continue
            if artifact.required_on_every_surface:
                missing.append(
                    f"{surface_label}: missing required lane-local token "
                    f"{artifact.lane_local_token!r}"
                )
            elif _basename_mentioned(active, artifact):
                missing.append(
                    f"{surface_label}: mentions {artifact.basename!r} but is "
                    f"missing lane-local token {artifact.lane_local_token!r}"
                )
    assert not missing, (
        "Active surfaces missing lane-local handoff-artifact guidance:\n"
        + "\n".join(missing)
    )


def test_active_surfaces_reject_bare_repo_global_path_references() -> None:
    """In the active region of each surface, every occurrence of any
    governed artifact's repo-global path must be preceded (within a
    short window) by a negation marker. A bare reference is the
    signature of a regressed active instruction.
    """
    violations: list[str] = []
    for surface in SURFACES:
        active = _active_region(surface)
        surface_label = str(surface.relative_to(REPO_ROOT))
        for artifact in ARTIFACTS:
            for match in re.finditer(re.escape(artifact.repo_global_path), active):
                if _has_negation_context(active, match.start()):
                    continue
                snippet_start = max(0, match.start() - 60)
                snippet_end = min(len(active), match.end() + 40)
                snippet = active[snippet_start:snippet_end].replace("\n", " ")
                violations.append(
                    f"{surface_label} [artifact={artifact.basename}, "
                    f"offset={match.start()}]: ...{snippet}..."
                )
    assert not violations, (
        "Bare repo-global handoff-artifact references found in active "
        "instruction regions (no negation context within 60 chars):\n"
        + "\n".join(violations)
    )


def test_legacy_pre_fix_active_phrases_are_absent() -> None:
    """Named pre-fix phrasings must not reappear in any active region.
    Whitespace is normalised so this check is robust against reflow.
    """
    hits: list[str] = []
    for surface in SURFACES:
        active_normalised = _normalised(_active_region(surface))
        for phrase in LEGACY_ACTIVE_PHRASES:
            if _normalised(phrase) in active_normalised:
                hits.append(
                    f"{surface.relative_to(REPO_ROOT)}: legacy phrase "
                    f"resurfaced: {phrase!r}"
                )
    assert not hits, (
        "Pre-fix active-instruction phrasings found:\n" + "\n".join(hits)
    )

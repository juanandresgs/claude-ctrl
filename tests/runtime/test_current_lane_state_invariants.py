"""Mechanical pin for current-lane state-authority claims in ClauDEX docs.

@decision DEC-CLAUDEX-CURRENT-LANE-STATE-INVARIANT-001
Title: Current-lane state-authority docs must reflect the 23-file cc-policy-who-remediation staged checkpoint debt
Status: proposed
Rationale: `ClauDEX/CURRENT_STATE.md` and `ClauDEX/SUPERVISOR_HANDOFF.md`
  are the two declared lane-state authorities for the active cc-policy-who-
  remediation cutover slice. Earlier session turns surfaced a recurring drift
  class where these docs silently fell behind the real staged checkpoint
  count (19 → 21 → 22 → 23 as the bundle grew), leaving current-lane banners
  contradicted by installed git truth. This scanner test fails if either
  doc's current-lane section drops below the 23-file truth, or if a stale
  22-count claim reappears in an active region without an explicit
  historical/intermediate context marker.

  The test is a static scanner: no SQLite, no git subprocess, no network.
  It reads the two files and applies three invariants:

  - **Current-truth banner pins** — the current-lane banner in each doc
    must contain the dated "2026-04-17" anchor AND the literal token
    "23-file" (CURRENT_STATE.md) or "23-file staged checkpoint debt"
    (SUPERVISOR_HANDOFF.md).

  - **Active-region 22-count guard** — any occurrence of `22-file` /
    `22 files` / `22 staged` / `22 paths` in the "active" region of
    either doc (see `_ACTIVE_REGION_SECTION_DELIMITERS` below) must
    appear in a context that marks it as historical/intermediate: a
    nearby (same-paragraph) token from the allowed-historical-marker
    set must be present. A bare `22-file` current-lane claim fails.

  - **Sanity pin** — the scanner finds ≥ 1 `23-file` marker in each doc
    (catches a scanner regression that returns empty sets).

  A positive fixture (synthetic stale doc) and negative fixture (synthetic
  current-truth doc) prove the scanner's rules catch regression and accept
  clean state respectively.

Adjacent authorities:
  - ``ClauDEX/CURRENT_STATE.md`` top-of-file "Status (current, 2026-04-17)"
    banner — primary current-truth anchor.
  - ``ClauDEX/SUPERVISOR_HANDOFF.md`` "## Current Lane Truth (2026-04-17)"
    section — supervisor-facing current-truth anchor.
  - Related pins:
    ``tests/runtime/test_handoff_artifact_path_invariants.py`` (lane-local
    artifact-path authority) and
    ``tests/runtime/policies/test_command_intent_single_authority.py``
    (Invariant #5 command-semantics authority) use the same AST/regex
    scan pattern.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import List, Tuple

import pytest


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]

CURRENT_STATE_DOC = _REPO_ROOT / "ClauDEX" / "CURRENT_STATE.md"
SUPERVISOR_HANDOFF_DOC = _REPO_ROOT / "ClauDEX" / "SUPERVISOR_HANDOFF.md"

# The canonical current-lane checkpoint size.  If the cc-policy-who-
# remediation staged bundle legitimately grows, a follow-on slice MUST
# update both this constant and the docs in the same change. 2026-04-17
# growth path: 19 → 21 → 22 → 23 → 24 → 25 → 27 → 28 (CUTOVER_PLAN
# phase-closure invariant pin added at 28).
_CURRENT_STAGED_COUNT = 28
_CURRENT_STAGED_TOKEN = f"{_CURRENT_STAGED_COUNT}-file"

# Date anchor required near the current-lane banners.
_CURRENT_LANE_DATE_ANCHOR = "2026-04-17"

# Stale-count tokens we detect.  Any of these in an active region without
# a historical context marker is a regression. Covers the three most
# recent intermediate sizes (22, 23, and 24) — a bare "22-file" /
# "23-file" / "24-file" claim in current-lane wording while the lane is
# at 25 files is stale.
_STALE_STAGED_COUNT_PATTERNS: Tuple[str, ...] = (
    r"\b22-file\b",
    r"\b22 files\b",
    r"\b22 staged\b",
    r"\b22 paths\b",
    r"\b23-file\b",
    r"\b23 files\b",
    r"\b23 staged\b",
    r"\b23 paths\b",
    r"\b24-file\b",
    r"\b24 files\b",
    r"\b24 staged\b",
    r"\b24 paths\b",
    r"\b25-file\b",
    r"\b25 files\b",
    r"\b25 staged\b",
    r"\b25 paths\b",
    r"\b27-file\b",
    r"\b27 files\b",
    r"\b27 staged\b",
    r"\b27 paths\b",
)

# Context markers (case-insensitive, checked in a character window around the
# match) that make a `22-file` occurrence acceptable as historical/intermediate
# prose rather than a current-truth claim.
_HISTORICAL_CONTEXT_TOKENS: Tuple[str, ...] = (
    "historical",
    "at the time of",
    "at the time",
    "prior to",
    "grew to 23",
    "subsequently grew",
    "became 22",
    "intermediate",
    "turn sequence",
    "growth path",
    "19 \u2192 21 \u2192 22 \u2192 23",            # arrow-sequence marker (pre-24)
    "19 \u2192 21 \u2192 22 \u2192 23 \u2192 24",       # arrow-sequence marker (pre-25)
    "19 \u2192 21 \u2192 22 \u2192 23 \u2192 24 \u2192 25",       # arrow-sequence marker (pre-27)
    "19 \u2192 21 \u2192 22 \u2192 23 \u2192 24 \u2192 25 \u2192 27",       # arrow-sequence marker (pre-28)
    "19 \u2192 21 \u2192 22 \u2192 23 \u2192 24 \u2192 25 \u2192 27 \u2192 28",  # arrow-sequence marker (current)
    "19 -> 21 -> 22 -> 23",                                  # ascii-arrow variant (pre-24)
    "19 -> 21 -> 22 -> 23 -> 24",                            # ascii-arrow variant (pre-25)
    "19 -> 21 -> 22 -> 23 -> 24 -> 25",                      # ascii-arrow variant (pre-27)
    "19 -> 21 -> 22 -> 23 -> 24 -> 25 -> 27",                # ascii-arrow variant (pre-28)
    "19 -> 21 -> 22 -> 23 -> 24 -> 25 -> 27 -> 28",          # ascii-arrow variant (current)
    "grew to 24",
    "bundle grew to 24",
    "grew to 25",
    "bundle grew to 25",
    "grew to 27",
    "bundle grew to 27",
    "grew to 28",
    "bundle grew to 28",
)

_HISTORICAL_CONTEXT_WINDOW = 400  # unused fallback; see _has_historical_context_near

# Active-region delimiters are doc-specific. `## Open Soak Issues` is NOT a
# global cutoff: in `SUPERVISOR_HANDOFF.md` the Open Soak Issues heading sits
# near the top of the file, and many later sections (including
# `## Current Restart Slice`, `## Tonight's Priority Order`, `## Steady-State
# Behavior`, `## Checkpoint Stewardship`, `## Canonical Prompt Files`) are
# current-lane content that the scanner MUST cover. The only historical
# bucket in that file is `## Historical Phase State Snapshot (as of
# 2026-04-14)` and everything under it.
#
# In `CURRENT_STATE.md` the historical bucket is `## Checkpoint Readiness
# (Phase 8 Slice 12 closeout, 2026-04-14) — HISTORICAL SNAPSHOT` and
# everything under it.
#
# Keyed per basename so `_split_active_region_for` can pick the right cutoff.
_ACTIVE_REGION_DELIMITERS_BY_DOC: dict[str, Tuple[str, ...]] = {
    "CURRENT_STATE.md": (
        "## Checkpoint Readiness (Phase 8 Slice 12 closeout, 2026-04-14)",
    ),
    "SUPERVISOR_HANDOFF.md": (
        "## Historical Phase State Snapshot",
    ),
}

# Fallback delimiter set for any doc not explicitly keyed above — used by
# the synthetic-fixture tests.  Kept permissive.
_ACTIVE_REGION_DELIMITERS_DEFAULT: Tuple[str, ...] = (
    "## Historical Phase State Snapshot",
    "## Checkpoint Readiness (Phase 8 Slice 12 closeout, 2026-04-14)",
)


# ---------------------------------------------------------------------------
# Scanner helpers
# ---------------------------------------------------------------------------


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _split_active_region_for(
    text: str,
    delimiters: Tuple[str, ...],
) -> str:
    """Return the active-region prefix of ``text``: everything before the
    first **line-anchored** occurrence of any delimiter in ``delimiters``.
    A delimiter matches only when it appears at the start of a line (i.e.,
    preceded by start-of-text or a newline). This prevents prose that
    contains the literal delimiter string from falsely truncating the
    active region.

    If no delimiter is found, the full text is considered active.
    """
    earliest = len(text)
    for delim in delimiters:
        # Require line-start anchoring so prose mentions don't trigger.
        if text.startswith(delim):
            earliest = min(earliest, 0)
            continue
        anchored = "\n" + delim
        idx = text.find(anchored)
        if idx != -1:
            # Position of the delimiter heading (after the newline).
            idx = idx + 1
            if idx < earliest:
                earliest = idx
    return text[:earliest]


def _active_region_for_path(path: Path, text: str) -> str:
    """Doc-aware active-region split.  Dispatches on the basename."""
    delimiters = _ACTIVE_REGION_DELIMITERS_BY_DOC.get(
        path.name, _ACTIVE_REGION_DELIMITERS_DEFAULT
    )
    return _split_active_region_for(text, delimiters)


def _split_active_region(text: str) -> str:
    """Back-compat wrapper for synthetic fixtures that don't have a path.
    Uses the permissive default delimiter set.
    """
    return _split_active_region_for(text, _ACTIVE_REGION_DELIMITERS_DEFAULT)


def _has_historical_context_near(text: str, match_start: int) -> bool:
    """True if any `_HISTORICAL_CONTEXT_TOKENS` token appears in the SAME
    paragraph as the match. Paragraph boundaries are blank lines
    (``\\n\\n``). Keeping the check paragraph-scoped prevents a stale
    current-lane claim from being exonerated by unrelated historical
    narrative elsewhere in the doc.
    """
    # Find enclosing paragraph.
    para_start = text.rfind("\n\n", 0, match_start)
    para_start = 0 if para_start == -1 else para_start + 2
    para_end = text.find("\n\n", match_start)
    if para_end == -1:
        para_end = len(text)
    paragraph = text[para_start:para_end].lower()
    return any(token.lower() in paragraph for token in _HISTORICAL_CONTEXT_TOKENS)


def _find_stale_active_matches(
    text: str, path: Path | None = None
) -> List[Tuple[int, str, str]]:
    """Return (offset, matched_text, surrounding_snippet) for stale-count
    tokens that appear in the active region WITHOUT a nearby historical
    context marker.  Empty list means clean.

    If ``path`` is given, the active region is resolved per-doc via
    ``_ACTIVE_REGION_DELIMITERS_BY_DOC``.  Without a path (synthetic
    fixtures), the permissive default delimiter set is used.
    """
    if path is not None:
        active = _active_region_for_path(path, text)
    else:
        active = _split_active_region(text)
    violations: List[Tuple[int, str, str]] = []
    for pattern in _STALE_STAGED_COUNT_PATTERNS:
        for match in re.finditer(pattern, active):
            if _has_historical_context_near(active, match.start()):
                continue
            start = max(0, match.start() - 60)
            end = min(len(active), match.end() + 60)
            snippet = active[start:end].replace("\n", " ")
            violations.append((match.start(), match.group(0), snippet))
    return violations


def _current_truth_banner_region(text: str) -> str:
    """Return the CURRENT_STATE.md / SUPERVISOR_HANDOFF.md current-truth
    banner region as the first ~1400 characters of the file, which is
    where both docs place their dated current-lane banner.
    """
    return text[:1400]


# ---------------------------------------------------------------------------
# Tests — live-repo
# ---------------------------------------------------------------------------


class TestCurrentStateDocBanner:
    """CURRENT_STATE.md must contain a dated current-lane banner asserting
    the 23-file staged checkpoint debt.
    """

    def test_current_state_doc_exists(self) -> None:
        assert CURRENT_STATE_DOC.exists(), (
            f"Current-state authority doc missing at {CURRENT_STATE_DOC}"
        )

    def test_current_state_banner_has_date_anchor(self) -> None:
        banner = _current_truth_banner_region(_read(CURRENT_STATE_DOC))
        assert _CURRENT_LANE_DATE_ANCHOR in banner, (
            f"CURRENT_STATE.md current-lane banner does not contain the "
            f"required date anchor {_CURRENT_LANE_DATE_ANCHOR!r}. The "
            "banner must be explicitly dated so future readers can tell "
            "current-lane claims from historical snapshots."
        )

    def test_current_state_banner_states_23_file_debt(self) -> None:
        banner = _current_truth_banner_region(_read(CURRENT_STATE_DOC))
        assert _CURRENT_STAGED_TOKEN in banner, (
            f"CURRENT_STATE.md current-lane banner must contain the literal "
            f"token {_CURRENT_STAGED_TOKEN!r}. If the staged bundle "
            "legitimately grew past 23, update _CURRENT_STAGED_COUNT in "
            "this test file AND both authority docs in the same change.\n"
            f"Banner region (first 1400 chars):\n{banner[:800]}..."
        )


class TestSupervisorHandoffDocBanner:
    """SUPERVISOR_HANDOFF.md must contain a dated current-lane banner
    asserting ``23-file staged checkpoint debt present`` (supervisor-facing
    phrasing).
    """

    _REQUIRED_PHRASE = f"{_CURRENT_STAGED_COUNT}-file staged checkpoint debt present"

    def test_supervisor_handoff_doc_exists(self) -> None:
        assert SUPERVISOR_HANDOFF_DOC.exists(), (
            f"Supervisor-handoff authority doc missing at "
            f"{SUPERVISOR_HANDOFF_DOC}"
        )

    def test_supervisor_handoff_banner_has_date_anchor(self) -> None:
        banner = _current_truth_banner_region(_read(SUPERVISOR_HANDOFF_DOC))
        assert _CURRENT_LANE_DATE_ANCHOR in banner, (
            f"SUPERVISOR_HANDOFF.md current-lane banner does not contain "
            f"the required date anchor {_CURRENT_LANE_DATE_ANCHOR!r}. "
            "The banner must be explicitly dated so the supervisor loop "
            "can distinguish current-lane claims from historical snapshots."
        )

    def test_supervisor_handoff_banner_states_23_file_debt_phrase(self) -> None:
        banner = _current_truth_banner_region(_read(SUPERVISOR_HANDOFF_DOC))
        assert self._REQUIRED_PHRASE in banner, (
            f"SUPERVISOR_HANDOFF.md current-lane banner must contain the "
            f"exact phrase {self._REQUIRED_PHRASE!r}. If the staged bundle "
            "legitimately grew past 23, update _CURRENT_STAGED_COUNT in "
            "this test file AND both authority docs in the same change.\n"
            f"Banner region (first 1400 chars):\n{banner[:800]}..."
        )


class TestNoStaleActive22CountClaims:
    """Active regions of both docs must not contain bare 22-count stale
    claims presented as current-lane truth. Historical / intermediate /
    growth-path references are allowed when a historical context marker
    appears nearby.
    """

    def test_current_state_active_region_has_no_stale_22_claims(self) -> None:
        text = _read(CURRENT_STATE_DOC)
        violations = _find_stale_active_matches(text, path=CURRENT_STATE_DOC)
        assert not violations, (
            "CURRENT_STATE.md active region contains stale 22-count claims "
            "without a historical context marker in a ±400 char window. "
            "Either scope the claim as historical (prefix with 'historical', "
            "'at the time of', 'grew to 23', etc.) or rewrite it to current "
            f"{_CURRENT_STAGED_COUNT}-file truth.\n"
            + "\n".join(
                f"  - offset {off}: {snip!r}  (match: {match!r})"
                for off, match, snip in violations
            )
        )

    def test_supervisor_handoff_active_region_has_no_stale_22_claims(self) -> None:
        text = _read(SUPERVISOR_HANDOFF_DOC)
        violations = _find_stale_active_matches(text, path=SUPERVISOR_HANDOFF_DOC)
        assert not violations, (
            "SUPERVISOR_HANDOFF.md active region contains stale 22-count "
            "claims without a historical context marker in a ±400 char "
            "window. Active region is everything from top-of-file down to "
            "`## Historical Phase State Snapshot` (NOT `## Open Soak Issues` "
            "— that heading appears near the top and many supervisor-current "
            "sections live below it, so it cannot serve as a cutoff). "
            "Either scope the claim as historical (prefix with 'historical', "
            "'at the time of', 'grew to 23', etc.) or rewrite it to current "
            f"{_CURRENT_STAGED_COUNT}-file truth.\n"
            + "\n".join(
                f"  - offset {off}: {snip!r}  (match: {match!r})"
                for off, match, snip in violations
            )
        )


class TestSanityPins:
    """Scanner-sanity pins — the current-truth token count must be non-zero
    in each doc.  Catches a scanner or regex regression that silently
    matches nothing.
    """

    def test_current_state_has_at_least_one_23_file_marker(self) -> None:
        text = _read(CURRENT_STATE_DOC)
        count = text.count(_CURRENT_STAGED_TOKEN)
        assert count >= 1, (
            f"CURRENT_STATE.md contains zero occurrences of "
            f"{_CURRENT_STAGED_TOKEN!r}. Scanner may be broken, or the "
            "current-lane banner is missing entirely."
        )

    def test_supervisor_handoff_has_at_least_one_23_file_marker(self) -> None:
        text = _read(SUPERVISOR_HANDOFF_DOC)
        count = text.count(_CURRENT_STAGED_TOKEN)
        assert count >= 1, (
            f"SUPERVISOR_HANDOFF.md contains zero occurrences of "
            f"{_CURRENT_STAGED_TOKEN!r}. Scanner may be broken, or the "
            "current-lane banner is missing entirely."
        )


# ---------------------------------------------------------------------------
# Synthetic fixtures — prove the scanner catches regressions and accepts
# clean state.  Fixtures are in-memory strings; no disk writes.
# ---------------------------------------------------------------------------


_CLEAN_FIXTURE = """\
# Fixture Current State

Status (current, 2026-04-17): **CHECKPOINT DEBT PRESENT — HARNESS-BLOCKED** — lane
carries a **28-file** staged bundle (...)

## Open Soak Issues

### Historical entry (2026-04-14) — RESOLVED
At the time of the stash-pop recovery, the bundle was 19 files; subsequently
grew to 28 through the turn sequence. Historical narrative.
"""


_STALE_CURRENT_FIXTURE = """\
# Fixture Current State

Status (current, 2026-04-17): **CHECKPOINT DEBT PRESENT** — lane carries a
**22-file** staged bundle (stale wording: this should fail the scanner).

## Open Soak Issues

### Historical entry (2026-04-14) — RESOLVED
At the time of the stash-pop recovery, the bundle was 19 files.
"""


_HISTORICAL_22_IN_ACTIVE_WITH_CONTEXT_FIXTURE = """\
# Fixture Current State

Status (current, 2026-04-17): lane carries a **28-file** staged bundle.

The staged bundle grew 19 \u2192 21 \u2192 22 \u2192 23 \u2192 24 \u2192 25 \u2192 27 \u2192 28 across the
turn sequence; at the time of the Invariant-#11 integration it became 22
paths, and subsequently grew to 28 with additional invariant-scanner pins,
the coverage-matrix doc+pin pair, and the CUTOVER_PLAN phase-closure pin.

## Open Soak Issues
"""


# Supervisor-shape fixture: proves that a stale `22-file` claim appearing
# AFTER `## Open Soak Issues` but BEFORE `## Historical Phase State Snapshot`
# is detected.  This is the regression pattern from the first-landing form
# of the scanner (which used `## Open Soak Issues` as a hard cutoff and
# thus silently skipped the supervisor-current sections that live below it).
_SUPERVISOR_SHAPE_STALE_AFTER_OPEN_SOAK_FIXTURE = """\
# ClauDEX Supervisor Handoff

## Current Lane Truth (2026-04-17)

- Branch `claudesox-local` at HEAD `f24df96`, ahead 10.
- **28-file staged checkpoint debt present** in the git index.

## Purpose

Supervisor narrative.

## Open Soak Issues

### Some historical entry (2026-04-14) — RESOLVED
Historical narrative at the time of the incident.

## Current Restart Slice

This is a supervisor-current section that lives AFTER Open Soak Issues
but BEFORE the historical snapshot heading. A stale bare claim inserted
here must be flagged by the scanner because it represents current-lane
guidance, not historical narrative.

- **Staged bundle:** 22 files. (STALE — regression seed for the scanner.)

## Historical Phase State Snapshot (as of 2026-04-14)

Historical narrative here; references past this delimiter are OK.
"""


_SUPERVISOR_SHAPE_CLEAN_AFTER_OPEN_SOAK_FIXTURE = """\
# ClauDEX Supervisor Handoff

## Current Lane Truth (2026-04-17)

- Branch `claudesox-local` at HEAD `f24df96`, ahead 10.
- **28-file staged checkpoint debt present** in the git index.

## Purpose

Supervisor narrative.

## Open Soak Issues

### Some historical entry (2026-04-14) — RESOLVED
Historical narrative at the time of the incident.

## Current Restart Slice

- **Staged bundle:** 28 files. Clean supervisor-current guidance below
  the Open Soak Issues section.

## Historical Phase State Snapshot (as of 2026-04-14)

Historical narrative here.
"""


class TestScannerCatchesSyntheticRegression:
    """Positive fixture — the scanner must flag a stale 22-count claim that
    lives in the active region without a historical context marker.
    """

    def test_scanner_flags_bare_22_file_current_claim(self) -> None:
        violations = _find_stale_active_matches(_STALE_CURRENT_FIXTURE)
        assert violations, (
            "scanner failed to catch a synthetic stale `22-file` current-"
            "lane claim in the active region"
        )


class TestScannerAcceptsCleanFixture:
    """Negative fixture — a clean doc passes the active-region 22-count
    guard.
    """

    def test_clean_fixture_has_no_stale_matches(self) -> None:
        violations = _find_stale_active_matches(_CLEAN_FIXTURE)
        assert not violations, (
            f"clean fixture unexpectedly flagged: {violations!r}"
        )


class TestScannerAcceptsHistoricalContextIn22Reference:
    """Negative fixture — a 22-count reference in the active region IS
    allowed when a historical context marker (e.g., growth-path arrow
    sequence, "at the time of", "subsequently grew to 23") appears nearby.
    This prevents over-strict regression when legitimate turn-history
    narrative mentions the intermediate count.
    """

    def test_historical_context_in_active_region_is_accepted(self) -> None:
        violations = _find_stale_active_matches(
            _HISTORICAL_22_IN_ACTIVE_WITH_CONTEXT_FIXTURE
        )
        assert not violations, (
            f"scanner incorrectly flagged a 22-count reference inside an "
            f"explicit historical-narrative context: {violations!r}"
        )


class TestSupervisorActiveRegionCoversSectionsBelowOpenSoakIssues:
    """Regression guard — prior to this fix the scanner truncated active
    scanning at `## Open Soak Issues`, which in SUPERVISOR_HANDOFF.md
    sits near the top of the file. That left sections below Open Soak
    Issues (including `## Current Restart Slice`) unscanned, so a stale
    `22-file` claim introduced in supervisor-current guidance would pass
    undetected.

    The fix:
      - CURRENT_STATE.md active region ends at `## Checkpoint Readiness
        (Phase 8 Slice 12 closeout, 2026-04-14)`.
      - SUPERVISOR_HANDOFF.md active region ends at `## Historical Phase
        State Snapshot`.
      - `## Open Soak Issues` is NOT a global cutoff.

    These tests prove the fix with synthetic supervisor-shape fixtures.
    """

    def test_stale_22_file_between_open_soak_and_historical_is_flagged(self) -> None:
        """Synthetic supervisor-shape doc with a stale `22 files` claim
        inside `## Current Restart Slice` (below Open Soak Issues, above
        Historical Phase State Snapshot).  Scanner MUST flag it.
        """
        # Path simulates a SUPERVISOR_HANDOFF.md so the doc-specific
        # delimiter logic runs — delimiter for that basename is
        # `## Historical Phase State Snapshot`, NOT `## Open Soak Issues`.
        fake_path = SUPERVISOR_HANDOFF_DOC.with_name("SUPERVISOR_HANDOFF.md")
        violations = _find_stale_active_matches(
            _SUPERVISOR_SHAPE_STALE_AFTER_OPEN_SOAK_FIXTURE,
            path=fake_path,
        )
        assert violations, (
            "regression guard failure — scanner did not flag a synthetic "
            "stale `22 files` claim that lives AFTER `## Open Soak Issues` "
            "but BEFORE `## Historical Phase State Snapshot`. The fix for "
            "instruction 1776418837623-0006-7qr3w9 is not in place."
        )
        # And the violation should mention the regression seed text.
        seed_snippets = [snip for _, _, snip in violations if "Staged bundle" in snip]
        assert seed_snippets, (
            f"scanner flagged a violation but not on the expected "
            f"`**Staged bundle:** 22 files.` seed line. Violations: "
            f"{violations!r}"
        )

    def test_clean_supervisor_shape_after_open_soak_passes(self) -> None:
        """Inverse negative fixture — a clean supervisor-shape doc whose
        `## Current Restart Slice` section says `23 files` must pass
        (proves the fix is not over-strict).
        """
        fake_path = SUPERVISOR_HANDOFF_DOC.with_name("SUPERVISOR_HANDOFF.md")
        violations = _find_stale_active_matches(
            _SUPERVISOR_SHAPE_CLEAN_AFTER_OPEN_SOAK_FIXTURE,
            path=fake_path,
        )
        assert not violations, (
            f"clean supervisor-shape fixture was unexpectedly flagged: "
            f"{violations!r}"
        )

    def test_supervisor_active_region_includes_current_restart_slice(self) -> None:
        """Direct pin: the real SUPERVISOR_HANDOFF.md active region must
        include the `## Current Restart Slice` heading (if the doc has
        one). Proves the doc-specific boundary covers sections below
        `## Open Soak Issues`.
        """
        text = _read(SUPERVISOR_HANDOFF_DOC)
        # Only meaningful if the live doc actually has that section.
        if "## Current Restart Slice" not in text:
            pytest.skip(
                "SUPERVISOR_HANDOFF.md does not currently contain "
                "`## Current Restart Slice`; boundary-coverage invariant "
                "is vacuously true."
            )
        active = _active_region_for_path(SUPERVISOR_HANDOFF_DOC, text)
        assert "## Current Restart Slice" in active, (
            "SUPERVISOR_HANDOFF.md active region does NOT include "
            "`## Current Restart Slice`. The active-region boundary "
            "has regressed — likely the delimiter was narrowed back to "
            "`## Open Soak Issues`, which is a regression."
        )

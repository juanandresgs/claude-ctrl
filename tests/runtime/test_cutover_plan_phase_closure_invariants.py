"""Mechanical pin for CUTOVER_PLAN phase-closure time-scoping.

@decision DEC-CLAUDEX-CUTOVER-PHASE-CLOSURE-INVARIANT-001
Title: Every phase entry under ClauDEX/CUTOVER_PLAN.md § Phase Plan must carry an explicit Status: annotation naming its closure date
Status: proposed
Rationale: CUTOVER_PLAN.md is the architecture source of truth and its
  Phase Plan section was originally written as a pre-cutover roadmap (each
  phase in future tense). The public tree preserves closure state directly
  in the Phase Plan annotations. Prior session turns surfaced a drift hazard
  where future-tense prose in
  CUTOVER_PLAN silently contradicted the closed phase state (e.g.,
  "Until the reviewer stage is live..." at line 1164, "post-guardian
  planner continuation only becomes live after..." at line 1184–1185).
  The 2026-04-17 edit adds an explicit ``Status: CLOSED <date>`` line
  immediately under each ``### Phase N — <title>`` heading. This test
  mechanically pins that annotation against future regression.

  The scanner:
    - walks the Phase Plan region of ``ClauDEX/CUTOVER_PLAN.md`` (from
      the ``## Phase Plan`` heading down to the next ``## `` heading);
    - enumerates every ``### Phase <num> — <title>`` entry;
    - asserts every entry carries a ``Status:`` line within the first
      few non-blank lines after the heading;
    - asserts every ``Status:`` line names a closure state (``CLOSED``)
      and carries an explicit date anchor (``YYYY-MM-DD`` or
      ``pre-YYYY-MM-DD`` for pre-audit closures);
    - asserts every declared phase number matches the expected set
      (``{0, 1, 2, "2b", 3, 4, 5, 6, 7, 8}``);
    - asserts the Phase Plan preamble contains a DEC annotation
      pointing at this test file's decision record.

  Three synthetic-regression fixtures prove detection of: (a) a phase
  entry missing its ``Status:`` line, (b) a phase entry whose
  ``Status:`` line carries a forbidden marker (e.g.,
  ``IN PROGRESS`` / ``PENDING`` / ``PLANNED``), and (c) a stale
  future-tense marker left in a phase declared CLOSED (paragraph-
  scoped check for "will become live" / "when X is complete"
  language).

Adjacent authorities:
  - ``ClauDEX/CUTOVER_PLAN.md`` § Phase Plan — the architecture
    authority this test validates.
  - Sister pins with the same shadow-only / stdlib-only scan pattern:
    ``tests/runtime/test_decision_ref_resolution.py``,
    ``tests/runtime/test_retrieval_layer_downstream_invariant.py``,
    ``tests/runtime/test_cutover_invariant_coverage_matrix.py``,
    ``tests/runtime/policies/test_command_intent_single_authority.py``.

Shadow-only discipline: stdlib-only (``re``, ``pathlib``, ``textwrap``).
No SQLite, no git subprocess, no network, no runtime imports.
"""

from __future__ import annotations

import re
import textwrap
from pathlib import Path
from typing import Dict, List, Set, Tuple

import pytest


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]
CUTOVER_PLAN_DOC = _REPO_ROOT / "ClauDEX" / "CUTOVER_PLAN.md"

# Canonical phase numbers expected under `## Phase Plan`. Phase 2b is
# a sub-phase tracked as its own heading in the plan and must carry
# its own Status annotation.
_EXPECTED_PHASE_NUMBERS: Set[str] = {
    "0", "1", "2", "2b", "3", "4", "5", "6", "7", "8",
}

# Allowed status markers in a Phase `Status:` line.  Only `CLOSED`
# is canonical today; adding a new marker requires updating this
# test's allowlist in the same slice.
_ALLOWED_STATUS_MARKERS: Set[str] = {"CLOSED"}

# Forbidden status markers — these would signal that a phase is silently
# reopened without explicit architecture scope.
_FORBIDDEN_STATUS_MARKERS: Set[str] = {
    "IN PROGRESS",
    "IN-PROGRESS",
    "PENDING",
    "PLANNED",
    "OPEN",
    "WIP",
    "TBD",
    "TODO",
}

# Date anchors accepted in a `Status:` line.  Full ISO date or "pre-"
# prefix variant (for pre-audit closures where exact date is unknown
# but before a reference date).
_DATE_ANCHOR_RE = re.compile(r"\b(?:pre-)?(20\d{2}-\d{2}-\d{2})\b")

# Stale future-tense markers that MUST NOT appear within a phase block
# whose Status is CLOSED (paragraph-scoped check below).  Note these are
# loose phrasings; context matters — the scanner treats each match as a
# candidate and lets a nearby CLOSURE-SCOPED marker exonerate it.
_STALE_FUTURE_TENSE_MARKERS: Tuple[str, ...] = (
    "will become live",
    "will be proven",
    "pending approval",
    "not yet live",
    "not yet proven",
    "not yet complete",
)

# A phrase nearby that exonerates a future-tense marker as historical
# prose rather than a live requirement.
_CLOSURE_SCOPED_MARKERS: Tuple[str, ...] = (
    "historical",
    "closed",
    "status: closed",
    "status note",
    "was live",
    "is live",
    "already live",
)

# The DEC annotation this test file owns; the CUTOVER_PLAN preamble
# must cite it so a reader can find the test.
_REQUIRED_DEC_ID = "DEC-CLAUDEX-CUTOVER-PHASE-CLOSURE-INVARIANT-001"


# ---------------------------------------------------------------------------
# Parser helpers
# ---------------------------------------------------------------------------


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _extract_phase_plan_region(text: str) -> str:
    """Return the substring of ``text`` from the ``## Phase Plan`` heading
    down to (but not including) the next top-level ``## `` heading. If no
    next heading, return to end of file.
    """
    start_marker = "\n## Phase Plan"
    idx = text.find(start_marker)
    if idx == -1:
        # Try without leading newline in case Phase Plan is first heading.
        if text.startswith("## Phase Plan"):
            idx = 0
        else:
            return ""
    else:
        idx = idx + 1  # Advance past the leading newline.
    rest = text[idx:]
    next_heading = re.search(r"\n## (?!#)", rest[len("## Phase Plan"):])
    if next_heading is None:
        return rest
    cut = len("## Phase Plan") + next_heading.start()
    return rest[:cut]


# Phase heading: `### Phase <num> — <title>`. num can be digit(s) or
# `2b`-style composite. We tolerate em-dash, en-dash, and ascii dash.
_PHASE_HEADING_RE = re.compile(
    r"^###\s+Phase\s+([0-9]+[a-z]*)\s*[—–-]\s*(.+?)\s*$",
    re.MULTILINE,
)


def _extract_phase_blocks(region: str) -> List[Tuple[str, str, str]]:
    """Return (phase_number, heading_title, body_text) tuples in
    document order. Body text is everything from immediately after the
    heading line to just before the next ``###`` heading (or end of
    region).
    """
    matches = list(_PHASE_HEADING_RE.finditer(region))
    blocks: List[Tuple[str, str, str]] = []
    for i, match in enumerate(matches):
        phase_num = match.group(1)
        title = match.group(2).strip()
        body_start = match.end()
        body_end = (
            matches[i + 1].start() if i + 1 < len(matches) else len(region)
        )
        body = region[body_start:body_end]
        blocks.append((phase_num, title, body))
    return blocks


_STATUS_LINE_RE = re.compile(r"^\s*Status:\s*(.+?)\s*$", re.MULTILINE)


def _extract_status_line(phase_body: str) -> str:
    """Return the first `Status:` line inside a phase body. Only searches
    the first 10 non-blank lines after the heading to keep the check
    tight — Status must be adjacent to the heading, not buried in scope
    bullets.
    """
    leading = "\n".join(phase_body.splitlines()[:20])
    match = _STATUS_LINE_RE.search(leading)
    if not match:
        return ""
    return match.group(1).strip()


def _stale_future_tense_hits(phase_body: str) -> List[Tuple[int, str]]:
    """Return (line_offset, matched_phrase) for stale future-tense
    phrases in the phase body, UNLESS a closure-scoped marker appears in
    the same paragraph.
    """
    hits: List[Tuple[int, str]] = []
    paragraphs = re.split(r"\n\s*\n", phase_body)
    offset = 0
    for paragraph in paragraphs:
        para_lower = paragraph.lower()
        for marker in _STALE_FUTURE_TENSE_MARKERS:
            if marker.lower() in para_lower:
                if any(s in para_lower for s in _CLOSURE_SCOPED_MARKERS):
                    continue
                # Not exonerated — record a hit.
                hits.append((offset + para_lower.find(marker.lower()), marker))
        offset += len(paragraph) + 2  # +2 for the paragraph separator.
    return hits


# ---------------------------------------------------------------------------
# Tests — live repo
# ---------------------------------------------------------------------------


class TestCutoverPlanDocExists:
    def test_cutover_plan_is_present(self) -> None:
        assert CUTOVER_PLAN_DOC.exists(), (
            f"CUTOVER_PLAN authority doc missing at {CUTOVER_PLAN_DOC}"
        )

    def test_phase_plan_region_is_non_empty(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        assert region.strip(), (
            f"`## Phase Plan` region not found or empty in "
            f"{CUTOVER_PLAN_DOC}. Scanner may be broken, or the Phase Plan "
            "section was removed / renamed."
        )


class TestPhasePlanHasAllExpectedPhases:
    def test_every_expected_phase_number_is_declared(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        blocks = _extract_phase_blocks(region)
        declared = {num for num, *_ in blocks}
        missing = _EXPECTED_PHASE_NUMBERS - declared
        extra = declared - _EXPECTED_PHASE_NUMBERS
        assert not missing and not extra, (
            "Phase Plan phase-number set mismatch.\n"
            f"  expected: {sorted(_EXPECTED_PHASE_NUMBERS)}\n"
            f"  declared: {sorted(declared)}\n"
            f"  missing:  {sorted(missing)}\n"
            f"  extra:    {sorted(extra)}"
        )


class TestEveryPhaseHasStatusAnnotation:
    def test_every_phase_block_has_status_line(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        blocks = _extract_phase_blocks(region)
        missing: List[str] = []
        for num, title, body in blocks:
            status = _extract_status_line(body)
            if not status:
                missing.append(f"  - Phase {num} — {title}: no `Status:` line in heading block")
        assert not missing, (
            "Every phase entry under `## Phase Plan` MUST carry a "
            "`Status:` annotation within the first 20 lines of its body. "
            "This is the mechanical time-scoping pin.\n" + "\n".join(missing)
        )


class TestEveryPhaseStatusIsClosedWithDate:
    def test_status_markers_use_allowed_vocabulary(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        blocks = _extract_phase_blocks(region)
        offenders: List[str] = []
        for num, title, body in blocks:
            status = _extract_status_line(body)
            if not status:
                continue  # Covered by TestEveryPhaseHasStatusAnnotation.
            marker_found = None
            for allowed in _ALLOWED_STATUS_MARKERS:
                if allowed in status.upper():
                    marker_found = allowed
                    break
            if not marker_found:
                offenders.append(
                    f"  - Phase {num} — {title}: `Status:` line "
                    f"{status!r} does not name an allowed marker "
                    f"({sorted(_ALLOWED_STATUS_MARKERS)})"
                )
        assert not offenders, (
            "Phase Plan Status: lines must use the allowed marker "
            "vocabulary. Allowed: `CLOSED`. A new marker requires a "
            "bounded slice that updates this test's allowlist.\n"
            + "\n".join(offenders)
        )

    def test_status_markers_forbid_in_progress_tokens(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        blocks = _extract_phase_blocks(region)
        offenders: List[str] = []
        for num, title, body in blocks:
            status = _extract_status_line(body)
            if not status:
                continue
            for forbidden in _FORBIDDEN_STATUS_MARKERS:
                if forbidden in status.upper():
                    offenders.append(
                        f"  - Phase {num} — {title}: `Status:` line "
                        f"carries forbidden marker {forbidden!r}: "
                        f"{status!r}"
                    )
                    break
        assert not offenders, (
            "Phase Plan Status: lines must NOT carry IN PROGRESS / "
            "PENDING / PLANNED / OPEN / WIP / TBD / TODO markers. Every "
            "declared phase in the plan is closed; a phase genuinely "
            "reopened requires explicit architecture-scope review and an "
            "update to the allowed vocabulary.\n" + "\n".join(offenders)
        )

    def test_status_lines_carry_date_anchor(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        blocks = _extract_phase_blocks(region)
        offenders: List[str] = []
        for num, title, body in blocks:
            status = _extract_status_line(body)
            if not status:
                continue
            if not _DATE_ANCHOR_RE.search(status):
                offenders.append(
                    f"  - Phase {num} — {title}: `Status:` line "
                    f"{status!r} lacks a ``YYYY-MM-DD`` or "
                    "``pre-YYYY-MM-DD`` date anchor"
                )
        assert not offenders, (
            "Phase Plan Status: lines MUST carry an explicit date anchor "
            "(ISO ``YYYY-MM-DD`` or ``pre-YYYY-MM-DD``) so the closure "
            "is time-scoped and auditable.\n"
            + "\n".join(offenders)
        )


class TestNoStaleFutureTenseInClosedPhases:
    """When every declared phase is CLOSED, stale future-tense language
    like "will become live" / "not yet live" / "pending approval" inside
    a phase body is a contradiction. Paragraph-scoped closure-marker
    exoneration allows historical framing prose to carry these phrases.
    """

    def test_no_phase_body_has_unscoped_stale_future_tense(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        blocks = _extract_phase_blocks(region)
        offenders: List[str] = []
        for num, title, body in blocks:
            hits = _stale_future_tense_hits(body)
            for offset, phrase in hits:
                offenders.append(
                    f"  - Phase {num} — {title}: stale future-tense "
                    f"phrase {phrase!r} at body-offset {offset} without "
                    "a closure-scoped marker in the same paragraph"
                )
        assert not offenders, (
            "Phase Plan bodies must not carry unscoped future-tense "
            "phrases when every declared phase is CLOSED. Either scope "
            "the phrase as historical (prefix with 'historical', "
            "'Status: CLOSED', 'is live now', etc.) or remove it.\n"
            + "\n".join(offenders)
        )


class TestPhasePlanPreambleCitesDecisionRecord:
    def test_phase_plan_preamble_names_the_decision_record(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        assert _REQUIRED_DEC_ID in region, (
            f"Phase Plan preamble must mention this test's decision "
            f"record {_REQUIRED_DEC_ID!r} so a reader can locate the "
            "mechanical pin. The canonical mention appears in the "
            "'Status summary' paragraph at the top of `## Phase Plan`."
        )


# ---------------------------------------------------------------------------
# Synthetic fixtures — prove detection of the three regression shapes.
# ---------------------------------------------------------------------------


_CLEAN_FIXTURE = """\
## Phase Plan

Status summary anchor: DEC-CLAUDEX-CUTOVER-PHASE-CLOSURE-INVARIANT-001.

### Phase 0 — Hook Authority Reset

Status: CLOSED pre-2026-04-13

Goal:
Something closed.

### Phase 1 — Constitutional Kernel

Status: CLOSED 2026-04-13

Goal:
Something closed.

## Next section
"""


_MISSING_STATUS_FIXTURE = """\
## Phase Plan

Status summary anchor: DEC-CLAUDEX-CUTOVER-PHASE-CLOSURE-INVARIANT-001.

### Phase 0 — Hook Authority Reset

Goal:
No Status line. Scanner should flag this.

### Phase 1 — Constitutional Kernel

Status: CLOSED 2026-04-13

Goal:
Something closed.

## Next section
"""


_FORBIDDEN_MARKER_FIXTURE = """\
## Phase Plan

Status summary anchor: DEC-CLAUDEX-CUTOVER-PHASE-CLOSURE-INVARIANT-001.

### Phase 0 — Hook Authority Reset

Status: IN PROGRESS 2026-04-13

Goal:
Phase with IN PROGRESS marker must be flagged.

### Phase 1 — Constitutional Kernel

Status: CLOSED 2026-04-13

Goal:
Something closed.

## Next section
"""


_STALE_FUTURE_TENSE_FIXTURE = """\
## Phase Plan

Status summary anchor: DEC-CLAUDEX-CUTOVER-PHASE-CLOSURE-INVARIANT-001.

### Phase 0 — Hook Authority Reset

Status: CLOSED 2026-04-13

Goal:
This phase will become live after Phase 1 finishes bootstrapping. The
seed sentence carries no exoneration anchor in the same paragraph.

### Phase 1 — Constitutional Kernel

Status: CLOSED 2026-04-13

Goal:
Historical note: under the original pre-cutover plan this phase will become
live only when Phase 0 finishes. That phrasing is historical now and the
phase is already live.

## Next section
"""


class TestScannerCatchesSyntheticRegressions:
    """Positive fixtures."""

    def test_clean_fixture_passes_all_scanner_rules(self) -> None:
        region = _extract_phase_plan_region(_CLEAN_FIXTURE)
        blocks = _extract_phase_blocks(region)
        assert {n for n, *_ in blocks} == {"0", "1"}
        for num, title, body in blocks:
            status = _extract_status_line(body)
            assert status, f"clean fixture Phase {num} missing Status"
            assert "CLOSED" in status.upper()
            assert _DATE_ANCHOR_RE.search(status), (
                f"clean fixture Phase {num} missing date anchor: {status!r}"
            )
            assert not _stale_future_tense_hits(body), (
                f"clean fixture Phase {num} unexpectedly flagged for stale "
                f"future-tense: {_stale_future_tense_hits(body)!r}"
            )

    def test_missing_status_fixture_is_detected(self) -> None:
        region = _extract_phase_plan_region(_MISSING_STATUS_FIXTURE)
        blocks = _extract_phase_blocks(region)
        missing = [num for num, _, body in blocks if not _extract_status_line(body)]
        assert missing == ["0"], (
            f"missing-status fixture should flag Phase 0 only; got: {missing}"
        )

    def test_forbidden_marker_fixture_is_detected(self) -> None:
        region = _extract_phase_plan_region(_FORBIDDEN_MARKER_FIXTURE)
        blocks = _extract_phase_blocks(region)
        offenders: List[str] = []
        for num, title, body in blocks:
            status = _extract_status_line(body)
            for forbidden in _FORBIDDEN_STATUS_MARKERS:
                if forbidden in status.upper():
                    offenders.append(num)
                    break
        assert offenders == ["0"], (
            f"forbidden-marker fixture should flag Phase 0 only; got: {offenders}"
        )

    def test_stale_future_tense_fixture_flags_unscoped_phase_only(self) -> None:
        """In the stale-future-tense fixture, Phase 0's body carries
        `will become live` without closure-scoped exoneration; Phase 1's
        body contains the same phrase INSIDE a paragraph that explicitly
        says "historical" and "Status: CLOSED" which exonerates it.
        """
        region = _extract_phase_plan_region(_STALE_FUTURE_TENSE_FIXTURE)
        blocks = _extract_phase_blocks(region)
        offenders: List[str] = []
        for num, _, body in blocks:
            if _stale_future_tense_hits(body):
                offenders.append(num)
        assert offenders == ["0"], (
            f"stale-future-tense fixture should flag Phase 0 (unscoped) "
            f"but NOT Phase 1 (historical-scoped); got: {offenders}"
        )


class TestScannerSanity:
    def test_live_scanner_finds_at_least_eight_phase_blocks(self) -> None:
        region = _extract_phase_plan_region(_read(CUTOVER_PLAN_DOC))
        blocks = _extract_phase_blocks(region)
        assert len(blocks) >= 8, (
            f"scanner found only {len(blocks)} phase blocks in the "
            "Phase Plan region; expected at least 8. Scanner may be "
            f"broken. Declared: {[n for n, *_ in blocks]}"
        )


# ---------------------------------------------------------------------------
# Execution Model status-note framing pin
#
# Context: CUTOVER_PLAN.md's `## Execution Model` section contains
# pre-closure sequencing prose (phrases like "Until the reviewer stage is
# live...", "the `reviewer` stage becomes active only after...",
# "post-guardian planner continuation only becomes live after..."). The
# section opens with a `Status note (2026-04-17)` framing paragraph that
# explicitly reframes that downstream prose as historical and confirms
# every referenced stage is live. This pin ensures the framing paragraph
# cannot silently regress — if a future edit drops the status note, or
# drops one of the explicit "is live" stage-closure tokens, or drops the
# "historical framing" phrase, the test fails.
# ---------------------------------------------------------------------------


def _extract_execution_model_region(text: str) -> str:
    """Return everything from `## Execution Model` down to (but not
    including) the next top-level heading.  Empty string if absent.
    """
    start = text.find("\n## Execution Model")
    if start == -1:
        if text.startswith("## Execution Model"):
            start = 0
        else:
            return ""
    else:
        start += 1
    rest = text[start:]
    next_heading = re.search(r"\n## (?!#)", rest[len("## Execution Model"):])
    if next_heading is None:
        return rest
    return rest[: len("## Execution Model") + next_heading.start()]


# Tokens the Execution Model status-note paragraph must contain. We pin
# token-level anchors (not full sentences) so wording can be edited for
# clarity without breaking the guard, as long as the core commitments
# remain. Matching is whitespace-tolerant via `_match_token`.
_EXECUTION_MODEL_REQUIRED_TOKENS: Tuple[str, ...] = (
    # Dated anchor so the note stays attributable to a specific closure
    # checkpoint.
    "Status note (2026-04-17)",
    # Confirm reviewer stage is live (counters the pre-cutover "until X is
    # live" language below).
    "reviewer stage is live",
    # Confirm post-guardian planner continuation is live (counters the
    # "only becomes live after..." language below).
    "post-guardian planner continuation is live",
    # Confirm the supervision fabric is live (counters Phase 2b "becomes"
    # language). Hyphenated line-wrap tolerant ("agent-\nagnostic" →
    # "agent-agnostic" or "agentagnostic" after whitespace collapse).
    "supervision fabric is live",
    # Explicit historical-framing marker so the pre-closure sequencing
    # sentences below are clearly scoped.
    "historical framing",
    # Explicit "does NOT imply" clause for future-tense sentences further
    # down in the section.
    "does NOT imply",
    # Cross-reference to the per-phase Status annotations.
    "`Status:` annotation",
)


def _normalize_ws(text: str) -> str:
    """Collapse whitespace runs (including newlines and hyphenated
    line-wraps) so multi-line phrases can be matched against the
    Execution Model region without brittle full-string anchoring.
    """
    # Join hyphenated line-wrap artifacts: "agent-\nagnostic" → "agent-agnostic".
    text = re.sub(r"-\n", "-", text)
    # Collapse remaining whitespace runs to single space.
    text = re.sub(r"\s+", " ", text)
    return text


def _contains_token(region: str, token: str) -> bool:
    """Whitespace-tolerant token check. If the raw region contains the
    token literally, fast-path True. Otherwise fall back to normalized
    comparison so tokens spanning hyphenated line wraps are accepted.
    """
    if token in region:
        return True
    return _normalize_ws(token) in _normalize_ws(region)


def _extract_status_note_paragraph(region: str) -> str:
    """Return the paragraph anchored on the `**Status note` marker (the
    contiguous block of non-blank lines starting with that marker),
    or empty string if the marker is absent.

    Scoping required framing tokens to this paragraph — rather than the
    whole Execution Model region — prevents phrases like
    ``reviewer stage is live`` from leaking in via the historical
    sequencing sentinel ``Until the reviewer stage is live``.
    """
    lines = region.splitlines()
    start = None
    for idx, line in enumerate(lines):
        if "**Status note" in line:
            start = idx
            break
    if start is None:
        return ""
    end = start
    while end < len(lines) and lines[end].strip():
        end += 1
    return "\n".join(lines[start:end])

# Sequencing phrases that are historical-by-design in the Execution Model
# section. These are allowed to appear BECAUSE the status note above
# scopes them; they would be red flags only if the status note were
# removed. The pin below verifies each sentinel is present (so future
# edits can't silently delete the historical framing by deleting BOTH
# the note AND the sentinels, which would hide the drift).
_EXECUTION_MODEL_SCOPED_SEQUENCING_SENTINELS: Tuple[str, ...] = (
    "Until the reviewer stage is live",
    "becomes active only after",
    "only becomes live after",
)


class TestExecutionModelStatusNoteFraming:
    """Pin the `## Execution Model` section's Status note framing so
    downstream historical-sequencing prose cannot silently be misread
    as current-state claims if the note is dropped.
    """

    def test_execution_model_region_is_non_empty(self) -> None:
        region = _extract_execution_model_region(_read(CUTOVER_PLAN_DOC))
        assert region.strip(), (
            "`## Execution Model` section not found or empty in "
            f"{CUTOVER_PLAN_DOC}. Scanner may be broken, or the section "
            "was removed / renamed."
        )

    def test_execution_model_contains_all_required_framing_tokens(self) -> None:
        region = _extract_execution_model_region(_read(CUTOVER_PLAN_DOC))
        note = _extract_status_note_paragraph(region)
        missing = [
            t for t in _EXECUTION_MODEL_REQUIRED_TOKENS
            if not _contains_token(note, t)
        ]
        assert not missing, (
            "Execution Model status-note framing is incomplete. Each of "
            "the required tokens anchors a specific commitment the note "
            "makes (dated anchor, stage-liveness confirmations, "
            "historical-framing marker, authority cross-refs). A missing "
            "token indicates the status note was edited in a way that "
            "weakens the guard on the historical-sequencing prose "
            "further down in the section.\n"
            + "\n".join(f"  - missing: {t!r}" for t in missing)
        )

    def test_sequencing_sentinels_present_and_scoped_by_status_note(
        self,
    ) -> None:
        """Every historical sequencing sentinel must appear in the
        Execution Model region, AND the status note's required tokens
        must also appear. If a future edit silently deletes the status
        note (attempting to remove the "is live" framing), this test
        catches the drift because the sentinels remain and the required
        framing tokens disappear.
        """
        region = _extract_execution_model_region(_read(CUTOVER_PLAN_DOC))
        sentinel_misses = [
            s for s in _EXECUTION_MODEL_SCOPED_SEQUENCING_SENTINELS
            if s not in region
        ]
        # If sentinels are also removed, the drift is less dangerous
        # (because there's no misleading future-tense prose left) — but
        # this test is about the pair: sentinels + framing together.
        # If a future author removes both, the structure is simpler and
        # this test can be relaxed in the same slice that removes them.
        # Until then, both must be present.
        if sentinel_misses:
            pytest.skip(
                f"Sequencing sentinels removed from Execution Model: "
                f"{sentinel_misses}. If this is a deliberate section "
                "simplification, remove the corresponding sentinel(s) "
                "from _EXECUTION_MODEL_SCOPED_SEQUENCING_SENTINELS in "
                "the same change; otherwise investigate drift."
            )
        # Sentinels present — required framing tokens MUST also be
        # present (checked by the sibling test). This test provides a
        # second, narrower signal if the framing is weakened.
        note = _extract_status_note_paragraph(region)
        framing_misses = [
            t for t in _EXECUTION_MODEL_REQUIRED_TOKENS
            if not _contains_token(note, t)
        ]
        assert not framing_misses, (
            "Execution Model contains historical-sequencing sentinels "
            f"({sorted(_EXECUTION_MODEL_SCOPED_SEQUENCING_SENTINELS)}) "
            "but the framing status note is missing required tokens. "
            "Without the framing, those sentinels read as current-state "
            "claims and contradict the declared phase closures.\n"
            + "\n".join(f"  - missing framing token: {t!r}" for t in framing_misses)
        )


# Fixtures for TestExecutionModelFramingScanner — synthetic CUTOVER_PLAN-
# shape samples exercising the invariant's three regression shapes.

_EXECUTION_MODEL_CLEAN_FIXTURE = """\
## Execution Model

**Status note (2026-04-17):** the reviewer stage is live, guardian
provision/land split is live, post-guardian planner continuation is
live, derived-surface validation is live, legacy deletion is complete,
and the agent-
agnostic supervision fabric is live. The narrative below is preserved
as historical framing for how the system was sequenced; it does NOT
imply that the reviewer stage or post-guardian continuation are still
pending. See each `Status:` annotation under `## Phase Plan` for the
authoritative closure dates.

Until the reviewer stage is live, implementation work still uses the
current chain.

The `reviewer` stage becomes active only after the stage registry is
proven.

Post-guardian planner continuation only becomes live after planner
completion contracts are proven.

## Next section
"""


_EXECUTION_MODEL_MISSING_STATUS_NOTE_FIXTURE = """\
## Execution Model

Until the reviewer stage is live, implementation work still uses the
current chain.

The `reviewer` stage becomes active only after the stage registry is
proven.

Post-guardian planner continuation only becomes live after planner
completion contracts are proven.

## Next section
"""


_EXECUTION_MODEL_WEAKENED_NOTE_FIXTURE = """\
## Execution Model

**Status note (2026-04-17):** The section follows; read it.

Until the reviewer stage is live, implementation work still uses the
current chain.

The `reviewer` stage becomes active only after the stage registry is
proven.

Post-guardian planner continuation only becomes live after planner
completion contracts are proven.

## Next section
"""


class TestExecutionModelFramingScanner:
    """Synthetic fixtures — prove the scanner catches status-note drift."""

    def test_clean_fixture_passes_all_framing_checks(self) -> None:
        region = _extract_execution_model_region(_EXECUTION_MODEL_CLEAN_FIXTURE)
        note = _extract_status_note_paragraph(region)
        missing = [
            t for t in _EXECUTION_MODEL_REQUIRED_TOKENS
            if not _contains_token(note, t)
        ]
        assert not missing, (
            f"clean fixture unexpectedly missing framing tokens: {missing}"
        )

    def test_missing_status_note_fixture_is_detected(self) -> None:
        region = _extract_execution_model_region(
            _EXECUTION_MODEL_MISSING_STATUS_NOTE_FIXTURE
        )
        note = _extract_status_note_paragraph(region)
        missing = [
            t for t in _EXECUTION_MODEL_REQUIRED_TOKENS
            if not _contains_token(note, t)
        ]
        # Fixture has no status note at all — every framing token must
        # be missing.
        assert len(missing) == len(_EXECUTION_MODEL_REQUIRED_TOKENS), (
            f"missing-status-note fixture should miss ALL framing tokens; "
            f"actually missing: {missing}"
        )
        # And sequencing sentinels SHOULD still be present.
        sentinel_misses = [
            s for s in _EXECUTION_MODEL_SCOPED_SEQUENCING_SENTINELS
            if s not in region
        ]
        assert not sentinel_misses, (
            "missing-status-note fixture unexpectedly also dropped "
            f"sequencing sentinels: {sentinel_misses}"
        )

    def test_weakened_status_note_fixture_is_detected(self) -> None:
        """Status note heading exists but the commitment tokens are
        stripped out (e.g., the "is live" confirmations are removed).
        Most framing tokens must be missing even though the dated
        heading remains.
        """
        region = _extract_execution_model_region(
            _EXECUTION_MODEL_WEAKENED_NOTE_FIXTURE
        )
        note = _extract_status_note_paragraph(region)
        # Dated heading IS present in this fixture.
        assert _contains_token(note, "Status note (2026-04-17)")
        # But the commitment tokens are gone.
        missing = [
            t for t in _EXECUTION_MODEL_REQUIRED_TOKENS
            if not _contains_token(note, t)
        ]
        # Should be missing at least the stage-liveness anchors.
        key_missing = {
            "reviewer stage is live",
            "post-guardian planner continuation is live",
            "historical framing",
            "does NOT imply",
        }
        assert key_missing.issubset(set(missing)), (
            f"weakened-note fixture should miss the stage-liveness + "
            f"framing commitment tokens; actually missing: {missing}"
        )

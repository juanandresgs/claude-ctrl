"""Behavioral Evaluation Framework — scorer and output parser.

Parses raw evaluator output (EVAL_VERDICT trailers, evidence sections,
coverage tables) from agents/tester.md format, then computes weighted scores
against ground truth from scenario YAML files.

This module is read-only with respect to databases. It never writes to
state.db or eval_results.db — the caller persists results via
eval_metrics.record_score(). It does not invoke any LLM; all scoring is
heuristic (keyword/phrase matching, exact-value comparison).

@decision DEC-EVAL-SCORER-001
Title: eval_scorer is stateless and never writes to any database
Status: accepted
Rationale: The scorer is a pure transformation layer: raw evaluator text +
  ground truth config → structured score dict. Keeping it stateless means it
  can be tested without SQLite setup and called from any context without
  side-effects. Persistence is the caller's responsibility (eval_metrics or
  the runner). This mirrors the pattern established by DEC-EVAL-METRICS-001:
  each module owns one domain; the scorer's domain is parsing and scoring,
  not persistence.

@decision DEC-EVAL-SCORER-002
Title: evidence scoring uses keyword/phrase presence, not LLM-as-judge
Status: accepted
Rationale: DEC-EVAL-012 explicitly defers LLM-as-judge to avoid the
  meta-evaluation problem (using an LLM to score an LLM creates circular
  evaluation). Keyword/phrase presence against expected_evidence lists is
  deterministic, fast, and reproducible. False negatives (missed nuance) are
  acceptable in v1; false positives (approving wrong evidence) are bounded by
  the ground-truth list quality.

@decision DEC-EVAL-SCORER-003
Title: Coverage table parsing uses a 4-column markdown table pattern
Status: accepted
Rationale: The tester agent emits a fixed-schema Coverage table per
  agents/tester.md: Area | Tier | Status | Evidence. Parsing assumes this
  4-column layout and skips rows that don't conform. This is intentionally
  strict — a table with a different number of columns is not a Coverage table
  and is skipped rather than silently misinterpreted. Malformed rows are
  dropped gracefully (no exception raised).
"""

from __future__ import annotations

import re
from typing import Optional

# ---------------------------------------------------------------------------
# Constants — trailer field names (single authority, matches tester.md)
# ---------------------------------------------------------------------------

_TRAILER_FIELDS = ("EVAL_VERDICT", "EVAL_TESTS_PASS", "EVAL_NEXT_ROLE", "EVAL_HEAD_SHA")

# Status words that indicate a coverage area is NOT clean (case-insensitive).
_FAIL_STATUS_WORDS = frozenset({"failed", "not verified", "not_verified"})

# Adjacent confidence pairs (bi-directional; stored as frozensets for O(1) lookup)
_ADJACENT_CONFIDENCE = (
    frozenset({"High", "Medium"}),
    frozenset({"Medium", "Low"}),
)


# ---------------------------------------------------------------------------
# Trailer parsing
# ---------------------------------------------------------------------------


def parse_trailer(raw_output: str) -> dict:
    """Extract EVAL_* trailer fields from raw evaluator output.

    Scans for lines matching ``FIELD: value`` anywhere in the text. Returns
    a dict with all four canonical trailer keys; absent fields are None.

    Args:
        raw_output: Full raw text output from the tester agent.

    Returns:
        Dict with keys: EVAL_VERDICT, EVAL_TESTS_PASS, EVAL_NEXT_ROLE,
        EVAL_HEAD_SHA. Values are stripped strings or None if not found.
    """
    result: dict[str, Optional[str]] = {field: None for field in _TRAILER_FIELDS}
    if not raw_output:
        return result

    for line in raw_output.splitlines():
        stripped = line.strip()
        for field in _TRAILER_FIELDS:
            if stripped.startswith(f"{field}:"):
                value = stripped[len(field) + 1 :].strip()
                if value:
                    result[field] = value
                break  # each line can only match one field

    return result


# ---------------------------------------------------------------------------
# Evidence section extraction
# ---------------------------------------------------------------------------


def extract_evidence(raw_output: str) -> str:
    """Extract the 'What I Observed' section from evaluator output.

    Looks for a heading (## What I Observed or **What I Observed**) and
    returns everything from that heading until the next heading or end of
    document. Strips the heading line itself.

    Args:
        raw_output: Full raw text output from the tester agent.

    Returns:
        The body text of the "What I Observed" section, or empty string
        if the section is not found.
    """
    if not raw_output:
        return ""

    # Match either markdown heading (## ...) or bold (**...**) section markers
    # that contain "What I Observed" (case-insensitive)
    section_pattern = re.compile(
        r"(?:^#{1,3}\s+What I Observed\s*$|^\*\*What I Observed\*\*\s*$)",
        re.IGNORECASE | re.MULTILINE,
    )
    next_section_pattern = re.compile(
        r"^(?:#{1,3}\s+\S|\*\*\w)",
        re.MULTILINE,
    )

    match = section_pattern.search(raw_output)
    if not match:
        return ""

    # Content starts after the matched heading line
    content_start = match.end()
    remaining = raw_output[content_start:]

    # Find the next section heading to delimit the end
    next_match = next_section_pattern.search(remaining)
    if next_match:
        section_body = remaining[: next_match.start()]
    else:
        section_body = remaining

    return section_body.strip()


# ---------------------------------------------------------------------------
# Coverage table parsing
# ---------------------------------------------------------------------------


def extract_coverage(raw_output: str) -> list[dict]:
    """Parse the Coverage table (markdown format) from evaluator output.

    Expects a 4-column table with headers: Area | Tier | Status | Evidence.
    Skips the separator row (|---|...) and skips rows that do not have
    exactly 4 pipe-delimited cells.

    Args:
        raw_output: Full raw text output from the tester agent.

    Returns:
        List of dicts with keys: area, tier, status, evidence.
        Empty list if no conforming table is found.
    """
    if not raw_output:
        return []

    rows: list[dict] = []
    in_table = False
    past_header = False
    past_separator = False

    for line in raw_output.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            if in_table:
                # Table ended
                break
            continue

        # Detect table header: must contain all four column names
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if not in_table:
            if len(cells) == 4:
                lower_cells = [c.lower() for c in cells]
                if (
                    "area" in lower_cells[0]
                    and "tier" in lower_cells[1]
                    and "status" in lower_cells[2]
                    and "evidence" in lower_cells[3]
                ):
                    in_table = True
                    past_header = True
                    continue
            continue

        if past_header and not past_separator:
            # This is the separator row (|---|---|...)
            past_separator = True
            continue

        # Data rows: must have exactly 4 cells
        if len(cells) != 4:
            continue

        rows.append(
            {
                "area": cells[0],
                "tier": cells[1],
                "status": cells[2],
                "evidence": cells[3],
            }
        )

    return rows


# ---------------------------------------------------------------------------
# Individual scoring functions
# ---------------------------------------------------------------------------


def score_verdict(actual: Optional[str], expected: Optional[str]) -> float:
    """Return 1.0 if actual matches expected, 0.0 otherwise.

    None values are treated as non-matching (return 0.0). Comparison is
    exact string equality (case-sensitive, matching canonical lowercase values
    like 'ready_for_guardian', 'needs_changes', 'deny').

    Args:
        actual:   The verdict the agent actually produced.
        expected: The ground-truth expected verdict.

    Returns:
        1.0 for exact match, 0.0 otherwise.
    """
    if actual is None or expected is None:
        return 0.0
    return 1.0 if actual == expected else 0.0


def score_defect_recall(evidence_text: str, expected_defects: list[dict]) -> float:
    """Compute the fraction of expected defect keywords found in evidence_text.

    Each defect in expected_defects is a dict with at minimum a 'keyword' key.
    An optional 'section' key (not used in current scoring — reserved for
    future section-scoped matching) is accepted but ignored here.

    Matching is case-insensitive substring search.

    Args:
        evidence_text:    The extracted evidence text from the evaluator.
        expected_defects: List of dicts, each with at least {'keyword': str}.

    Returns:
        1.0 if expected_defects is empty. Otherwise the fraction (0.0–1.0)
        of keywords found in evidence_text.
    """
    if not expected_defects:
        return 1.0
    if not evidence_text:
        return 0.0

    lower_evidence = evidence_text.lower()
    found = sum(1 for d in expected_defects if d.get("keyword", "").lower() in lower_evidence)
    return found / len(expected_defects)


def score_evidence_quality(evidence_text: str, expected_evidence: list[str]) -> float:
    """Compute the fraction of expected evidence phrases found in evidence_text.

    Matching is case-insensitive substring search.

    Args:
        evidence_text:     The extracted evidence text from the evaluator.
        expected_evidence: List of phrase strings that should appear in the
                           evidence.

    Returns:
        1.0 if expected_evidence is empty. Otherwise the fraction (0.0–1.0)
        of phrases found.
    """
    if not expected_evidence:
        return 1.0
    if not evidence_text:
        return 0.0

    lower_evidence = evidence_text.lower()
    found = sum(1 for phrase in expected_evidence if phrase.lower() in lower_evidence)
    return found / len(expected_evidence)


def score_false_positives(coverage: list[dict], expected_clean_areas: list[str]) -> int:
    """Count coverage areas marked as failed/not-verified that should be clean.

    An area "fails" false-positive scoring if its status contains any of the
    words in _FAIL_STATUS_WORDS (case-insensitive). Only areas named in
    expected_clean_areas are checked.

    Args:
        coverage:             List of coverage dicts (from extract_coverage()).
        expected_clean_areas: List of area names that must be fully verified.

    Returns:
        Count of false positives (0 if expected_clean_areas is empty).
    """
    if not expected_clean_areas:
        return 0

    # Build a lookup from area name → status
    area_status: dict[str, str] = {row["area"]: row["status"] for row in coverage}

    count = 0
    for area in expected_clean_areas:
        status = area_status.get(area, "")
        lower_status = status.lower()
        # Check if any failure word appears in the status string
        if any(fail_word in lower_status for fail_word in _FAIL_STATUS_WORDS):
            count += 1

    return count


def score_confidence(actual: Optional[str], expected: Optional[str]) -> float:
    """Score confidence level match.

    Returns:
        1.0  — exact match (High/High, Medium/Medium, Low/Low)
        0.5  — adjacent (High/Medium or Medium/Low, in either direction)
        0.0  — distant (High/Low or Low/High) or any None

    Args:
        actual:   The confidence level the agent reported.
        expected: The ground-truth expected confidence level.
    """
    if actual is None or expected is None:
        return 0.0
    if actual == expected:
        return 1.0
    pair = frozenset({actual, expected})
    for adjacent_pair in _ADJACENT_CONFIDENCE:
        if pair == adjacent_pair:
            return 0.5
    return 0.0


# ---------------------------------------------------------------------------
# score_scenario() — orchestrator
# ---------------------------------------------------------------------------


def score_scenario(raw_output: str, ground_truth: dict, scoring_weights: dict) -> dict:
    """Orchestrate all scoring functions and compute a weighted total score.

    Parses the evaluator output, extracts evidence and coverage, then
    computes each sub-score and combines them via scoring_weights. The
    returned dict is compatible with eval_metrics.record_score() kwargs.

    ground_truth keys expected (all optional with safe defaults):
      - expected_verdict:      str | None
      - expected_defects:      list[dict] (default [])
      - expected_evidence:     list[str] (default [])
      - expected_confidence:   str | None
      - expected_clean_areas:  list[str] (default [])

    scoring_weights keys expected (all default to 0.0):
      - verdict_weight:          float
      - defect_recall_weight:    float
      - evidence_weight:         float
      - false_positive_weight:   float

    false_positive_weight reduces the total score by weight × count
    (capped so total never goes below 0.0).

    Args:
        raw_output:      Full raw text output from the tester agent.
        ground_truth:    Ground truth section from the scenario YAML.
        scoring_weights: Scoring weights section from the scenario YAML.

    Returns:
        Dict with keys matching eval_metrics.record_score() signature plus
        'total_score'. All parsing errors are captured in 'error_message'
        rather than propagated as exceptions.

    @decision DEC-EVAL-SCORER-004
    Title: score_scenario never raises; parsing failures are captured in error_message
    Status: accepted
    Rationale: The scorer runs inside the eval_runner loop, which must handle
      all scenarios without crashing. Any unexpected parsing exception is
      caught, recorded in error_message, and scores default to 0.0. This
      mirrors the error_message convention already in eval_scores schema.
    """
    error_message: Optional[str] = None

    try:
        trailer = parse_trailer(raw_output)
        evidence_text = extract_evidence(raw_output)
        coverage = extract_coverage(raw_output)

        verdict_actual = trailer.get("EVAL_VERDICT")
        confidence_actual = _extract_confidence_level(raw_output)

        expected_verdict = ground_truth.get("expected_verdict")
        expected_defects = ground_truth.get("expected_defects") or []
        expected_evidence = ground_truth.get("expected_evidence") or []
        expected_clean_areas = ground_truth.get("expected_clean_areas") or []

        v_score = score_verdict(verdict_actual, expected_verdict)
        dr_score = score_defect_recall(evidence_text, expected_defects)
        ev_score = score_evidence_quality(evidence_text, expected_evidence)
        fp_count = score_false_positives(coverage, expected_clean_areas)

        vw = scoring_weights.get("verdict_weight", 0.0)
        drw = scoring_weights.get("defect_recall_weight", 0.0)
        evw = scoring_weights.get("evidence_weight", 0.0)
        fpw = scoring_weights.get("false_positive_weight", 0.0)

        total = vw * v_score + drw * dr_score + evw * ev_score - fpw * fp_count
        total = max(0.0, total)

        verdict_correct = 1 if v_score == 1.0 else 0

    except Exception as exc:  # noqa: BLE001
        error_message = str(exc)
        verdict_actual = None
        verdict_correct = 0
        dr_score = 0.0
        ev_score = 0.0
        fp_count = 0
        confidence_actual = None
        total = 0.0

    return {
        "verdict_actual": verdict_actual if error_message is None else None,
        "verdict_correct": verdict_correct,
        "defect_recall": dr_score if error_message is None else 0.0,
        "evidence_score": ev_score if error_message is None else 0.0,
        "false_positive_count": fp_count if error_message is None else 0,
        "confidence_actual": confidence_actual if error_message is None else None,
        "duration_ms": None,
        "error_message": error_message,
        "total_score": total,
    }


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _extract_confidence_level(raw_output: str) -> Optional[str]:
    """Extract the reported Confidence Level from evaluator output.

    Looks for patterns like:
      **Confidence Level:** **High** ...
      **Confidence Level:** High ...
      Confidence Level: High

    Returns the level string (High/Medium/Low) or None if not found.
    """
    if not raw_output:
        return None

    # Match "Confidence Level:" followed optionally by bold markers and the value
    pattern = re.compile(
        r"confidence\s+level[:\s]+\*{0,2}(High|Medium|Low)\*{0,2}",
        re.IGNORECASE,
    )
    match = pattern.search(raw_output)
    if match:
        raw = match.group(1)
        # Normalize capitalization to canonical form
        canonical = {"high": "High", "medium": "Medium", "low": "Low"}
        return canonical.get(raw.lower(), raw)
    return None

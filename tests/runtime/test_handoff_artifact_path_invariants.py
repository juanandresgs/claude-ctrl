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


# ---------------------------------------------------------------------------
# Supervisor Step 4 response-surface fallback pin
#
# Context: under observed bridge response-broker drift, `get_response()` can
# return `count: 0` while the lane-local `pending-review.json` carries a
# valid on-disk response payload for the same active run. The supervisor
# prompt's Step 4 defines the fallback order the steady-state loop must
# follow in that case. This invariant pins the required phrasing so the
# fallback cannot silently regress (e.g., by removing the fallback,
# demoting `pending-review.json` below `get_response()` unconditionally,
# or collapsing Step 4 back to the pre-fix single-line form).
#
# The fallback order is authoritative in `.codex/prompts/claudex_supervisor.txt`
# Step 4. This test pins the three critical tokens:
#   1. Primary path name: `get_response()`
#   2. Empty-count trigger: `count: 0` or `count=0`
#   3. Run-id match phrasing: `matching \`run_id\`` or equivalent
# and the run-id-mismatch rule:
#   4. `Ignore`/`ignore` + `run_id`
#
# Refs: SUPERVISOR_HANDOFF.md "Bridge response-broker drift in
# `waiting_for_codex`" Open Soak Issues entry.
# ---------------------------------------------------------------------------

SUPERVISOR_PROMPT = REPO_ROOT / ".codex" / "prompts" / "claudex_supervisor.txt"

FALLBACK_REQUIRED_TOKENS: tuple[str, ...] = (
    # Primary path still named
    "get_response()",
    # Fallback trigger: empty-count signal
    "count: 0",
    # Run-id match check for the fallback path
    "run_id",
    # Lane-local artifact referenced as fallback source
    "$CLAUDEX_STATE_DIR/pending-review.json",
    # response_path readability check
    "response_path",
)

FALLBACK_MISMATCH_IGNORE_PHRASES: tuple[str, ...] = (
    # Mismatch-ignore rule: when run_id does NOT match active run
    "does NOT match",
    "ignore",
)


def test_supervisor_step4_response_surface_fallback_is_pinned() -> None:
    """The supervisor prompt must encode the Step 4 response-surface
    fallback order: primary = `get_response()`, fallback on `count: 0`
    with matching `run_id` = lane-local `pending-review.json` artifact,
    mismatch-ignore when `run_id` diverges from the active run.

    This guards against silent regression of the fallback guidance, which
    would re-introduce the known bridge response-broker drift failure mode
    (supervisor missed an on-disk response because `get_response()` under-
    reported in `waiting_for_codex`).
    """
    text = SUPERVISOR_PROMPT.read_text()
    # Step 4 block is identified by the numbered-list marker. Extract only
    # the Step 4 region so changes to other steps do not accidentally
    # satisfy this pin.
    step4_match = re.search(
        r"(?m)^4\. If bridge state is `waiting_for_codex`.*?(?=\n\d+\. |\Z)",
        text,
        re.DOTALL,
    )
    assert step4_match is not None, (
        "Supervisor prompt Step 4 for `waiting_for_codex` not found at "
        f"{SUPERVISOR_PROMPT.relative_to(REPO_ROOT)}. Expected a numbered "
        "Step 4 opening with 'If bridge state is `waiting_for_codex`'."
    )
    step4 = step4_match.group(0)

    missing_required = [t for t in FALLBACK_REQUIRED_TOKENS if t not in step4]
    assert not missing_required, (
        "Supervisor Step 4 is missing response-surface fallback tokens:\n"
        + "\n".join(f"  - {t!r}" for t in missing_required)
        + f"\n\nStep 4 text:\n{step4}"
    )

    missing_mismatch = [p for p in FALLBACK_MISMATCH_IGNORE_PHRASES if p not in step4]
    assert not missing_mismatch, (
        "Supervisor Step 4 is missing run_id-mismatch ignore phrasing:\n"
        + "\n".join(f"  - {p!r}" for p in missing_mismatch)
        + f"\n\nStep 4 text:\n{step4}"
    )


def test_supervisor_step4_primary_before_fallback_ordering() -> None:
    """Within Step 4, the primary-path token (`get_response()`) must
    appear before the fallback artifact token (`pending-review.json`).
    This pins the fallback order so a future edit cannot flip the
    priority (which would make `pending-review.json` the primary, losing
    the broker's dedupe/ack semantics).
    """
    text = SUPERVISOR_PROMPT.read_text()
    step4_match = re.search(
        r"(?m)^4\. If bridge state is `waiting_for_codex`.*?(?=\n\d+\. |\Z)",
        text,
        re.DOTALL,
    )
    assert step4_match is not None
    step4 = step4_match.group(0)
    primary_idx = step4.find("get_response()")
    fallback_idx = step4.find("$CLAUDEX_STATE_DIR/pending-review.json")
    assert primary_idx != -1 and fallback_idx != -1, (
        "Step 4 must name both `get_response()` and "
        "`$CLAUDEX_STATE_DIR/pending-review.json` to pin ordering."
    )
    assert primary_idx < fallback_idx, (
        "Step 4 ordering regression: `get_response()` must appear before "
        "`$CLAUDEX_STATE_DIR/pending-review.json` so the primary path "
        "stays primary. Current offsets: "
        f"get_response={primary_idx}, pending-review.json={fallback_idx}."
    )


# ---------------------------------------------------------------------------
# Checkpoint report staged-scope authority pin
#
# Context: 2026-04-17, Codex instruction `1776422371697-0001-b39h0v` surfaced
# a scope-narration drift where a guardian subagent report listed
# `Included scope` paths that were not in the live staged index. The real
# git index was intact (staged count matched), but the report's prose
# enumerated hallucinated paths from recall rather than from live git
# output. The fix (applied in this test file's sibling slice) pins the
# execution-prompt surface to require:
#   1. `Included scope` derived from `git diff --cached --name-only`
#   2. count anchored to `git diff --cached --name-only | wc -l`
#   3. any non-staged path in the report is invalid
# Adjacent: `ClauDEX/SUPERVISOR_HANDOFF.md` Open Soak Issues entry
# "Checkpoint-report staged-scope narration drift (2026-04-17)".
# ---------------------------------------------------------------------------

EXECUTION_PROMPT_DOC = (
    REPO_ROOT / "ClauDEX" / "CC_POLICY_WHO_REMEDIATION_EXECUTION_PROMPT.txt"
)

_CHECKPOINT_SCOPE_AUTHORITY_REQUIRED_TOKENS: tuple[str, ...] = (
    # Rule-heading anchor so the invariant is findable:
    "CHECKPOINT REPORT STAGED-SCOPE AUTHORITY RULE",
    # Rule 1: derive scope from live git output.
    "git diff --cached --name-only",
    # Rule 2: count citation requirement.
    "git diff --cached --name-only | wc -l",
    # Rule 3: non-staged-path rejection clause.
    "is invalid",
    # Rule 4: explicit prohibition of narration/recall sources.
    "MUST NOT be narrated from",
)


def test_execution_prompt_carries_checkpoint_scope_authority_rule() -> None:
    """The execution-prompt surface must state the checkpoint-report
    staged-scope authority rule verbatim. Every required token must
    appear in the file's body. Missing tokens indicate a silent
    regression of the 2026-04-17 drift-guardrail edit.
    """
    assert EXECUTION_PROMPT_DOC.exists(), (
        f"Execution prompt surface missing at {EXECUTION_PROMPT_DOC}"
    )
    text = EXECUTION_PROMPT_DOC.read_text(encoding="utf-8")
    missing = [t for t in _CHECKPOINT_SCOPE_AUTHORITY_REQUIRED_TOKENS if t not in text]
    assert not missing, (
        "Execution prompt is missing required CHECKPOINT REPORT STAGED-"
        "SCOPE AUTHORITY RULE tokens. The authoritative guidance for "
        "how a guardian report derives its `Included scope` cell must "
        "stay in this file.\n"
        + "\n".join(f"  - missing: {t!r}" for t in missing)
    )


def test_execution_prompt_names_this_mechanical_pin() -> None:
    """The execution-prompt rule must cite the pin test so a future
    reader can locate the mechanical guard.
    """
    text = EXECUTION_PROMPT_DOC.read_text(encoding="utf-8")
    required_test_ref = (
        "tests/runtime/test_handoff_artifact_path_invariants.py"
        "::TestCheckpointReportScopeAuthority"
    )
    assert required_test_ref in text, (
        "Execution prompt must name the mechanical pin "
        f"{required_test_ref!r} so the rule's enforcement is traceable."
    )


class TestCheckpointReportScopeAuthority:
    """Grouping class for the two pins above — keeps the
    ``::TestCheckpointReportScopeAuthority`` reference the execution
    prompt cites resolvable, and carries the rule tokens forward as a
    class-level reference for future extensions.
    """

    REQUIRED_TOKENS = _CHECKPOINT_SCOPE_AUTHORITY_REQUIRED_TOKENS

    def test_required_token_list_is_non_empty(self) -> None:
        """Scanner-sanity pin so a future refactor cannot empty the
        required-token list and silently disable both sibling tests.
        """
        assert len(self.REQUIRED_TOKENS) >= 3, (
            f"_CHECKPOINT_SCOPE_AUTHORITY_REQUIRED_TOKENS shrunk to "
            f"{len(self.REQUIRED_TOKENS)} token(s); must remain ≥ 3 to "
            "keep the authority-rule invariant meaningful."
        )

    def test_class_ref_resolves_in_prompt(self) -> None:
        """Delegates to the module-level test but via the class path
        the execution prompt cites (``TestCheckpointReportScopeAuthority``).
        """
        test_execution_prompt_names_this_mechanical_pin()

    def test_prompt_rule_is_present_via_class(self) -> None:
        """Delegates to the module-level token-presence test. Keeps the
        rule discoverable under the class path named in the execution
        prompt.
        """
        test_execution_prompt_carries_checkpoint_scope_authority_rule()


# ---------------------------------------------------------------------------
# Checkpoint-report EXCLUDED-scope authority rule
# ---------------------------------------------------------------------------
# Sibling guardrail to the staged-scope rule above. Added 2026-04-17 after
# instruction `1776423808293-0006-4eqliy` surfaced a drift where a
# checkpoint-retry report's `Excluded scope` cell enumerated many
# modified / untracked paths narrated from a session-start `gitStatus`
# snapshot rather than live `git status --short` output. Live state at
# report time showed only `?? .claudex/` outside the staged bundle;
# the report's excluded-scope list contained ~25 unrelated paths.
#
# The fix pins the execution-prompt surface to require:
#   1. `Excluded scope` derived from live `git status --short`
#   2. explicit distinction between staged vs unstaged/untracked rows
#   3. explicit "none outside lane-local artifacts" wording when applicable
#   4. any non-worktree path in the excluded cell is invalid
# Adjacent: `ClauDEX/SUPERVISOR_HANDOFF.md` Open Soak Issues entry
# "Checkpoint-report excluded-scope narration drift (2026-04-17)".
# ---------------------------------------------------------------------------

_CHECKPOINT_EXCLUDED_SCOPE_AUTHORITY_REQUIRED_TOKENS: tuple[str, ...] = (
    # Rule-heading anchor so the invariant is findable:
    "CHECKPOINT REPORT EXCLUDED-SCOPE AUTHORITY RULE",
    # Rule 1: derive excluded scope from live git status.
    "git status --short",
    # Rule 2: staged vs unstaged/untracked distinction.
    "distinguish staged entries",
    # Rule 3: explicit "none" wording when applicable.
    "none outside lane-local artifacts",
    # Rule 4: prohibition of narration from session-start snapshot.
    "session-start status snapshot",
)


def test_execution_prompt_carries_checkpoint_excluded_scope_authority_rule() -> None:
    """The execution-prompt surface must state the checkpoint-report
    excluded-scope authority rule verbatim. Every required token must
    appear in the file's body. Missing tokens indicate a silent
    regression of the 2026-04-17 excluded-scope drift guardrail.
    """
    assert EXECUTION_PROMPT_DOC.exists(), (
        f"Execution prompt surface missing at {EXECUTION_PROMPT_DOC}"
    )
    text = EXECUTION_PROMPT_DOC.read_text(encoding="utf-8")
    missing = [
        t for t in _CHECKPOINT_EXCLUDED_SCOPE_AUTHORITY_REQUIRED_TOKENS
        if t not in text
    ]
    assert not missing, (
        "Execution prompt is missing required CHECKPOINT REPORT EXCLUDED-"
        "SCOPE AUTHORITY RULE tokens. The authoritative guidance for how "
        "a guardian report derives its `Excluded scope` cell must stay "
        "in this file.\n"
        + "\n".join(f"  - missing: {t!r}" for t in missing)
    )


def test_execution_prompt_names_excluded_scope_mechanical_pin() -> None:
    """The execution-prompt rule must cite the pin test so a future
    reader can locate the mechanical guard for excluded-scope drift.
    """
    text = EXECUTION_PROMPT_DOC.read_text(encoding="utf-8")
    required_test_ref = (
        "tests/runtime/test_handoff_artifact_path_invariants.py"
        "::TestCheckpointReportExcludedScopeAuthority"
    )
    assert required_test_ref in text, (
        "Execution prompt must name the mechanical pin "
        f"{required_test_ref!r} so the excluded-scope rule's "
        "enforcement is traceable."
    )


class TestCheckpointReportExcludedScopeAuthority:
    """Grouping class for the excluded-scope authority pins — keeps the
    ``::TestCheckpointReportExcludedScopeAuthority`` reference the
    execution prompt cites resolvable, and carries the rule tokens
    forward as a class-level reference for future extensions.
    """

    REQUIRED_TOKENS = _CHECKPOINT_EXCLUDED_SCOPE_AUTHORITY_REQUIRED_TOKENS

    def test_required_token_list_is_non_empty(self) -> None:
        """Scanner-sanity pin so a future refactor cannot empty the
        required-token list and silently disable both sibling tests.
        """
        assert len(self.REQUIRED_TOKENS) >= 4, (
            f"_CHECKPOINT_EXCLUDED_SCOPE_AUTHORITY_REQUIRED_TOKENS "
            f"shrunk to {len(self.REQUIRED_TOKENS)} token(s); must "
            "remain ≥ 4 to keep the authority-rule invariant meaningful."
        )

    def test_class_ref_resolves_in_prompt(self) -> None:
        """Delegates to the module-level pin-citation test but via the
        class path the execution prompt cites.
        """
        test_execution_prompt_names_excluded_scope_mechanical_pin()

    def test_prompt_rule_is_present_via_class(self) -> None:
        """Delegates to the module-level token-presence test. Keeps the
        rule discoverable under the class path named in the execution
        prompt.
        """
        test_execution_prompt_carries_checkpoint_excluded_scope_authority_rule()

    def test_rule_distinguishes_staged_from_unstaged(self) -> None:
        """The excluded-scope rule must explicitly require
        distinguishing staged entries (first column non-space) from
        unstaged / untracked entries (first column space or ``?``).
        Without this distinction, reports can list staged files under
        `Excluded scope` or vice versa.
        """
        text = EXECUTION_PROMPT_DOC.read_text(encoding="utf-8")
        # The rule body must reference both the staged-indicator and
        # the untracked-indicator explicitly so the distinction is
        # mechanically unambiguous.
        assert "unstaged" in text or "untracked" in text, (
            "Excluded-scope rule missing staged/unstaged distinction "
            "vocabulary; reports cannot mechanically classify "
            "`git status --short` rows without it."
        )
        assert "??" in text, (
            "Excluded-scope rule must reference the `??` untracked "
            "indicator so authors know which status rows qualify as "
            "excluded."
        )


# ---------------------------------------------------------------------------
# Checkpoint-retry throttle rule
# ---------------------------------------------------------------------------
# Added 2026-04-17 after repeated identical checkpoint retries were observed
# producing the same harness-level Bash-approval deny with unchanged lane
# fingerprint (same HEAD, same staged count, same denial text). The rule
# prevents immediate retry loops that cannot make forward progress and
# instead routes the supervisor to the next bounded non-write slice until
# an approval-state or lane-state change is observed.
#
# The pin verifies the SUPERVISOR_HANDOFF.md Checkpoint Stewardship section
# carries the rule's anchor heading and its three fingerprint-component
# clauses plus the "approval-state change" / "lane-state change" retry
# gating vocabulary.
# ---------------------------------------------------------------------------

SUPERVISOR_HANDOFF_DOC = REPO_ROOT / "ClauDEX" / "SUPERVISOR_HANDOFF.md"

_CHECKPOINT_RETRY_THROTTLE_REQUIRED_TOKENS: tuple[str, ...] = (
    # Rule-heading anchor:
    "Checkpoint-retry throttle rule",
    # Unchanged-fingerprint trigger vocabulary:
    "lane fingerprint is **unchanged**",
    # Three fingerprint components (HEAD, staged count, denial text):
    "`git rev-parse HEAD`",
    "`git diff --cached --name-only | wc -l`",
    "Permission to use Bash with command git commit -F",
    # Forward-motion clause: proceed to next bounded non-write slice.
    "next bounded non-write cutover slice",
    # Retry-gating clause: approval-state OR lane-state change.
    "approval-state change",
    "lane-state change",
    # Pin-citation clause:
    "TestCheckpointRetryThrottleRule",
)


def test_supervisor_handoff_carries_checkpoint_retry_throttle_rule() -> None:
    """The SUPERVISOR_HANDOFF.md Checkpoint Stewardship section must state
    the checkpoint-retry throttle rule verbatim. Every required token
    must appear in the file's body. Missing tokens indicate a silent
    regression of the 2026-04-17 governance-hardening edit.
    """
    assert SUPERVISOR_HANDOFF_DOC.exists(), (
        f"Supervisor handoff doc missing at {SUPERVISOR_HANDOFF_DOC}"
    )
    text = SUPERVISOR_HANDOFF_DOC.read_text(encoding="utf-8")
    missing = [
        t for t in _CHECKPOINT_RETRY_THROTTLE_REQUIRED_TOKENS if t not in text
    ]
    assert not missing, (
        "SUPERVISOR_HANDOFF.md is missing required Checkpoint-retry "
        "throttle rule tokens. The authoritative guidance for when a "
        "harness-denied checkpoint retry may or must not be immediately "
        "re-dispatched must stay in this file.\n"
        + "\n".join(f"  - missing: {t!r}" for t in missing)
    )


class TestCheckpointRetryThrottleRule:
    """Grouping class for the checkpoint-retry throttle invariant — keeps
    the ``::TestCheckpointRetryThrottleRule`` reference the supervisor
    handoff cites resolvable, and carries the required-token list forward
    as a class-level reference for future extensions.
    """

    REQUIRED_TOKENS = _CHECKPOINT_RETRY_THROTTLE_REQUIRED_TOKENS

    def test_required_token_list_is_non_empty(self) -> None:
        """Scanner-sanity pin so a future refactor cannot empty the
        required-token list and silently disable the sibling test.
        """
        assert len(self.REQUIRED_TOKENS) >= 6, (
            f"_CHECKPOINT_RETRY_THROTTLE_REQUIRED_TOKENS shrunk to "
            f"{len(self.REQUIRED_TOKENS)} token(s); must remain ≥ 6 to "
            "keep the throttle-rule invariant meaningful."
        )

    def test_rule_names_all_three_fingerprint_components(self) -> None:
        """The rule body must enumerate all three fingerprint components
        (HEAD, staged count, denial text) explicitly. Without all three,
        the throttle predicate is under-specified and a regression could
        drop one component and silently reopen the retry-loop class.
        """
        text = SUPERVISOR_HANDOFF_DOC.read_text(encoding="utf-8")
        components = {
            "HEAD": "`git rev-parse HEAD`",
            "staged count": "`git diff --cached --name-only | wc -l`",
            "denial text": "Permission to use Bash with command git commit -F",
        }
        missing = {
            name: tok for name, tok in components.items() if tok not in text
        }
        assert not missing, (
            "Throttle rule must name all three fingerprint components "
            "(HEAD, staged count, denial text). Missing: "
            + ", ".join(f"{n}={t!r}" for n, t in missing.items())
        )

    def test_rule_specifies_forward_motion_on_unchanged_fingerprint(
        self,
    ) -> None:
        """The rule must direct the supervisor to proceed to a next
        bounded non-write slice when the fingerprint is unchanged —
        otherwise the rule only says 'do not retry' without providing
        the forward-motion path, leaving the supervisor idle.
        """
        text = SUPERVISOR_HANDOFF_DOC.read_text(encoding="utf-8")
        assert "next bounded non-write cutover slice" in text, (
            "Throttle rule must direct the supervisor toward a next "
            "bounded non-write slice when the checkpoint is throttled; "
            "otherwise the rule blocks retry without providing forward "
            "motion."
        )

    def test_rule_specifies_retry_unblock_conditions(self) -> None:
        """The rule must name BOTH retry-unblock conditions
        (approval-state change OR lane-state change). Dropping either
        creates a class of drift where a legitimate retry is blocked
        (or an illegitimate retry is permitted).
        """
        text = SUPERVISOR_HANDOFF_DOC.read_text(encoding="utf-8")
        assert "approval-state change" in text, (
            "Throttle rule must name `approval-state change` as a "
            "retry-unblock condition (user grants harness approval)."
        )
        assert "lane-state change" in text, (
            "Throttle rule must name `lane-state change` as a retry-"
            "unblock condition (HEAD moves, staged count changes, or "
            "denial text changes)."
        )


# ---------------------------------------------------------------------------
# Guardian-only landing guidance pins
# ---------------------------------------------------------------------------
# Context: the runtime already enforces guardian-only landing via
# bash_git_who / authority_registry, but active prompt + handoff surfaces
# previously still preserved an operator action card that told the
# orchestrator to run a push-approval grant followed by `git push`.
# That guidance reintroduced the wrong authority model even though the
# runtime policy was correct. These pins keep the active surfaces aligned:
# Guardian owns evaluated commit/merge/straightforward push, and the
# orchestrator must treat routine push-approval prompts as helper/runtime
# drift rather than self-granting or self-pushing.
# ---------------------------------------------------------------------------

GUARDIAN_LANDING_SURFACES: tuple[Path, ...] = (
    REPO_ROOT / "CLAUDE.md",
    REPO_ROOT / ".codex" / "prompts" / "claudex_handoff.txt",
    REPO_ROOT / ".codex" / "prompts" / "claudex_supervisor.txt",
    REPO_ROOT / "ClauDEX" / "SUPERVISOR_HANDOFF.md",
    REPO_ROOT / "ClauDEX" / "CURRENT_STATE.md",
)

_GUARDIAN_ACTIVE_REGION_DELIMITERS_BY_DOC: dict[str, tuple[str, ...]] = {
    "SUPERVISOR_HANDOFF.md": ("## Historical Phase State Snapshot",),
    "CURRENT_STATE.md": (
        "## Checkpoint Readiness (Phase 8 Slice 12 closeout, 2026-04-14)",
    ),
}

_LEGACY_PUSH_TOKEN_PHRASES: tuple[str, ...] = (
    "cc-policy approval grant claudesox-local push",
)

_PROMPT_REQUIRED_TOKENS: dict[str, tuple[str, ...]] = {
    "claudex_supervisor.txt": (
        "do NOT self-grant",
        "do NOT self-run `git push`",
        "Guardian remains the sole landing actor",
    ),
    "claudex_handoff.txt": (
        "do NOT self-grant",
        "do NOT self-run `git push`",
        "Guardian remains the sole landing actor",
    ),
}


def _guardian_active_region(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    delimiters = _GUARDIAN_ACTIVE_REGION_DELIMITERS_BY_DOC.get(path.name)
    if not delimiters:
        return text
    earliest = len(text)
    for delim in delimiters:
        if text.startswith(delim):
            earliest = min(earliest, 0)
            continue
        anchored = "\n" + delim
        idx = text.find(anchored)
        if idx != -1:
            earliest = min(earliest, idx + 1)
    return text[:earliest]


def test_active_surfaces_do_not_reintroduce_push_token_action_cards() -> None:
    """Active operator surfaces must not reintroduce the old
    `approval grant ... push` action card. Historical snapshots are
    excluded by the doc-specific active-region delimiters above.
    """
    hits: list[str] = []
    for surface in GUARDIAN_LANDING_SURFACES:
        active = _guardian_active_region(surface)
        for phrase in _LEGACY_PUSH_TOKEN_PHRASES:
            if phrase in active:
                hits.append(
                    f"{surface.relative_to(REPO_ROOT)}: legacy push-token phrase "
                    f"reappeared in active guidance: {phrase!r}"
                )
    assert not hits, (
        "Active landing guidance must not tell the orchestrator to run the "
        "legacy push-token workaround:\n" + "\n".join(hits)
    )


def test_claude_md_guardian_land_bullet_mentions_straightforward_push() -> None:
    """CLAUDE.md must state that guardian:land owns straightforward push.
    Omitting push from that bullet leaves room for the orchestrator to
    treat push as outside Guardian's landing authority.
    """
    text = (REPO_ROOT / "CLAUDE.md").read_text(encoding="utf-8")
    assert (
        "- `guardian (land)`: local landing authority (`commit`/`merge`/straightforward `push`"
        in text
    ), (
        "CLAUDE.md must explicitly say guardian (land) owns straightforward "
        "push, not just commit/merge."
    )


def test_supervisor_prompts_forbid_self_grant_or_self_push() -> None:
    """Supervisor-facing prompts must explicitly reject self-grant/self-push
    behavior when a routine push approval prompt appears.
    """
    missing: list[str] = []
    for basename, tokens in _PROMPT_REQUIRED_TOKENS.items():
        path = REPO_ROOT / ".codex" / "prompts" / basename
        text = path.read_text(encoding="utf-8")
        for token in tokens:
            if token not in text:
                missing.append(f"{path.relative_to(REPO_ROOT)}: missing {token!r}")
    assert not missing, (
        "Supervisor-facing prompt surfaces must explicitly forbid self-grant / "
        "self-push drift and keep Guardian as the sole landing actor:\n"
        + "\n".join(missing)
    )


# ---------------------------------------------------------------------------
# A26: mechanical handoff-tip agreement invariant
# ---------------------------------------------------------------------------
# The SUPERVISOR_HANDOFF.md file contains TWO live snapshot sections that both
# narrate the current published lane state:
#   1. `## Current Lane Truth` (top block)
#   2. `## Next bounded cutover slice` (first paragraph + published-chain
#      summary)
# A recurring class of defect (see A17, A20, A23, A24, A25 reconciliation
# slices) is one section landing ahead of the other by a single hop: a docs
# slice updates one section's tip claim but the other section's claim goes
# stale. Readers navigating via the ToC or body-scroll then hit contradictory
# snapshots in the same file.
#
# This invariant enforces internal consistency — both sections must agree on
# the most-recent "current tip" / "post-A<N> push" hash they name. It does
# NOT require the named hash to equal git HEAD (the doc snapshot trails itself
# by one hop by construction; the last hash in the doc is the parent of the
# commit that edited the doc). The guard is about same-file agreement.
# ---------------------------------------------------------------------------


_LANE_TRUTH_SECTION_HEADING = "## Current Lane Truth"
_NEXT_BOUNDED_SECTION_HEADING = "## Next bounded cutover slice"
# Matches the two canonical claim phrasings we expect in these sections:
#   "current tip `27ec3e4`"      (both sections)
#   "Current tip: `27ec3e4`"     (top)
#   "post-A24 push `27ec3e4`"    (`## Next bounded cutover slice` header)
# The suffix `A\d+[A-Z]?` tolerates suffixed slice names like `A21R`, `A19R`.
_TIP_CLAIM_PATTERN = re.compile(
    r"(?:current\s+tip|post-A\d+[A-Z]?\s+push)\s*[:\s]*`([0-9a-f]{7,40})`",
    re.IGNORECASE,
)


def _extract_handoff_section(text: str, heading: str) -> str:
    """Return text from `heading` (inclusive) up to the next top-level `## `
    heading (exclusive). Raises AssertionError when `heading` is absent.
    """
    start = text.find("\n" + heading)
    if start == -1 and text.startswith(heading):
        start = 0
    else:
        start = start + 1 if start != -1 else -1
    assert start != -1, (
        f"SUPERVISOR_HANDOFF.md is missing required section heading {heading!r}; "
        "the A26 tip-agreement invariant cannot locate the snapshot blocks."
    )
    # Find the next top-level `\n## ` heading strictly after this one.
    next_heading = re.search(r"\n## [^\n]", text[start + len(heading):])
    end = (start + len(heading) + next_heading.start()) if next_heading else len(text)
    return text[start:end]


def _last_named_tip(section_text: str) -> str:
    """Return the last 7-char hash referenced by a `current tip` / `post-A<N>
    push` claim in `section_text`. Returns '' when no claim is present.
    """
    hits = _TIP_CLAIM_PATTERN.findall(section_text)
    return hits[-1][:7] if hits else ""


def test_handoff_current_tip_snapshots_agree_between_top_and_next_bounded_sections() -> None:
    """A26 invariant: `## Current Lane Truth` top block and `## Next bounded
    cutover slice` MUST name the same `current tip` / `post-A<N> push` hash.

    The A17 / A20 / A23 / A24 / A25 sequence of manual reconciliation slices
    demonstrates that this class of handoff-internal desynchronization
    recurs every time a docs slice updates one snapshot section without
    touching the other. This guard fails loudly at commit/CI time so the
    drift is impossible to land unnoticed.

    This test enforces **internal consistency**, not equality to git HEAD.
    The named hash naturally trails HEAD by one hop (the current commit is
    the parent of the next commit that will edit the snapshot), which is
    fine — the invariant only requires both sections to name the SAME tip.
    """
    text = SUPERVISOR_HANDOFF_DOC.read_text(encoding="utf-8")

    top_section = _extract_handoff_section(text, _LANE_TRUTH_SECTION_HEADING)
    next_section = _extract_handoff_section(text, _NEXT_BOUNDED_SECTION_HEADING)

    top_tip = _last_named_tip(top_section)
    next_tip = _last_named_tip(next_section)

    assert top_tip, (
        f"{_LANE_TRUTH_SECTION_HEADING!r} section must name at least one "
        "`current tip` or `post-A<N> push <hash>` claim so A26 tip-agreement "
        "can be verified. If the section intentionally omits a live tip "
        "claim, update this invariant to reflect the new canonical shape."
    )
    assert next_tip, (
        f"{_NEXT_BOUNDED_SECTION_HEADING!r} section must name at least one "
        "`current tip` or `post-A<N> push <hash>` claim so A26 tip-agreement "
        "can be verified. If the section intentionally omits a live tip "
        "claim, update this invariant to reflect the new canonical shape."
    )
    assert top_tip == next_tip, (
        f"A26 handoff-tip drift: `{_LANE_TRUTH_SECTION_HEADING}` names tip "
        f"`{top_tip}` but `{_NEXT_BOUNDED_SECTION_HEADING}` names tip "
        f"`{next_tip}`. The two snapshot sections must agree on the most "
        "recent published lane tip. When a docs slice advances the snapshot "
        "of ONE section, update the OTHER section in the same commit — or "
        "run a dedicated reconciliation slice (A17/A20/A23/A24/A25 pattern) "
        "before the next docs slice lands."
    )


def test_handoff_tip_agreement_invariant_scanner_finds_claim_phrases() -> None:
    """Scanner-self sanity pin: the regex used by A26 must actually detect
    the canonical claim phrasings. Catches regression if the claim vocabulary
    in SUPERVISOR_HANDOFF.md changes without the scanner being updated in
    lockstep.
    """
    fixture_claims = [
        "Current tip: `27ec3e4` (post-A24 …)",
        "current tip `27ec3e4`",
        "post-A24 push `27ec3e4`",
        "post-A21R push `db8382c`",
    ]
    for claim in fixture_claims:
        hits = _TIP_CLAIM_PATTERN.findall(claim)
        assert hits, (
            f"A26 tip-claim scanner failed to detect a canonical claim "
            f"phrasing: {claim!r}. Update _TIP_CLAIM_PATTERN to cover the "
            "new phrasing, or keep the handoff doc using existing phrasings."
        )


# ---------------------------------------------------------------------------
# A27: branch-precondition contract pinned in the supervisor prompt
# ---------------------------------------------------------------------------
# Context: the Branch-Precondition Drift class in
# ClauDEX/SUPERVISOR_HANDOFF.md recorded multiple slices (A5-class) that
# were authored against A-branch state but executed on soak
# `claudesox-local`, producing false-premise findings when the implementer
# tried to apply the described patch. The A5R planner deliverable §1
# (re-read target files on the live branch, assert pre-slice state BEFORE
# issuing the scope manifest) was the working recovery pattern. A27
# promotes that pattern from one-slice recovery into a mandatory dispatch
# contract in the supervisor prompt and mechanically pins the contract so
# future prompt drift surfaces as a test failure rather than as another
# class-of-defect recurrence.
# ---------------------------------------------------------------------------


_SUPERVISOR_PROMPT_PATH = REPO_ROOT / ".codex" / "prompts" / "claudex_supervisor.txt"

# Canonical phrase tokens that MUST appear in the supervisor prompt's
# branch-precondition contract clause. Each token names one of the three
# required elements (target branch / expected HEAD / precondition
# verification) plus a header anchor so the clause itself is discoverable
# by phrase-search. Phrasings are narrow enough to fail on meaningful
# rewording but tolerant of whitespace variation.
_BRANCH_PRECONDITION_REQUIRED_TOKENS: tuple[str, ...] = (
    "Branch-precondition contract",
    "target branch identity",
    "expected HEAD SHA",
    "precondition-verification deliverable",
    "re-read the target file",
    "assert the pre-slice state",
    "BEFORE issuing the scope manifest",
)


def test_supervisor_prompt_carries_branch_precondition_contract() -> None:
    """A27 invariant: `.codex/prompts/claudex_supervisor.txt` MUST pin the
    branch-precondition contract clause naming all three required elements
    (target branch identity, expected HEAD SHA, precondition-verification
    deliverable) for every new bounded implementation slice.

    This closes the Branch-Precondition Drift class documented in
    `ClauDEX/SUPERVISOR_HANDOFF.md` where A5-class slices were authored
    against A-branch line numbers but executed on soak `claudesox-local`,
    producing false-premise findings. The clause was a recovery pattern
    (A5R §1); A27 promotes it to a mandatory dispatch contract so future
    prompt drift surfaces here as a failing test rather than as another
    recurrence of the defect class.
    """
    assert _SUPERVISOR_PROMPT_PATH.exists(), (
        f"supervisor prompt missing at {_SUPERVISOR_PROMPT_PATH}; the A27 "
        "branch-precondition contract invariant cannot verify its anchors."
    )
    text = _SUPERVISOR_PROMPT_PATH.read_text(encoding="utf-8")

    missing: list[str] = []
    for token in _BRANCH_PRECONDITION_REQUIRED_TOKENS:
        if token not in text:
            missing.append(token)
    assert not missing, (
        f"A27 branch-precondition contract drift: "
        f"{_SUPERVISOR_PROMPT_PATH.relative_to(REPO_ROOT)} is missing required "
        f"token(s) {missing!r}. The supervisor prompt MUST pin the "
        "branch-precondition contract clause naming target branch identity, "
        "expected HEAD SHA, and a precondition-verification deliverable that "
        "re-reads target files on the live branch BEFORE the scope manifest "
        "is issued. If the clause has been intentionally reworded, update "
        "the token list above in lockstep."
    )


def test_supervisor_prompt_branch_precondition_names_mandatory_discipline() -> None:
    """A27 counterpart pin: the contract clause must be phrased as a hard
    MANDATORY requirement, not advisory. A prompt that softens the clause
    to "consider including" or "optionally" bypasses the defect closure
    silently.
    """
    text = _SUPERVISOR_PROMPT_PATH.read_text(encoding="utf-8")
    assert "MANDATORY" in text, (
        f"{_SUPERVISOR_PROMPT_PATH.relative_to(REPO_ROOT)} must phrase the "
        "branch-precondition contract as MANDATORY (or equivalently-strong "
        "language). An advisory-only phrasing silently reopens the Branch-"
        "Precondition Drift class. If the discipline word was intentionally "
        "softened, update this invariant in lockstep and document why."
    )

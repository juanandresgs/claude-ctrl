"""Phase 8 deletion invariants (Slice 2 + Slice 4 + Slice 5 + Slice 6).

Pins the state produced by Phase 8's narrow deletion slices — that the
specific files removed in each slice stay gone and that no live/near-live
surface still references them by name.

These assertions are narrow and deletion-specific on purpose. They are NOT
a generic "deleted-file registry"; they exist to prevent accidental
reintroduction of the specific orphans removed in Phase 8.

@decision DEC-PHASE8-SLICE2-001
Title: auto-review.sh decommission invariant pins
Status: accepted
Rationale: auto-review.sh was removed from live wiring by commit c7a3109
  per DEC-PHASE0-003 (MASTER_PLAN.md:10354) and P0-C. Phase 8 Slice 2
  completed the deletion of the hook, its three scenario tests, and the
  one stale comment in hooks/lib/hook-safety.sh. These pins detect any
  re-add without going through a coordinated slice.

@decision DEC-PHASE8-SLICE4-001
Title: handoff-doc deletion invariant pins
Status: accepted
Rationale: Phase 8 Slice 4 deleted two session-scoped handoff artifacts
  (docs/AGENT_HANDOFFS.md, docs/HANDOFF_2026-03-31.md) that had zero live
  inbound references outside historical session-forensics archives. The
  third handoff (docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md) was retained at
  Slice 4 because MASTER_PLAN.md:2645 still cited it; Phase 8 Slice 6
  subsequently retired that handoff after preservation audit (see
  DEC-PHASE8-SLICE6-001). These pins detect any re-add of the two
  Slice-4 handoffs and any accidental inbound reference to their names
  from live docs/config/tests.

@decision DEC-PHASE8-SLICE5-001
Title: PHASE0 donor-doc retirement invariant pins
Status: accepted
Rationale: Phase 8 Slice 5 deleted docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md
  after a preservation audit confirmed its three recommendations and the
  11-item HOOKS.md-vs-official-docs delta are all canonically held in
  MASTER_PLAN.md INIT-PHASE0 (DEC-PHASE0-001 at L10310, DEC-PHASE0-002 at
  L10331, DEC-PHASE0-003 at L10354, P0-H delta table at L10512-10530).
  The donor doc self-declared as non-normative at its own line 6. These
  pins detect any re-add of the donor doc or any inbound reference to its
  basename from live authority surfaces. Phase 8 tracking docs under
  ClauDEX/ are intentionally excluded so historical-context citations
  remain permitted there.

@decision DEC-PHASE8-SLICE6-001
Title: INIT-CONV handoff-doc retirement invariant pins
Status: accepted
Rationale: Phase 8 Slice 6 deleted docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md
  after a preservation audit confirmed its North Star, 6 execution
  packets, and required retest set are canonically held in MASTER_PLAN.md
  INIT-CONV (L2631-3043) across W-CONV-1 through W-CONV-7. INIT-CONV
  itself is marked `complete (all 6 waves landed, 2026-04-05/06)`. The
  MASTER_PLAN.md:2645 **Handoff:** link was replaced with a historical
  note in the same bundle. These pins detect any re-add of the handoff
  doc or any inbound reference to its basename from live authority
  surfaces — the MASTER_PLAN.md surface in particular guards against the
  dead link reappearing. ClauDEX/ tracking docs are intentionally
  excluded so historical-context citations remain permitted there.

@decision DEC-PHASE8-SLICE10-001
Title: Tester Bundle 1 wiring-decommission invariant pins
Status: accepted
Rationale: Phase 8 Slice 10 (Tester Bundle 1) removed every live
  producer path that creates a `tester` SubagentStop/completion. Slice 10
  pinned the file-level deletions (hooks/check-tester.sh, agents/tester.md,
  and four tester-specific scenario tests) and the absence of a
  SubagentStop:tester wiring in settings.json / hooks/HOOKS.md. The
  runtime-authority flip (ROLE_SCHEMAS, dispatch_engine._known_types,
  dispatch_shadow.KNOWN_LIVE_ROLES, leases.ROLE_DEFAULTS, ensure_schema)
  shipped in Slice 11 (Tester Bundle 2); the executable-test and live-doc
  cleanup landed as the Slice 11 correction. The pins in this file
  therefore split along the same boundary:
    • Slice 10 pins (this section) continue to forbid reintroduction of
      the deleted file set, the `check-tester.sh` script name, and the
      `agents/tester.md` prompt path on live-authority surfaces.
    • Slice 11 pins (below) forbid the runtime-authority reappearance of
      the `tester` role and require live CLI help plus scenario/acceptance
      tests to be free of live `implementer→tester` / `tester→guardian`
      routing claims and `check-tester.sh` invocations.

@decision DEC-PHASE8-SLICE11-001
Title: Tester Bundle 2 runtime + executable-surface invariant pins
Status: accepted
Rationale: Phase 8 Slice 11 (Tester Bundle 2) completes the retirement of
  the `tester` role. Runtime pins below query live Python authority
  modules (not file contents) so they cannot be satisfied by moving
  ``tester`` into a comment. Surface pins below forbid live scenario and
  acceptance tests from invoking the deleted ``check-tester.sh`` or
  asserting the retired ``implementer→tester`` / ``tester→guardian``
  routing; a live CLI-help pin verifies that no advertised agent-role
  example still names ``tester``.
"""
from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]

# Slice 2: auto-review.sh hook + scenario tests
SLICE2_DELETED_FILES = (
    REPO_ROOT / "hooks" / "auto-review.sh",
    REPO_ROOT / "tests" / "scenarios" / "test-auto-review.sh",
    REPO_ROOT / "tests" / "scenarios" / "test-auto-review-heredoc.sh",
    REPO_ROOT / "tests" / "scenarios" / "test-auto-review-quoted-pipes.sh",
)

SLICE2_NO_REFERENCE_SURFACES = (
    REPO_ROOT / "settings.json",
    REPO_ROOT / "hooks" / "HOOKS.md",
    REPO_ROOT / "hooks" / "lib" / "hook-safety.sh",
)

# Slice 4: handoff docs proven unreferenced by live authority
SLICE4_DELETED_HANDOFFS = (
    REPO_ROOT / "docs" / "AGENT_HANDOFFS.md",
    REPO_ROOT / "docs" / "HANDOFF_2026-03-31.md",
)

# Surfaces that must NOT reference the Slice 4 deleted handoff basenames.
# Scope is deliberately narrow: live top-level authority docs + runtime
# config + the runtime/hooks/tests trees. Historical session-forensics
# archives under ClauDEX/session-forensics/ are intentionally excluded
# because they are frozen session captures, not live authority.
SLICE4_NO_REFERENCE_SURFACES = (
    REPO_ROOT / "settings.json",
    REPO_ROOT / "MASTER_PLAN.md",
    REPO_ROOT / "CLAUDE.md",
    REPO_ROOT / "AGENTS.md",
    REPO_ROOT / "implementation_plan.md",
    REPO_ROOT / "docs" / "ARCHITECTURE.md",
    REPO_ROOT / "docs" / "DISPATCH.md",
    REPO_ROOT / "docs" / "PLAN_DISCIPLINE.md",
    REPO_ROOT / "hooks" / "HOOKS.md",
)

SLICE4_DELETED_BASENAMES = tuple(p.name for p in SLICE4_DELETED_HANDOFFS)

# Slice 5: PHASE0 donor doc retired after preservation audit
SLICE5_DELETED_DOC = REPO_ROOT / "docs" / "PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md"
SLICE5_DELETED_BASENAME = SLICE5_DELETED_DOC.name

# Live-authority surfaces that must not name the deleted donor doc.
# Phase 8 tracking docs under ClauDEX/ are intentionally excluded so
# historical-context citations of the deleted doc remain permitted there.
SLICE5_NO_REFERENCE_SURFACES = (
    REPO_ROOT / "settings.json",
    REPO_ROOT / "MASTER_PLAN.md",
    REPO_ROOT / "CLAUDE.md",
    REPO_ROOT / "AGENTS.md",
    REPO_ROOT / "implementation_plan.md",
    REPO_ROOT / "docs" / "ARCHITECTURE.md",
    REPO_ROOT / "docs" / "DISPATCH.md",
    REPO_ROOT / "docs" / "PLAN_DISCIPLINE.md",
    REPO_ROOT / "hooks" / "HOOKS.md",
)

# Slice 6: INIT-CONV handoff retired after preservation audit
SLICE6_DELETED_HANDOFF = REPO_ROOT / "docs" / "HANDOFF_2026-04-05_SYSTEM_EVAL.md"
SLICE6_DELETED_BASENAME = SLICE6_DELETED_HANDOFF.name

# Same live-authority surface set as Slice 5. The MASTER_PLAN.md pin is
# especially important here because it guards against the old
# `**Handoff:** docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` link silently
# reappearing under a new INIT-CONV wave.
SLICE6_NO_REFERENCE_SURFACES = (
    REPO_ROOT / "settings.json",
    REPO_ROOT / "MASTER_PLAN.md",
    REPO_ROOT / "CLAUDE.md",
    REPO_ROOT / "AGENTS.md",
    REPO_ROOT / "implementation_plan.md",
    REPO_ROOT / "docs" / "ARCHITECTURE.md",
    REPO_ROOT / "docs" / "DISPATCH.md",
    REPO_ROOT / "docs" / "PLAN_DISCIPLINE.md",
    REPO_ROOT / "hooks" / "HOOKS.md",
)


@pytest.mark.parametrize("path", SLICE2_DELETED_FILES, ids=lambda p: p.name)
def test_phase8_slice2_file_is_deleted(path: Path) -> None:
    assert not path.exists(), (
        f"{path.relative_to(REPO_ROOT)} must not exist after Phase 8 Slice 2. "
        f"It was deleted as part of the auto-review.sh decommission."
    )


@pytest.mark.parametrize(
    "path",
    SLICE2_NO_REFERENCE_SURFACES,
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_phase8_slice2_surface_has_no_auto_review_reference(path: Path) -> None:
    assert path.exists(), f"expected surface to exist: {path}"
    text = path.read_text(encoding="utf-8")
    assert "auto-review" not in text, (
        f"{path.relative_to(REPO_ROOT)} still references 'auto-review'. "
        f"All references must be removed by Phase 8 Slice 2."
    )


@pytest.mark.parametrize("path", SLICE4_DELETED_HANDOFFS, ids=lambda p: p.name)
def test_phase8_slice4_handoff_is_deleted(path: Path) -> None:
    assert not path.exists(), (
        f"{path.relative_to(REPO_ROOT)} must not exist after Phase 8 Slice 4. "
        f"It was deleted as an unreferenced session-scoped handoff artifact."
    )


@pytest.mark.parametrize(
    "path",
    SLICE4_NO_REFERENCE_SURFACES,
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_phase8_slice4_surface_has_no_deleted_handoff_reference(path: Path) -> None:
    assert path.exists(), f"expected surface to exist: {path}"
    text = path.read_text(encoding="utf-8")
    for basename in SLICE4_DELETED_BASENAMES:
        assert basename not in text, (
            f"{path.relative_to(REPO_ROOT)} still references "
            f"'{basename}'. Phase 8 Slice 4 requires all live inbound "
            f"references to deleted handoff docs to be removed."
        )


def test_phase8_slice5_phase0_doc_is_deleted() -> None:
    assert not SLICE5_DELETED_DOC.exists(), (
        f"{SLICE5_DELETED_DOC.relative_to(REPO_ROOT)} must not exist after "
        f"Phase 8 Slice 5. It was retired after MASTER_PLAN.md INIT-PHASE0 "
        f"was confirmed as the canonical authority (DEC-PHASE0-001/002/003 "
        f"and the P0-H delta table)."
    )


@pytest.mark.parametrize(
    "path",
    SLICE5_NO_REFERENCE_SURFACES,
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_phase8_slice5_surface_has_no_phase0_doc_reference(path: Path) -> None:
    assert path.exists(), f"expected surface to exist: {path}"
    text = path.read_text(encoding="utf-8")
    assert SLICE5_DELETED_BASENAME not in text, (
        f"{path.relative_to(REPO_ROOT)} still references "
        f"'{SLICE5_DELETED_BASENAME}'. Phase 8 Slice 5 requires all live "
        f"authority references to the retired donor doc to be removed "
        f"(re-point at MASTER_PLAN.md INIT-PHASE0 / DEC-PHASE0-003)."
    )


def test_phase8_slice6_handoff_is_deleted() -> None:
    assert not SLICE6_DELETED_HANDOFF.exists(), (
        f"{SLICE6_DELETED_HANDOFF.relative_to(REPO_ROOT)} must not exist "
        f"after Phase 8 Slice 6. It was retired after MASTER_PLAN.md "
        f"INIT-CONV (L2631-3043) was confirmed as the canonical authority "
        f"holding the North Star, 6 packets, and retest set."
    )


@pytest.mark.parametrize(
    "path",
    SLICE6_NO_REFERENCE_SURFACES,
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_phase8_slice6_surface_has_no_handoff_reference(path: Path) -> None:
    assert path.exists(), f"expected surface to exist: {path}"
    text = path.read_text(encoding="utf-8")
    assert SLICE6_DELETED_BASENAME not in text, (
        f"{path.relative_to(REPO_ROOT)} still references "
        f"'{SLICE6_DELETED_BASENAME}'. Phase 8 Slice 6 requires all live "
        f"authority references to the retired handoff doc to be removed "
        f"(re-point at MASTER_PLAN.md INIT-CONV)."
    )


# ---------------------------------------------------------------------------
# Slice 10: Tester Bundle 1 wiring decommission
# ---------------------------------------------------------------------------

# Files deleted by Slice 10: the tester SubagentStop hook, the tester
# agent prompt, and the four tester-specific scenario tests. Bundle 2
# (Slice 11) removed the remaining dead runtime code (ROLE_SCHEMAS entry,
# dispatch_engine branch, dispatch_shadow mappings, leases/schemas/eval
# harness paths) and cleaned the near-live docs and executable tests; the
# runtime-authority and executable-surface pins live in the Slice 11
# section below.
SLICE10_DELETED_FILES = (
    REPO_ROOT / "hooks" / "check-tester.sh",
    REPO_ROOT / "agents" / "tester.md",
    REPO_ROOT / "tests" / "scenarios" / "test-check-tester-valid-trailer.sh",
    REPO_ROOT / "tests" / "scenarios" / "test-check-tester-invalid-trailer.sh",
    REPO_ROOT / "tests" / "scenarios" / "test-completion-tester.sh",
    REPO_ROOT / "tests" / "scenarios" / "test-routing-tester-completion.sh",
)

# Live-authority surfaces that must not name the deleted check-tester.sh
# adapter OR the deleted agents/tester.md prompt path. We deliberately do
# NOT forbid the bare string "tester" here; Bundle 2 will remove the
# remaining dead runtime references and can tighten the pin at that time.
#
# The pin set includes:
#   - settings.json (live hook wiring authority)
#   - hooks/HOOKS.md (generated projection of the runtime manifest)
#   - the live SubagentStop/PreToolUse/UserPromptSubmit hooks whose comments
#     were cleaned as part of the Slice 10 correction — re-introduction of
#     `check-tester.sh` in any of these would silently resurrect the legacy
#     producer in live narrative
#   - live authority docs under docs/ that also carried stale references
SLICE10_NO_ADAPTER_REFERENCE_SURFACES = (
    REPO_ROOT / "settings.json",
    REPO_ROOT / "hooks" / "HOOKS.md",
    REPO_ROOT / "hooks" / "prompt-submit.sh",
    REPO_ROOT / "hooks" / "track.sh",
    REPO_ROOT / "hooks" / "check-reviewer.sh",
    REPO_ROOT / "hooks" / "check-guardian.sh",
    REPO_ROOT / "hooks" / "check-implementer.sh",
    REPO_ROOT / "hooks" / "post-task.sh",
    REPO_ROOT / "hooks" / "write-guard.sh",
    REPO_ROOT / "hooks" / "context-lib.sh",
    REPO_ROOT / "docs" / "DISPATCH.md",
    REPO_ROOT / "docs" / "SYSTEM_MENTAL_MODEL.md",
    REPO_ROOT / "tests" / "scenarios" / "capture" / "PAYLOAD_CONTRACT.md",
)

SLICE10_DELETED_ADAPTER_BASENAME = "check-tester.sh"
SLICE10_DELETED_PROMPT_PATH = "agents/tester.md"


@pytest.mark.parametrize(
    "path", SLICE10_DELETED_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT))
)
def test_phase8_slice10_file_is_deleted(path: Path) -> None:
    assert not path.exists(), (
        f"{path.relative_to(REPO_ROOT)} must not exist after Phase 8 "
        f"Slice 10 (Tester Bundle 1 wiring decommission). It was removed "
        f"as part of the live tester-producer deletion. If re-adding is "
        f"truly needed, go through a new coordinated slice — do not "
        f"silently reintroduce a live tester producer."
    )


@pytest.mark.parametrize(
    "path",
    SLICE10_NO_ADAPTER_REFERENCE_SURFACES,
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_phase8_slice10_surface_has_no_check_tester_reference(path: Path) -> None:
    assert path.exists(), f"expected surface to exist: {path}"
    text = path.read_text(encoding="utf-8")
    assert SLICE10_DELETED_ADAPTER_BASENAME not in text, (
        f"{path.relative_to(REPO_ROOT)} still references "
        f"'{SLICE10_DELETED_ADAPTER_BASENAME}'. Phase 8 Slice 10 removed "
        f"every live tester producer — no live hook/doc/settings surface "
        f"may carry a SubagentStop:tester adapter reference."
    )


@pytest.mark.parametrize(
    "path",
    SLICE10_NO_ADAPTER_REFERENCE_SURFACES,
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_phase8_slice10_surface_has_no_tester_prompt_reference(path: Path) -> None:
    """Live surfaces must not name the deleted agents/tester.md prompt path.

    Deliberately narrow: this forbids only the exact relative path
    `agents/tester.md` (the deleted prompt), not the bare role string
    `tester`. Bundle 2 owns the broader dead-code cleanup and can tighten
    the pin to forbid the raw role string once the runtime references are
    gone.
    """
    assert path.exists(), f"expected surface to exist: {path}"
    text = path.read_text(encoding="utf-8")
    assert SLICE10_DELETED_PROMPT_PATH not in text, (
        f"{path.relative_to(REPO_ROOT)} still references "
        f"'{SLICE10_DELETED_PROMPT_PATH}'. Phase 8 Slice 10 deleted the "
        f"tester agent prompt — live hook/doc/settings surfaces must not "
        f"carry the path back in."
    )


def test_phase8_slice10_settings_has_no_tester_matcher() -> None:
    """settings.json must not declare any SubagentStop matcher === 'tester'.

    Narrow JSON-shape check — does not scan the file for the bare string
    "tester". The runtime-authority flip pinning the absence of ``tester``
    in completions/dispatch/schemas/leases lives in the Slice 11 section
    below.
    """
    import json

    settings_path = REPO_ROOT / "settings.json"
    assert settings_path.exists(), "settings.json must exist"
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    subagent_stop = settings.get("hooks", {}).get("SubagentStop", [])
    for matcher_block in subagent_stop:
        matcher = matcher_block.get("matcher", "")
        assert matcher != "tester", (
            "settings.json SubagentStop declares matcher='tester'. "
            "Phase 8 Slice 10 removed this wiring — it must not reappear."
        )


# ---------------------------------------------------------------------------
# Slice 11: Tester Bundle 2 — dead-code cleanup + invariant flip
# ---------------------------------------------------------------------------
#
# The runtime-authority pins below (ROLE_SCHEMAS, dispatch_engine,
# dispatch_shadow, leases, schemas, determine_next_role) are joined by
# (1) a live CLI-help pin verifying that no advertised agent-role example
# still names ``tester`` and (2) executable-surface pins forbidding any
# scenario or acceptance test from naming ``check-tester.sh``, asserting
# ``implementer→tester`` / ``tester→guardian`` routing, or claiming
# ``tester`` as a current payload role. Together they mechanically enforce
# the Slice 11 contract: after this slice `tester` is not a known,
# validated, routed, advertised, or exercised runtime role.


def test_phase8_slice11_tester_absent_from_role_schemas() -> None:
    """runtime.core.completions.ROLE_SCHEMAS must not contain 'tester'.

    ROLE_SCHEMAS is the single source of truth for which roles have a
    validated completion schema. Phase 8 Slice 11 removed the tester entry;
    a re-addition would revive role_not_enforced→validated on tester payloads.
    """
    from runtime.core import completions as _c

    assert "tester" not in _c.ROLE_SCHEMAS, (
        "runtime.core.completions.ROLE_SCHEMAS must not contain 'tester' "
        "after Phase 8 Slice 11. Adding it back reintroduces a validated "
        "tester completion path the rest of the runtime no longer honours."
    )


def test_phase8_slice11_tester_absent_from_dispatch_engine_known_types() -> None:
    """process_agent_stop must take the unknown-type silent-exit path for 'tester'.

    The `_known_types` set inside ``process_agent_stop`` determines which
    agent_type values get routing. After Slice 11, tester stop events must
    fall through to the early silent return. We verify this behaviourally:
    a SubagentStop with agent_type="tester" must return next_role=None,
    error=None, auto_dispatch=False, and emit no shadow event.
    """
    import sqlite3

    from runtime.core import events
    from runtime.core.dispatch_engine import process_agent_stop
    from runtime.schemas import ensure_schema

    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        before = len(events.query(conn, type="shadow_stage_decision", limit=100))
        result = process_agent_stop(conn, "tester", "/tmp/irrelevant")
        assert result["next_role"] in (None, ""), (
            f"tester must be treated as unknown-type; got next_role={result['next_role']!r}"
        )
        assert result["error"] is None
        assert result["auto_dispatch"] is False
        after = len(events.query(conn, type="shadow_stage_decision", limit=100))
        assert after == before, (
            "process_agent_stop('tester', ...) emitted a shadow event — "
            "tester must take the unknown-type early-exit path with no emission."
        )
    finally:
        conn.close()


def test_phase8_slice11_tester_absent_from_dispatch_shadow_known_live_roles() -> None:
    """dispatch_shadow.KNOWN_LIVE_ROLES must not contain 'tester'.

    The shadow observer's KNOWN_LIVE_ROLES gates whether a live role gets
    mapped onto the shadow stage graph. After Slice 11 tester is unknown —
    every shadow decision with live_role='tester' returns reason=unknown_live_role.
    """
    from runtime.core import dispatch_shadow as _ds

    assert "tester" not in _ds.KNOWN_LIVE_ROLES, (
        "dispatch_shadow.KNOWN_LIVE_ROLES must not contain 'tester' after "
        "Phase 8 Slice 11. Re-adding it revives the tester→reviewer collapse "
        "mapping that the live path no longer produces."
    )

    # Behavioural assertion: compute_shadow_decision with live_role='tester'
    # must tag the payload as unknown_live_role and agreed=False.
    d = _ds.compute_shadow_decision(
        live_role="tester",
        live_verdict="ready_for_guardian",
        live_next_role="guardian",
        guardian_mode="",
    )
    assert d["reason"] == _ds.REASON_UNKNOWN_LIVE_ROLE
    assert d["agreed"] is False
    assert d["shadow_from_stage"] is None
    assert d["shadow_next_stage"] is None


def test_phase8_slice11_tester_absent_from_leases_role_defaults() -> None:
    """leases.ROLE_DEFAULTS must not contain 'tester'.

    ROLE_DEFAULTS is the single source of per-role allowed_ops and
    requires_eval defaults. Unknown roles fall back to the conservative
    ``["routine_local"]`` policy. After Slice 11 tester is no longer a
    first-class role; this pin catches a silent re-add that would grant
    tester a privileged ops set again.
    """
    from runtime.core import leases as _l

    assert "tester" not in _l.ROLE_DEFAULTS, (
        "runtime.core.leases.ROLE_DEFAULTS must not contain 'tester' after "
        "Phase 8 Slice 11. Re-adding it revives a privileged tester op set; "
        "unknown roles must fall back to routine_local only."
    )


def test_phase8_slice11_tester_not_in_ensure_schema_retained_role_set() -> None:
    """ensure_schema() must deactivate tester markers on startup.

    DEC-CONV-002 (runtime/schemas.py) deactivates any active marker whose
    role is NOT in the retained set. Phase 8 Slice 11 removed ``tester``
    from that whitelist, so a tester marker inserted into a fresh DB must
    be ``is_active=0`` after the next ensure_schema() run.
    """
    import sqlite3
    import time

    from runtime.schemas import ensure_schema

    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        now = int(time.time())
        conn.execute(
            "INSERT INTO agent_markers "
            "(agent_id, role, started_at, is_active, status) "
            "VALUES (?, ?, ?, 1, 'active')",
            ("ghost-tester-agent", "tester", now),
        )
        conn.commit()
        # Second ensure_schema call runs the idempotent cleanup migration.
        ensure_schema(conn)
        row = conn.execute(
            "SELECT is_active, status FROM agent_markers WHERE agent_id = ?",
            ("ghost-tester-agent",),
        ).fetchone()
        assert row is not None
        assert row["is_active"] == 0, (
            "ensure_schema must deactivate active 'tester' markers after "
            "Phase 8 Slice 11. Retaining tester in the whitelist reintroduces "
            "a ghost-role path in build_context()."
        )
        assert row["status"] == "stopped"
    finally:
        conn.close()


def test_phase8_slice11_determine_next_role_returns_none_for_tester() -> None:
    """completions.determine_next_role('tester', <verdict>) must return None.

    The routing authority no longer knows 'tester'; every tester verdict
    collapses to None (unknown-role). Pinning this catches a silent re-add
    of a tester branch in _ROLE_TO_STAGES or _STAGE_TO_ROLE.
    """
    from runtime.core.completions import determine_next_role

    for verdict in ("ready_for_guardian", "needs_changes", "blocked_by_plan", ""):
        assert determine_next_role("tester", verdict) is None, (
            f"determine_next_role('tester', {verdict!r}) must return None "
            f"after Phase 8 Slice 11."
        )


def test_phase8_slice11_agents_tester_md_stays_deleted() -> None:
    """agents/tester.md was deleted in Slice 10; must still be gone in Bundle 2."""
    path = REPO_ROOT / "agents" / "tester.md"
    assert not path.exists(), (
        f"{path.relative_to(REPO_ROOT)} must not exist after Phase 8 "
        f"Slice 11. Bundle 2 completes the tester retirement; the prompt "
        f"may not reappear."
    )


# ---------------------------------------------------------------------------
# Slice 11: CLI help advertisement pin
# ---------------------------------------------------------------------------

_SLICE11_CLI_HELP_COMMANDS = (
    ("lease", "issue-for-dispatch", "--help"),
)


@pytest.mark.parametrize("argv", _SLICE11_CLI_HELP_COMMANDS, ids=lambda a: " ".join(a))
def test_phase8_slice11_cli_help_does_not_advertise_tester(argv) -> None:
    """Live CLI help surfaces must not list ``tester`` as an agent-role example.

    ``cc-policy lease issue-for-dispatch --help`` (and other role-bearing
    CLI entrypoints) renders a parenthetical of valid roles via argparse.
    After Phase 8 Slice 11 the advertised role list is
    ``(implementer, reviewer, guardian, planner)``; the string ``tester``
    must be absent from the help output. This pin invokes the CLI directly
    so it also catches help-string drift caused by argparse help= edits
    that are invisible in tests/ file-scans.
    """
    import subprocess
    import sys

    cli = REPO_ROOT / "runtime" / "cli.py"
    result = subprocess.run(
        [sys.executable, str(cli), *argv],
        capture_output=True,
        text=True,
        check=False,
    )
    combined = (result.stdout or "") + (result.stderr or "")
    assert combined, f"cc-policy {' '.join(argv)} produced no help output"
    assert "tester" not in combined, (
        f"cc-policy {' '.join(argv)} help output still advertises 'tester'. "
        f"After Phase 8 Slice 11 the role list must not name the retired "
        f"tester role. Full output:\n{combined}"
    )


# ---------------------------------------------------------------------------
# Slice 11: Executable-surface pins — live scenario and acceptance tests
# must not resurrect tester as a routed role or invoke check-tester.sh.
# ---------------------------------------------------------------------------

# Directories that contain executable scenario and acceptance tests. Their
# contents ship as part of the tests suite and run in CI. Any live tester
# claim in these files would mean Slice 11 is not actually enforced.
_SLICE11_EXECUTABLE_TEST_ROOTS = (
    REPO_ROOT / "tests" / "scenarios",
    REPO_ROOT / "tests" / "acceptance",
)

# Phrases that would indicate a live tester producer/routing claim. The
# set is deliberately narrow: we forbid the exact invocation string
# ``check-tester.sh`` and the two retired routing arrows, not the bare
# word "tester" (which is permitted in explicit retirement invariants
# and in natural-language notes explaining the retirement itself).
_SLICE11_FORBIDDEN_LIVE_TESTER_PHRASES = (
    "check-tester.sh",
    "implementer→tester",
    "implementer->tester",
    "tester→guardian",
    "tester->guardian",
)

# Files whose role is precisely to pin the retirement (and therefore
# legitimately spell the forbidden phrases as negative assertions or
# explanatory prose). Bundle 2 adds only this pin module to the set.
_SLICE11_EXECUTABLE_PIN_EXEMPTIONS = frozenset(
    {
        # self — this pin file asserts absence via the forbidden strings.
    }
)


def _iter_slice11_executable_test_files():
    for root in _SLICE11_EXECUTABLE_TEST_ROOTS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            if path.suffix not in {".sh", ".py"}:
                continue
            yield path


def _slice11_executable_test_ids():
    return [
        str(p.relative_to(REPO_ROOT)) for p in _iter_slice11_executable_test_files()
    ]


@pytest.mark.parametrize(
    "path",
    list(_iter_slice11_executable_test_files()),
    ids=_slice11_executable_test_ids(),
)
def test_phase8_slice11_executable_test_has_no_live_tester_surface(
    path: Path,
) -> None:
    """Live scenario/acceptance tests must not resurrect the tester path.

    After Phase 8 Slice 11 no executable test under ``tests/scenarios`` or
    ``tests/acceptance`` may:
      * invoke ``hooks/check-tester.sh`` (the Slice 10 deleted adapter), or
      * assert ``implementer→tester`` / ``tester→guardian`` routing.

    These phrases were the live tester producer/routing surface in the
    pre-Slice-11 tree. Any reappearance means a live test is exercising
    a retired role.
    """
    if path.relative_to(REPO_ROOT) in _SLICE11_EXECUTABLE_PIN_EXEMPTIONS:
        pytest.skip("pin-module exemption")
    text = path.read_text(encoding="utf-8", errors="replace")
    for phrase in _SLICE11_FORBIDDEN_LIVE_TESTER_PHRASES:
        assert phrase not in text, (
            f"{path.relative_to(REPO_ROOT)} still contains "
            f"'{phrase}' — a live tester producer/routing surface. "
            f"Phase 8 Slice 11 retired the tester role; executable tests "
            f"must route through reviewer instead."
        )


# ---------------------------------------------------------------------------
# Slice 11: Capture-doc pin — payload role catalogue must not list tester
# as a current payload role.
# ---------------------------------------------------------------------------

_SLICE11_CAPTURE_DOC_PAYLOAD_CONTRACT = (
    REPO_ROOT / "tests" / "scenarios" / "capture" / "PAYLOAD_CONTRACT.md"
)


def test_phase8_slice11_capture_payload_contract_has_no_live_tester_role() -> None:
    """PAYLOAD_CONTRACT.md must not list ``tester`` as a live agent_type value.

    The Slice 11 correction rewrote the SubagentStart agent_type catalogue
    to drop ``tester`` from the live list and add a retirement note. This
    pin asserts that structure mechanically: the file may mention the word
    ``tester`` only in the retirement context — never as a bullet entry
    ``- `tester` — ...`` advertising it as a known live value.
    """
    path = _SLICE11_CAPTURE_DOC_PAYLOAD_CONTRACT
    assert path.exists(), f"expected capture contract doc to exist: {path}"
    text = path.read_text(encoding="utf-8")
    # A live-role bullet has the form: ``- `tester` — ...``
    assert "- `tester` —" not in text and "- `tester` -" not in text, (
        f"{path.relative_to(REPO_ROOT)} still advertises `tester` as a "
        f"live agent_type payload value. Phase 8 Slice 11 retired the role; "
        f"the bullet must be removed (a retirement note is permitted)."
    )


# ---------------------------------------------------------------------------
# Post-Phase-8 Category C bundle 1 — proof_state retirement
# (DEC-CATEGORY-C-PROOF-RETIRE-001)
# ---------------------------------------------------------------------------


def test_post_phase8_category_c_proof_source_is_deleted() -> None:
    """runtime/core/proof.py must remain deleted under
    DEC-CATEGORY-C-PROOF-RETIRE-001.
    """
    path = REPO_ROOT / "runtime" / "core" / "proof.py"
    assert not path.exists(), (
        f"runtime/core/proof.py must remain deleted under "
        f"DEC-CATEGORY-C-PROOF-RETIRE-001; still present at {path}"
    )


def test_post_phase8_category_c_proof_state_ddl_removed_from_schemas() -> None:
    """runtime/schemas.py must not declare PROOF_STATE_DDL or a
    CREATE TABLE statement for proof_state.
    """
    import re as _re

    schemas_src = (REPO_ROOT / "runtime" / "schemas.py").read_text(encoding="utf-8")
    assert "PROOF_STATE_DDL" not in schemas_src, (
        "runtime/schemas.py must not define PROOF_STATE_DDL after Category C "
        "bundle 1 retirement"
    )
    assert not _re.search(
        r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+proof_state",
        schemas_src,
        flags=_re.IGNORECASE,
    ), (
        "runtime/schemas.py must not contain a CREATE TABLE IF NOT EXISTS "
        "proof_state statement"
    )


# ---------------------------------------------------------------------------
# Post-Phase-8 Category C bundle 2 — dispatch_queue / dispatch_cycles retirement
# (DEC-CATEGORY-C-DISPATCH-RETIRE-001)
# ---------------------------------------------------------------------------


def test_post_phase8_category_c_dispatch_source_is_deleted() -> None:
    """runtime/core/dispatch.py must remain deleted under
    DEC-CATEGORY-C-DISPATCH-RETIRE-001.
    """
    path = REPO_ROOT / "runtime" / "core" / "dispatch.py"
    assert not path.exists(), (
        f"runtime/core/dispatch.py must remain deleted under "
        f"DEC-CATEGORY-C-DISPATCH-RETIRE-001; still present at {path}"
    )


def test_post_phase8_category_c_dispatch_queue_ddl_removed_from_schemas() -> None:
    """runtime/schemas.py must not declare DISPATCH_QUEUE_DDL or a
    CREATE TABLE for dispatch_queue.
    """
    import re as _re

    schemas_src = (REPO_ROOT / "runtime" / "schemas.py").read_text(encoding="utf-8")
    assert "DISPATCH_QUEUE_DDL" not in schemas_src, (
        "runtime/schemas.py must not define DISPATCH_QUEUE_DDL after retirement"
    )
    assert not _re.search(
        r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+dispatch_queue",
        schemas_src,
        flags=_re.IGNORECASE,
    ), (
        "runtime/schemas.py must not contain a CREATE TABLE IF NOT EXISTS "
        "dispatch_queue statement"
    )


def test_post_phase8_category_c_dispatch_cycles_ddl_removed_from_schemas() -> None:
    """runtime/schemas.py must not declare DISPATCH_CYCLES_DDL or a
    CREATE TABLE for dispatch_cycles.
    """
    import re as _re

    schemas_src = (REPO_ROOT / "runtime" / "schemas.py").read_text(encoding="utf-8")
    assert "DISPATCH_CYCLES_DDL" not in schemas_src, (
        "runtime/schemas.py must not define DISPATCH_CYCLES_DDL after retirement"
    )
    assert not _re.search(
        r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+dispatch_cycles",
        schemas_src,
        flags=_re.IGNORECASE,
    ), (
        "runtime/schemas.py must not contain a CREATE TABLE IF NOT EXISTS "
        "dispatch_cycles statement"
    )

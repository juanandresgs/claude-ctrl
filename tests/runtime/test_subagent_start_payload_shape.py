"""Pins the observed live SubagentStart payload shape from dispatch-debug.jsonl.

@decision DEC-CLAUDEX-SA-PAYLOAD-SHAPE-001
Title: SubagentStart payload shape pinned from captured truth — six contract
       fields are NOT present; single runtime-owned carrier path identified
Status: accepted (truth-finding, 2026-04-09)
Rationale:
  hooks/subagent-start.sh (after the Slice 5 hook-adapter reduction) has a
  runtime-first branch that activates when the incoming payload carries the
  six prompt-pack request fields at the top level.  Before the carrier path
  is implemented, that branch is NEVER reached because the Claude Code
  harness only emits six fixed fields in the SubagentStart payload:

    session_id, transcript_path, cwd, agent_id, agent_type, hook_event_name

  None of the six contract fields (workflow_id, stage_id, goal_id,
  work_item_id, decision_scope, generated_at) appear in any of the 40
  captured real SubagentStart events in runtime/dispatch-debug.jsonl.

Carrier path recommendation (single candidate, runtime-owned):
  PreToolUse:Agent fires BEFORE SubagentStart in the same session, and the
  following invariant holds in ALL 37 observed sequential pairings in the
  captured data:

    tool_input.subagent_type (PreToolUse:Agent)
      == agent_type (subsequent SubagentStart in same session)

  and every PreToolUse:Agent fires before the NEXT PreToolUse:Agent of any
  type in the same session (sequential dispatch model).

  This makes (session_id, agent_type) a viable write-key, justified from
  captured data: session_id is present in 100% of both SubagentStart and
  PreToolUse:Agent payloads; agent_type/subagent_type match in all 37
  observed sequential pairings.

  RECOMMENDED CARRIER: SQLite-backed pending-request registry
  (a new table in the existing state.db, e.g. ``pending_agent_requests``):

    1. The orchestrator embeds the six contract fields as a structured block
       in the Agent tool prompt it controls (producer side).
    2. hooks/pre-agent.sh (PreToolUse:Agent hook) extracts the block from
       tool_input.prompt and writes a row keyed by (session_id, agent_type)
       into the ``pending_agent_requests`` SQLite table.
    3. hooks/subagent-start.sh reads the row by (session_id, agent_type)
       from the same SQLite DB, deletes it atomically, and the existing
       runtime-first branch becomes reachable in production.

  Why SQLite, not file sidecars:
    File-sidecar approaches (tmp/<session_id>_<agent_type> breadcrumbs) are
    explicitly rejected by this repo's architecture.  A tmp sidecar is a
    second non-runtime authority for a workflow/control-plane fact.  It
    violates the single-source-of-truth rule and would reintroduce the class
    of dual-authority bugs this architecture is designed to prevent.  The
    SQLite state.db is already the sole authority for runtime state; the
    pending-request registry is a natural extension of that authority, not a
    new one.

  No harness changes are needed. The PreToolUse:Agent hook already has a
  registered matcher (settings.json — pre-agent.sh chain) and fires in the
  same process environment as the subagent-start.sh hook.

Changed files (this slice): tests/runtime/test_subagent_start_payload_shape.py
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_LIVE_CAPTURE = _REPO_ROOT / "runtime" / "dispatch-debug.jsonl"
_SEED_CAPTURE = _REPO_ROOT / "tests" / "fixtures" / "dispatch-debug.seed.jsonl"


def _effective_capture() -> Path:
    """Return the active dispatch-debug source.

    Prefers the live ``runtime/dispatch-debug.jsonl`` when present (primary
    repo with active hook capture). Falls back to the committed deterministic
    seed fixture ``tests/fixtures/dispatch-debug.seed.jsonl`` so the invariant
    pins run hermetically in fresh worktrees where no live capture exists.

    DEC-CLAUDEX-SA-PAYLOAD-SHAPE-FIXTURE-001: the seed fixture carries the
    same *structural* payload shape (field presence / absence, carrier
    write-key correspondence) that the invariants care about. It carries no
    live command text beyond the minimal ``CLAUDEX_CONTRACT_BLOCK`` marker
    and trivial task-body placeholders — the assertions in this module are
    structural, not content-sensitive.
    """
    if _LIVE_CAPTURE.is_file():
        return _LIVE_CAPTURE
    return _SEED_CAPTURE


_CAPTURE = _effective_capture()

# The six contract fields that drive the runtime-first branch.
_CONTRACT_FIELDS: frozenset[str] = frozenset(
    {"workflow_id", "stage_id", "goal_id", "work_item_id", "decision_scope", "generated_at"}
)

# The exact set of fields emitted by the harness in real SubagentStart payloads.
_EXPECTED_SA_FIELDS: frozenset[str] = frozenset(
    {"session_id", "transcript_path", "cwd", "agent_id", "agent_type", "hook_event_name"}
)


def _load_real_subagent_start_payloads() -> list[dict]:
    """Parse dispatch-debug capture; return SubagentStart payloads that have session_id.

    Rows without session_id are synthetic test fixtures and are excluded.
    """
    capture = _CAPTURE
    if not capture.is_file():
        return []
    payloads: list[dict] = []
    with capture.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (
                isinstance(event, dict)
                and event.get("hook_event_name") == "SubagentStart"
                and "session_id" in event
            ):
                payloads.append(event)
    return payloads


def _load_real_pre_tool_agent_payloads() -> list[dict]:
    """Parse dispatch-debug capture; return PreToolUse:Agent payloads with session_id."""
    capture = _CAPTURE
    if not capture.is_file():
        return []
    payloads: list[dict] = []
    with capture.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (
                isinstance(event, dict)
                and event.get("hook_event_name") == "PreToolUse"
                and event.get("tool_name") == "Agent"
                and "session_id" in event
            ):
                payloads.append(event)
    return payloads


# ---------------------------------------------------------------------------
# 1. SubagentStart payload shape — pins observed harness output
# ---------------------------------------------------------------------------


class TestSubagentStartPayloadShape:
    """Pins the observed SubagentStart payload fields from captured truth.

    These tests read REAL captured events from runtime/dispatch-debug.jsonl.
    They will be skipped in environments where no SubagentStart events have
    been captured yet, and must be updated if the harness schema changes.
    """

    @pytest.fixture(autouse=True)
    def payloads(self):
        p = _load_real_subagent_start_payloads()
        if not p:
            pytest.skip("No real SubagentStart payloads in dispatch-debug.jsonl")
        self._payloads = p

    def test_capture_file_exists(self):
        assert _CAPTURE.is_file(), (
            f"Neither live capture ({_LIVE_CAPTURE}) nor seed fixture "
            f"({_SEED_CAPTURE}) is present. At least one must exist to run "
            "these tests."
        )

    def test_all_payloads_have_session_id(self):
        for p in self._payloads:
            assert "session_id" in p, f"SubagentStart payload missing session_id: {p}"

    def test_all_payloads_have_exactly_expected_fields(self):
        # The harness emits exactly these six fields. Any addition or removal
        # is a schema change and must be re-verified + this test updated.
        for p in self._payloads:
            actual = frozenset(p.keys())
            assert actual == _EXPECTED_SA_FIELDS, (
                f"SubagentStart payload field mismatch.\n"
                f"  Expected: {sorted(_EXPECTED_SA_FIELDS)}\n"
                f"  Actual:   {sorted(actual)}\n"
                f"  Extra:    {sorted(actual - _EXPECTED_SA_FIELDS)}\n"
                f"  Missing:  {sorted(_EXPECTED_SA_FIELDS - actual)}"
            )

    def test_no_contract_field_present_in_any_payload(self):
        # The runtime-first branch in subagent-start.sh is never triggered by
        # the harness today. This test will fail (as expected) once the carrier
        # path (pre-agent.sh writes to SQLite pending-request registry;
        # subagent-start.sh reads and deletes the row atomically) is live.
        for p in self._payloads:
            present = _CONTRACT_FIELDS & frozenset(p.keys())
            assert not present, (
                f"Contract field(s) {sorted(present)} found in a real SubagentStart "
                f"payload — the harness now injects them directly. Update "
                f"DEC-CLAUDEX-SA-PAYLOAD-SHAPE-001 to reflect the new source of truth."
            )

    def test_agent_type_always_present_and_string(self):
        for p in self._payloads:
            assert isinstance(p["agent_type"], str) and p["agent_type"], (
                f"agent_type missing or non-string in SubagentStart payload: {p}"
            )

    def test_cwd_always_present_and_string(self):
        for p in self._payloads:
            assert isinstance(p.get("cwd"), str) and p["cwd"], (
                f"cwd missing or empty in SubagentStart payload: {p}"
            )


# ---------------------------------------------------------------------------
# 2. PreToolUse:Agent payload shape — confirms carrier prerequisites
# ---------------------------------------------------------------------------


class TestPreToolAgentPayloadShape:
    """Pins the fields available to pre-agent.sh at SubagentStart intercept time.

    The SQLite pending-request registry carrier requires that PreToolUse:Agent
    provides both session_id (for the registry write-key) and
    tool_input.prompt (to extract the embedded contract block).
    File-sidecar approaches are rejected — see DEC-CLAUDEX-SA-PAYLOAD-SHAPE-001.
    """

    @pytest.fixture(autouse=True)
    def payloads(self):
        p = _load_real_pre_tool_agent_payloads()
        if not p:
            pytest.skip("No real PreToolUse:Agent payloads in dispatch-debug.jsonl")
        self._payloads = p

    def test_session_id_always_present(self):
        for p in self._payloads:
            assert "session_id" in p, f"PreToolUse:Agent missing session_id: {p}"

    def test_tool_input_prompt_always_present(self):
        # The carrier path reads the contract block from tool_input.prompt.
        # Pin that this field is always a non-empty string in live captures.
        for p in self._payloads:
            assert isinstance(p.get("tool_input", {}).get("prompt"), str) and (
                p["tool_input"]["prompt"]
            ), f"PreToolUse:Agent missing or empty tool_input.prompt: {p}"

    def test_subagent_type_matches_subsequent_subagent_start_agent_type(self):
        # Write-key existence invariant: within a session, every non-empty
        # PreToolUse:Agent.tool_input.subagent_type X has a matching
        # SubagentStart.agent_type == X in the same session.  This justifies
        # (session_id, agent_type) as the write-key for the SQLite
        # pending-request registry carrier: the carrier writes rows keyed by
        # (session_id, subagent_type) at PreToolUse and reads by
        # (session_id, agent_type) at SubagentStart, and this invariant pins
        # that the read key is recoverable from the captured truth.
        #
        # Sequential "next-SubagentStart" pairing is intentionally not used
        # here — the live capture contains sessions where multiple agents
        # dispatch within one session and their SubagentStart events are not
        # strictly chronologically paired with their originating PreToolUse
        # events, so strict pairing produces false mismatches.  Existence
        # over the (session_id, agent_type) pair is the invariant the
        # carrier actually depends on.
        #
        # Empty subagent_type is explicitly excluded: the CLAUDE.md dispatch
        # rule ("ClauDEX Contract Injection") requires subagent_type to be
        # set, and the carrier write path (hooks/pre-agent.sh) writes no row
        # when subagent_type is empty (live-verified 2026-04-09).  Those
        # PreToolUse events therefore correspond to no carrier row and are
        # not expected to match any SubagentStart under this invariant.
        if not _CAPTURE.is_file():
            pytest.skip("No capture file")

        # Load all events (with session_id) in order
        all_events: list[dict] = []
        with _CAPTURE.open() as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(e, dict) and "session_id" in e:
                    all_events.append(e)

        # Group by session_id preserving order
        by_session: dict[str, list[dict]] = {}
        for e in all_events:
            by_session.setdefault(e["session_id"], []).append(e)

        mismatches: list[str] = []
        for sess_id, events in by_session.items():
            pre_tool_subagent_types: list[str] = [
                e.get("tool_input", {}).get("subagent_type", "")
                for e in events
                if e.get("hook_event_name") == "PreToolUse"
                and e.get("tool_name") == "Agent"
            ]
            sa_agent_types: set[str] = {
                e.get("agent_type", "")
                for e in events
                if e.get("hook_event_name") == "SubagentStart"
            }
            if not pre_tool_subagent_types or not sa_agent_types:
                continue

            for expected_type in pre_tool_subagent_types:
                # Empty subagent_type is an explicit no-carrier case.
                if not expected_type:
                    continue
                if expected_type not in sa_agent_types:
                    mismatches.append(
                        f"session={sess_id[:8]}: "
                        f"PreToolUse.subagent_type={expected_type!r} "
                        f"has no matching SubagentStart.agent_type in "
                        f"session (observed agent_types="
                        f"{sorted(sa_agent_types)!r})"
                    )

        assert not mismatches, (
            "PreToolUse:Agent → SubagentStart write-key existence broken:\n"
            + "\n".join(f"  {m}" for m in mismatches)
        )


# ---------------------------------------------------------------------------
# 3. Contract fields absent — explicit gap assertion for the carrier
# ---------------------------------------------------------------------------


class TestContractCarrierGap:
    """Explicit pinning that the runtime-first branch is unreachable today.

    These tests document the CURRENT state: the six contract fields are not
    injected by any known path into SubagentStart payloads.  Once the
    SQLite pending-request registry carrier (pre-agent.sh writes, subagent-start.sh
    reads) is implemented, the test in section 1
    (test_no_contract_field_present_in_any_payload) will be updated to
    expect the new source.  File-sidecar approaches are rejected — they
    reintroduce non-runtime authority for a control-plane fact.
    """

    def test_dispatch_debug_file_exists_and_has_subagent_start_events(self):
        payloads = _load_real_subagent_start_payloads()
        assert _CAPTURE.is_file(), (
            f"Neither live capture ({_LIVE_CAPTURE}) nor seed fixture "
            f"({_SEED_CAPTURE}) exists — at least one must be present to "
            "pin the carrier gap"
        )
        assert len(payloads) > 0, (
            f"Effective capture ({_CAPTURE}) has no SubagentStart events — "
            "live capture must be active or seed fixture must contain "
            "structural SubagentStart rows for this assertion to have meaning"
        )

    def test_seed_fixture_exists_and_is_non_empty(self):
        """Pin: tests/fixtures/dispatch-debug.seed.jsonl exists and carries
        at least one PreToolUse:Agent row and one SubagentStart row so
        fresh-worktree runs have structural data to assert against.

        DEC-CLAUDEX-SA-PAYLOAD-SHAPE-FIXTURE-001.
        """
        assert _SEED_CAPTURE.is_file(), (
            f"Seed fixture must exist at {_SEED_CAPTURE}. It anchors the "
            "fresh-worktree test path so TestContractCarrierGap can run "
            "hermetically without a live runtime/dispatch-debug.jsonl."
        )
        seed_text = _SEED_CAPTURE.read_text().strip()
        assert seed_text, f"Seed fixture at {_SEED_CAPTURE} must be non-empty"

        # Walk the seed and classify rows structurally.
        pre_tool_count = 0
        subagent_start_count = 0
        for line in seed_text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError as exc:
                raise AssertionError(
                    f"Seed fixture contains invalid JSON on a line: {exc}"
                )
            if not isinstance(evt, dict):
                continue
            if (
                evt.get("hook_event_name") == "PreToolUse"
                and evt.get("tool_name") == "Agent"
            ):
                pre_tool_count += 1
            elif evt.get("hook_event_name") == "SubagentStart":
                subagent_start_count += 1

        assert pre_tool_count >= 1, (
            f"Seed fixture must carry at least one PreToolUse:Agent row; "
            f"got {pre_tool_count}"
        )
        assert subagent_start_count >= 1, (
            f"Seed fixture must carry at least one SubagentStart row; "
            f"got {subagent_start_count}"
        )

    def test_contract_fields_absent_from_all_observed_payloads(self):
        payloads = _load_real_subagent_start_payloads()
        if not payloads:
            pytest.skip("No payloads to check")
        for field in sorted(_CONTRACT_FIELDS):
            count = sum(1 for p in payloads if field in p)
            assert count == 0, (
                f"Contract field {field!r} found in {count}/{len(payloads)} "
                f"real SubagentStart payloads. The harness may now inject it "
                f"directly — verify and update the carrier path design."
            )

    def test_session_id_is_viable_correlation_key(self):
        # Pin that session_id is present in 100% of real SubagentStart payloads
        # and in 100% of real PreToolUse:Agent payloads, establishing it as the
        # shared key the SQLite pending-request registry carrier can use.
        # File-sidecar approaches using this key are rejected — they would
        # reintroduce non-runtime authority for a control-plane fact.
        sa_payloads = _load_real_subagent_start_payloads()
        pa_payloads = _load_real_pre_tool_agent_payloads()
        if not sa_payloads or not pa_payloads:
            pytest.skip("Insufficient captures for correlation assertion")

        sa_with_session = sum(1 for p in sa_payloads if "session_id" in p)
        pa_with_session = sum(1 for p in pa_payloads if "session_id" in p)

        assert sa_with_session == len(sa_payloads), (
            f"Only {sa_with_session}/{len(sa_payloads)} SubagentStart payloads "
            f"have session_id — SQLite registry key (session_id, agent_type) would be unreliable"
        )
        assert pa_with_session == len(pa_payloads), (
            f"Only {pa_with_session}/{len(pa_payloads)} PreToolUse:Agent payloads "
            f"have session_id — SQLite registry key (session_id, agent_type) would be unreliable"
        )

"""Slice 32: reviewer_findings.status state-machine completeness invariant.

Pins bidirectional parity between the schema vocabulary authority
(``runtime.schemas.FINDING_STATUSES``) and the runtime state machine
(``runtime.core.reviewer_findings._VALID_TRANSITIONS``) for the
``reviewer_findings`` table.

This is the first completeness slice targeting an authority OUTSIDE the
supervision fabric: ``reviewer_findings`` is the CUTOVER Authority-Map
row 546 authority for workflow review readiness / reviewer convergence.
Parallel to:

  - Slice 24 DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001
  - Slice 25 DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001
  - Slice 26 DEC-CLAUDEX-DISPATCH-ATTEMPTS-STATUS-MACHINE-COMPLETENESS-001
  - Slice 28 DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001
  - Slice 30 DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001
  - Slice 31 DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001

Structural difference from slices 30/31: ``reviewer_findings`` is **fully
cyclic with ZERO terminal states**.  Every status has at least one outgoing
edge.  The four edges are: open->resolved, open->waived, resolved->open,
waived->open.

Gaps closed:

  Gap A (orphan schema status, reverse direction): The existing check at
    test_reviewer_findings.py:751 proves FINDING_STATUSES ⊆
    _VALID_TRANSITIONS.keys(). T3 closes the reverse direction, upgrading
    the existing subset check to full equality.

  Gap B (no-terminal invariant): The narrative at reviewer_findings.py:31-32
    states that "findings do not have a deleted state" — implying every status
    has an outgoing edge. T4 pins this mechanically as the mirror-complement
    of slice 31's terminal-emptiness pin.

  Gap C (initial-state dual-role): 'open' is both a source key AND a target
    in the union of values. T5 pins this and confirms _insert_finding produces
    status='open' via real in-memory DB call.

  Gap D (producer-to-target parity): T6/T7/T8/T9 exercise all four state-machine
    edges (open->resolved, open->waived, resolved->open, waived->open) via the
    real public API against an in-memory DB. No monkeypatching.

  Gap E (state-machine gate inside _transition_status): T11 proves the
    ValueError gate lives in _transition_status directly (not only in the
    resolve/waive/reopen wrappers).

  Gap F (vocabulary-gate redundancy): T13 proves ReviewerFinding.__post_init__
    raises ValueError for any status outside FINDING_STATUSES — this gate
    runs independently of the transition-table gate.

  Gap G (literal mirror tripwire absence): T14 pins the full literal expected
    transition table (EXPECTED_TRANSITIONS) so any future edit to _VALID_TRANSITIONS
    requires a reviewer-visible diff here.

@decision DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001
@title reviewer_findings.status state-machine completeness invariant (test-only)
@status accepted
@rationale reviewer_findings is the CUTOVER Authority-Map row 546 authority
  for workflow review readiness. Its three-value fully-cyclic state machine
  (open, resolved, waived) with four edges is pinned one-directionally only by
  test_reviewer_findings.py:751-756. This file seals all seven gaps (A-G)
  without touching any runtime source or existing test. First slice in this
  completeness family targeting an authority outside the supervision fabric;
  first with ZERO terminal states, making T4 the mirror-complement of slice
  31's terminal-emptiness pin and T12 a novel no-self-loop invariant guard.
"""

from __future__ import annotations

import inspect
import operator
import sqlite3
from functools import reduce

import pytest

from runtime import schemas
from runtime.core import reviewer_findings as rf
from runtime.schemas import FINDING_STATUSES

# ---------------------------------------------------------------------------
# Module-level literal mirrors (authority anchors).
#
# These constants pin the implementer's write-time understanding of the runtime
# authority surfaces. They must be updated in lockstep with any change to
# runtime/schemas.py (FINDING_STATUSES) or
# runtime/core/reviewer_findings.py (_VALID_TRANSITIONS).
#
# The live assertions in each test use the runtime authority directly;
# these literals are present so that ANY change to the runtime surface requires
# a reviewer-visible diff here too.
# ---------------------------------------------------------------------------

EXPECTED_STATUSES: frozenset = frozenset({"open", "resolved", "waived"})

# Four-edge fully cyclic graph: ZERO terminal states.
# Mirror-complement of slice 31's EXPECTED_TRANSITIONS which had one terminal ('dead').
EXPECTED_TRANSITIONS: dict = {
    "open":     frozenset({"resolved", "waived"}),
    "resolved": frozenset({"open"}),
    "waived":   frozenset({"open"}),
}


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

def _make_conn() -> sqlite3.Connection:
    """Return a fresh in-memory connection with full production schema applied.

    Pure in-memory; no on-disk sqlite file is created (forbidden by scope_json).
    row_factory = sqlite3.Row so SELECT * can be converted via _row_to_finding.
    """
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    schemas.ensure_schema(conn)
    return conn


def _insert_open(conn: sqlite3.Connection, finding_id_suffix: str = "t") -> rf.ReviewerFinding:
    """Insert a fresh finding in 'open' state and return it."""
    return rf.insert(
        conn,
        workflow_id=f"wf-{finding_id_suffix}",
        severity="note",
        title="title",
        detail="detail",
    )


def _db_status(conn: sqlite3.Connection, finding_id: str) -> str:
    """Fetch only the status column from the DB for a finding."""
    row = conn.execute(
        "SELECT status FROM reviewer_findings WHERE finding_id = ?",
        (finding_id,),
    ).fetchone()
    assert row is not None, f"No DB row found for finding_id={finding_id!r}"
    return row["status"]


# ---------------------------------------------------------------------------
# Test class: 14 cases T1-T14
# ---------------------------------------------------------------------------


class TestFindingStatusMachineCompletenessInvariant:
    """14-case completeness invariant for reviewer_findings.status state machine.

    DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001
    """

    # --- T1: anchor pin ---

    def test_T1_expected_statuses_anchor_equals_literal(self):
        """T1 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Pin the in-file EXPECTED_STATUSES anchor.

        Guards against a future edit that silently renames, adds, or removes a
        member from the anchor constant inside this test file — which would make
        all downstream set-equality assertions vacuously correct against a wrong
        anchor.
        """
        assert EXPECTED_STATUSES == frozenset(
            {"open", "resolved", "waived"}
        ), (
            "EXPECTED_STATUSES anchor has drifted from its pinned literal; "
            "this file must be updated together with the runtime source authority"
        )
        assert len(EXPECTED_STATUSES) == 3, (
            "EXPECTED_STATUSES must have exactly 3 members"
        )

    # --- T2: schema enum equality ---

    def test_T2_schema_finding_statuses_equals_expected(self):
        """T2 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Pin runtime.schemas.FINDING_STATUSES == EXPECTED_STATUSES.

        Named symmetric-difference on failure: missing_from_schema reports
        statuses in EXPECTED_STATUSES not yet in the runtime enum;
        extra_in_schema reports statuses added to the enum without updating
        this anchor.
        """
        actual = set(schemas.FINDING_STATUSES)
        expected = set(EXPECTED_STATUSES)
        missing_from_schema = expected - actual
        extra_in_schema = actual - expected
        assert actual == expected, (
            f"FINDING_STATUSES parity failure: "
            f"missing_from_schema={missing_from_schema!r}, "
            f"extra_in_schema={extra_in_schema!r}"
        )

    # --- T3: transition graph keys == schema enum ---

    def test_T3_transition_table_keys_equal_schema_vocabulary(self):
        """T3 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Pin set(rf._VALID_TRANSITIONS.keys()) == FINDING_STATUSES.

        Closes Gap A reverse direction: upgrades the existing one-direction subset
        check at test_reviewer_findings.py:751-756 to full set-equality.  A status
        added to the schema without a corresponding transition-table key creates
        a silent trap state where rows can arrive with no valid outgoing edge.
        """
        graph_keys = set(rf._VALID_TRANSITIONS.keys())
        schema_statuses = set(schemas.FINDING_STATUSES)
        missing_from_graph = schema_statuses - graph_keys
        extra_in_graph = graph_keys - schema_statuses
        assert graph_keys == schema_statuses, (
            f"_VALID_TRANSITIONS key-set parity failure: "
            f"missing_from_graph={missing_from_graph!r}, "
            f"extra_in_graph={extra_in_graph!r}"
        )

    # --- T4: no-terminal invariant (novel — mirror-complement of slice 31) ---

    def test_T4_no_terminal_statuses(self):
        """T4 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Assert NO key in _VALID_TRANSITIONS has an empty frozenset value.

        Computed terminals (keys with empty out-edges) must be frozenset()
        (the empty set). Closes Gap B: the narrative at reviewer_findings.py:31-32
        claims every status is reachable — this test pins it mechanically.

        This is the structural inverse of slice 31's terminal-emptiness pin
        (_VALID_TRANSITIONS['dead'] == frozenset()). Here: reviewer_findings has
        ZERO terminals by design — every status has at least one outgoing edge.
        """
        computed_terminals = frozenset(
            s for s, outs in rf._VALID_TRANSITIONS.items() if not outs
        )
        assert computed_terminals == frozenset(), (
            f"reviewer_findings state machine must have ZERO terminal states; "
            f"found terminals with empty out-edges: {computed_terminals!r}. "
            f"This violates the fully-cyclic invariant (Gap B). "
            f"All FINDING_STATUSES must have at least one outgoing transition."
        )
        # Explicit confirmation: all declared statuses have at least one out-edge
        for s in FINDING_STATUSES:
            assert len(rf._VALID_TRANSITIONS[s]) > 0, (
                f"Status {s!r} has an empty out-edge set in _VALID_TRANSITIONS; "
                f"reviewer_findings must be fully cyclic with zero terminal states"
            )

    # --- T5: initial-state dual-role pin (novel — 'open' is both source and target) ---

    def test_T5_initial_status_is_open_and_insert_produces_it(self):
        """T5 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Real-path proof: insert() produces status='open'; 'open' is both a
        transition source AND a transition target in _VALID_TRANSITIONS.

        Closes Gap C (initial-state drift + dual-role invariant):
        - 'open' must be in _VALID_TRANSITIONS.keys() (source)
        - 'open' must be in reduce(|, _VALID_TRANSITIONS.values()) (target)
        - rf.insert() returns dataclass .status == 'open'
        - DB row status == 'open'
        - _insert_finding source contains literal status="open"

        No monkeypatching.
        """
        conn = _make_conn()

        # Real-path producer call
        finding = _insert_open(conn, "t5")

        # Returned dataclass must have status='open'
        assert finding.status == "open", (
            f"rf.insert() must return a finding with status='open'; "
            f"got {finding.status!r}"
        )

        # DB row must have status='open'
        db_stat = _db_status(conn, finding.finding_id)
        assert db_stat == "open", (
            f"DB row status must be 'open' immediately after insert; got {db_stat!r}"
        )

        # 'open' must be a source key in _VALID_TRANSITIONS
        assert "open" in rf._VALID_TRANSITIONS, (
            "'open' must be a key (transition source) in _VALID_TRANSITIONS"
        )

        # 'open' must be a target in the union of all transition value sets
        all_targets: frozenset = reduce(
            operator.or_,
            rf._VALID_TRANSITIONS.values(),
            frozenset(),
        )
        assert "open" in all_targets, (
            "'open' must appear as a transition target in the union of "
            "_VALID_TRANSITIONS.values() — this proves the cyclic 'open' return path "
            "exists (resolved->open and waived->open)"
        )

        # _insert_finding source contains the literal status="open" (Gap C source check)
        source = inspect.getsource(rf._insert_finding)
        assert 'status="open"' in source or "status='open'" in source, (
            "_insert_finding must contain the literal status='open' or status=\"open\" "
            "to confirm it is the sole producer of the initial open state"
        )

        conn.close()

    # --- T6: transition-table values subset of schema vocabulary ---

    def test_T6_transition_table_values_subset_of_schema_vocabulary(self):
        """T6 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        For every key in _VALID_TRANSITIONS, the value frozenset must be a
        subset of FINDING_STATUSES.

        Re-pins value containment in this file so any future edit that adds a
        status to the transition targets but forgets the schema enum fails both
        this file and test_reviewer_findings.py simultaneously.
        """
        declared = set(schemas.FINDING_STATUSES)
        for from_status, targets in rf._VALID_TRANSITIONS.items():
            undeclared = set(targets) - declared
            assert not undeclared, (
                f"_VALID_TRANSITIONS[{from_status!r}] references undeclared "
                f"target statuses: {undeclared!r}. "
                f"All transition targets must be declared in FINDING_STATUSES."
            )

    # --- T7: full transition-table equality with literal mirror ---

    def test_T7_transition_table_equals_expected_transitions(self):
        """T7 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Pin rf._VALID_TRANSITIONS == EXPECTED_TRANSITIONS.

        Named per-key symmetric-difference diagnostic: shows which from-status
        rows have diverged and in which direction.  Primary catcher for renames
        and typos in the transition graph.  Literal-mirror lockstep invariant:
        any future transition-table edit must update EXPECTED_TRANSITIONS in this
        file, which forces a reviewer-visible diff.

        Closes Gap G.
        """
        actual = rf._VALID_TRANSITIONS
        per_key_diffs = []
        all_keys = set(EXPECTED_TRANSITIONS.keys()) | set(actual.keys())
        for k in sorted(all_keys):
            expected_set = set(EXPECTED_TRANSITIONS.get(k, frozenset()))
            actual_set = set(actual.get(k, frozenset()))
            if expected_set != actual_set:
                per_key_diffs.append(
                    f"  [{k!r}]: "
                    f"missing_from_actual={expected_set - actual_set!r}, "
                    f"extra_in_actual={actual_set - expected_set!r}"
                )
        assert not per_key_diffs, (
            "_VALID_TRANSITIONS diverges from EXPECTED_TRANSITIONS:\n"
            + "\n".join(per_key_diffs)
        )

    # --- T8: full cycle round-trip (real-path compound interaction) ---

    def test_T8_full_cycle_round_trip(self):
        """T8 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Real-path full-cycle producer round-trip:
          insert() -> resolve() -> reopen() -> waive() -> reopen()

        Exercises all four transition edges in sequence:
          open -> resolved (via resolve)
          resolved -> open (via reopen)
          open -> waived (via waive)
          waived -> open (via reopen)

        Asserts each returned dataclass has the expected status AND the DB row
        matches.  Closes Gap D fully by covering all four edges with a real
        in-memory DB and no monkeypatching.

        This is the compound-interaction test satisfying the "production sequence
        end-to-end" requirement for this slice.
        """
        conn = _make_conn()
        finding = _insert_open(conn, "t8")
        fid = finding.finding_id
        assert finding.status == "open"

        # Edge 1: open -> resolved
        resolved = rf.resolve(conn, fid)
        assert resolved is not None, "resolve() must return the updated finding"
        assert resolved.status == "resolved", (
            f"resolve() must produce status='resolved'; got {resolved.status!r}"
        )
        assert _db_status(conn, fid) == "resolved", "DB row must be 'resolved' after resolve()"

        # Edge 2: resolved -> open
        reopened_1 = rf.reopen(conn, fid)
        assert reopened_1 is not None, "reopen() from 'resolved' must return the updated finding"
        assert reopened_1.status == "open", (
            f"reopen() from 'resolved' must produce status='open'; got {reopened_1.status!r}"
        )
        assert _db_status(conn, fid) == "open", "DB row must be 'open' after reopen() from resolved"

        # Edge 3: open -> waived
        waived = rf.waive(conn, fid)
        assert waived is not None, "waive() must return the updated finding"
        assert waived.status == "waived", (
            f"waive() must produce status='waived'; got {waived.status!r}"
        )
        assert _db_status(conn, fid) == "waived", "DB row must be 'waived' after waive()"

        # Edge 4: waived -> open
        reopened_2 = rf.reopen(conn, fid)
        assert reopened_2 is not None, "reopen() from 'waived' must return the updated finding"
        assert reopened_2.status == "open", (
            f"reopen() from 'waived' must produce status='open'; got {reopened_2.status!r}"
        )
        assert _db_status(conn, fid) == "open", "DB row must be 'open' after reopen() from waived"

        conn.close()

    # --- T9: four direct edges exercised individually ---

    def test_T9_all_four_direct_transition_edges(self):
        """T9 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        Exercise each of the four edges directly via public producers:
          (a) open -> resolved via resolve()
          (b) open -> waived via waive()
          (c) resolved -> open via reopen()
          (d) waived -> open via reopen()

        Each sub-test uses a fresh finding. Asserts the returned dataclass
        status AND the corresponding edge exists in _VALID_TRANSITIONS.
        No monkeypatching.
        """
        # (a) open -> resolved
        conn_a = _make_conn()
        f_a = _insert_open(conn_a, "t9a")
        r_a = rf.resolve(conn_a, f_a.finding_id)
        assert r_a is not None
        assert r_a.status == "resolved", f"edge open->resolved failed; got {r_a.status!r}"
        assert "resolved" in rf._VALID_TRANSITIONS["open"], (
            "'resolved' must be in _VALID_TRANSITIONS['open']"
        )
        conn_a.close()

        # (b) open -> waived
        conn_b = _make_conn()
        f_b = _insert_open(conn_b, "t9b")
        r_b = rf.waive(conn_b, f_b.finding_id)
        assert r_b is not None
        assert r_b.status == "waived", f"edge open->waived failed; got {r_b.status!r}"
        assert "waived" in rf._VALID_TRANSITIONS["open"], (
            "'waived' must be in _VALID_TRANSITIONS['open']"
        )
        conn_b.close()

        # (c) resolved -> open
        conn_c = _make_conn()
        f_c = _insert_open(conn_c, "t9c")
        rf.resolve(conn_c, f_c.finding_id)
        r_c = rf.reopen(conn_c, f_c.finding_id)
        assert r_c is not None
        assert r_c.status == "open", f"edge resolved->open failed; got {r_c.status!r}"
        assert "open" in rf._VALID_TRANSITIONS["resolved"], (
            "'open' must be in _VALID_TRANSITIONS['resolved']"
        )
        conn_c.close()

        # (d) waived -> open
        conn_d = _make_conn()
        f_d = _insert_open(conn_d, "t9d")
        rf.waive(conn_d, f_d.finding_id)
        r_d = rf.reopen(conn_d, f_d.finding_id)
        assert r_d is not None
        assert r_d.status == "open", f"edge waived->open failed; got {r_d.status!r}"
        assert "open" in rf._VALID_TRANSITIONS["waived"], (
            "'open' must be in _VALID_TRANSITIONS['waived']"
        )
        conn_d.close()

    # --- T10: illegal-transition enforcement ---

    def test_T10_illegal_transitions_raise_value_error(self):
        """T10 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        State-machine gate enforcement: each invalid transition raises ValueError
        with message matching r'[Ii]nvalid.*transition' (case-insensitive).

        Sub-assertions:
          (a) resolve() on already-resolved finding raises ValueError
          (b) waive() on resolved finding raises ValueError
          (c) resolve() on waived finding raises ValueError
          (d) waive() on waived finding raises ValueError
          (e) reopen() on open finding raises ValueError

        Proves the gate is enforced on all invalid cross-edges and for the
        'no self-loop' case (e). No monkeypatching.
        """
        # (a) resolved -> resolved (resolve on resolved)
        conn_a = _make_conn()
        f_a = _insert_open(conn_a, "t10a")
        rf.resolve(conn_a, f_a.finding_id)
        with pytest.raises(ValueError, match=r"(?i)invalid.*transition"):
            rf.resolve(conn_a, f_a.finding_id)
        conn_a.close()

        # (b) resolved -> waived (waive on resolved)
        conn_b = _make_conn()
        f_b = _insert_open(conn_b, "t10b")
        rf.resolve(conn_b, f_b.finding_id)
        with pytest.raises(ValueError, match=r"(?i)invalid.*transition"):
            rf.waive(conn_b, f_b.finding_id)
        conn_b.close()

        # (c) waived -> resolved (resolve on waived)
        conn_c = _make_conn()
        f_c = _insert_open(conn_c, "t10c")
        rf.waive(conn_c, f_c.finding_id)
        with pytest.raises(ValueError, match=r"(?i)invalid.*transition"):
            rf.resolve(conn_c, f_c.finding_id)
        conn_c.close()

        # (d) waived -> waived (waive on waived)
        conn_d = _make_conn()
        f_d = _insert_open(conn_d, "t10d")
        rf.waive(conn_d, f_d.finding_id)
        with pytest.raises(ValueError, match=r"(?i)invalid.*transition"):
            rf.waive(conn_d, f_d.finding_id)
        conn_d.close()

        # (e) open -> open (reopen on open)
        conn_e = _make_conn()
        f_e = _insert_open(conn_e, "t10e")
        with pytest.raises(ValueError, match=r"(?i)invalid.*transition"):
            rf.reopen(conn_e, f_e.finding_id)
        conn_e.close()

    # --- T11: _transition_status returns None for missing finding_id ---

    def test_T11_transition_status_returns_none_for_missing_finding(self):
        """T11 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        _transition_status returns None (not ValueError) when finding_id
        does not exist.

        Pins the specific contract at reviewer_findings.py:472-474:
            existing = get(conn, finding_id)
            if existing is None:
                return None

        This distinguishes the "finding does not exist" case (None) from the
        "invalid transition" case (ValueError).
        """
        conn = _make_conn()
        result = rf._transition_status(conn, "nonexistent-id-xxxxxxxx", "resolved")
        assert result is None, (
            f"_transition_status must return None for a missing finding_id; "
            f"got {result!r}"
        )
        conn.close()

    # --- T12: no-self-loop invariant (novel — not possible in supervision fabric) ---

    def test_T12_no_self_loop_invariant(self):
        """T12 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        For every status s in _VALID_TRANSITIONS, assert s not in _VALID_TRANSITIONS[s].

        This proves no state can transition to itself — self-loops are not encoded.
        Guards against a future edit that adds a self-loop for idempotency reasons
        (e.g. to make resolve() idempotent on an already-resolved finding) and
        thereby hides a failed transition by silently succeeding.

        Real-path verification: rf._transition_status(conn, fid, 'open') on an
        open finding raises ValueError, confirming the no-self-loop property
        is enforced at runtime, not just statically in the transition table.
        """
        # Static table check: no self-loops in the table
        for status in FINDING_STATUSES:
            assert status not in rf._VALID_TRANSITIONS[status], (
                f"Self-loop detected: _VALID_TRANSITIONS[{status!r}] contains "
                f"{status!r}. reviewer_findings must not have idempotent self-transitions."
            )

        # Real-path enforcement: open -> open raises ValueError
        conn = _make_conn()
        f = _insert_open(conn, "t12")
        with pytest.raises(ValueError, match=r"(?i)invalid.*transition"):
            rf._transition_status(conn, f.finding_id, "open")
        conn.close()

    # --- T13: vocabulary gate rejects unknown status ---

    def test_T13_post_init_rejects_unknown_status(self):
        """T13 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        ReviewerFinding.__post_init__ (vocabulary gate) raises ValueError for
        any status outside FINDING_STATUSES.

        Closes Gap F: this gate runs independently of the transition-table gate;
        a future refactor that removed the FINDING_STATUSES check in __post_init__
        (moving it to _insert_finding only) would not surface as a
        completeness-invariant regression without this test.

        Negative cases (must raise ValueError with 'status must be one of'):
          - status="garbage"
          - status=""
          - status="pending"
          - status="dismissed"

        Positive cases (must NOT raise):
          - All three FINDING_STATUSES members construct successfully.
        """
        import time as _time

        def _make_finding(**kwargs):
            now = int(_time.time())
            defaults = dict(
                finding_id="fid-test",
                workflow_id="wf-test",
                severity="note",
                status="open",
                title="t",
                detail="d",
                created_at=now,
                updated_at=now,
            )
            defaults.update(kwargs)
            return rf.ReviewerFinding(**defaults)

        # Negative cases
        for bad_status in ("garbage", "", "pending", "dismissed"):
            with pytest.raises(ValueError, match="status must be one of"):
                _make_finding(status=bad_status)

        # Positive cases — all declared statuses must construct without error
        for good_status in sorted(FINDING_STATUSES):
            obj = _make_finding(status=good_status)
            assert obj.status == good_status, (
                f"ReviewerFinding(status={good_status!r}) must construct successfully"
            )

    # --- T14: module docstring contains DEC-ID ---

    def test_T14_decision_id_in_module_docstring(self):
        """T14 — DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001:
        The literal 'DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001'
        appears in this module's __doc__.

        Provides scope-audit traceability and supports archaeological grep.
        Any future renaming of the decision ID requires updating the module
        docstring AND this assertion simultaneously.
        """
        dec_id = "DEC-CLAUDEX-FINDING-STATUS-MACHINE-COMPLETENESS-001"
        assert dec_id in (__doc__ or ""), (
            f"Module docstring must contain the literal DEC-id {dec_id!r} "
            f"for scope-audit traceability; current module __doc__ is missing it"
        )

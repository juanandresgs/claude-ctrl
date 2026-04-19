"""Slice 31: seats.status state-machine completeness invariant.

Pins bidirectional parity between the schema vocabulary authority
(``runtime.schemas.SEAT_STATUSES``) and the runtime state machine
(``runtime.core.seats._VALID_TRANSITIONS``) for the ``seats`` table.

This is the final CUTOVER Authority-Map status axis among the four runtime
domains {seat, agent_session, dispatch_attempt, supervision_thread} without a
bidirectional completeness invariant.  Parallel to:

  - Slice 24 DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001
  - Slice 25 DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001
  - Slice 26 DEC-CLAUDEX-DISPATCH-ATTEMPTS-STATUS-MACHINE-COMPLETENESS-001
  - Slice 28 DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001
  - Slice 30 DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001

Gaps closed:

  Gap A (orphan schema status): A new status added to SEAT_STATUSES but not to
    _VALID_TRANSITIONS would create a silent trap — rows could reach that status
    via raw UPDATE with no transition gate.  T3 closes this by asserting keyset
    equality (not just subset).

  Gap B (terminal-state drift): The narrative claim that ``dead`` is terminal
    lives only in the inline comment at seats.py:76 before this slice.  T6
    asserts the computed set of terminal states (keys with empty out-edges) ==
    frozenset({"dead"}).

  Gap C (initial-state drift): T5 asserts that 'active' has no incoming
    transition-target edges (it is only produced by create(), never by any
    _transition call).  Also proved by real-path round-trip.

  Gap D (producer-to-terminal parity): T6/T7/T8 exercise release()->released,
    mark_dead()->dead (from active), and release()->mark_dead()->dead (the
    intermediate active→released→dead edge) against a real in-memory DB.
    The structural difference from slice 30: seats has a non-terminal
    intermediate state 'released' with an outgoing edge to 'dead'; T8 covers
    this explicitly.

  Gap E (vocabulary gate): T9 calls _require_status with unknown values under
    pytest.raises to prove the vocabulary gate is live.

Structural note: unlike slice 30 (supervision_threads) where both non-initial
statuses are terminal, seats has two non-terminal keys ('active' and 'released')
and one terminal key ('dead').  T7 therefore asserts
computed_non_terminals == frozenset({"active","released"}) and T6 asserts
computed_terminals == frozenset({"dead"}).

@decision DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001
@title Seat status state-machine completeness invariant (test-only)
@status accepted
@rationale seats is the final CUTOVER Authority-Map supervision-fabric status
  axis without an explicit bidirectional state-machine completeness invariant.
  Existing test_seats.py:264-268 and test_supervision_schema.py:515-539 only
  prove subset containment (graph ⊆ schema), leaving four structural gaps
  (A-D above) identical to those closed by slices 24/25/26/28/30 on the other
  three runtime domains.  This file seals all four gaps plus Gap E (vocabulary
  gate) without touching any runtime source or existing test, completing the
  4-way symmetry across the supervision fabric.
"""

from __future__ import annotations

import inspect
import sqlite3
import time
from functools import reduce

import pytest

from runtime import schemas
from runtime.core import seats as seat_mod

# ---------------------------------------------------------------------------
# Module-level literal mirrors (authority anchors).
#
# These constants pin the implementer's write-time understanding of the runtime
# authority.  They must be updated in lockstep with any change to
# runtime/schemas.py (SEAT_STATUSES) or
# runtime/core/seats.py (_VALID_TRANSITIONS).
#
# The live assertions in each test case use the runtime authority directly;
# these literals are present so that ANY change to the runtime surface
# requires a reviewer-visible diff here too.
# ---------------------------------------------------------------------------

EXPECTED_STATUSES: frozenset = frozenset({"active", "released", "dead"})

EXPECTED_TRANSITIONS: dict = {
    "active":   frozenset({"released", "dead"}),
    "released": frozenset({"dead"}),
    # Terminal — no transitions out.
    "dead":     frozenset(),
}

EXPECTED_TERMINALS: frozenset = frozenset({"dead"})

# Non-terminal keys (have at least one outgoing edge) — TWO for seats,
# unlike supervision_threads which has only one ('active').
EXPECTED_NON_TERMINALS: frozenset = frozenset({"active", "released"})


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

def _make_conn() -> sqlite3.Connection:
    """Return a fresh in-memory connection with the full production schema applied.

    Pure in-memory; no on-disk sqlite file is created (forbidden by scope_json).
    PRAGMA foreign_keys=ON is enabled so the agent_sessions FK on seats is
    enforced.
    """
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    schemas.ensure_schema(conn)
    return conn


def _insert_session(conn: sqlite3.Connection, session_id: str) -> None:
    """Insert a minimal agent_sessions row to satisfy seats.session_id FK."""
    now = int(time.time())
    conn.execute(
        """
        INSERT INTO agent_sessions (
            session_id, workflow_id, transport, transport_handle,
            status, created_at, updated_at
        ) VALUES (?, NULL, 'claude_code', NULL, 'active', ?, ?)
        """,
        (session_id, now, now),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Test class: 12 cases T1-T12
# ---------------------------------------------------------------------------


class TestSeatStatusMachineCompletenessInvariant:
    """12-case completeness invariant for seats.status state machine.

    DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001
    """

    # --- T1: anchor pin ---

    def test_T1_expected_statuses_anchor_is_correct(self):
        """T1 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Pin the in-file EXPECTED_STATUSES anchor.

        Guards against a future edit that silently renames, adds, or removes a
        member from the anchor constant inside this test file — which would make
        all downstream set-equality assertions vacuously correct against a wrong
        anchor.
        """
        assert EXPECTED_STATUSES == frozenset(
            {"active", "released", "dead"}
        ), (
            "EXPECTED_STATUSES anchor has drifted from its pinned literal; "
            "this file must be updated together with the runtime source authority"
        )
        assert len(EXPECTED_STATUSES) == 3, (
            "EXPECTED_STATUSES must have exactly 3 members"
        )

    # --- T2: schema enum equality ---

    def test_T2_schema_enum_equals_expected_statuses(self):
        """T2 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Pin runtime.schemas.SEAT_STATUSES == EXPECTED_STATUSES.

        Named symmetric-difference on failure: missing_from_schema reports
        statuses in EXPECTED_STATUSES not yet in the runtime enum; extra_in_schema
        reports statuses added to the enum without updating this anchor.
        """
        actual = set(schemas.SEAT_STATUSES)
        expected = set(EXPECTED_STATUSES)
        missing_from_schema = expected - actual
        extra_in_schema = actual - expected
        assert actual == expected, (
            f"SEAT_STATUSES parity failure: "
            f"missing_from_schema={missing_from_schema!r}, "
            f"extra_in_schema={extra_in_schema!r}"
        )

    # --- T3: transition graph keys == schema enum ---

    def test_T3_transition_graph_keys_equal_schema_enum(self):
        """T3 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Pin set(seats._VALID_TRANSITIONS.keys()) == SEAT_STATUSES.

        Closes Gap A: every declared schema status must have exactly one row in
        the transition graph.  A status added to the schema without a
        corresponding transition-graph key creates a silent trap state where
        rows can arrive (via raw UPDATE or _require_status pass-through) with no
        valid outgoing edge.
        """
        graph_keys = set(seat_mod._VALID_TRANSITIONS.keys())
        schema_statuses = set(schemas.SEAT_STATUSES)
        missing_from_graph = schema_statuses - graph_keys
        extra_in_graph = graph_keys - schema_statuses
        assert graph_keys == schema_statuses, (
            f"_VALID_TRANSITIONS key-set parity failure: "
            f"missing_from_graph={missing_from_graph!r}, "
            f"extra_in_graph={extra_in_graph!r}"
        )

    # --- T4: transition graph values ⊆ schema enum ---

    def test_T4_transition_graph_value_image_is_subset_of_schema_enum(self):
        """T4 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        For every key in _VALID_TRANSITIONS, the value frozenset must be a
        subset of SEAT_STATUSES.

        Re-pins the direction partially covered today by
        test_seats.test_state_machine_uses_only_schema_declared_statuses and
        test_supervision_schema.test_seats_domain_module_imports_and_pins_schema_vocabulary
        (which assert subset containment but not equality).  Together with T3,
        this makes the pinning bidirectional.
        """
        declared = set(schemas.SEAT_STATUSES)
        for from_status, targets in seat_mod._VALID_TRANSITIONS.items():
            undeclared = set(targets) - declared
            assert not undeclared, (
                f"_VALID_TRANSITIONS[{from_status!r}] references undeclared "
                f"target statuses: {undeclared!r}"
            )

    # --- T5: full graph equality with per-key symmetric-diff diagnostic ---

    def test_T5_transition_graph_equals_expected_transitions(self):
        """T5 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Pin seats._VALID_TRANSITIONS == EXPECTED_TRANSITIONS.

        Named per-key symmetric-difference diagnostic: shows which from-status
        rows have diverged and in which direction.  Primary catcher for renames
        and typos in the transition graph.  Literal-mirror lockstep: any future
        transition-table edit must update EXPECTED_TRANSITIONS in this file, which
        forces a reviewer-visible diff.

        Additional invariant (Gap C / initial-state): 'active' must not appear
        as a value in any _VALID_TRANSITIONS entry — i.e. no _transition() call
        can produce status='active', confirming create() is the sole initial-state
        producer.
        """
        actual = seat_mod._VALID_TRANSITIONS
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

        # Gap C — 'active' must not appear as any transition target.
        # Uses functools.reduce to union all target frozensets, then asserts
        # 'active' not in the result.  An empty transition table yields
        # frozenset() so the assertion still holds.
        all_targets: frozenset = reduce(
            lambda acc, v: acc | v,
            seat_mod._VALID_TRANSITIONS.values(),
            frozenset(),
        )
        assert "active" not in all_targets, (
            "Invariant violation: 'active' appears as a transition target in "
            "_VALID_TRANSITIONS.values(), meaning some non-create() path can "
            "produce status='active'.  This breaks the create()-as-sole-initial-producer "
            "invariant (Gap C)."
        )

    # --- T6: computed terminals ---

    def test_T6_computed_terminal_statuses_match_expected(self):
        """T6 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Compute terminal states as keys with empty out-edges.

        Asserts computed_terminals == frozenset({'dead'}).
        Closes Gap B: the inline comment at seats.py:76 claiming 'dead' is
        terminal is pinned mechanically here.  Catches the drift where a
        previously-terminal state gains an out-edge (making it no longer terminal)
        or a non-terminal is accidentally made terminal.

        Note: 'released' is NOT terminal in this state machine — it has one
        outgoing edge to 'dead'.  This distinguishes seats from supervision_threads
        where all non-initial statuses are terminal.
        """
        computed_terminals = frozenset(
            s for s, outs in seat_mod._VALID_TRANSITIONS.items() if not outs
        )
        assert computed_terminals == EXPECTED_TERMINALS, (
            f"Computed terminal-state set diverges from expected: "
            f"missing_from_computed={EXPECTED_TERMINALS - computed_terminals!r}, "
            f"extra_in_computed={computed_terminals - EXPECTED_TERMINALS!r}"
        )

    # --- T7: computed non-terminals (initials / intermediates) ---

    def test_T7_computed_non_terminal_statuses_match_expected(self):
        """T7 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Compute non-terminal states as keys with non-empty out-edges.

        Asserts computed_non_terminals == frozenset({'active','released'}).

        This is the key structural difference from slice 30 (supervision_threads):
        seats has TWO non-terminal keys — the initial state 'active' and the
        intermediate state 'released'.  Catches the drift where 'released' gains
        a terminal emptiness (making it a dead-end), or a third intermediate state
        is inadvertently added to the graph.
        """
        computed_non_terminals = frozenset(
            s for s, outs in seat_mod._VALID_TRANSITIONS.items() if outs
        )
        assert computed_non_terminals == EXPECTED_NON_TERMINALS, (
            f"Computed non-terminal-state set diverges from expected: "
            f"missing_from_computed={EXPECTED_NON_TERMINALS - computed_non_terminals!r}, "
            f"extra_in_computed={computed_non_terminals - EXPECTED_NON_TERMINALS!r}"
        )

    # --- T8: intermediate edge round-trip (novel vs slice 30) ---

    def test_T8_released_to_dead_intermediate_edge_round_trip(self):
        """T8 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Real-path proof: active → released → dead (3-step intermediate edge).

        This is the novel case that distinguishes slice 31 from slice 30.  In
        supervision_threads, all non-initial statuses are terminal; in seats,
        'released' is non-terminal with a single outgoing edge to 'dead'.

        Production sequence:
          1. ensure_schema(:memory:) with PRAGMA foreign_keys=ON
          2. seed agent_sessions row for FK
          3. seats.create() → status='active'
          4. seats.release() → returns {transitioned: True, row.status='released'}
          5. seats.mark_dead() → returns {transitioned: True, row.status='dead'}

        Asserts that:
          - release() returned transitioned=True and row status == 'released'
          - mark_dead() returned transitioned=True and row status == 'dead'
          - DB row after mark_dead has status == 'dead'
          - 'dead' is in _VALID_TRANSITIONS['released'] (edge exists in table)

        No monkeypatching.  No on-disk SQLite.  No subprocess.
        """
        conn = _make_conn()
        session_id = "sess-t8-intermediate"
        seat_id = "seat-t8"

        _insert_session(conn, session_id)
        create_result = seat_mod.create(conn, seat_id, session_id, "worker")
        assert create_result["status"] == "active", (
            f"create() must produce status='active'; got {create_result['status']!r}"
        )

        # First transition: active → released
        release_result = seat_mod.release(conn, seat_id)
        assert release_result["transitioned"] is True, (
            f"release() from 'active' must report transitioned=True; "
            f"got {release_result['transitioned']!r}"
        )
        assert release_result["row"]["status"] == "released", (
            f"release() must produce row status='released'; "
            f"got {release_result['row']['status']!r}"
        )

        # Second transition: released → dead
        mark_dead_result = seat_mod.mark_dead(conn, seat_id)
        assert mark_dead_result["transitioned"] is True, (
            f"mark_dead() from 'released' must report transitioned=True; "
            f"got {mark_dead_result['transitioned']!r}"
        )
        assert mark_dead_result["row"]["status"] == "dead", (
            f"mark_dead() must produce row status='dead'; "
            f"got {mark_dead_result['row']['status']!r}"
        )

        # Verify DB row independently
        db_row = conn.execute(
            "SELECT status FROM seats WHERE seat_id = ?", (seat_id,)
        ).fetchone()
        assert db_row is not None, f"DB row for seat {seat_id!r} not found"
        assert db_row["status"] == "dead", (
            f"DB row status must be 'dead' after full active→released→dead path; "
            f"got {db_row['status']!r}"
        )

        # Edge must exist in transition table
        assert "dead" in seat_mod._VALID_TRANSITIONS["released"], (
            "'dead' must be an out-edge of 'released' in _VALID_TRANSITIONS"
        )

        conn.close()

    # --- T9: active → dead direct (skip released) ---

    def test_T9_active_to_dead_direct_round_trip(self):
        """T9 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Terminal-from-initial round-trip: active → dead directly, skipping released.

        Proves that mark_dead() can be called directly on an 'active' seat without
        requiring the intermediate 'released' step.  This is the second transition
        out of 'active' documented in _VALID_TRANSITIONS['active'].

        Asserts:
          - create() produces status='active'
          - mark_dead() directly from 'active' returns transitioned=True
          - row status == 'dead' after mark_dead

        No monkeypatching.  No on-disk SQLite.  No subprocess.
        """
        conn = _make_conn()
        session_id = "sess-t9-direct"
        seat_id = "seat-t9-direct"

        _insert_session(conn, session_id)
        create_result = seat_mod.create(conn, seat_id, session_id, "worker")
        assert create_result["status"] == "active", (
            f"create() must produce status='active'; got {create_result['status']!r}"
        )

        mark_dead_result = seat_mod.mark_dead(conn, seat_id)
        assert mark_dead_result["transitioned"] is True, (
            f"mark_dead() from 'active' must report transitioned=True; "
            f"got {mark_dead_result['transitioned']!r}"
        )
        assert mark_dead_result["row"]["status"] == "dead", (
            f"mark_dead() from 'active' must produce row status='dead'; "
            f"got {mark_dead_result['row']['status']!r}"
        )

        # 'dead' must be in active's out-edges
        assert "dead" in seat_mod._VALID_TRANSITIONS["active"], (
            "'dead' must be an out-edge of 'active' in _VALID_TRANSITIONS"
        )

        conn.close()

    # --- T10: illegal-transition enforcement ---

    def test_T10_illegal_transition_raises_value_error(self):
        """T10 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        State-machine gate enforcement: release() on a dead seat must raise ValueError.

        Proves the gate lives inside _transition, not only in the transition table
        keys.  Production sequence: create → mark_dead → attempt release.

        Asserts ValueError matching 'invalid transition' is raised with detail
        string indicating the invalid 'dead' → 'released' arc.

        No monkeypatching.  No on-disk SQLite.  No subprocess.
        """
        conn = _make_conn()
        session_id = "sess-t10-illegal"
        seat_id = "seat-t10-illegal"

        _insert_session(conn, session_id)
        seat_mod.create(conn, seat_id, session_id, "worker")
        seat_mod.mark_dead(conn, seat_id)

        # 'dead' is terminal; release() must raise ValueError
        with pytest.raises(ValueError, match="invalid transition"):
            seat_mod.release(conn, seat_id)

        conn.close()

    # --- T11: terminal narrative claim pinned mechanically ---

    def test_T11_terminal_narrative_claim_and_computed_terminals_match(self):
        """T11 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Two sub-assertions:

        (a) Inline comment proof: inspect.getsource(seats) contains the literal
            string '# Terminal — no transitions out.' immediately followed
            (within the same source block) by '"dead":     frozenset()' (or the
            equivalent form without extra whitespace).  This proves the inline
            comment at seats.py:76 that claims dead is terminal is mechanically
            pinned — a future edit removing the terminal emptiness would also need
            to remove or update this assertion.

        (b) Computed terminals from T6 equal the pinned anchor EXPECTED_TERMINALS
            == frozenset({'dead'}).  Redundant re-check here so T11 and T6 are
            jointly authoritative — both must be updated if the terminal set changes.
        """
        # (a) Inline comment proof via inspect.getsource
        source = inspect.getsource(seat_mod)
        assert "# Terminal — no transitions out." in source, (
            "seats.py must contain the literal inline comment "
            "'# Terminal — no transitions out.' to document the terminal state; "
            "found in source at seats.py:76.  If this comment was removed, "
            "update this assertion and the corresponding terminal-state narrative."
        )
        # The comment must appear near the "dead": frozenset() entry
        comment_idx = source.index("# Terminal — no transitions out.")
        dead_entry_start = source.find('"dead"', comment_idx)
        assert dead_entry_start != -1, (
            "The '# Terminal — no transitions out.' comment must be followed by "
            "the 'dead' key in _VALID_TRANSITIONS within the same source block"
        )
        dead_entry_substr = source[dead_entry_start:dead_entry_start + 30]
        assert "frozenset()" in dead_entry_substr or "frozenset()" in source[
            dead_entry_start:dead_entry_start + 50
        ], (
            "The 'dead' entry in _VALID_TRANSITIONS must be 'frozenset()' "
            "(empty — terminal).  Actual text near 'dead' entry: "
            f"{dead_entry_substr!r}"
        )

        # (b) Computed terminals pin (redundant with T6 — both files must agree)
        computed_terminals = frozenset(
            s for s, outs in seat_mod._VALID_TRANSITIONS.items() if not outs
        )
        assert computed_terminals == frozenset({"dead"}), (
            f"Computed terminal-state set must equal frozenset({{'dead'}}); "
            f"got {computed_terminals!r}"
        )

    # --- T12: DEC-ID in module docstring + _require_status negative gate ---

    def test_T12_dec_id_in_module_docstring_and_require_status_negative(self):
        """T12 — DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001:
        Two sub-assertions:

        (a) Decision-ID presence: the literal string
            'DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001' appears in this
            module's __doc__ (the test file's own docstring) for scope-audit
            traceability and archaeological grep support.

        (b) Vocabulary-gate negative case: seats._require_status("garbage") raises
            ValueError.  Closes Gap E by proving the gate is live for arbitrary
            unknown status strings.  Complements T9's three-specific-string check
            with a canary assertion that any out-of-vocabulary string is rejected.
        """
        # (a) DEC-ID presence in this module's docstring
        dec_id = "DEC-CLAUDEX-SEAT-STATUS-MACHINE-COMPLETENESS-001"
        assert dec_id in (__doc__ or ""), (
            f"Module docstring must contain the literal DEC-id {dec_id!r} "
            f"for scope-audit traceability; current module __doc__ is missing it"
        )

        # (b) _require_status negative gate
        for unknown in ("suspended", "", "orphaned", "garbage"):
            with pytest.raises(ValueError, match="invalid status"):
                seat_mod._require_status(unknown)

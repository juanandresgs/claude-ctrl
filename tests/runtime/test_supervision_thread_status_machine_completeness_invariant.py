"""Slice 30: supervision_threads.status state-machine completeness invariant.

Pins bidirectional parity between the schema vocabulary authority
(``runtime.schemas.SUPERVISION_THREAD_STATUSES``) and the runtime state machine
(``runtime.core.supervision_threads._VALID_TRANSITIONS``) for the
``supervision_threads`` table.

This is the sole CUTOVER Authority-Map status axis among the four runtime
domains {seat, agent_session, dispatch_attempt, supervision_thread} that lacked
an explicit completeness invariant before this slice.  Parallel to:

  - Slice 24 DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001
  - Slice 25 DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001
  - Slice 26 DEC-CLAUDEX-DISPATCH-ATTEMPTS-STATUS-MACHINE-COMPLETENESS-001
  - Slice 28 DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001

Gaps closed:

  Gap A (orphan schema status): A new status added to SUPERVISION_THREAD_STATUSES
    but not to _VALID_TRANSITIONS would create a silent trap — rows could reach
    that status via raw UPDATE with no transition gate.  T3 closes this by
    asserting keyset equality (not just subset).

  Gap B (terminal-state drift): The narrative claim that ``completed`` and
    ``abandoned`` are terminal lives only in the module docstring before this
    slice.  T6 asserts the computed set of terminal states (keys with empty
    out-edges) == frozenset({"completed","abandoned"}).

  Gap C (initial-state drift): T7 asserts the sole non-terminal (initial) key
    is frozenset({"active"}).  T10 proves attach() is the only public producer
    of status='active' via a real in-memory SQLite round-trip.

  Gap D (producer→terminal parity): T10 exercises detach()→'completed' and
    abandon()→'abandoned' against a real in-memory DB.

  Gap E (vocabulary gate): T10 exercises _require_status("suspended") and
    _require_status("paused") under pytest.raises to prove the vocabulary gate
    is live.

@decision DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001
@title Supervision-thread status state-machine completeness invariant (test-only)
@status accepted
@rationale supervision_threads is the recursive-supervision authority defined in
  CUTOVER_PLAN §Authority Map and §Target Architecture §2a rule 4.  Bidirectional
  schema-to-graph parity was absent: existing test_supervision_threads.py:499-506
  only proved subset containment (graph ⊆ schema), leaving four structural gaps
  (A-D above).  This file seals all four gaps plus the vocabulary gate (Gap E)
  without touching any runtime source or existing test, completing the set of
  runtime-domain completeness invariants required by CUTOVER §Invariants items 1
  and 13.
"""

from __future__ import annotations

import re
import sqlite3
import time

import pytest

from runtime import schemas
from runtime.core import supervision_threads as sup_mod

# ---------------------------------------------------------------------------
# Module-level literal mirrors (authority anchors).
#
# These constants pin the implementer's write-time understanding of the runtime
# authority.  They must be updated in lockstep with any change to
# runtime/schemas.py (SUPERVISION_THREAD_STATUSES) or
# runtime/core/supervision_threads.py (_VALID_TRANSITIONS).
#
# The live assertions in each test case use the runtime authority directly;
# these literals are present so that ANY change to the runtime surface
# requires a reviewer-visible diff here too.
# ---------------------------------------------------------------------------

EXPECTED_STATUSES: frozenset = frozenset({"active", "completed", "abandoned"})

EXPECTED_TRANSITIONS: dict = {
    "active": frozenset({"completed", "abandoned"}),
    # Terminal — no transitions out.
    "completed": frozenset(),
    "abandoned": frozenset(),
}

EXPECTED_TERMINALS: frozenset = frozenset({"completed", "abandoned"})

EXPECTED_INITIALS: frozenset = frozenset({"active"})


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

def _make_conn() -> sqlite3.Connection:
    """Return a fresh in-memory connection with the full production schema applied.

    Pure in-memory; no on-disk sqlite file is created (forbidden by scope_json).
    Seeding agent_session and seat rows satisfies the FK preconditions of
    supervision_threads.attach() without relying on PRAGMA foreign_keys=ON.
    """
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    schemas.ensure_schema(conn)
    return conn


def _seed_seats(conn: sqlite3.Connection, suffix: str) -> tuple[str, str]:
    """Seed a minimal agent_session + two seat rows for attach() preconditions.

    Returns (supervisor_seat_id, worker_seat_id).  Each call uses ``suffix``
    to generate unique IDs so multiple sub-tests on the same connection don't
    collide on PRIMARY KEY constraints.
    """
    now = int(time.time())
    session_id = f"sess-smc-{suffix}"
    sup_seat_id = f"seat-sup-{suffix}"
    wrk_seat_id = f"seat-wrk-{suffix}"

    conn.execute(
        "INSERT INTO agent_sessions "
        "(session_id, workflow_id, transport, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (session_id, f"wf-{suffix}", "tmux", "active", now, now),
    )
    conn.execute(
        "INSERT INTO seats "
        "(seat_id, session_id, role, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (sup_seat_id, session_id, "supervisor", "active", now, now),
    )
    conn.execute(
        "INSERT INTO seats "
        "(seat_id, session_id, role, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (wrk_seat_id, session_id, "worker", "active", now, now),
    )
    conn.commit()
    return sup_seat_id, wrk_seat_id


# ---------------------------------------------------------------------------
# Test class: 11 cases T1-T11
# ---------------------------------------------------------------------------


class TestSupervisionThreadStatusMachineCompletenessInvariant:
    """11-case completeness invariant for supervision_threads.status state machine.

    DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001
    """

    # --- T1: anchor pin ---

    def test_T1_expected_statuses_anchor_is_correct(self):
        """T1 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Pin the in-file EXPECTED_STATUSES anchor.

        Guards against a future edit that silently renames, adds, or removes a
        member from the anchor constant inside this test file — which would make
        all downstream set-equality assertions vacuously correct against a wrong
        anchor.
        """
        assert EXPECTED_STATUSES == frozenset(
            {"active", "completed", "abandoned"}
        ), (
            "EXPECTED_STATUSES anchor has drifted from its pinned literal; "
            "this file must be updated together with the runtime source authority"
        )
        assert len(EXPECTED_STATUSES) == 3, (
            "EXPECTED_STATUSES must have exactly 3 members"
        )

    # --- T2: schema enum equality ---

    def test_T2_schema_enum_equals_expected_statuses(self):
        """T2 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Pin runtime.schemas.SUPERVISION_THREAD_STATUSES == EXPECTED_STATUSES.

        Named symmetric-difference on failure: missing_from_schema reports
        statuses in EXPECTED_STATUSES not yet in the runtime enum; extra_in_schema
        reports statuses added to the enum without updating this anchor.
        """
        actual = set(schemas.SUPERVISION_THREAD_STATUSES)
        expected = set(EXPECTED_STATUSES)
        missing_from_schema = expected - actual
        extra_in_schema = actual - expected
        assert actual == expected, (
            f"SUPERVISION_THREAD_STATUSES parity failure: "
            f"missing_from_schema={missing_from_schema!r}, "
            f"extra_in_schema={extra_in_schema!r}"
        )

    # --- T3: transition graph keys == schema enum ---

    def test_T3_transition_graph_keys_equal_schema_enum(self):
        """T3 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Pin set(supervision_threads._VALID_TRANSITIONS.keys()) ==
        SUPERVISION_THREAD_STATUSES.

        Closes Gap A: every declared schema status must have exactly one row in
        the transition graph.  A status added to the schema without a
        corresponding transition-graph key creates a silent trap state where
        rows can arrive (via raw UPDATE or _require_status pass-through) with no
        valid outgoing edge.
        """
        graph_keys = set(sup_mod._VALID_TRANSITIONS.keys())
        schema_statuses = set(schemas.SUPERVISION_THREAD_STATUSES)
        missing_from_graph = schema_statuses - graph_keys
        extra_in_graph = graph_keys - schema_statuses
        assert graph_keys == schema_statuses, (
            f"_VALID_TRANSITIONS key-set parity failure: "
            f"missing_from_graph={missing_from_graph!r}, "
            f"extra_in_graph={extra_in_graph!r}"
        )

    # --- T4: transition graph values ⊆ schema enum ---

    def test_T4_transition_graph_value_image_is_subset_of_schema_enum(self):
        """T4 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        For every key in _VALID_TRANSITIONS, the value frozenset must be a
        subset of SUPERVISION_THREAD_STATUSES.

        Re-pins the direction partially covered today by
        test_supervision_threads.test_module_defers_to_schema_vocabulary (which
        asserts subset containment but not equality).  Together with T3, this
        makes the pinning bidirectional.
        """
        declared = set(schemas.SUPERVISION_THREAD_STATUSES)
        for from_status, targets in sup_mod._VALID_TRANSITIONS.items():
            undeclared = set(targets) - declared
            assert not undeclared, (
                f"_VALID_TRANSITIONS[{from_status!r}] references undeclared "
                f"target statuses: {undeclared!r}"
            )

    # --- T5: full graph equality with per-key symmetric-diff diagnostic ---

    def test_T5_transition_graph_equals_expected_transitions(self):
        """T5 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Pin supervision_threads._VALID_TRANSITIONS == EXPECTED_TRANSITIONS.

        Named per-key symmetric-difference diagnostic: shows which from-status
        rows have diverged and in which direction.  Primary catcher for renames
        and typos in the transition graph.  Literal-mirror lockstep: any future
        transition-table edit must update EXPECTED_TRANSITIONS in this file, which
        forces a reviewer-visible diff.
        """
        actual = sup_mod._VALID_TRANSITIONS
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

    # --- T6: computed terminals ---

    def test_T6_computed_terminal_statuses_match_expected(self):
        """T6 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Compute terminal states as keys with empty out-edges.

        Asserts computed_terminals == frozenset({'completed', 'abandoned'}).
        Closes Gap B: the docstring claim at supervision_threads.py:37-38 that
        completed/abandoned are terminal is pinned mechanically here.  Catches the
        drift where a previously-terminal state gains an out-edge (making it no
        longer terminal) or a non-terminal is accidentally made terminal.
        """
        computed_terminals = frozenset(
            s for s, outs in sup_mod._VALID_TRANSITIONS.items() if not outs
        )
        assert computed_terminals == EXPECTED_TERMINALS, (
            f"Computed terminal-state set diverges from expected: "
            f"missing_from_computed={EXPECTED_TERMINALS - computed_terminals!r}, "
            f"extra_in_computed={computed_terminals - EXPECTED_TERMINALS!r}"
        )

    # --- T7: computed initials ---

    def test_T7_computed_initial_statuses_match_expected(self):
        """T7 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Compute initial states as keys with non-empty out-edges.

        Asserts computed_initials == frozenset({'active'}).
        Closes Gap C: the invariant that 'active' is the sole non-terminal key
        (and therefore the only valid initial state produced by attach()) is
        pinned mechanically here.  Catches the drift where a second non-terminal
        status is added to the graph (e.g. a 'paused' state with a return arc).
        """
        computed_initials = frozenset(
            s for s, outs in sup_mod._VALID_TRANSITIONS.items() if outs
        )
        assert computed_initials == EXPECTED_INITIALS, (
            f"Computed initial-state set diverges from expected: "
            f"missing_from_computed={EXPECTED_INITIALS - computed_initials!r}, "
            f"extra_in_computed={computed_initials - EXPECTED_INITIALS!r}"
        )

    # --- T8: docstring terminal claim ---

    def test_T8_module_docstring_terminal_claim_matches_expected_terminals(self):
        """T8 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Parse supervision_threads.__doc__ for the 'Terminal states:' clause and
        extract backtick-quoted identifiers.

        Asserts sorted(extracted) == ['abandoned', 'completed'].
        Catches docstring drift where a terminal is added/removed in the
        transition graph but the docstring is not updated, or vice-versa.
        """
        import inspect
        doc = inspect.getdoc(sup_mod) or ""
        m = re.search(r"Terminal states?:\s*([^\n]+)", doc, re.IGNORECASE)
        assert m is not None, (
            "supervision_threads module docstring must contain a "
            "'Terminal states: ...' line for parity enforcement"
        )
        raw = m.group(1)
        # Extract backtick-quoted identifiers in RST style: ``completed``, ``abandoned``
        # Only capture content wrapped in double backticks to avoid false positives.
        extracted = re.findall(r"``([a-z_]+)``", raw)
        assert sorted(extracted) == ["abandoned", "completed"], (
            f"Docstring 'Terminal states:' claim diverges from expected terminals: "
            f"extracted={extracted!r}, "
            f"expected={sorted(['abandoned', 'completed'])!r}"
        )

    # --- T9: public producer introspection ---

    def test_T9_public_producer_functions_exist_and_are_callable(self):
        """T9 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Introspect supervision_threads module: attach, detach, and abandon must
        exist and be callable.

        Also asserts that 'active' has no incoming transition-target edges in
        _VALID_TRANSITIONS (corollary of Gap C: no public transition producer
        writes status='active' other than attach).  This proves that attach() is
        the sole public producer of the initial state.
        """
        # All three public producers must exist and be callable
        for name in ("attach", "detach", "abandon"):
            fn = getattr(sup_mod, name, None)
            assert fn is not None, (
                f"Expected public producer {name!r} to exist on "
                f"runtime.core.supervision_threads but it is missing"
            )
            assert callable(fn), (
                f"Expected {name!r} on runtime.core.supervision_threads "
                f"to be callable"
            )

        # 'active' must not appear as a transition target in any out-edge
        # (proves no _transition call can produce status='active')
        all_targets: frozenset = frozenset().union(
            *sup_mod._VALID_TRANSITIONS.values()
        )
        assert "active" not in all_targets, (
            "Invariant violation: 'active' appears as a transition target in "
            "_VALID_TRANSITIONS.values(), meaning some non-attach path can "
            "produce status='active'.  This breaks the attach-as-sole-initial-producer "
            "invariant (Gap C)."
        )

    # --- T10: real-path producer round-trip ---

    def test_T10_producer_round_trip_in_memory_sqlite(self):
        """T10 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Real production sequence: open in-memory SQLite, apply ensure_schema,
        seed prerequisite agent_sessions + seats rows for FK validity, then call
        the three public producers and assert the returned status and the DB row.

        Sub-case A: attach(conn, sup_seat, wrk_seat, 'analysis')
          → returned dict status == 'active', DB row status == 'active'.

        Sub-case B: detach(conn, thread_id)
          → returned dict status == 'completed', DB row status == 'completed'.
          → _VALID_TRANSITIONS['active'] contains 'completed'.

        Sub-case C: abandon(conn, thread_id2) (fresh attach)
          → returned dict status == 'abandoned', DB row status == 'abandoned'.
          → _VALID_TRANSITIONS['active'] contains 'abandoned'.

        Sub-case D: _require_status('suspended'), _require_status(''), _require_status('paused')
          → each raises ValueError matching 'invalid status'.

        Sub-case E: attach → detach → _transition(conn, thread_id, 'active')
          → raises ValueError (completed is terminal; the state-machine gate
          is enforced inside _transition, not only in the transition table).

        No monkeypatching.  No on-disk SQLite.  No subprocess.
        """
        # --- Sub-case A: attach produces 'active' ---
        conn_a = _make_conn()
        sup_id_a, wrk_id_a = _seed_seats(conn_a, "t10a")
        result_a = sup_mod.attach(conn_a, sup_id_a, wrk_id_a, "analysis")

        assert result_a["status"] == "active", (
            f"attach() must return status='active'; got {result_a['status']!r}"
        )
        thread_id_a = result_a["thread_id"]
        db_row_a = conn_a.execute(
            "SELECT status FROM supervision_threads WHERE thread_id = ?",
            (thread_id_a,),
        ).fetchone()
        assert db_row_a is not None, "DB row for attached thread not found"
        assert db_row_a["status"] == "active", (
            f"DB row status must be 'active' immediately after attach(); "
            f"got {db_row_a['status']!r}"
        )

        # --- Sub-case B: detach produces 'completed' ---
        detach_result = sup_mod.detach(conn_a, thread_id_a)
        assert detach_result["status"] == "completed", (
            f"detach() must return status='completed'; got {detach_result['status']!r}"
        )
        db_row_b = conn_a.execute(
            "SELECT status FROM supervision_threads WHERE thread_id = ?",
            (thread_id_a,),
        ).fetchone()
        assert db_row_b["status"] == "completed", (
            f"DB row status must be 'completed' after detach(); "
            f"got {db_row_b['status']!r}"
        )
        assert "completed" in sup_mod._VALID_TRANSITIONS["active"], (
            "'completed' must be an out-edge of 'active' in _VALID_TRANSITIONS"
        )

        # --- Sub-case C: abandon produces 'abandoned' (fresh thread on same conn) ---
        conn_c = _make_conn()
        sup_id_c, wrk_id_c = _seed_seats(conn_c, "t10c")
        result_c = sup_mod.attach(conn_c, sup_id_c, wrk_id_c, "analysis")
        thread_id_c = result_c["thread_id"]

        abandon_result = sup_mod.abandon(conn_c, thread_id_c)
        assert abandon_result["status"] == "abandoned", (
            f"abandon() must return status='abandoned'; got {abandon_result['status']!r}"
        )
        db_row_c = conn_c.execute(
            "SELECT status FROM supervision_threads WHERE thread_id = ?",
            (thread_id_c,),
        ).fetchone()
        assert db_row_c["status"] == "abandoned", (
            f"DB row status must be 'abandoned' after abandon(); "
            f"got {db_row_c['status']!r}"
        )
        assert "abandoned" in sup_mod._VALID_TRANSITIONS["active"], (
            "'abandoned' must be an out-edge of 'active' in _VALID_TRANSITIONS"
        )

        # --- Sub-case D: _require_status rejects unknown statuses ---
        for unknown in ("suspended", "", "paused"):
            with pytest.raises(ValueError, match="invalid status"):
                sup_mod._require_status(unknown)

        # --- Sub-case E: _transition rejects out-of-machine move ---
        # thread_id_a is now 'completed' (terminal); attempting active is invalid
        with pytest.raises(ValueError):
            sup_mod._transition(conn_a, thread_id_a, "active")

        conn_a.close()
        conn_c.close()

    # --- T11: literal-mirror lockstep + DEC-ID in module docstring ---

    def test_T11_literal_mirror_lockstep_and_dec_id_in_docstring(self):
        """T11 — DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001:
        Two sub-assertions:

        (a) Literal-mirror lockstep: EXPECTED_TRANSITIONS at module level equals
            supervision_threads._VALID_TRANSITIONS literally.  Any future change
            to the transition table must also update EXPECTED_TRANSITIONS in this
            file, which forces a reviewer-visible diff — this is the
            'litmus lockstep' pattern from slice 24.

        (b) DEC-ID presence: the literal string
            'DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001'
            appears in this module's __doc__ (the test file's own docstring) for
            scope-audit traceability and archaeological grep support.
        """
        # (a) Literal mirror equality
        actual = sup_mod._VALID_TRANSITIONS
        assert actual == EXPECTED_TRANSITIONS, (
            f"_VALID_TRANSITIONS has drifted from EXPECTED_TRANSITIONS literal mirror: "
            f"actual={actual!r}, expected={EXPECTED_TRANSITIONS!r}. "
            f"Update EXPECTED_TRANSITIONS in this file to match the new runtime "
            f"authority AND ensure a separate decision record exists for the change."
        )

        # (b) DEC-ID presence in this module's docstring
        dec_id = "DEC-CLAUDEX-SUPERVISION-THREAD-STATUS-MACHINE-COMPLETENESS-001"
        assert dec_id in (__doc__ or ""), (
            f"Module docstring must contain the literal DEC-id {dec_id!r} "
            f"for scope-audit traceability; current module __doc__ is missing it"
        )

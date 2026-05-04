"""Slice 26: dispatch_attempts.status state-machine completeness invariant.

Five surfaces independently declare or consume the status vocabulary for the
``dispatch_attempts`` table.  This file pins 5-way parity across all of them
so that any rename, orphan, trap, or terminal-state drift fails at test time
with a named symmetric-diff diagnostic.

Authority surfaces pinned:
  1. Schema enum      — ``runtime.schemas.DISPATCH_ATTEMPT_STATUSES``
  2. Transition graph — ``runtime.core.dispatch_attempts._VALID_TRANSITIONS``
  3. DDL default      — ``runtime.schemas.DISPATCH_ATTEMPTS_DDL`` (``DEFAULT 'pending'``)
  4. Docstring claim  — ``dispatch_attempts.__doc__`` line: "Terminal states: ..."
  5. Producer funcs   — ``issue``, ``claim``, ``acknowledge``, ``fail``,
                        ``cancel``, ``timeout``, ``retry`` round-trip via
                        in-memory SQLite + ``ensure_schema()``.

@decision DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001
Title: 5-way parity invariant pins dispatch_attempts delivery authority
Status: accepted
Rationale: ``runtime/core/dispatch_attempts.py`` is the sole runtime authority
  for "was the instruction delivered?" (CUTOVER_PLAN §Authority Map row
  "Dispatch delivery and timeout state", line 550).  Five surfaces
  independently declare or consume the status vocabulary:
  (1) schema enum, (2) transition graph (_VALID_TRANSITIONS),
  (3) DDL DEFAULT, (4) module docstring terminal-state claim,
  (5) public producer functions.  Prior coverage was a single subset-check
  in test_supervision_schema.py (asymmetric, did not import _VALID_TRANSITIONS).
  This file closes the gap with set-equality assertions and named
  symmetric-difference diagnostics so any future rename, orphan, trap,
  or terminal-state drift fails loudly at test time, not silently at runtime.
"""

from __future__ import annotations

import inspect
import re
import sqlite3
import time

import pytest

from runtime import schemas
from runtime.core import dispatch_attempts

# ---------------------------------------------------------------------------
# Authority anchor — canonical expected values for this invariant.
# These mirror runtime/schemas.py:869-871 and dispatch_attempts.py:82-90.
# Changing these values requires also changing the source authority + docstring.
# ---------------------------------------------------------------------------

EXPECTED_STATUSES: frozenset = frozenset(
    {
        "pending",
        "delivered",
        "acknowledged",
        "timed_out",
        "failed",
        "cancelled",
    }
)

EXPECTED_TERMINAL_STATUSES: frozenset = frozenset(
    {"acknowledged", "cancelled"}
)

EXPECTED_TRANSITIONS: dict = {
    "pending":      frozenset({"delivered", "cancelled", "failed", "timed_out"}),
    "delivered":    frozenset({"acknowledged", "failed", "timed_out"}),
    "timed_out":    frozenset({"pending"}),
    "failed":       frozenset({"pending"}),
    "acknowledged": frozenset(),
    "cancelled":    frozenset(),
}

EXPECTED_DDL_DEFAULT: str = "pending"

# All (from, to) pairs reachable by the public producer functions
# (excluding issue() which does an INSERT, and expire_stale() which is bulk SQL).
EXPECTED_PRODUCER_PAIRS: frozenset = frozenset(
    (k, v)
    for k, vs in EXPECTED_TRANSITIONS.items()
    for v in vs
)

# Convenience: seat setup for in-memory fixture
_SEAT = "seat-sm-01"


def _make_conn() -> sqlite3.Connection:
    """Return a fresh in-memory connection with the full schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    schemas.ensure_schema(c)
    now = int(time.time())
    # Insert the minimal FK chain: agent_session → seat
    c.execute(
        "INSERT INTO agent_sessions "
        "(session_id, transport, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        ("sess-sm-01", "claude_code", "active", now, now),
    )
    c.execute(
        "INSERT INTO seats "
        "(seat_id, session_id, role, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (_SEAT, "sess-sm-01", "worker", "active", now, now),
    )
    c.commit()
    return c


# ---------------------------------------------------------------------------
# Class: parity invariants
# ---------------------------------------------------------------------------


class TestDispatchAttemptStatusMachineCompletenessInvariant:
    """5-way parity invariant for dispatch_attempts.status state machine.

    DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001
    """

    # --- Test 1: vacuous truth guard ---

    def test_expected_statuses_is_non_empty_vacuous_truth_guard(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Guard against a future edit that empties EXPECTED_STATUSES or
        EXPECTED_TRANSITIONS, which would make all downstream set-equality
        assertions vacuously true for an empty set.

        Also pin that every non-terminal status has a non-empty transition set.
        """
        assert len(EXPECTED_STATUSES) >= 3, "EXPECTED_STATUSES must be non-empty"
        assert len(EXPECTED_TRANSITIONS) >= 3, "EXPECTED_TRANSITIONS must be non-empty"
        non_terminals = EXPECTED_STATUSES - EXPECTED_TERMINAL_STATUSES
        for s in non_terminals:
            assert s in EXPECTED_TRANSITIONS, (
                f"Non-terminal status {s!r} missing from EXPECTED_TRANSITIONS"
            )
            assert len(EXPECTED_TRANSITIONS[s]) > 0, (
                f"Non-terminal status {s!r} has empty transition set in anchor"
            )

    # --- Test 2: schema enum equality ---

    def test_schema_enum_equals_expected_statuses(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Pin runtime.schemas.DISPATCH_ATTEMPT_STATUSES == EXPECTED_STATUSES.

        Named symmetric-difference on failure: missing_from_schema reports
        statuses added to EXPECTED_STATUSES but not yet in the runtime enum;
        extra_in_schema reports statuses added to the enum without updating
        this anchor.
        """
        actual = set(schemas.DISPATCH_ATTEMPT_STATUSES)
        expected = set(EXPECTED_STATUSES)
        missing_from_schema = expected - actual
        extra_in_schema = actual - expected
        assert actual == expected, (
            f"DISPATCH_ATTEMPT_STATUSES parity failure: "
            f"missing_from_schema={missing_from_schema}, "
            f"extra_in_schema={extra_in_schema}"
        )

    # --- Test 3: transition graph keys == enum ---

    def test_private_transition_graph_keys_equal_expected_statuses(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Pin set(dispatch_attempts._VALID_TRANSITIONS.keys()) == EXPECTED_STATUSES.

        Every declared status must have exactly one row in the transition graph:
        no status is orphaned by omission, no phantom key exists.
        """
        graph_keys = set(dispatch_attempts._VALID_TRANSITIONS.keys())
        expected = set(EXPECTED_STATUSES)
        missing_from_graph = expected - graph_keys
        extra_in_graph = graph_keys - expected
        assert graph_keys == expected, (
            f"_VALID_TRANSITIONS key-set parity failure: "
            f"missing_from_graph={missing_from_graph}, "
            f"extra_in_graph={extra_in_graph}"
        )

    # --- Test 4: transition graph values subset of enum ---

    def test_private_transition_graph_values_are_subsets_of_expected_statuses(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        For every key k in _VALID_TRANSITIONS, the value set must be a subset
        of EXPECTED_STATUSES.  Pins that no transition targets an undeclared status.
        """
        declared = set(EXPECTED_STATUSES)
        for from_status, targets in dispatch_attempts._VALID_TRANSITIONS.items():
            undeclared = set(targets) - declared
            assert not undeclared, (
                f"_VALID_TRANSITIONS[{from_status!r}] references undeclared "
                f"target statuses: {undeclared}"
            )

    # --- Test 5: full graph equality ---

    def test_private_transition_graph_equals_expected_transitions(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Pin dispatch_attempts._VALID_TRANSITIONS == EXPECTED_TRANSITIONS.

        Named per-key symmetric-difference diagnostic: shows which from-status
        rows have diverged and in which direction.  Primary catcher for renames
        and typos.
        """
        actual = dispatch_attempts._VALID_TRANSITIONS
        per_key_diffs = []
        for k in EXPECTED_TRANSITIONS.keys() | actual.keys():
            expected_set = set(EXPECTED_TRANSITIONS.get(k, frozenset()))
            actual_set = set(actual.get(k, frozenset()))
            if expected_set != actual_set:
                per_key_diffs.append(
                    f"  [{k!r}]: "
                    f"missing_from_actual={expected_set - actual_set}, "
                    f"extra_in_actual={actual_set - expected_set}"
                )
        assert not per_key_diffs, (
            "_VALID_TRANSITIONS diverges from EXPECTED_TRANSITIONS:\n"
            + "\n".join(per_key_diffs)
        )

    # --- Test 6: terminal states have empty outgoing sets ---

    def test_terminal_statuses_have_empty_transition_set(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        For every s in EXPECTED_TERMINAL_STATUSES, _VALID_TRANSITIONS[s] must
        be frozenset().

        Pins the docstring claim ("Terminal states: acknowledged, cancelled")
        against the actual transition graph.
        """
        for s in EXPECTED_TERMINAL_STATUSES:
            assert s in dispatch_attempts._VALID_TRANSITIONS, (
                f"Terminal status {s!r} not present in _VALID_TRANSITIONS"
            )
            outgoing = dispatch_attempts._VALID_TRANSITIONS[s]
            assert outgoing == frozenset(), (
                f"Terminal status {s!r} has non-empty outgoing transitions: {outgoing}"
            )

    # --- Test 7: non-terminal statuses have non-empty outgoing sets ---

    def test_non_terminal_statuses_have_nonempty_transition_set(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        For every s in EXPECTED_STATUSES - EXPECTED_TERMINAL_STATUSES, the
        transition graph must have at least one outgoing edge.

        Catches the drift where a non-terminal state is silently made terminal
        by assigning it frozenset() in _VALID_TRANSITIONS.
        """
        non_terminals = EXPECTED_STATUSES - EXPECTED_TERMINAL_STATUSES
        for s in non_terminals:
            assert s in dispatch_attempts._VALID_TRANSITIONS, (
                f"Non-terminal status {s!r} not in _VALID_TRANSITIONS"
            )
            outgoing = dispatch_attempts._VALID_TRANSITIONS[s]
            assert len(outgoing) > 0, (
                f"Non-terminal status {s!r} has empty outgoing transitions "
                f"(should be non-terminal but looks terminal in graph)"
            )

    # --- Test 8: public producer functions exist and are callable ---

    def test_public_producer_functions_exist_and_are_callable(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Pin the public producer function surface from __all__.

        Each of issue, claim, acknowledge, fail, cancel, timeout, retry,
        expire_stale must be callable on dispatch_attempts.

        Catches the drift where a producer is renamed or removed without
        updating the module contract.
        """
        expected_producers = {
            "issue", "claim", "acknowledge", "fail",
            "cancel", "timeout", "retry", "expire_stale",
        }
        for name in expected_producers:
            fn = getattr(dispatch_attempts, name, None)
            assert fn is not None, (
                f"Producer function {name!r} missing from dispatch_attempts"
            )
            assert callable(fn), (
                f"dispatch_attempts.{name} is not callable"
            )

    # --- Test 9: real production sequence exercises all (from, to) pairs ---

    def test_every_non_issue_producer_reaches_declared_transition_via_in_memory_runtime(
        self,
    ):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Real production sequence: exercise every (from, to) transition pair
        declared in _VALID_TRANSITIONS using actual producer functions and an
        in-memory SQLite connection with ensure_schema() applied.

        The set of (from, to) pairs reached by this test is compared set-equal
        against the pairs derived from _VALID_TRANSITIONS.  A future producer
        whose call-pattern drifts from _VALID_TRANSITIONS fails here.

        Transitions exercised:
          pending → delivered         (claim)
          pending → cancelled         (cancel)
          pending → timed_out         (timeout from pending)
          pending → failed            (fail from pending)
          delivered → acknowledged    (acknowledge)
          delivered → failed          (fail)
          delivered → timed_out       (timeout from delivered)
          timed_out → pending         (retry from timed_out)
          failed → pending            (retry from failed)
        """
        c = _make_conn()
        reached: set[tuple[str, str]] = set()

        # pending → delivered
        a = dispatch_attempts.issue(c, _SEAT, "i1")
        assert a["status"] == "pending"
        a = dispatch_attempts.claim(c, a["attempt_id"])
        assert a["status"] == "delivered"
        reached.add(("pending", "delivered"))

        # delivered → acknowledged
        a = dispatch_attempts.acknowledge(c, a["attempt_id"])
        assert a["status"] == "acknowledged"
        reached.add(("delivered", "acknowledged"))

        # pending → cancelled
        a2 = dispatch_attempts.issue(c, _SEAT, "i2")
        a2 = dispatch_attempts.cancel(c, a2["attempt_id"])
        assert a2["status"] == "cancelled"
        reached.add(("pending", "cancelled"))

        # pending → timed_out (via timeout() from pending)
        a3 = dispatch_attempts.issue(c, _SEAT, "i3")
        a3 = dispatch_attempts.timeout(c, a3["attempt_id"])
        assert a3["status"] == "timed_out"
        reached.add(("pending", "timed_out"))

        # pending → failed
        af1 = dispatch_attempts.issue(c, _SEAT, "if1")
        af1 = dispatch_attempts.fail(c, af1["attempt_id"], reason="test")
        assert af1["status"] == "failed"
        reached.add(("pending", "failed"))

        # timed_out → pending (retry from timed_out)
        a3 = dispatch_attempts.retry(c, a3["attempt_id"])
        assert a3["status"] == "pending"
        reached.add(("timed_out", "pending"))

        # delivered → failed
        a4 = dispatch_attempts.issue(c, _SEAT, "i4")
        a4 = dispatch_attempts.claim(c, a4["attempt_id"])
        a4 = dispatch_attempts.fail(c, a4["attempt_id"])
        assert a4["status"] == "failed"
        reached.add(("delivered", "failed"))

        # failed → pending (retry from failed)
        a4 = dispatch_attempts.retry(c, a4["attempt_id"])
        assert a4["status"] == "pending"
        reached.add(("failed", "pending"))

        # delivered → timed_out (via timeout() from delivered)
        a5 = dispatch_attempts.issue(c, _SEAT, "i5")
        a5 = dispatch_attempts.claim(c, a5["attempt_id"])
        a5 = dispatch_attempts.timeout(c, a5["attempt_id"])
        assert a5["status"] == "timed_out"
        reached.add(("delivered", "timed_out"))

        c.close()

        # Pin set-equality against pairs derived from _VALID_TRANSITIONS
        declared_pairs = EXPECTED_PRODUCER_PAIRS
        missing_from_test = declared_pairs - reached
        extra_in_test = reached - declared_pairs
        assert reached == declared_pairs, (
            f"Producer round-trip coverage parity failure: "
            f"missing_from_test={missing_from_test}, "
            f"extra_in_test={extra_in_test}"
        )

    # --- Test 10: DDL default is a declared status ---

    def test_schema_ddl_default_status_is_in_expected_statuses(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Parse schemas.DISPATCH_ATTEMPTS_DDL via regex to extract the DEFAULT
        literal for the status column.  Assert it equals EXPECTED_DDL_DEFAULT
        and is a member of EXPECTED_STATUSES.

        Pins the DDL bootstrap default against the declared enum — prevents
        silent drift where the default is changed to a status outside the enum.
        """
        ddl = schemas.DISPATCH_ATTEMPTS_DDL
        # Match:  status  TEXT  NOT NULL  DEFAULT  'pending'
        match = re.search(
            r"status\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'([^']+)'",
            ddl,
            re.IGNORECASE,
        )
        assert match, (
            "Could not find 'status TEXT NOT NULL DEFAULT ...' in "
            "schemas.DISPATCH_ATTEMPTS_DDL; DDL may have changed shape"
        )
        ddl_default = match.group(1)
        assert ddl_default == EXPECTED_DDL_DEFAULT, (
            f"DDL default '{ddl_default}' != EXPECTED_DDL_DEFAULT '{EXPECTED_DDL_DEFAULT}'"
        )
        assert ddl_default in EXPECTED_STATUSES, (
            f"DDL default '{ddl_default}' not in EXPECTED_STATUSES {EXPECTED_STATUSES}"
        )

    # --- Test 11: docstring terminal-state claim matches expected ---

    def test_module_docstring_terminal_claim_matches_expected_terminal_statuses(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Parse inspect.getdoc(dispatch_attempts) for the line matching
        "Terminal states: ..." and assert the parsed set equals
        EXPECTED_TERMINAL_STATUSES.

        The docstring at dispatch_attempts.py:40 claims:
          "Terminal states: ``acknowledged``, ``cancelled``."
        This test catches docstring drift without editing the docstring itself.
        """
        doc = inspect.getdoc(dispatch_attempts) or ""
        # Match "Terminal states: ``acknowledged``, ``cancelled``." style,
        # stripping backtick RST markup and trailing punctuation.
        match = re.search(r"Terminal states?:([^\n]+)", doc, re.IGNORECASE)
        assert match, (
            "dispatch_attempts module docstring must contain a "
            "'Terminal states: ...' line for parity enforcement"
        )
        raw = match.group(1)
        # Strip RST backticks, trailing punctuation, and split on commas.
        tokens = re.findall(r"[a-z_]+", raw)
        claimed_terminals = frozenset(tokens)
        assert claimed_terminals == EXPECTED_TERMINAL_STATUSES, (
            f"Docstring terminal-state claim diverges from EXPECTED_TERMINAL_STATUSES: "
            f"missing_from_claim={EXPECTED_TERMINAL_STATUSES - claimed_terminals}, "
            f"extra_in_claim={claimed_terminals - EXPECTED_TERMINAL_STATUSES}"
        )

    # --- Test 12: teeth — fake orphan status is refused by transition graph ---

    def test_fake_orphan_status_is_refused_by_transition_graph(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Teeth — orphan detection.

        Using an in-memory fixture, issue a pending attempt and attempt to
        force _transition(..., "orphaned", ...) — assert that ValueError
        is raised and that "orphaned" is not in EXPECTED_STATUSES.

        Demonstrates that the invariant would fire if orphan statuses entered
        the transition surface.
        """
        assert "orphaned" not in EXPECTED_STATUSES, (
            "Teeth precondition: 'orphaned' must not be a declared status"
        )
        c = _make_conn()
        a = dispatch_attempts.issue(c, _SEAT, "teeth-orphan")
        with pytest.raises(ValueError, match=r"invalid transition 'pending'"):
            dispatch_attempts._transition(c, a["attempt_id"], "orphaned")
        c.close()

    # --- Test 13: teeth — trap terminal widening detected by graph equality ---

    def test_fake_trap_terminal_widening_detected_by_graph_equality(self):
        """DEC-CLAUDEX-DISPATCH-ATTEMPT-STATUS-MACHINE-COMPLETENESS-001:
        Teeth — trap detection.

        Construct a hypothetical widened graph where "cancelled" (terminal) has
        a non-empty outgoing transition set.  Assert that this widened graph
        differs from _VALID_TRANSITIONS, and that _VALID_TRANSITIONS["cancelled"]
        is still frozenset().

        Proves that test_private_transition_graph_equals_expected_transitions
        would catch a silent widening of a terminal state, and that
        test_terminal_statuses_have_empty_transition_set would also catch it.
        """
        # Build the hypothetical widened graph (do NOT mutate the real graph)
        widened = dict(dispatch_attempts._VALID_TRANSITIONS)
        widened["cancelled"] = frozenset({"pending"})  # hypothetical undo transition

        # The real graph must differ from the widened one
        assert dispatch_attempts._VALID_TRANSITIONS != widened, (
            "Teeth precondition: widened graph must differ from real graph"
        )

        # The real terminal state must still have empty outgoing transitions
        assert dispatch_attempts._VALID_TRANSITIONS["cancelled"] == frozenset(), (
            "Real graph 'cancelled' must be terminal (frozenset())"
        )

        # Demonstrate the symmetric-diff diagnostic that test 5 would emit
        per_key_diffs = []
        for k in EXPECTED_TRANSITIONS.keys() | widened.keys():
            expected_set = set(EXPECTED_TRANSITIONS.get(k, frozenset()))
            widened_set = set(widened.get(k, frozenset()))
            if expected_set != widened_set:
                per_key_diffs.append(
                    f"  [{k!r}]: "
                    f"missing_from_widened={expected_set - widened_set}, "
                    f"extra_in_widened={widened_set - expected_set}"
                )
        assert len(per_key_diffs) > 0, (
            "Teeth: widened graph must produce at least one per-key diff"
        )
        assert any("cancelled" in d for d in per_key_diffs), (
            "Teeth: 'cancelled' must appear in the per-key diff for the widened graph"
        )

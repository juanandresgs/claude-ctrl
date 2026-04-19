"""Slice 28: agent_sessions.status state-machine completeness invariant.

Six surfaces independently declare or consume the status vocabulary for the
``agent_sessions`` table.  This file pins 6-way parity across all of them so
that any rename, orphan, trap, or terminal-state drift fails at test time with
a named symmetric-diff diagnostic.

Authority surfaces pinned:
  S1  Schema enum       — ``runtime.schemas.AGENT_SESSION_STATUSES``
  S2  Transition graph  — ``runtime.core.agent_sessions._VALID_TRANSITIONS``
  S3  DDL default       — ``runtime.schemas.AGENT_SESSIONS_DDL`` (``DEFAULT 'active'``)
  S4  Docstring claim   — ``agent_sessions.__doc__`` line: "Terminal states: ..."
  S5  Producer funcs    — ``mark_completed``, ``mark_dead``, ``mark_orphaned``
                          round-trip via in-memory SQLite + ``ensure_schema()``.
  S6  CLI subparser     — ``runtime.cli.build_parser()`` ``agent-session`` action set

@decision DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001
Title: 6-way parity invariant pins agent_sessions delivery authority
Status: accepted
Rationale: ``runtime/core/agent_sessions.py`` is the sole runtime authority
  for session lifecycle — every PreToolUse:Agent dispatch bootstraps through
  ``dispatch_hook.ensure_session_and_seat`` → ``agent_sessions.create()`` and
  every transport-observed end flows through one of ``mark_completed``,
  ``mark_dead``, or ``mark_orphaned``.  Six surfaces independently declare or
  consume the status vocabulary: (1) schema enum, (2) transition graph
  (_VALID_TRANSITIONS), (3) DDL DEFAULT, (4) module docstring terminal-state
  claim, (5) public producer functions, (6) CLI subparser action set.  Prior
  coverage was a one-way subset check in test_agent_sessions.py:241-245 and a
  frozenset + subset check in test_supervision_schema.py:228-233.  This file
  closes the 6-way gap with set-equality assertions and named symmetric-diff
  diagnostics so any future rename, orphan, trap, or terminal-state drift fails
  loudly at test time, not silently at runtime.  Agent_sessions is the FK
  parent of seats and the session-lifecycle backbone of the full dispatch chain;
  sealing it before seats/supervision_threads is the correct ordering per
  CUTOVER §2a model-symmetry completion at e982d50.
"""

from __future__ import annotations

import inspect
import re
import sqlite3

import pytest

from runtime import schemas
from runtime.core import agent_sessions

# ---------------------------------------------------------------------------
# Authority anchor — canonical expected values for this invariant.
# These mirror runtime/schemas.py:839-841 and agent_sessions.py:69-75.
# Changing these values requires also changing the source authority + docstring.
# ---------------------------------------------------------------------------

EXPECTED_STATUSES: frozenset = frozenset(
    {"active", "completed", "dead", "orphaned"}
)

EXPECTED_TRANSITIONS: dict = {
    "active": frozenset({"completed", "dead", "orphaned"}),
    # Terminal — no transitions out.
    "completed": frozenset(),
    "dead": frozenset(),
    "orphaned": frozenset(),
}

EXPECTED_TERMINALS: frozenset = frozenset({"completed", "dead", "orphaned"})

EXPECTED_INITIALS: frozenset = frozenset({"active"})

EXPECTED_DDL_DEFAULT: str = "active"

# The exact regex the plan specifies for the DDL DEFAULT extraction.
_DDL_STATUS_RE = re.compile(
    r"status\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'([a-z_]+)'",
    re.IGNORECASE,
)


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


def _make_conn() -> sqlite3.Connection:
    """Return a fresh in-memory connection with the full schema applied.

    Pure in-memory; no on-disk sqlite file is created (forbidden by scope_json).
    The agent_sessions table is seeded by ensure_schema — no raw INSERT needed
    for the session-only tests here (agent_sessions has no FK dependencies).
    """
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    schemas.ensure_schema(conn)
    return conn


# ---------------------------------------------------------------------------
# Class: parity invariants
# ---------------------------------------------------------------------------


class TestAgentSessionStatusMachineCompletenessInvariant:
    """6-way parity invariant for agent_sessions.status state machine.

    DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001
    """

    # --- Case 1: anchor pin ---

    def test_expected_statuses_anchor_is_correct(self):
        """Case 1 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Pin the in-file EXPECTED_STATUSES anchor.

        Guards against a future edit that silently renames, adds, or removes a
        member from the anchor constant inside this test file — which would make
        all downstream set-equality assertions vacuously correct against a
        wrong anchor.
        """
        assert EXPECTED_STATUSES == frozenset(
            {"active", "completed", "dead", "orphaned"}
        ), (
            "EXPECTED_STATUSES anchor has drifted from its pinned literal; "
            "this file must be updated together with the runtime source authority"
        )
        assert len(EXPECTED_STATUSES) == 4, (
            "EXPECTED_STATUSES must have exactly 4 members"
        )

    # --- Case 2: schema enum equality ---

    def test_schema_enum_equals_expected_statuses(self):
        """Case 2 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Pin runtime.schemas.AGENT_SESSION_STATUSES == EXPECTED_STATUSES.

        Named symmetric-difference on failure: missing_from_schema reports
        statuses in EXPECTED_STATUSES not yet in the runtime enum; extra_in_schema
        reports statuses added to the enum without updating this anchor.
        """
        actual = set(schemas.AGENT_SESSION_STATUSES)
        expected = set(EXPECTED_STATUSES)
        missing_from_schema = expected - actual
        extra_in_schema = actual - expected
        assert actual == expected, (
            f"AGENT_SESSION_STATUSES parity failure: "
            f"missing_from_schema={missing_from_schema!r}, "
            f"extra_in_schema={extra_in_schema!r}"
        )

    # --- Case 3: transition graph keys == schema enum ---

    def test_transition_graph_keys_equal_schema_enum(self):
        """Case 3 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Pin set(agent_sessions._VALID_TRANSITIONS.keys()) == AGENT_SESSION_STATUSES.

        Every declared status must have exactly one row in the transition graph:
        no status is orphaned by omission, no phantom key exists.
        """
        graph_keys = set(agent_sessions._VALID_TRANSITIONS.keys())
        schema_statuses = set(schemas.AGENT_SESSION_STATUSES)
        missing_from_graph = schema_statuses - graph_keys
        extra_in_graph = graph_keys - schema_statuses
        assert graph_keys == schema_statuses, (
            f"_VALID_TRANSITIONS key-set parity failure: "
            f"missing_from_graph={missing_from_graph!r}, "
            f"extra_in_graph={extra_in_graph!r}"
        )

    # --- Case 4: transition graph values are subset of schema enum ---

    def test_transition_graph_value_image_is_subset_of_schema_enum(self):
        """Case 4 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        For every key k in _VALID_TRANSITIONS, the value frozenset must be a
        subset of AGENT_SESSION_STATUSES.

        Pins that no transition targets an undeclared status (orphan target
        emission would pass case 3 but fail here).
        """
        declared = set(schemas.AGENT_SESSION_STATUSES)
        for from_status, targets in agent_sessions._VALID_TRANSITIONS.items():
            undeclared = set(targets) - declared
            assert not undeclared, (
                f"_VALID_TRANSITIONS[{from_status!r}] references undeclared "
                f"target statuses: {undeclared!r}"
            )

    # --- Case 5: full graph equality ---

    def test_transition_graph_equals_expected_transitions(self):
        """Case 5 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Pin agent_sessions._VALID_TRANSITIONS == EXPECTED_TRANSITIONS.

        Named per-key symmetric-difference diagnostic: shows which from-status
        rows have diverged and in which direction.  Primary catcher for renames
        and typos in the transition graph.
        """
        actual = agent_sessions._VALID_TRANSITIONS
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

    # --- Case 6: computed terminals ---

    def test_computed_terminal_statuses_match_expected(self):
        """Case 6 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Compute terminal states as keys with empty out-edges.

        Asserts computed_terminals == frozenset({'completed', 'dead', 'orphaned'}).
        Catches the drift where a previously-terminal state gains an out-edge or
        a non-terminal is accidentally made terminal.
        """
        computed_terminals = frozenset(
            s for s, outs in agent_sessions._VALID_TRANSITIONS.items() if not outs
        )
        assert computed_terminals == EXPECTED_TERMINALS, (
            f"Computed terminal-state set diverges from expected: "
            f"missing_from_computed={EXPECTED_TERMINALS - computed_terminals!r}, "
            f"extra_in_computed={computed_terminals - EXPECTED_TERMINALS!r}"
        )

    # --- Case 7: exactly one initial status ---

    def test_computed_initial_statuses_match_expected(self):
        """Case 7 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Compute initial states as keys with non-empty out-edges.

        Asserts computed_initials == frozenset({'active'}).
        Catches the drift where a second non-terminal status is added to the
        transition graph (e.g. a 'paused' → 'active' restart arc).
        """
        computed_initials = frozenset(
            s for s, outs in agent_sessions._VALID_TRANSITIONS.items() if outs
        )
        assert computed_initials == EXPECTED_INITIALS, (
            f"Computed initial-state set diverges from expected: "
            f"missing_from_computed={EXPECTED_INITIALS - computed_initials!r}, "
            f"extra_in_computed={computed_initials - EXPECTED_INITIALS!r}"
        )

    # --- Case 8: DDL DEFAULT parity ---

    def test_ddl_default_matches_expected_and_is_sole_initial(self):
        """Case 8 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Parse schemas.AGENT_SESSIONS_DDL via regex to extract the DEFAULT literal
        for the status column.

        The captured literal must:
          - equal EXPECTED_DDL_DEFAULT ('active')
          - be a key in _VALID_TRANSITIONS
          - be the sole non-terminal key (i.e. the only key with non-empty out-edges)

        Pins the DDL bootstrap default against the declared enum and the sole
        non-terminal status — prevents silent drift where the default is changed
        to a status outside the enum or is no longer the unique initial state.
        """
        ddl = schemas.AGENT_SESSIONS_DDL
        m = _DDL_STATUS_RE.search(ddl)
        assert m is not None, (
            "Could not find 'status TEXT NOT NULL DEFAULT ...' in "
            "schemas.AGENT_SESSIONS_DDL using pattern "
            r"r\"status\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'([a-z_]+)'\"; "
            "DDL may have changed shape"
        )
        captured = m.group(1)
        assert captured == EXPECTED_DDL_DEFAULT, (
            f"DDL status DEFAULT {captured!r} != EXPECTED_DDL_DEFAULT {EXPECTED_DDL_DEFAULT!r}"
        )
        assert captured in agent_sessions._VALID_TRANSITIONS, (
            f"DDL DEFAULT {captured!r} is not a key in _VALID_TRANSITIONS"
        )
        # Must be the sole non-terminal key
        non_terminals = [
            s for s, outs in agent_sessions._VALID_TRANSITIONS.items() if outs
        ]
        assert non_terminals == [captured], (
            f"DDL DEFAULT {captured!r} must be the sole non-terminal key; "
            f"actual non-terminal keys: {non_terminals!r}"
        )

    # --- Case 9: docstring terminal claim parity ---

    def test_module_docstring_terminal_claim_matches_expected_terminals(self):
        """Case 9 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Parse agent_sessions.__doc__ for the 'Terminal states:' clause and extract
        backtick-quoted identifiers.

        Asserts sorted(extracted) == sorted(['completed', 'dead', 'orphaned']).
        Catches docstring drift where a terminal is added/removed in the
        transition graph but the docstring is not updated, or vice-versa.
        """
        doc = inspect.getdoc(agent_sessions) or ""
        m = re.search(r"Terminal states?:\s*([^\n]+)", doc, re.IGNORECASE)
        assert m is not None, (
            "agent_sessions module docstring must contain a "
            "'Terminal states: ...' line for parity enforcement"
        )
        raw = m.group(1)
        # Extract backtick-quoted identifiers in RST style: ``completed``, ``dead``, etc.
        # Only capture content wrapped in double backticks to avoid false positives
        # from prose words on the same line (e.g. "All three are terminal").
        extracted = re.findall(r"``([a-z_]+)``", raw)
        assert sorted(extracted) == sorted(["completed", "dead", "orphaned"]), (
            f"Docstring 'Terminal states:' claim diverges from expected terminals: "
            f"extracted={extracted!r}, "
            f"expected={sorted(['completed', 'dead', 'orphaned'])!r}"
        )

    # --- Case 10: public producer function image ---

    def test_public_producer_function_image_equals_expected_terminals(self):
        """Case 10 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Introspect agent_sessions module for callables matching ^mark_([a-z]+)$.

        Asserts the set of (name-without-mark_ prefix) == {'completed','dead','orphaned'}.
        Catches the drift where a producer is renamed/removed without updating
        the transition graph, or the graph gains an out-edge with no public producer.
        """
        image = {
            m.group(1)
            for name in dir(agent_sessions)
            if (m := re.match(r"^mark_([a-z]+)$", name))
            and callable(getattr(agent_sessions, name))
        }
        expected_image = {"completed", "dead", "orphaned"}
        assert image == expected_image, (
            f"Public mark_* producer image diverges from expected terminals: "
            f"missing={expected_image - image!r}, "
            f"extra={image - expected_image!r}"
        )

    # --- Case 11: producer round-trip (real path check) ---

    def test_producer_round_trip_in_memory_sqlite(self):
        """Case 11 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Real production sequence: for each terminal t in {'completed','dead','orphaned'},
        create a session via agent_sessions.create(conn, f'sess-smc-{t}', transport='tmux'),
        call the corresponding mark_{t} method, and assert the returned row's status == t.

        Uses a fresh in-memory SQLite connection with ensure_schema applied.
        Uses unique session_ids per iteration to avoid idempotent-noop interference.
        This is the compound-interaction test that crosses the schema, domain module,
        and in-memory SQLite boundaries in the actual production call sequence.
        """
        terminals = sorted(agent_sessions._VALID_TRANSITIONS["active"])
        for t in terminals:
            conn = _make_conn()
            session_id = f"sess-smc-{t}"
            # Create session (status == 'active' after this)
            created_row = agent_sessions.create(conn, session_id, transport="tmux")
            assert created_row["status"] == "active", (
                f"Expected create() to yield status='active', got {created_row['status']!r}"
            )
            # Transition to terminal t
            mark_fn = getattr(agent_sessions, f"mark_{t}")
            result = mark_fn(conn, session_id)
            # mark_* returns {"row": <dict>, "transitioned": bool}
            row = result["row"]
            assert row["status"] == t, (
                f"mark_{t}() on session {session_id!r} returned row with "
                f"status={row['status']!r}, expected {t!r}"
            )
            assert result["transitioned"] is True, (
                f"mark_{t}() expected transitioned=True, got {result['transitioned']!r}"
            )
            conn.close()

    # --- Case 12: producer target set == active out-edges ---

    def test_producer_image_equals_active_out_edges(self):
        """Case 12 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Producer-to-graph completeness pin.

        Asserts:
          {name.removeprefix('mark_') for name in
           ('mark_completed', 'mark_dead', 'mark_orphaned')}
          == _VALID_TRANSITIONS['active']

        Catches the drift where a new edge is added to _VALID_TRANSITIONS['active']
        with no corresponding public producer, or vice-versa.
        """
        producer_suffixes = frozenset(
            name.removeprefix("mark_")
            for name in ("mark_completed", "mark_dead", "mark_orphaned")
        )
        active_out_edges = agent_sessions._VALID_TRANSITIONS["active"]
        missing_from_producers = active_out_edges - producer_suffixes
        extra_in_producers = producer_suffixes - active_out_edges
        assert producer_suffixes == active_out_edges, (
            f"Producer↔graph completeness failure on 'active' out-edges: "
            f"missing_from_producers={missing_from_producers!r}, "
            f"extra_in_producers={extra_in_producers!r}"
        )

    # --- Case 13: CLI subparser parity (real path check) ---

    def test_cli_subparser_mark_actions_match_expected_terminals(self):
        """Case 13 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        Real path check: invoke runtime.cli.build_parser() in-process (no subprocess,
        no stdout side-effects) to locate the 'agent-session' subparser and its
        action subparsers.

        Asserts:
          - The set of action names matching ^mark-[a-z]+$ == {'mark-completed',
            'mark-dead', 'mark-orphaned'} (no missing, no phantom CLI surface).
          - The full action set is a superset of {'get', 'mark-completed',
            'mark-dead', 'mark-orphaned', 'list-active'}.

        Catches the drift where a new terminal status is added to the graph
        without a corresponding CLI surface, or the CLI surface gains a phantom
        action not backed by a producer function.
        """
        from runtime.cli import build_parser

        parser = build_parser()

        # Walk subparsers to find 'agent-session'
        as_subparsers = None
        root_subparsers = parser._subparsers
        assert root_subparsers, "build_parser() returned a parser with no subparsers"

        # argparse stores subparsers in _group_actions; find the one for agent-session
        agent_session_subparser = None
        for group in parser._subparsers._group_actions:
            choices = getattr(group, "choices", {}) or {}
            if "agent-session" in choices:
                agent_session_subparser = choices["agent-session"]
                break

        assert agent_session_subparser is not None, (
            "Could not locate 'agent-session' subparser in build_parser() output; "
            "the CLI subparser may have been renamed or removed"
        )

        # Find the action sub-subparsers
        action_choices: dict = {}
        for group in agent_session_subparser._subparsers._group_actions:
            choices = getattr(group, "choices", {}) or {}
            if choices:
                action_choices.update(choices)
                break

        assert action_choices, (
            "Could not find any action subparsers under 'agent-session'; "
            "the action subparser group may have changed structure"
        )

        full_action_name_set = set(action_choices.keys())

        # Extract mark-* action names
        mark_actions = {
            name for name in full_action_name_set
            if re.match(r"^mark-[a-z]+$", name)
        }
        expected_mark_actions = {"mark-completed", "mark-dead", "mark-orphaned"}
        missing_from_cli = expected_mark_actions - mark_actions
        extra_in_cli = mark_actions - expected_mark_actions
        assert mark_actions == expected_mark_actions, (
            f"CLI agent-session mark-* action parity failure: "
            f"missing_from_cli={missing_from_cli!r}, "
            f"extra_in_cli={extra_in_cli!r}"
        )

        # Full surface superset assertion
        required_full = {"get", "mark-completed", "mark-dead", "mark-orphaned", "list-active"}
        missing_from_full = required_full - full_action_name_set
        assert not missing_from_full, (
            f"CLI agent-session full action surface is missing expected actions: "
            f"missing={missing_from_full!r}, "
            f"full_action_name_set={full_action_name_set!r}"
        )

    # --- Case 14: module docstring DEC-id pin ---

    def test_module_docstring_contains_dec_id(self):
        """Case 14 — DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001:
        The literal string 'DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001'
        must appear in this module's __doc__.

        This is a scope-audit anchor for the Guardian landing commit message and
        for future grep-driven archaeology — any change to this invariant file can
        be traced back to the governing decision ID.
        """
        dec_id = "DEC-CLAUDEX-AGENT-SESSION-STATUS-MACHINE-COMPLETENESS-001"
        assert dec_id in (__doc__ or ""), (
            f"Module docstring must contain the literal DEC-id {dec_id!r} "
            f"for scope-audit traceability; current module __doc__ is missing it"
        )

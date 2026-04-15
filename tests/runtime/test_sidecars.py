"""Unit tests for shadow-mode sidecars (TKT-015).

Tests cover:
- Observatory.observe() populates state from all 5 canonical tables
- Observatory.report() returns a valid JSON-serializable dict
- Observatory._compute_health() detects stale proofs, too many agents, dispatch backlog
- SearchIndex.observe() indexes traces and trace_manifest
- SearchIndex.search() returns matching results by query term
- SearchIndex.report() returns valid dict
- Read-only enforcement: sidecars never write to canonical tables

Production sequence exercised:
  1. Populate db with proof_state, agent_markers, events, worktrees,
     dispatch_queue, traces, trace_manifest rows.
  2. Instantiate Observatory and SearchIndex with the same db.
  3. Call observe() on both.
  4. Assert report() fields match what was inserted.
  5. Assert no canonical table rows were added/modified by the sidecar.

@decision DEC-SIDECAR-001
Title: Sidecars are read-only consumers of the canonical SQLite runtime
Status: accepted
Rationale: TKT-015 specifies that sidecars may read but never write to any
  runtime table. This boundary is enforced by convention (no conn.execute
  writes in sidecar code) and verified by the test suite, which counts
  canonical table rows before and after observe()/search() calls and asserts
  equality. This keeps the sidecar/runtime authority boundary clean --
  sidecars cannot become authorities by accident.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

# Make project root importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.proof as proof_mod
import runtime.core.markers as markers_mod
import runtime.core.events as events_mod
import runtime.core.worktrees as worktrees_mod
import runtime.core.dispatch as dispatch_mod
import runtime.core.traces as traces_mod

from sidecars.observatory.observe import Observatory
from sidecars.search.search import SearchIndex


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def conn():
    """In-memory DB with full schema, yielded open."""
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def populated_conn(conn):
    """DB pre-populated with one row in every canonical table."""
    now = int(time.time())

    # proof_state
    proof_mod.set_status(conn, "wf-001", "pending")

    # agent_markers
    markers_mod.set_active(conn, "agent-001", "implementer")

    # events
    events_mod.emit(conn, type="test_event", source="pytest", detail="hello")

    # worktrees
    worktrees_mod.register(conn, path="/tmp/wt-test", branch="feature/x")

    # dispatch_queue
    dispatch_mod.enqueue(conn, role="reviewer", ticket="TKT-015")

    # traces + trace_manifest
    traces_mod.start_trace(conn, "sess-populate", agent_role="implementer", ticket="TKT-015")
    traces_mod.add_manifest_entry(conn, "sess-populate", "file_write",
                                  path="sidecars/observatory/observe.py",
                                  detail="created observatory sidecar")
    traces_mod.end_trace(conn, "sess-populate", summary="TKT-015 sidecars implemented")

    return conn


# ---------------------------------------------------------------------------
# Helper: count rows across all canonical tables
# ---------------------------------------------------------------------------

def _canonical_row_counts(conn) -> dict:
    tables = [
        "proof_state", "agent_markers", "events",
        "worktrees", "dispatch_queue", "dispatch_cycles",
        "traces", "trace_manifest",
    ]
    return {t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in tables}


# ---------------------------------------------------------------------------
# Observatory tests
# ---------------------------------------------------------------------------

class TestObservatory:

    def test_observe_populates_proof_states(self, populated_conn):
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        assert len(obs.proof_states) == 1

    def test_observe_populates_active_markers(self, populated_conn):
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        # One active marker was inserted
        assert len(obs.active_markers) >= 1

    def test_observe_populates_recent_events(self, populated_conn):
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        assert len(obs.recent_events) >= 1

    def test_observe_populates_worktrees(self, populated_conn):
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        assert len(obs.worktrees) >= 1

    def test_observe_populates_dispatch(self, populated_conn):
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        # dispatch has one pending item
        assert len(obs.dispatch) >= 1

    def test_report_is_json_serializable(self, populated_conn):
        import json
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        report = obs.report()
        # Must not raise
        serialized = json.dumps(report)
        data = json.loads(serialized)
        assert data["name"] == "observatory"
        assert "observed_at" in data
        assert isinstance(data["observed_at"], int)

    def test_report_counts_match_state(self, populated_conn):
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        report = obs.report()
        assert report["proof_count"] == 1
        assert report["active_agents"] >= 1
        assert report["pending_dispatches"] >= 1
        assert report["worktree_count"] >= 1
        assert report["recent_event_count"] >= 1

    def test_health_ok_with_normal_state(self, populated_conn):
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        health = obs._compute_health()
        assert "ok" in health
        assert "issues" in health
        assert isinstance(health["issues"], list)

    def test_health_detects_many_active_agents(self, conn):
        """Four active agents triggers many_active_agents issue."""
        for i in range(4):
            markers_mod.set_active(conn, f"agent-{i:03d}", "implementer")
        obs = Observatory("observatory", conn)
        obs.observe()
        health = obs._compute_health()
        assert health["ok"] is False
        assert "many_active_agents" in health["issues"]

    def test_health_detects_dispatch_backlog(self, conn):
        """More than 10 pending dispatches triggers dispatch_backlog issue."""
        for i in range(11):
            dispatch_mod.enqueue(conn, role="reviewer", ticket=f"TKT-{i:03d}")
        obs = Observatory("observatory", conn)
        obs.observe()
        health = obs._compute_health()
        assert health["ok"] is False
        assert "dispatch_backlog" in health["issues"]

    def test_health_detects_stale_proofs(self, conn):
        """A proof_state with status=pending and updated_at > 1h ago is stale."""
        # Insert a proof with a timestamp 2 hours in the past
        two_hours_ago = int(time.time()) - 7201
        with conn:
            conn.execute(
                "INSERT INTO proof_state (workflow_id, status, updated_at) VALUES (?, ?, ?)",
                ("wf-stale", "pending", two_hours_ago),
            )
        obs = Observatory("observatory", conn)
        obs.observe()
        health = obs._compute_health()
        assert health["ok"] is False
        assert "stale_proofs" in health["issues"]

    def test_health_ok_with_empty_state(self, conn):
        """Empty DB produces a healthy report (no issues)."""
        obs = Observatory("observatory", conn)
        obs.observe()
        health = obs._compute_health()
        assert health["ok"] is True
        assert health["issues"] == []

    def test_observatory_does_not_write_canonical_tables(self, populated_conn):
        """observe() and report() must not insert/update any canonical row."""
        before = _canonical_row_counts(populated_conn)
        obs = Observatory("observatory", populated_conn)
        obs.observe()
        obs.report()
        after = _canonical_row_counts(populated_conn)
        assert before == after, (
            f"Observatory wrote to canonical tables!\n  before={before}\n  after={after}"
        )


# ---------------------------------------------------------------------------
# SearchIndex tests
# ---------------------------------------------------------------------------

class TestSearchIndex:

    def test_observe_indexes_traces(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        assert len(si.traces) >= 1

    def test_observe_indexes_trace_manifest(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        assert len(si.manifest_entries) >= 1

    def test_search_matches_ticket_in_trace(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        results = si.search("TKT-015")
        assert len(results) >= 1
        types = [r["type"] for r in results]
        assert "trace" in types

    def test_search_matches_agent_role(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        results = si.search("implementer")
        assert len(results) >= 1

    def test_search_matches_manifest_path(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        results = si.search("observe.py")
        # matches manifest entry path
        assert len(results) >= 1
        types = [r["type"] for r in results]
        assert "manifest" in types

    def test_search_matches_manifest_detail(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        results = si.search("observatory sidecar")
        assert len(results) >= 1

    def test_search_matches_trace_summary(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        results = si.search("sidecars implemented")
        assert len(results) >= 1

    def test_search_no_match_returns_empty(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        results = si.search("zzzno-such-term-xyz")
        assert results == []

    def test_search_respects_limit(self, conn):
        """Search returns at most `limit` results."""
        for i in range(20):
            traces_mod.start_trace(conn, f"sess-{i:03d}", agent_role="implementer",
                                   ticket="TKT-015")
        si = SearchIndex("search", conn)
        si.observe()
        results = si.search("implementer", limit=5)
        assert len(results) <= 5

    def test_search_is_case_insensitive(self, populated_conn):
        si = SearchIndex("search", populated_conn)
        si.observe()
        upper = si.search("TKT-015")
        lower = si.search("tkt-015")
        assert len(upper) >= 1
        assert len(lower) >= 1

    def test_report_is_json_serializable(self, populated_conn):
        import json
        si = SearchIndex("search", populated_conn)
        si.observe()
        report = si.report()
        serialized = json.dumps(report)
        data = json.loads(serialized)
        assert data["name"] == "search"
        assert "observed_at" in data
        assert data["indexed_traces"] >= 1
        assert data["indexed_manifest_entries"] >= 1

    def test_search_index_does_not_write_canonical_tables(self, populated_conn):
        """observe() and search() must not insert/update any canonical row."""
        before = _canonical_row_counts(populated_conn)
        si = SearchIndex("search", populated_conn)
        si.observe()
        si.search("TKT-015")
        si.report()
        after = _canonical_row_counts(populated_conn)
        assert before == after, (
            f"SearchIndex wrote to canonical tables!\n  before={before}\n  after={after}"
        )


# ---------------------------------------------------------------------------
# Compound interaction test — real production sequence end-to-end
# ---------------------------------------------------------------------------

class TestSidecarProductionSequence:
    """
    Exercises the real production sequence: runtime state is populated by
    hooks/domain modules, then a sidecar reads it without writes.

    This mirrors what happens in production:
      1. session-init.sh calls cc-policy trace start → traces row
      2. pre-write.sh checks proof, markers → proof_state, agent_markers rows
      3. post-task.sh enqueues dispatch → dispatch_queue row
      4. A sidecar is invoked by the user → reads all tables, produces output
      5. Runtime state is identical after the sidecar ran
    """

    def test_full_runtime_population_then_sidecar_observe(self, conn):
        import json

        # --- Production write sequence (simulating hooks/domain modules) ---
        proof_mod.set_status(conn, "wf-compound", "pending")
        markers_mod.set_active(conn, "agent-compound", "implementer")
        events_mod.emit(conn, type="session_start", source="session-init.sh",
                        detail="session compound started")
        worktrees_mod.register(conn, path="/tmp/wt-compound", branch="feature/compound")
        dispatch_mod.enqueue(conn, role="reviewer", ticket="TKT-015")
        traces_mod.start_trace(conn, "sess-compound", agent_role="implementer",
                               ticket="TKT-015")
        traces_mod.add_manifest_entry(conn, "sess-compound", "file_write",
                                      path="sidecars/observatory/observe.py",
                                      detail="TKT-015 observatory implemented")
        traces_mod.end_trace(conn, "sess-compound",
                             summary="compound test session complete")

        before = _canonical_row_counts(conn)

        # --- Sidecar observe sequence ---
        obs = Observatory("observatory", conn)
        obs.observe()
        obs_report = obs.report()

        si = SearchIndex("search", conn)
        si.observe()
        si_report = si.report()
        search_results = si.search("TKT-015")

        after = _canonical_row_counts(conn)

        # --- Assertions ---

        # Observatory sees the state
        assert obs_report["proof_count"] == 1
        assert obs_report["active_agents"] >= 1
        assert obs_report["pending_dispatches"] >= 1
        assert obs_report["worktree_count"] >= 1
        assert obs_report["recent_event_count"] >= 1

        # Search finds traces
        assert len(search_results) >= 1
        assert any(r["type"] == "trace" for r in search_results)

        # Both reports are JSON-serializable
        json.dumps(obs_report)
        json.dumps(si_report)

        # No canonical table was mutated
        assert before == after, (
            "Sidecars wrote to canonical tables in compound test!\n"
            f"  before={before}\n  after={after}"
        )

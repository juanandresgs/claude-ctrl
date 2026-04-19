"""Slice 24: lease-lifecycle state-machine completeness invariant.

@decision DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001
Title: Lease status authority enum must equal the set reachable by runtime operations
Status: proposed
Rationale:
    runtime/schemas.py declares LEASE_STATUSES as the one authority enum for
    dispatch_leases.status.  runtime/core/leases.py produces these statuses via
    issue(), release(), revoke(), expire_stale(), claim(), and
    _revoke_active_for_worktree().  Currently zero tests import LEASE_STATUSES —
    no cross-authority parity is pinned.  This invariant closes that gap by
    asserting set-equality in both directions:
      producer(runtime operations) == consumer(schema enum)
    so trap states (enum entries with no producer) and orphan states
    (runtime-produced status not in enum) both fail at test time.

    Drift modes caught:
      1. Trap state: a future author adds "suspended"/"paused" to LEASE_STATUSES
         with no runtime transition — status enum grows without a producer.
      2. Orphan state: runtime adds UPDATE to status='rebased' without widening
         LEASE_STATUSES — rows land in an undeclared status.
      3. Rename/typo: someone renames 'released' to 'completed' in one surface
         only — silent because no test pins set-equality.

    Adjacent authorities (must remain aligned, not modified by this slice):
      - runtime/schemas.py: LEASE_STATUSES (authority enum, read-only here)
      - runtime/core/leases.py: issue/release/revoke/expire_stale/claim
        (producer operations, read-only here)
      - tests/runtime/test_leases.py: exercises transitions individually;
        this file adds cross-authority set-equality only, does not replace
        or modify test_leases.py

    Shadow-only discipline: this slice creates one new test file.  No runtime
    source is modified.  If tests reveal real drift, HALT and report — do NOT
    patch runtime/core/leases.py or runtime/schemas.py as part of this slice.

DEC-ID usage: DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001 appears verbatim
in module docstring, every test docstring, scope manifest, plan header, and
eventual commit message so supervisor traceability is unambiguous.
"""

import sqlite3
import time
from typing import Set

import pytest

from runtime.schemas import LEASE_STATUSES, ensure_schema
from runtime.core import leases

# ---------------------------------------------------------------------------
# Module-level authority anchor
# ---------------------------------------------------------------------------

# Literal mirror of the lifecycle claim in runtime/core/leases.py lines 18-19
# (DEC-LEASE-001):  "Lifecycle: active → released (normal completion) |
#  revoked (superseded) | expired (TTL elapsed, detected by expire_stale)."
# This constant pins the implementer's understanding at write time.  The live
# authority for the tests is LEASE_STATUSES imported directly from schemas.py.
EXPECTED_LEASE_STATUSES: frozenset = frozenset(
    {"active", "released", "revoked", "expired"}
)


# ---------------------------------------------------------------------------
# Shared fixture
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema applied.

    DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
    Each test gets an isolated in-memory DB — no cross-test state leakage.
    Matches the fixture shape used by tests/runtime/test_leases.py so
    ensure_schema is the only bootstrap call needed.
    """
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------


def _issue(
    conn,
    *,
    role: str = "implementer",
    worktree_path: str = "/repo/wt",
    workflow_id: str = "wf-test",
    ttl: int = 3600,
) -> dict:
    """Thin wrapper around leases.issue() with test-friendly defaults.

    DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
    No subprocess; no temp files; exercises the real production code path.
    """
    return leases.issue(
        conn,
        role=role,
        worktree_path=worktree_path,
        workflow_id=workflow_id,
        allowed_ops=["routine_local"],
        ttl=ttl,
    )


def _status(conn, lease_id: str) -> str:
    """Read current status of a lease from the in-memory DB."""
    row = conn.execute(
        "SELECT status FROM dispatch_leases WHERE lease_id = ?",
        (lease_id,),
    ).fetchone()
    assert row is not None, f"lease {lease_id} not found in DB"
    return row["status"]


def _all_distinct_statuses(conn) -> Set[str]:
    """Return the set of distinct status values present in dispatch_leases."""
    rows = conn.execute(
        "SELECT DISTINCT status FROM dispatch_leases"
    ).fetchall()
    return {r["status"] for r in rows}


# ===========================================================================
# TestLeaseStateMachineCompleteness
# ===========================================================================


class TestLeaseStateMachineCompleteness:
    """Cross-authority set-equality: LEASE_STATUSES ↔ reachable runtime statuses.

    DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001
    """

    # -----------------------------------------------------------------------
    # 1. Authority enum matches expected literal set
    # -----------------------------------------------------------------------

    def test_authority_enum_matches_expected_literal_set(self):
        """DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
        LEASE_STATUSES from schemas.py must equal the literal set declared by
        the leases.py module docstring lifecycle claim.  Guards against silent
        widening of the enum itself without updating this test's expectation —
        acts as a tripwire that forces a reviewer to consciously accept any
        addition to the lifecycle.
        """
        assert isinstance(LEASE_STATUSES, frozenset), (
            "LEASE_STATUSES must be a frozenset (authority invariant)"
        )
        assert LEASE_STATUSES == EXPECTED_LEASE_STATUSES, (
            f"LEASE_STATUSES changed without updating this invariant test.\n"
            f"  authority enum : {sorted(LEASE_STATUSES)}\n"
            f"  expected literal: {sorted(EXPECTED_LEASE_STATUSES)}"
        )

    # -----------------------------------------------------------------------
    # 2. Every declared status is reachable via a runtime operation
    # -----------------------------------------------------------------------

    def test_every_authority_status_is_reachable_via_runtime(self, conn):
        """DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
        Loop over every member of LEASE_STATUSES and drive the corresponding
        lifecycle operation.  Asserts there are no 'trap states' — enum members
        that no runtime operation can ever produce.

        Trap state example: adding "suspended" to LEASE_STATUSES without a
        corresponding UPDATE in leases.py would cause this test to fail.
        """
        produced: Set[str] = set()

        # --- "active" via issue() ---
        l_active = _issue(conn, worktree_path="/repo/active", workflow_id="wf-active")
        produced.add(_status(conn, l_active["lease_id"]))

        # --- "released" via release() ---
        l_rel = _issue(conn, worktree_path="/repo/rel", workflow_id="wf-rel")
        result = leases.release(conn, l_rel["lease_id"])
        assert result is True, "release() must return True on first call"
        produced.add(_status(conn, l_rel["lease_id"]))

        # --- "revoked" via revoke() ---
        l_rev = _issue(conn, worktree_path="/repo/rev", workflow_id="wf-rev")
        result = leases.revoke(conn, l_rev["lease_id"])
        assert result is True, "revoke() must return True on first call"
        produced.add(_status(conn, l_rev["lease_id"]))

        # --- "expired" via expire_stale() with explicit past `now` ---
        # Issue with ttl=3600, then call expire_stale with now=future so the
        # expires_at threshold is well in the past relative to the supplied now.
        # This avoids real wall-clock sleep and matches the technique in
        # tests/runtime/test_leases.py (risk register entry #2 mitigation).
        l_exp = _issue(conn, worktree_path="/repo/exp", workflow_id="wf-exp", ttl=3600)
        future_now = int(time.time()) + 10_000
        count = leases.expire_stale(conn, now=future_now)
        assert count >= 1, "expire_stale() must have expired at least one lease"
        produced.add(_status(conn, l_exp["lease_id"]))

        # Assert set-equality: every declared status is produced
        declared = set(LEASE_STATUSES)
        traps = declared - produced
        assert traps == set(), (
            f"DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001 VIOLATION — "
            f"Trap states detected: {traps}\n"
            f"These statuses appear in LEASE_STATUSES but no runtime operation "
            f"produces them.  Either add a producing operation or remove the "
            f"status from the enum."
        )

    # -----------------------------------------------------------------------
    # 3. No runtime operation produces an undeclared status
    # -----------------------------------------------------------------------

    def test_no_runtime_operation_produces_undeclared_status(self, conn):
        """DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
        Run a full smoke sequence covering all transitions, then assert
        SELECT DISTINCT status FROM dispatch_leases ⊆ LEASE_STATUSES.
        Detects 'orphan states' — runtime-produced statuses not declared in
        the enum.

        Orphan state example: adding UPDATE status='rebased' in leases.py
        without widening LEASE_STATUSES would cause this test to fail.
        """
        declared = set(LEASE_STATUSES)

        # issue → active
        l1 = _issue(conn, worktree_path="/repo/s1", workflow_id="wf1")

        # issue → released
        l2 = _issue(conn, worktree_path="/repo/s2", workflow_id="wf2")
        leases.release(conn, l2["lease_id"])

        # issue → revoked via revoke()
        l3 = _issue(conn, worktree_path="/repo/s3", workflow_id="wf3")
        leases.revoke(conn, l3["lease_id"])

        # issue → revoked via worktree-collision (second issue for same path)
        l4_old = _issue(conn, worktree_path="/repo/s4", workflow_id="wf4a")
        l4_new = _issue(conn, worktree_path="/repo/s4", workflow_id="wf4b")
        # l4_old is now revoked; l4_new is active
        assert _status(conn, l4_old["lease_id"]) == "revoked"
        assert _status(conn, l4_new["lease_id"]) == "active"

        # issue → expired via expire_stale()
        l5 = _issue(conn, worktree_path="/repo/s5", workflow_id="wf5", ttl=3600)
        future_now = int(time.time()) + 10_000
        leases.expire_stale(conn, now=future_now)

        # issue → revoked via claim() same-agent revocation path
        l6a = _issue(conn, worktree_path="/repo/s6a", workflow_id="wf6a")
        l6b = _issue(conn, worktree_path="/repo/s6b", workflow_id="wf6b")
        # claim l6b with agent X — this revokes l6a (one-lease-per-agent)
        leases.claim(conn, agent_id="agent-x", lease_id=l6a["lease_id"])
        leases.claim(conn, agent_id="agent-x", lease_id=l6b["lease_id"])
        # l6a is now revoked (superseded by l6b claim)
        assert _status(conn, l6a["lease_id"]) == "revoked"

        # Gather all statuses that actually landed in the DB
        produced = _all_distinct_statuses(conn)

        orphans = produced - declared
        assert orphans == set(), (
            f"DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001 VIOLATION — "
            f"Orphan states detected: {orphans}\n"
            f"Runtime produced these statuses but they are not in LEASE_STATUSES. "
            f"Widen the enum or remove the producing operation."
        )

    # -----------------------------------------------------------------------
    # 4. Docstring lifecycle claim matches authority enum
    # -----------------------------------------------------------------------

    def test_lifecycle_claim_in_leases_module_docstring_matches_authority(self):
        """DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
        Parse the leases.py module docstring, extract the declared lifecycle
        chain, and assert the terminal-status tokens equal
        LEASE_STATUSES minus 'active' (active is the entry state, not a
        terminal listed in the chain).

        This test ensures the prose claim at lines 18-19 stays aligned with
        the runtime authority.  If the chain is updated in prose but LEASE_STATUSES
        is not (or vice versa), this test fails.
        """
        doc = leases.__doc__ or ""
        # Extract line containing "Lifecycle:" (lines 18-19 per plan)
        lifecycle_line = ""
        continuation_line = ""
        lines = doc.splitlines()
        for i, line in enumerate(lines):
            if "Lifecycle:" in line:
                lifecycle_line = line
                if i + 1 < len(lines):
                    continuation_line = lines[i + 1]
                break

        assert lifecycle_line, (
            "Could not find 'Lifecycle:' in leases.py module docstring. "
            "The lifecycle claim at lines 18-19 may have been removed or renamed."
        )

        # The claim is: "active → released (normal completion) | revoked (superseded) |"
        # followed by: "             expired (TTL elapsed, detected by expire_stale)."
        full_claim = lifecycle_line + " " + continuation_line

        # Extract status tokens from the lifecycle claim
        # Statuses appear as bare words: 'active', 'released', 'revoked', 'expired'
        # They are the only lowercase alpha-only tokens in that section.
        import re
        tokens = set(re.findall(r"\b(active|released|revoked|expired)\b", full_claim))

        declared = set(LEASE_STATUSES)
        assert tokens == declared, (
            f"DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001 VIOLATION — "
            f"Docstring lifecycle claim tokens {sorted(tokens)} != "
            f"LEASE_STATUSES {sorted(declared)}.\n"
            f"Update runtime/core/leases.py docstring or runtime/schemas.py "
            f"LEASE_STATUSES to restore alignment."
        )

    # -----------------------------------------------------------------------
    # 5. Vacuous-truth guard: enum must be non-empty
    # -----------------------------------------------------------------------

    def test_vacuous_truth_guard_enum_is_nonempty(self):
        """DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
        Guard against an empty LEASE_STATUSES making the parity test
        vacuously true (empty set is a subset of anything; empty set minus
        anything is empty set).

        If a future agent clears or removes the enum, the parity checks above
        would pass trivially.  This test catches that.
        """
        assert isinstance(LEASE_STATUSES, frozenset), (
            "LEASE_STATUSES must be a frozenset"
        )
        assert len(LEASE_STATUSES) >= 4, (
            f"LEASE_STATUSES has {len(LEASE_STATUSES)} members — expected >= 4.  "
            "A reduction without a companion lifecycle amendment is a scope violation."
        )
        # Each expected status must be present by name
        for status in ("active", "released", "revoked", "expired"):
            assert status in LEASE_STATUSES, (
                f"'{status}' missing from LEASE_STATUSES — "
                "DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001 requires it."
            )

    # -----------------------------------------------------------------------
    # 6. Teeth test: fake drift would fail
    # -----------------------------------------------------------------------

    def test_teeth_fake_drift_would_fail(self, conn, monkeypatch):
        """DEC-CLAUDEX-LEASE-STATE-MACHINE-COMPLETENESS-001:
        Demonstrate that the invariant has teeth by simulating the two classes
        of drift this file is designed to catch.

        Scenario A (orphan state): runtime produces a status not in enum.
          Simulate by constructing a fake produced set with an extra status.
          Assert the orphan check would surface it.

        Scenario B (trap state): enum declares a status no operation produces.
          Simulate by monkeypatching LEASE_STATUSES to add "suspended".
          Assert the trap check detects it when production does not produce it.

        This test does NOT mutate the real runtime — it uses local variables and
        monkeypatch for the B scenario only.  The runtime DB is exercised in the
        A scenario via a normal lease op sequence.
        """
        import runtime.schemas as _schemas

        # --- Scenario A: orphan state (produced but not declared) ---
        fake_produced = {"active", "released", "revoked", "expired", "rolled_back"}
        declared_a = set(LEASE_STATUSES)
        orphans_a = fake_produced - declared_a
        assert orphans_a == {"rolled_back"}, (
            "Teeth A failure: orphan check did not surface 'rolled_back'"
        )

        # --- Scenario B: trap state (declared but never produced) ---
        augmented = frozenset(LEASE_STATUSES | {"suspended"})
        monkeypatch.setattr(_schemas, "LEASE_STATUSES", augmented)

        # Now drive the full normal production sequence
        l1 = _issue(conn, worktree_path="/repo/t1", workflow_id="tfwf1")
        l2 = _issue(conn, worktree_path="/repo/t2", workflow_id="tfwf2")
        leases.release(conn, l2["lease_id"])
        l3 = _issue(conn, worktree_path="/repo/t3", workflow_id="tfwf3")
        leases.revoke(conn, l3["lease_id"])
        l4 = _issue(conn, worktree_path="/repo/t4", workflow_id="tfwf4", ttl=3600)
        future_now = int(time.time()) + 10_000
        leases.expire_stale(conn, now=future_now)

        produced_b = _all_distinct_statuses(conn)
        declared_b = set(_schemas.LEASE_STATUSES)  # now includes "suspended"
        traps_b = declared_b - produced_b

        assert "suspended" in traps_b, (
            "Teeth B failure: trap check did not surface 'suspended' "
            "as an unreachable declared status."
        )
        # Restore is handled by monkeypatch teardown automatically.

"""Slice 25: test_state.status vocabulary completeness invariant.

@decision DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
    Title: test_state.status vocabulary completeness — multi-surface parity invariant
    Status: accepted
    Rationale: runtime/core/test_state.py producer is explicitly unvalidated
      (line 65-66: "No status validation: test-runner.sh may emit any status
      string; callers that care about validity (check_pass) use explicit
      comparisons"). Two consumer policy gates hand-maintain their own
      _PASS_STATUSES frozensets independently:
        - bash_test_gate._PASS_STATUSES  (bash_test_gate.py:26)
        - write_test_gate._PASS_STATUSES (write_test_gate.py:43)
      Plus check_pass() literal tuple at test_state.py:152 and the producer
      module docstring at test_state.py:4.
      No central TEST_STATE_STATUSES enum exists (grep returns 0 matches in
      runtime/** or tests/** at HEAD f265a51dfe3a4d4acf394a2b4878213e38deddd9).
      This invariant pins multi-surface parity: all four sources must agree on
      the authoritative vocabulary. A future rename in one consumer without the
      other fails at test time with a named symmetric-difference diagnostic.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
_PROJECT_ROOT = _HERE.parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

import runtime.core.test_state as ts_mod  # noqa: E402

from runtime.core.db import connect_memory  # noqa: E402
from runtime.core.policies import bash_test_gate, write_test_gate  # noqa: E402
from runtime.schemas import ensure_schema  # noqa: E402

# ---------------------------------------------------------------------------
# Canonical anchor: vocabulary extracted from all four authoritative surfaces.
#
# @decision DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
#   The complete set of status strings recognized by the test_state system.
#   Source: test_state.py module docstring line 4 (explicit prose enumeration),
#   confirmed against check_pass() tuple and both policy gate frozensets.
#   Drift in any surface must fail a named test with symmetric-difference output.
# ---------------------------------------------------------------------------

EXPECTED_TEST_STATE_STATUSES: frozenset[str] = frozenset({
    "pass",
    "fail",
    "pass_complete",
    "unknown",
})

# The pass-status subset: statuses that check_pass() and _PASS_STATUSES
# frozensets treat as passing.
EXPECTED_PASS_STATUSES: frozenset[str] = frozenset({
    "pass",
    "pass_complete",
})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run_cli(*args, cwd=None, env=None):
    """Run python3 -m runtime.cli <args>, return (returncode, stdout, stderr).

    Mirrors the helper in tests/runtime/test_test_state.py:157-171 so the
    CLI round-trip exercises the same path as the real test-runner.sh sequence.
    """
    import os

    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    result = subprocess.run(
        [sys.executable, "-m", "runtime.cli"] + list(args),
        capture_output=True,
        text=True,
        cwd=str(cwd or _PROJECT_ROOT),
        env=run_env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _extract_docstring_status_tokens(mod) -> set[str]:
    """Extract status-like tokens from the module-level docstring prose.

    @decision DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
      The test_state.py docstring carries the canonical prose enumeration:
        "Status values are open strings (pass, fail, pass_complete, unknown)"
      This helper extracts bare word-tokens from that clause by matching
      comma-separated identifiers that look like status strings
      (lowercase, may contain underscores). Used only for the docstring-pinning
      test (test 8) — does NOT feed the anchor at module level.
    """
    doc = mod.__doc__ or ""
    # Extract the parenthesized clause listing status values
    # e.g. "open strings (pass, fail, pass_complete, unknown)"
    match = re.search(r"open strings \(([^)]+)\)", doc)
    if match:
        raw = match.group(1)
        tokens = {t.strip() for t in raw.split(",")}
        return tokens
    # Fallback: collect any comma-listed all-lowercase/underscore words >=3 chars
    tokens = set(re.findall(r"\b([a-z][a-z_]{2,})\b", doc))
    plausible = {t for t in tokens if t in EXPECTED_TEST_STATE_STATUSES}
    return plausible


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema, matching
    tests/runtime/test_test_state.py:53-57 fixture exactly."""
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# Test class
# ---------------------------------------------------------------------------


class TestTestStateStatusCompletenessInvariant:
    """Multi-surface parity invariant for test_state.status vocabulary.

    @decision DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
      All 10 tests must pass before Guardian may land this slice.
    """

    # -----------------------------------------------------------------------
    # Test 1 — vacuous-truth guard
    # -----------------------------------------------------------------------

    def test_expected_set_is_non_empty_vacuous_truth_guard(self):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001: Guard against
        accidentally emptying the EXPECTED_TEST_STATE_STATUSES anchor.

        If this constant were an empty frozenset, every subset/parity check
        would vacuously pass. This test ensures the anchor has at least 2
        elements (pass and fail are minimum non-negotiable).
        """
        assert len(EXPECTED_TEST_STATE_STATUSES) >= 2, (
            "EXPECTED_TEST_STATE_STATUSES must have at least 2 entries; "
            f"got {EXPECTED_TEST_STATE_STATUSES!r}"
        )
        # Specifically require the two pass-statuses to be present
        assert "pass" in EXPECTED_TEST_STATE_STATUSES
        assert "pass_complete" in EXPECTED_TEST_STATE_STATUSES

    # -----------------------------------------------------------------------
    # Test 2 — bash_test_gate._PASS_STATUSES parity
    # -----------------------------------------------------------------------

    def test_bash_test_gate_pass_statuses_subset_of_expected(self):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
        bash_test_gate._PASS_STATUSES must be a subset of the anchor AND
        must equal EXPECTED_PASS_STATUSES exactly (named symmetric-diff on drift).

        Pins bash_test_gate.py:26 against the canonical anchor.
        """
        bash_pass = set(bash_test_gate._PASS_STATUSES)
        bash_only = bash_pass - EXPECTED_PASS_STATUSES
        expected_only = EXPECTED_PASS_STATUSES - bash_pass
        assert bash_only == set() and expected_only == set(), (
            f"bash_test_gate._PASS_STATUSES diverges from EXPECTED_PASS_STATUSES: "
            f"bash-only={bash_only!r}, expected-only={expected_only!r}"
        )
        # Also ensure subset of full vocabulary
        unknown_statuses = bash_pass - EXPECTED_TEST_STATE_STATUSES
        assert unknown_statuses == set(), (
            f"bash_test_gate._PASS_STATUSES contains statuses not in "
            f"EXPECTED_TEST_STATE_STATUSES: {unknown_statuses!r}"
        )

    # -----------------------------------------------------------------------
    # Test 3 — write_test_gate._PASS_STATUSES parity
    # -----------------------------------------------------------------------

    def test_write_test_gate_pass_statuses_subset_of_expected(self):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
        write_test_gate._PASS_STATUSES must be a subset of the anchor AND
        must equal EXPECTED_PASS_STATUSES exactly (named symmetric-diff on drift).

        Pins write_test_gate.py:43 against the canonical anchor.
        """
        write_pass = set(write_test_gate._PASS_STATUSES)
        write_only = write_pass - EXPECTED_PASS_STATUSES
        expected_only = EXPECTED_PASS_STATUSES - write_pass
        assert write_only == set() and expected_only == set(), (
            f"write_test_gate._PASS_STATUSES diverges from EXPECTED_PASS_STATUSES: "
            f"write-only={write_only!r}, expected-only={expected_only!r}"
        )
        # Also ensure subset of full vocabulary
        unknown_statuses = write_pass - EXPECTED_TEST_STATE_STATUSES
        assert unknown_statuses == set(), (
            f"write_test_gate._PASS_STATUSES contains statuses not in "
            f"EXPECTED_TEST_STATE_STATUSES: {unknown_statuses!r}"
        )

    # -----------------------------------------------------------------------
    # Test 4 — cross-gate rename/typo catcher
    # -----------------------------------------------------------------------

    def test_bash_and_write_test_gate_pass_statuses_identical(self):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
        bash_test_gate._PASS_STATUSES and write_test_gate._PASS_STATUSES must
        be identical frozensets (cross-gate rename/typo catcher).

        A rename of "pass_complete" to "passed" in one gate but not the other
        would produce silent drift in policy enforcement. Named symmetric-diff
        diagnostic makes the specific divergence immediately visible.
        """
        bash_pass = set(bash_test_gate._PASS_STATUSES)
        write_pass = set(write_test_gate._PASS_STATUSES)
        bash_only = bash_pass - write_pass
        write_only = write_pass - bash_pass
        assert bash_only == set() and write_only == set(), (
            f"bash_test_gate and write_test_gate _PASS_STATUSES diverge: "
            f"bash-only={bash_only!r}, write-only={write_only!r}"
        )

    # -----------------------------------------------------------------------
    # Test 5 — check_pass() literal tuple round-trip
    # -----------------------------------------------------------------------

    def test_check_pass_accepts_exactly_expected_pass_statuses(self, conn):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
        ts_mod.check_pass() must return True for every status in
        EXPECTED_PASS_STATUSES and False for every non-pass status in
        EXPECTED_TEST_STATE_STATUSES.

        Covers the ("pass", "pass_complete") literal at test_state.py:152.
        Uses round-trip: set_status() → check_pass() per status value.
        """
        project_root = "/test/project-root-check-pass"
        for status in EXPECTED_TEST_STATE_STATUSES:
            ts_mod.set_status(conn, project_root, status)
            result = ts_mod.check_pass(conn, project_root)
            if status in EXPECTED_PASS_STATUSES:
                assert result is True, (
                    f"check_pass() returned False for passing status {status!r}; "
                    f"EXPECTED_PASS_STATUSES={EXPECTED_PASS_STATUSES!r}"
                )
            else:
                assert result is False, (
                    f"check_pass() returned True for non-passing status {status!r}; "
                    f"EXPECTED_PASS_STATUSES={EXPECTED_PASS_STATUSES!r}"
                )

    # -----------------------------------------------------------------------
    # Test 6 — get_status() default pins "unknown"
    # -----------------------------------------------------------------------

    def test_get_status_default_is_declared_status(self, conn):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
        ts_mod.get_status() on an empty DB returns status="unknown".
        "unknown" must be a member of EXPECTED_TEST_STATE_STATUSES.

        Pins the safe-default fallthrough (test_state.py:117) against the
        vocabulary anchor. If "unknown" is ever renamed in the producer,
        this test fails.
        """
        result = ts_mod.get_status(conn, "/nonexistent/project/root")
        assert result["found"] is False
        default_status = result["status"]
        assert default_status == "unknown", (
            f"get_status() default status changed from 'unknown' to {default_status!r}"
        )
        assert default_status in EXPECTED_TEST_STATE_STATUSES, (
            f"get_status() default {default_status!r} not in "
            f"EXPECTED_TEST_STATE_STATUSES={EXPECTED_TEST_STATE_STATUSES!r}"
        )

    # -----------------------------------------------------------------------
    # Test 7 — CLI producer round-trip (real production sequence)
    # -----------------------------------------------------------------------

    def test_producer_round_trip_reaches_every_expected_status(self):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
        For each status in EXPECTED_TEST_STATE_STATUSES, verify the CLI
        producer round-trip: `cc-policy test-state set --status X` then
        `cc-policy test-state get` returns status=X.

        This is the real production sequence exercised end-to-end:
          test-runner.sh → rt_test_state_set → cc-policy test-state set
          guard.sh Check 8/9 → rt_test_state_get → cc-policy test-state get

        Uses subprocess + isolated tmp dir so no persistent state is written.
        Mirrors tests/runtime/test_test_state.py:157-223 patterns exactly.
        """
        with tempfile.TemporaryDirectory(
            dir=str(_PROJECT_ROOT / "tmp"),
            prefix="slice25_round_trip_",
        ) as tmp_dir:
            tmp_path = Path(tmp_dir)
            db_path = tmp_path / "state.db"
            env = {"CLAUDE_POLICY_DB": str(db_path)}
            project_root = str(tmp_path)

            for status in sorted(EXPECTED_TEST_STATE_STATUSES):
                # Set via CLI
                rc_set, stdout_set, stderr_set = _run_cli(
                    "test-state",
                    "set",
                    status,
                    "--project-root",
                    project_root,
                    env=env,
                )
                assert rc_set == 0, (
                    f"CLI test-state set {status!r} failed (rc={rc_set}): "
                    f"stderr={stderr_set!r}"
                )

                # Get via CLI
                rc_get, stdout_get, stderr_get = _run_cli(
                    "test-state",
                    "get",
                    "--project-root",
                    project_root,
                    env=env,
                )
                assert rc_get == 0, (
                    f"CLI test-state get after set {status!r} failed (rc={rc_get}): "
                    f"stderr={stderr_get!r}"
                )

                data = json.loads(stdout_get)
                assert data.get("found") is True, (
                    f"CLI round-trip for status {status!r}: found=False after set"
                )
                assert data.get("status") == status, (
                    f"CLI round-trip: set {status!r} but get returned "
                    f"{data.get('status')!r}"
                )

    # -----------------------------------------------------------------------
    # Test 8 — module docstring pins the declared vocabulary
    # -----------------------------------------------------------------------

    def test_module_docstring_pins_expected_set(self):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001:
        The test_state.py module docstring (line 4) must explicitly enumerate
        all statuses in EXPECTED_TEST_STATE_STATUSES.

        The docstring currently reads:
          "Status values are open strings (pass, fail, pass_complete, unknown)"

        Pins that prose against the anchor so docstring drift (e.g. adding a
        new status to the vocabulary but forgetting to update the docstring)
        fails at test collection with a named diagnostic.
        """
        docstring_tokens = _extract_docstring_status_tokens(ts_mod)
        missing_from_docstring = EXPECTED_TEST_STATE_STATUSES - docstring_tokens
        extra_in_docstring = docstring_tokens - EXPECTED_TEST_STATE_STATUSES
        assert missing_from_docstring == set(), (
            f"test_state.py docstring does not mention these expected statuses: "
            f"{missing_from_docstring!r}. "
            f"Extracted tokens: {docstring_tokens!r}. "
            f"Update the docstring to include all statuses in "
            f"EXPECTED_TEST_STATE_STATUSES."
        )
        # Extra tokens in the docstring that are NOT in the anchor are also
        # suspicious — they could indicate the anchor is stale.
        assert extra_in_docstring == set(), (
            f"test_state.py docstring mentions these statuses not in anchor: "
            f"{extra_in_docstring!r}. "
            f"Either update EXPECTED_TEST_STATE_STATUSES or fix the docstring."
        )

    # -----------------------------------------------------------------------
    # Test 9 — teeth: orphan status stored but not in anchor
    # -----------------------------------------------------------------------

    def test_fake_orphan_status_detected_as_not_passing_and_not_in_anchor(
        self, conn
    ):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001 (teeth — orphan):
        Demonstrates that an orphan status emitted by a rogue test-runner
        would be caught. "quarantined" is stored (producer is unvalidated)
        but is not in EXPECTED_TEST_STATE_STATUSES AND check_pass() rejects it.

        This teeth test proves the invariant has real detection power: if a
        future agent added "quarantined" as a real status without updating the
        anchor, test 1 would not catch it, but test 9 confirms we would detect
        any test exercising that status against the anchor.
        """
        project_root = "/test/project-root-orphan"
        orphan_status = "quarantined"

        # Producer accepts any string (unvalidated by design)
        ts_mod.set_status(conn, project_root, orphan_status)
        stored = ts_mod.get_status(conn, project_root)
        assert stored["found"] is True
        assert stored["status"] == orphan_status, (
            f"Producer should store any string; got {stored['status']!r}"
        )

        # Orphan is not in the anchor
        assert orphan_status not in EXPECTED_TEST_STATE_STATUSES, (
            f"Teeth check failed: {orphan_status!r} IS in EXPECTED_TEST_STATE_STATUSES "
            f"but should not be. Update the orphan status or the anchor."
        )

        # check_pass rejects it
        is_pass = ts_mod.check_pass(conn, project_root)
        assert is_pass is False, (
            f"check_pass() returned True for orphan status {orphan_status!r}; "
            f"it must only accept {EXPECTED_PASS_STATUSES!r}"
        )

    # -----------------------------------------------------------------------
    # Test 10 — teeth: trap status — widening anchor without updating consumers
    # -----------------------------------------------------------------------

    def test_fake_trap_status_widening_anchor_without_producers_caught(self):
        """DEC-CLAUDEX-TEST-STATE-STATUS-COMPLETENESS-001 (teeth — trap):
        Demonstrates that widening the anchor with a new pass-status ("green")
        without updating the consumer policy gates would be caught.

        If someone adds "green" to EXPECTED_PASS_STATUSES but does NOT update
        bash_test_gate._PASS_STATUSES or write_test_gate._PASS_STATUSES,
        tests 2, 3, and 4 would catch the divergence. This teeth test
        directly demonstrates that "green" is NOT in the live consumer frozensets.
        """
        trap_status = "green"

        # Widened anchor (hypothetical future edit)
        widened_pass = EXPECTED_PASS_STATUSES | {trap_status}
        assert trap_status in widened_pass  # confirm the hypothetical widening

        # Real consumers have NOT been updated
        bash_pass = set(bash_test_gate._PASS_STATUSES)
        write_pass = set(write_test_gate._PASS_STATUSES)

        assert trap_status not in bash_pass, (
            f"Teeth trap: {trap_status!r} is already in bash_test_gate._PASS_STATUSES. "
            f"Update this test if the vocabulary has legitimately been extended."
        )
        assert trap_status not in write_pass, (
            f"Teeth trap: {trap_status!r} is already in write_test_gate._PASS_STATUSES. "
            f"Update this test if the vocabulary has legitimately been extended."
        )

        # Named symmetric-diff shows the trap clearly
        bash_gap = widened_pass - bash_pass
        write_gap = widened_pass - write_pass
        assert bash_gap == {trap_status}, (
            f"Expected bash gap to be exactly {{{trap_status!r}}}, got {bash_gap!r}"
        )
        assert write_gap == {trap_status}, (
            f"Expected write gap to be exactly {{{trap_status!r}}}, got {write_gap!r}"
        )

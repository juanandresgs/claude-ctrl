"""Invariant tests for seat-role sentinel authority.

DEC-CLAUDEX-SEAT-ROLE-SENTINEL-AUTH-001

T1 — Sentinel-in-vocabulary invariant (6 cases):
    Four named sentinel constants (SEAT_ROLE_WORKER, SEAT_ROLE_SUPERVISOR,
    SEAT_ROLE_REVIEWER, SEAT_ROLE_OBSERVER) must be importable from
    runtime.schemas, each must be a non-empty str whose value exactly matches
    the corresponding SEAT_ROLES member, and together they must cover SEAT_ROLES
    exhaustively (symmetric-diff anchor pin).

T2 — Narrow AST ratchet on seat-write call sites (3 cases):
    Walks every runtime/core/*.py file and asserts that no seat-write call site
    (seats.create invocation or direct INSERT INTO seats SQL literal) contains a
    bare string literal for the role= keyword argument.

    Scanner scope (narrow by design per supervisor 1776750110550-0096-bey6qx):
    - ONLY ast.Call nodes whose callee is seats.create (via ast.Attribute with
      value.id == 'seats' and attr == 'create') or a bare create() imported from
      runtime.core.seats via 'from runtime.core.seats import create'.
    - Non-seat role= literals (role='planner' at dispatch_engine.py, role='claude'
      at lane_topology.py, role='reviewer' at reviewer_convergence.py, etc.) are
      stage/live-role or lane-engine authorities — NOT governed by SEAT_ROLES —
      and are explicitly out of scanner scope.
    - SQL INSERT INTO seats string constants are catalogued for awareness but not
      parsed for role literals (just counted as sql_seat_writes_count).

    A positive-control test (T2a) confirms the scanner correctly detects a
    synthetic seats.create(..., role='worker') bare literal, proving it would
    flag a future regression in real code.
"""

from __future__ import annotations

import ast
import pathlib
from typing import NamedTuple

import pytest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
_RUNTIME_CORE = _REPO_ROOT / "runtime" / "core"


# ---------------------------------------------------------------------------
# T1 — sentinel-in-vocabulary invariant
# ---------------------------------------------------------------------------


class TestSeatRoleSentinelInVocabulary:
    """T1: Four SEAT_ROLE_* sentinel constants exist, are typed correctly, and
    together cover SEAT_ROLES exhaustively.
    """

    def test_T1a_sentinel_worker_value(self) -> None:
        """SEAT_ROLE_WORKER must equal the exact string 'worker'."""
        from runtime.schemas import SEAT_ROLE_WORKER  # noqa: PLC0415

        assert SEAT_ROLE_WORKER == "worker"

    def test_T1b_sentinel_supervisor_value(self) -> None:
        """SEAT_ROLE_SUPERVISOR must equal the exact string 'supervisor'."""
        from runtime.schemas import SEAT_ROLE_SUPERVISOR  # noqa: PLC0415

        assert SEAT_ROLE_SUPERVISOR == "supervisor"

    def test_T1c_sentinel_reviewer_value(self) -> None:
        """SEAT_ROLE_REVIEWER must equal the exact string 'reviewer'."""
        from runtime.schemas import SEAT_ROLE_REVIEWER  # noqa: PLC0415

        assert SEAT_ROLE_REVIEWER == "reviewer"

    def test_T1d_sentinel_observer_value(self) -> None:
        """SEAT_ROLE_OBSERVER must equal the exact string 'observer'."""
        from runtime.schemas import SEAT_ROLE_OBSERVER  # noqa: PLC0415

        assert SEAT_ROLE_OBSERVER == "observer"

    def test_T1e_sentinels_are_str_nonempty_members_of_vocab(self) -> None:
        """Each sentinel is a str, non-empty, and a member of SEAT_ROLES."""
        from runtime.schemas import (  # noqa: PLC0415
            SEAT_ROLE_OBSERVER,
            SEAT_ROLE_REVIEWER,
            SEAT_ROLE_SUPERVISOR,
            SEAT_ROLE_WORKER,
            SEAT_ROLES,
        )

        sentinels = [
            SEAT_ROLE_WORKER,
            SEAT_ROLE_SUPERVISOR,
            SEAT_ROLE_REVIEWER,
            SEAT_ROLE_OBSERVER,
        ]
        for s in sentinels:
            assert isinstance(s, str), f"Sentinel {s!r} is not a str"
            assert len(s) > 0, f"Sentinel {s!r} is empty"
            assert s in SEAT_ROLES, (
                f"Sentinel {s!r} is not a member of SEAT_ROLES {SEAT_ROLES!r}"
            )

    def test_T1f_sentinels_cover_SEAT_ROLES_exhaustively(self) -> None:
        """Symmetric-diff anchor: the 4 sentinels == SEAT_ROLES exactly.

        If SEAT_ROLES gains a 5th member without a corresponding sentinel, this
        test fails loudly — forcing a deliberate slice to update the anchor
        together with the vocabulary change.
        """
        from runtime.schemas import (  # noqa: PLC0415
            SEAT_ROLE_OBSERVER,
            SEAT_ROLE_REVIEWER,
            SEAT_ROLE_SUPERVISOR,
            SEAT_ROLE_WORKER,
            SEAT_ROLES,
        )

        sentinel_set = {
            SEAT_ROLE_WORKER,
            SEAT_ROLE_SUPERVISOR,
            SEAT_ROLE_REVIEWER,
            SEAT_ROLE_OBSERVER,
        }
        _ANCHOR: frozenset[str] = frozenset({"worker", "supervisor", "reviewer", "observer"})

        # Sentinels cover SEAT_ROLES exhaustively.
        assert sentinel_set == SEAT_ROLES, (
            f"Sentinel set {sentinel_set!r} does not match SEAT_ROLES {SEAT_ROLES!r}. "
            f"Symmetric difference: {sentinel_set.symmetric_difference(SEAT_ROLES)!r}"
        )

        # SEAT_ROLES matches the frozen anchor (catches vocabulary drift).
        diff = SEAT_ROLES.symmetric_difference(_ANCHOR)
        assert diff == frozenset(), (
            f"SEAT_ROLES has drifted from the pinned anchor. "
            f"Symmetric difference: {diff!r}. "
            f"Update this anchor and the 4 SEAT_ROLE_* sentinels together in a "
            f"new slice if the vocabulary changed intentionally."
        )


# ---------------------------------------------------------------------------
# T2 — Narrow AST ratchet on seat-write call sites only
# ---------------------------------------------------------------------------


class _SeatWriteViolation(NamedTuple):
    path: str
    line: int
    literal: str  # the offending role string value


def _has_seats_create_import(tree: ast.Module) -> bool:
    """Return True if the module has 'from runtime.core.seats import create'
    (possibly with alias 'create'), indicating bare 'create(...)' calls are
    seats.create calls.
    """
    for node in ast.walk(tree):
        if not isinstance(node, ast.ImportFrom):
            continue
        if node.module != "runtime.core.seats":
            continue
        for alias in node.names:
            if alias.name == "create" and (alias.asname is None or alias.asname == "create"):
                return True
    return False


def scan_seat_write_role_literals(
    source: str,
    path: pathlib.Path,
) -> tuple[list[_SeatWriteViolation], int, int]:
    """Parse *source* and return seat-write role-literal violations.

    Returns:
        (violations, scanned_files, sql_seat_writes_count)

    The caller passes a single file; scanned_files is always 1 for a single
    call. Aggregate across callers for the full count.

    Scanner scope (narrow — per DEC-CLAUDEX-SEAT-ROLE-SENTINEL-AUTH-001 rev 2):
    - Identifies ast.Call nodes whose callee is EITHER:
        (a) ast.Attribute(value=ast.Name(id='seats'), attr='create')
            i.e. seats.create(...)
        (b) ast.Name(id='create') when the module has a top-level
            'from runtime.core.seats import create' ImportFrom.
    - For each matching Call, inspects keywords; any keyword(arg='role',
      value=ast.Constant(value=<str>)) is a violation.
    - Also scans top-level ast.Constant string values for the literal
      'INSERT INTO seats' and counts them as sql_seat_writes_count (catalogued
      for awareness; not parsed for role literals).
    - Non-seat role= literals (role='planner', role='claude', etc.) at other
      call sites are NOT in scope and do not fire.
    """
    violations: list[_SeatWriteViolation] = []
    sql_seat_writes_count = 0

    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError:
        raise

    has_create_import = _has_seats_create_import(tree)

    for node in ast.walk(tree):
        # Catalogue SQL seat-write sites (string constants containing INSERT INTO seats).
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if "INSERT INTO seats" in node.value:
                sql_seat_writes_count += 1
            continue

        # Scan seat-write call sites.
        if not isinstance(node, ast.Call):
            continue

        callee = node.func
        is_seat_create_call = False

        # Case (a): seats.create(...)
        if (
            isinstance(callee, ast.Attribute)
            and callee.attr == "create"
            and isinstance(callee.value, ast.Name)
            and callee.value.id == "seats"
        ):
            is_seat_create_call = True

        # Case (b): bare create(...) when imported from runtime.core.seats
        elif (
            isinstance(callee, ast.Name)
            and callee.id == "create"
            and has_create_import
        ):
            is_seat_create_call = True

        if not is_seat_create_call:
            continue

        # Inspect keywords for role=<bare string literal>.
        for kw in node.keywords:
            if kw.arg != "role":
                continue
            if isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str):
                violations.append(
                    _SeatWriteViolation(
                        path=str(path),
                        line=kw.value.lineno,
                        literal=kw.value.value,
                    )
                )

    return (violations, 1, sql_seat_writes_count)


class TestSeatWriteRoleAST:
    """T2: Narrow AST ratchet — seat-write call sites must not use bare role
    string literals.
    """

    def test_T2a_positive_control_detects_bare_literal(self) -> None:
        """Scanner MUST detect a synthetic seats.create bare role literal.

        This positive-control test proves the scanner is wired correctly and
        would flag a future regression. The synthetic fixture contains exactly
        one seats.create(..., role='worker') call with a bare string literal.
        """
        synthetic_source = """\
from runtime.core.seats import create

def make():
    create(conn, "sid", "sess", role="worker")
"""
        violations, _, _ = scan_seat_write_role_literals(
            synthetic_source,
            pathlib.Path("<synthetic_test_fixture>"),
        )

        assert len(violations) == 1, (
            f"Expected exactly 1 violation in synthetic fixture, "
            f"got {len(violations)}: {violations!r}"
        )
        assert violations[0].literal == "worker", (
            f"Expected violation literal 'worker', got {violations[0].literal!r}"
        )
        assert violations[0].line == 4, (
            f"Expected violation at line 4, got {violations[0].line}"
        )

    def test_T2b_runtime_core_scan_clean(self) -> None:
        """Walk all runtime/core/*.py files; assert zero seat-write bare role
        violations; assert scanned_files_count >= 30.

        This is the defensive pin: at HEAD 18300636, no runtime/core caller
        passes a bare string literal through seats.create. The ratchet catches
        future regressions.
        """
        py_files = sorted(_RUNTIME_CORE.glob("*.py"))
        assert py_files, f"No .py files found under {_RUNTIME_CORE}"

        all_violations: list[_SeatWriteViolation] = []
        skipped_files: list[str] = []
        scanned_files: list[str] = []
        total_sql_seat_writes = 0

        for fpath in py_files:
            try:
                source = fpath.read_text(encoding="utf-8")
            except OSError as exc:
                print(f"[T2b] SKIP (unreadable): {fpath.name} — {exc}")
                skipped_files.append(fpath.name)
                continue

            try:
                viols, _, sql_count = scan_seat_write_role_literals(source, fpath)
            except SyntaxError as exc:
                print(f"[T2b] SKIP (syntax error): {fpath.name} — {exc}")
                skipped_files.append(fpath.name)
                continue

            if viols:
                for v in viols:
                    print(
                        f"[T2b] VIOLATION: {v.path}:{v.line} role={v.literal!r}"
                    )
            all_violations.extend(viols)
            scanned_files.append(fpath.name)
            total_sql_seat_writes += sql_count

        print(
            f"\n[T2b] Scanned {len(scanned_files)} files, "
            f"skipped {len(skipped_files)}, "
            f"violations={len(all_violations)}, "
            f"sql_seat_writes_count={total_sql_seat_writes}."
        )
        if scanned_files:
            print(f"[T2b] Scanned: {scanned_files}")
        if skipped_files:
            print(f"[T2b] Skipped: {skipped_files}")

        # Guard: scanner must not silently skip all files.
        assert len(scanned_files) >= 30, (
            f"Expected >= 30 scanned files in runtime/core/, got {len(scanned_files)}. "
            f"The glob may be broken."
        )

        # Core ratchet assertion.
        assert all_violations == [], (
            f"Found {len(all_violations)} bare role literal(s) in seat-write "
            f"call sites across runtime/core/*.py. Each must be replaced with "
            f"a SEAT_ROLE_* sentinel from runtime.schemas:\n"
            + "\n".join(
                f"  {v.path}:{v.line}  role={v.literal!r}"
                for v in all_violations
            )
        )

    def test_T2c_scanner_ignores_non_seat_role_literals(self) -> None:
        """Scanner must NOT flag role='planner' at a non-seats-create call site.

        This proves the narrow scope: role= literals at other call sites
        (dispatch_engine, reviewer_convergence, lane_topology, etc.) are
        stage/live-role or lane-engine authorities and are not in scanner scope.
        """
        synthetic_source = """\
import dispatch_engine

def route():
    dispatch_engine._route_from_completion(conn, role="planner")
"""
        violations, _, _ = scan_seat_write_role_literals(
            synthetic_source,
            pathlib.Path("<synthetic_non_seat_fixture>"),
        )

        assert violations == [], (
            f"Scanner incorrectly flagged a non-seat-write call site. "
            f"Violations: {violations!r}. "
            f"The scanner must only flag seats.create(..., role=<literal>) "
            f"and bare create(..., role=<literal>) from runtime.core.seats — "
            f"not role= literals at other call sites."
        )

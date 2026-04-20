"""Invariant tests for finding-severity sentinel authority.

DEC-CLAUDEX-FINDING-SEVERITY-SENTINEL-AUTH-001

T1 — Sentinel-in-vocabulary invariant:
    ``runtime.schemas.FINDING_SEVERITY_BLOCKING`` must be importable, must be a
    non-empty ``str``, must equal the literal ``"blocking"``, and must be a
    member of ``FINDING_SEVERITIES``.

T2 — AST bare-literal scanner (ratchet):
    Walks every ``runtime/core/*.py`` file and asserts that no
    ``ast.Dict`` contains a ``"severity"`` key paired with a bare severity
    string literal *drawn from ``FINDING_SEVERITIES``*, and no call site uses
    ``severity=<bare_literal_in_FINDING_SEVERITIES>`` as a keyword argument.
    Exceptions:
    - ``reviewer_findings.py`` — write-path validator that accepts severity as a
      *function parameter* and validates it against the vocabulary; it does not
      construct filter dicts with bare literals.
    - Files excluded because they cannot be parsed (logged, not failed).
    The scanner collects ALL violations before asserting, so the failure message
    is complete rather than truncated at the first hit.

Design note: the AST scanner correctly ignores docstrings, comments, type
annotations (``typing.Literal[...]``), and string concatenations because it only
inspects ``ast.Constant`` *value* nodes inside ``ast.Dict`` value positions or
``keyword.value`` positions — not arbitrary string tokens.
"""

from __future__ import annotations

import ast
import pathlib
import sys
from typing import NamedTuple

import pytest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
_RUNTIME_CORE = _REPO_ROOT / "runtime" / "core"

# Files excluded from the T2 scanner because they are not filter-construction
# consumers — they own the write-path vocabulary definitions or the validation
# logic that *receives* severity as an argument.
_T2_EXCLUDED_FILENAMES: frozenset[str] = frozenset(
    {
        "reviewer_findings.py",  # write-path validator; severity is a kwarg
                                 # passed in by callers, not a filter literal
    }
)


# ---------------------------------------------------------------------------
# T1 — sentinel-in-vocabulary invariant
# ---------------------------------------------------------------------------


class TestFindingSeveritySentinelInVocabulary:
    """T1: FINDING_SEVERITY_BLOCKING exists, is typed correctly, and is in
    FINDING_SEVERITIES.
    """

    def test_sentinel_importable(self) -> None:
        from runtime.schemas import FINDING_SEVERITY_BLOCKING  # noqa: PLC0415

        assert FINDING_SEVERITY_BLOCKING is not None

    def test_sentinel_is_str(self) -> None:
        from runtime.schemas import FINDING_SEVERITY_BLOCKING  # noqa: PLC0415

        assert isinstance(FINDING_SEVERITY_BLOCKING, str)

    def test_sentinel_is_nonempty(self) -> None:
        from runtime.schemas import FINDING_SEVERITY_BLOCKING  # noqa: PLC0415

        assert len(FINDING_SEVERITY_BLOCKING) > 0

    def test_sentinel_value_pin(self) -> None:
        """Value is pinned to the exact string 'blocking'."""
        from runtime.schemas import FINDING_SEVERITY_BLOCKING  # noqa: PLC0415

        assert FINDING_SEVERITY_BLOCKING == "blocking"

    def test_sentinel_in_vocabulary(self) -> None:
        """The sentinel is a member of FINDING_SEVERITIES."""
        from runtime.schemas import (  # noqa: PLC0415
            FINDING_SEVERITIES,
            FINDING_SEVERITY_BLOCKING,
        )

        assert FINDING_SEVERITY_BLOCKING in FINDING_SEVERITIES

    def test_vocabulary_symmetric_diff_anchor(self) -> None:
        """Pin the full vocabulary against a literal anchor.

        If FINDING_SEVERITIES gains or loses a member, this test fails —
        forcing a deliberate slice to update the anchor together with the
        constant.  The anchor is: frozenset({"blocking", "concern", "note"}).
        """
        from runtime.schemas import FINDING_SEVERITIES  # noqa: PLC0415

        _ANCHOR: frozenset[str] = frozenset({"blocking", "concern", "note"})
        diff = FINDING_SEVERITIES.symmetric_difference(_ANCHOR)
        assert diff == frozenset(), (
            f"FINDING_SEVERITIES has drifted from the pinned anchor.  "
            f"Symmetric difference: {diff!r}.  "
            f"Update this anchor and FINDING_SEVERITY_BLOCKING together in a "
            f"new slice if the vocabulary changed intentionally."
        )


# ---------------------------------------------------------------------------
# T2 — AST bare-literal scanner (ratchet)
# ---------------------------------------------------------------------------


class _Violation(NamedTuple):
    path: str
    line: int
    kind: str          # "dict_value" | "kwarg"
    key_or_kwarg: str  # the "severity" key/kwarg name
    value: str         # the offending literal value


def _collect_severity_bare_literals(
    source: str,
    path: pathlib.Path,
    vocabulary: frozenset[str],
) -> list[_Violation]:
    """Parse *source* and return all bare-literal severity violations.

    A violation is any ``ast.Dict`` whose keys include the string constant
    ``"severity"`` paired with a value that is an ``ast.Constant`` whose
    string value is in *vocabulary*, OR any call-site keyword argument named
    ``"severity"`` whose value is an ``ast.Constant`` in *vocabulary*.

    AST ``Name`` nodes (i.e. identifiers resolving to a bound constant) are
    allowed and generate no violation.
    """
    violations: list[_Violation] = []
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError:
        # Callers log and skip unparseable files.
        raise

    for node in ast.walk(tree):
        # Case 1: ast.Dict with a "severity" string-keyed entry.
        if isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if not isinstance(key, ast.Constant):
                    continue
                if key.value != "severity":
                    continue
                # Key is the string "severity".  Check the value.
                if isinstance(value, ast.Constant) and isinstance(
                    value.value, str
                ) and value.value in vocabulary:
                    violations.append(
                        _Violation(
                            path=str(path),
                            line=value.lineno,
                            kind="dict_value",
                            key_or_kwarg="severity",
                            value=value.value,
                        )
                    )

        # Case 2: Call-site keyword argument named "severity".
        if isinstance(node, ast.Call):
            for kw in node.keywords:
                if kw.arg != "severity":
                    continue
                if isinstance(kw.value, ast.Constant) and isinstance(
                    kw.value.value, str
                ) and kw.value.value in vocabulary:
                    violations.append(
                        _Violation(
                            path=str(path),
                            line=kw.value.lineno,
                            kind="kwarg",
                            key_or_kwarg="severity",
                            value=kw.value.value,
                        )
                    )

    return violations


class TestFindingSeverityBareлитerалScannerRatchet:
    """T2: No runtime/core/*.py consumer uses a bare severity string literal
    in a 'severity'-keyed dict or severity= keyword argument.
    """

    def test_no_bare_severity_literals_in_runtime_core(self) -> None:
        """AST scan of all runtime/core/*.py files (minus exclusions).

        - Skips files that cannot be parsed (logs them to stdout).
        - Collects ALL violations before asserting.
        - Reports every violating (path, line, kind, value) tuple in the
          assertion message.
        """
        from runtime.schemas import FINDING_SEVERITIES  # noqa: PLC0415

        py_files = sorted(_RUNTIME_CORE.glob("*.py"))
        assert py_files, f"No .py files found under {_RUNTIME_CORE}"

        all_violations: list[_Violation] = []
        skipped: list[str] = []
        scanned: list[str] = []

        for fpath in py_files:
            fname = fpath.name
            if fname in _T2_EXCLUDED_FILENAMES:
                print(
                    f"[T2] EXCLUDED (write-path/vocab owner): {fname}",
                    file=sys.stdout,
                )
                continue

            try:
                source = fpath.read_text(encoding="utf-8")
            except OSError as exc:
                print(f"[T2] SKIP (unreadable): {fname} — {exc}", file=sys.stdout)
                skipped.append(fname)
                continue

            try:
                viols = _collect_severity_bare_literals(source, fpath, FINDING_SEVERITIES)
            except SyntaxError as exc:
                print(f"[T2] SKIP (syntax error): {fname} — {exc}", file=sys.stdout)
                skipped.append(fname)
                continue

            for v in viols:
                print(
                    f"[T2] VIOLATION: {v.path}:{v.line} "
                    f"kind={v.kind} key={v.key_or_kwarg!r} value={v.value!r}",
                    file=sys.stdout,
                )
            all_violations.extend(viols)
            scanned.append(fname)

        # Emit a summary so the reviewer can confirm scanner breadth.
        print(
            f"\n[T2] Scanned {len(scanned)} files, "
            f"skipped {len(skipped)} files, "
            f"found {len(all_violations)} violation(s).",
            file=sys.stdout,
        )
        print(f"[T2] Scanned files: {scanned}", file=sys.stdout)
        if skipped:
            print(f"[T2] Skipped files: {skipped}", file=sys.stdout)

        assert all_violations == [], (
            f"Found {len(all_violations)} bare severity literal(s) in "
            f"runtime/core/ that must be replaced with FINDING_SEVERITY_BLOCKING "
            f"(or another named sentinel from runtime.schemas):\n"
            + "\n".join(
                f"  {v.path}:{v.line}  [{v.kind}] severity={v.value!r}"
                for v in all_violations
            )
        )

    def test_scanner_covers_minimum_file_count(self) -> None:
        """Prove the scanner is not vacuously empty — at least 30 files must
        exist in runtime/core/ to guard against a broken glob.
        """
        py_files = sorted(_RUNTIME_CORE.glob("*.py"))
        assert len(py_files) >= 30, (
            f"Expected ≥30 .py files in runtime/core/, found {len(py_files)}.  "
            f"The glob may be broken."
        )

    def test_reviewer_convergence_uses_sentinel(self) -> None:
        """Compound-interaction check: the production call site in
        reviewer_convergence.py resolves severity via FINDING_SEVERITY_BLOCKING
        (a Name node), not a bare Constant.

        This is the primary defect the slice repairs.  The AST visitor should
        find the 'severity' key in the finding_filters dict and confirm its
        value is a Name node (i.e. an identifier referencing the sentinel),
        not a Constant.
        """
        fpath = _RUNTIME_CORE / "reviewer_convergence.py"
        source = fpath.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(fpath))

        sentinel_used = False
        bare_literal_found = False

        from runtime.schemas import FINDING_SEVERITIES  # noqa: PLC0415

        for node in ast.walk(tree):
            if isinstance(node, ast.Dict):
                for key, value in zip(node.keys, node.values):
                    if not isinstance(key, ast.Constant):
                        continue
                    if key.value != "severity":
                        continue
                    # This is a severity-keyed dict entry in reviewer_convergence.
                    if isinstance(value, ast.Name):
                        # Good: referencing a named sentinel.
                        sentinel_used = True
                    elif isinstance(value, ast.Constant) and value.value in FINDING_SEVERITIES:
                        # Bad: bare literal drawn from the vocabulary.
                        bare_literal_found = True

        assert sentinel_used, (
            "reviewer_convergence.py does not use a named sentinel (ast.Name) for "
            "the 'severity' key in finding_filters.  The bare literal was not replaced."
        )
        assert not bare_literal_found, (
            "reviewer_convergence.py still contains a bare severity string literal in "
            "the finding_filters dict.  The fix was not applied."
        )

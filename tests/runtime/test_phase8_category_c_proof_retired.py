"""Invariant tests: Category C bundle 1 — proof_state retirement.

Mechanical pins for the post-Phase-8 Category C retirement of proof_state,
proof.py, and the cc-policy proof CLI surface.

@decision DEC-CATEGORY-C-PROOF-RETIRE-001
@title proof_state storage + proof.py module + proof CLI retired post-Phase-8
@status accepted
@rationale DEC-EVAL-001 established evaluation_state as the sole Guardian
  readiness authority; proof_state retained zero enforcement effect after
  TKT-024. Category C bundle 1 removes the now-dead storage layer, the
  module that owns it, the CLI surface that reads/writes it, and the
  observatory query that reports it. Retention of dead storage violated the
  "no parallel authorities as a transition aid" rule; this bundle closes
  that drift path.
"""

from __future__ import annotations

import importlib
import re
import sqlite3
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]


class TestProofModuleRetired:
    """The runtime.core.proof module must not be importable."""

    def test_proof_module_not_importable(self):
        """importlib.import_module('runtime.core.proof') must fail closed."""
        with pytest.raises(ModuleNotFoundError):
            importlib.import_module("runtime.core.proof")

    def test_proof_source_file_does_not_exist(self):
        """The source file runtime/core/proof.py must have been deleted."""
        proof_file = REPO_ROOT / "runtime" / "core" / "proof.py"
        assert not proof_file.exists(), (
            f"runtime/core/proof.py must be deleted; still present at {proof_file}"
        )


class TestProofStateSchemaRetired:
    """The proof_state DDL must be removed from runtime.schemas."""

    def test_schemas_module_has_no_proof_state_ddl_constant(self):
        """runtime.schemas must not define PROOF_STATE_DDL."""
        import runtime.schemas as schemas

        assert not hasattr(schemas, "PROOF_STATE_DDL"), (
            "runtime.schemas must not define PROOF_STATE_DDL after retirement"
        )

    def test_schemas_source_has_no_proof_state_create_table(self):
        """runtime/schemas.py source must not contain a CREATE TABLE for proof_state."""
        schemas_src = (REPO_ROOT / "runtime" / "schemas.py").read_text()
        # Allow historical references in comments; forbid the live DDL string.
        assert not re.search(
            r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+proof_state",
            schemas_src,
            flags=re.IGNORECASE,
        ), "CREATE TABLE proof_state must not appear in runtime/schemas.py"

    def test_ensure_schema_does_not_create_proof_state(self):
        """A fresh DB initialised via ensure_schema() must not have proof_state."""
        from runtime.schemas import ensure_schema

        with tempfile.NamedTemporaryFile(suffix=".db") as f:
            conn = sqlite3.connect(f.name)
            try:
                ensure_schema(conn)
                row = conn.execute(
                    "SELECT name FROM sqlite_master "
                    "WHERE type='table' AND name='proof_state'"
                ).fetchone()
            finally:
                conn.close()
        assert row is None, "ensure_schema() must not create proof_state table"


class TestProofCliSurfaceRetired:
    """The proof subcommand must be absent from this worktree's runtime CLI.

    Tests invoke ``python3 runtime/cli.py`` from REPO_ROOT directly rather
    than the global ``cc-policy`` wrapper, because the wrapper resolves to
    whichever repo hosts the binary on PATH — which may not be this
    worktree. The canonical worktree-scoped assertion is what the runtime
    CLI in this tree exposes.
    """

    def _run_cli(self, *args: str) -> subprocess.CompletedProcess:
        import sys as _sys

        return subprocess.run(
            [_sys.executable, str(REPO_ROOT / "runtime" / "cli.py"), *args],
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_cli_rejects_proof_domain(self):
        """`python runtime/cli.py proof --help` must exit non-zero with
        'invalid choice'."""
        result = self._run_cli("proof", "--help")
        assert result.returncode != 0, (
            f"runtime/cli.py proof --help must fail; got rc={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
        combined = (result.stderr or "") + (result.stdout or "")
        assert "invalid choice: 'proof'" in combined, (
            f"expected 'invalid choice: \\'proof\\'' in argparse error; got: {combined!r}"
        )

    def test_cli_top_level_help_omits_proof(self):
        """runtime/cli.py -h must not list 'proof' as a domain choice."""
        result = self._run_cli("-h")
        combined = (result.stdout or "") + (result.stderr or "")
        # The top-level domain list appears as "{schema,init,...}" — look for
        # a token-boundary match so 'proof' as a word does not appear.
        assert not re.search(r"[,{]proof[,}]", combined), (
            f"runtime/cli.py top-level help must not list 'proof' as a domain; "
            f"got: {combined!r}"
        )


class TestObservatoryDoesNotReadProofState:
    """sidecars/observatory/observe.py must not query proof_state."""

    def test_observe_source_has_no_proof_state_query(self):
        """observe.py must not contain any FROM proof_state SQL or attribute."""
        src = (REPO_ROOT / "sidecars" / "observatory" / "observe.py").read_text()
        assert "FROM proof_state" not in src, (
            "observe.py must not issue SELECT ... FROM proof_state"
        )
        assert "self.proof_states" not in src, (
            "observe.py must not reference self.proof_states after retirement"
        )
        assert "proof_count" not in src, (
            "observe.py report dict must not expose proof_count"
        )
        assert "stale_proofs" not in src, (
            "observe.py _compute_health must not emit stale_proofs issue"
        )


class TestNoLiveProofReferencesInRuntime:
    """No live import of runtime.core.proof may remain in production code."""

    def test_no_live_proof_imports_in_runtime_or_hooks_or_sidecars(self):
        """grep for live imports/uses of runtime.core.proof outside comments/tests."""
        patterns = (
            re.compile(r"^\s*import\s+runtime\.core\.proof\b", re.MULTILINE),
            re.compile(r"^\s*from\s+runtime\.core\.proof\s+import\b", re.MULTILINE),
        )
        offenders: list[str] = []
        for area in ("runtime", "hooks", "sidecars"):
            base = REPO_ROOT / area
            if not base.exists():
                continue
            for path in base.rglob("*"):
                if not path.is_file():
                    continue
                if path.suffix not in {".py", ".sh"}:
                    continue
                text = path.read_text(errors="ignore")
                for pat in patterns:
                    for m in pat.finditer(text):
                        offenders.append(f"{path.relative_to(REPO_ROOT)}: {m.group(0)!r}")
        assert not offenders, (
            "Live runtime.core.proof imports remain after retirement:\n  "
            + "\n  ".join(offenders)
        )

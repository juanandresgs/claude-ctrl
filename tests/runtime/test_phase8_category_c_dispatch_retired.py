"""Invariant tests: Category C bundle 2 — dispatch_queue / dispatch_cycles retirement.

Mechanical pins for the post-Phase-8 Category C retirement of the legacy
``runtime/core/dispatch.py`` module, the ``dispatch_queue`` + ``dispatch_cycles``
tables, and the legacy ``cc-policy dispatch {enqueue,next,start,complete,
cycle-start,cycle-current}`` CLI actions.

@decision DEC-CATEGORY-C-DISPATCH-RETIRE-001
@title dispatch_queue + dispatch_cycles + legacy dispatch CLI retired post-Phase-8
@status accepted
@rationale DEC-WS6-001 made routing authority flow through
  determine_next_role(latest_completion.role, verdict); dispatch_queue was
  no longer on the routing hot-path. dispatch_cycles was last used only
  for initiative-level tracking in the statusline snapshot. Category C
  bundle 2 removes the dead storage, the CLI surface that reads/writes
  it, and the observatory read. The legacy dispatch module is deleted.
  The dispatch_cycle_id / dispatch_initiative / pending_dispatches
  top-level keys remain in the snapshot / report dicts with deterministic
  None / 0 defaults for downstream-consumer schema stability.
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


class TestDispatchModuleRetired:
    """runtime.core.dispatch must be gone."""

    def test_dispatch_module_not_importable(self):
        with pytest.raises(ModuleNotFoundError):
            importlib.import_module("runtime.core.dispatch")

    def test_dispatch_source_file_does_not_exist(self):
        path = REPO_ROOT / "runtime" / "core" / "dispatch.py"
        assert not path.exists(), (
            f"runtime/core/dispatch.py must be deleted; still present at {path}"
        )


class TestDispatchSchemasRetired:
    """DDL constants and ALL_DDL entries for dispatch_queue / dispatch_cycles must be gone."""

    def test_schemas_module_has_no_dispatch_queue_ddl_constant(self):
        import runtime.schemas as schemas

        assert not hasattr(schemas, "DISPATCH_QUEUE_DDL"), (
            "runtime.schemas must not define DISPATCH_QUEUE_DDL after retirement"
        )

    def test_schemas_module_has_no_dispatch_cycles_ddl_constant(self):
        import runtime.schemas as schemas

        assert not hasattr(schemas, "DISPATCH_CYCLES_DDL"), (
            "runtime.schemas must not define DISPATCH_CYCLES_DDL after retirement"
        )

    def test_schemas_module_has_no_dispatch_queue_statuses_constant(self):
        import runtime.schemas as schemas

        assert not hasattr(schemas, "DISPATCH_QUEUE_STATUSES"), (
            "runtime.schemas must not define DISPATCH_QUEUE_STATUSES after retirement"
        )
        assert not hasattr(schemas, "DISPATCH_CYCLE_STATUSES"), (
            "runtime.schemas must not define DISPATCH_CYCLE_STATUSES after retirement"
        )

    def test_schemas_source_has_no_dispatch_queue_create_table(self):
        schemas_src = (REPO_ROOT / "runtime" / "schemas.py").read_text()
        assert not re.search(
            r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+dispatch_queue",
            schemas_src,
            flags=re.IGNORECASE,
        ), "CREATE TABLE dispatch_queue must not appear in runtime/schemas.py"

    def test_schemas_source_has_no_dispatch_cycles_create_table(self):
        schemas_src = (REPO_ROOT / "runtime" / "schemas.py").read_text()
        assert not re.search(
            r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+dispatch_cycles",
            schemas_src,
            flags=re.IGNORECASE,
        ), "CREATE TABLE dispatch_cycles must not appear in runtime/schemas.py"

    def test_ensure_schema_does_not_create_dispatch_tables(self):
        from runtime.schemas import ensure_schema

        with tempfile.NamedTemporaryFile(suffix=".db") as f:
            conn = sqlite3.connect(f.name)
            try:
                ensure_schema(conn)
                rows = conn.execute(
                    "SELECT name FROM sqlite_master "
                    "WHERE type='table' AND name IN ('dispatch_queue','dispatch_cycles')"
                ).fetchall()
            finally:
                conn.close()
        assert rows == [], (
            f"ensure_schema() must not create dispatch_queue or dispatch_cycles; "
            f"found: {rows}"
        )


class TestDispatchLegacyCliActionsRetired:
    """The legacy queue/cycle actions on `cc-policy dispatch` must be absent.

    Tests invoke ``python3 runtime/cli.py`` from REPO_ROOT directly (not
    the global ``cc-policy`` wrapper, which resolves to whichever repo
    hosts it on PATH).

    Note: the ``dispatch`` domain itself is NOT retired — it still hosts
    process-stop / agent-start / agent-stop / agent-prompt / attempt-*
    actions owned by dispatch_engine / dispatch_attempts. Only the six
    legacy queue/cycle actions are retired.
    """

    def _run_cli(self, *args: str) -> subprocess.CompletedProcess:
        import sys as _sys

        return subprocess.run(
            [_sys.executable, str(REPO_ROOT / "runtime" / "cli.py"), *args],
            capture_output=True,
            text=True,
            timeout=10,
        )

    @pytest.mark.parametrize(
        "action", ["enqueue", "next", "start", "complete", "cycle-start", "cycle-current"]
    )
    def test_legacy_queue_cycle_action_rejected(self, action):
        result = self._run_cli("dispatch", action, "--help")
        assert result.returncode != 0, (
            f"'dispatch {action}' must be rejected; got rc={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
        combined = (result.stderr or "") + (result.stdout or "")
        assert f"invalid choice: '{action}'" in combined, (
            f"expected 'invalid choice: \\'{action}\\'' in argparse error; got: {combined!r}"
        )


class TestObservatoryDoesNotQueryDispatchQueue:
    """sidecars/observatory/observe.py must not query dispatch_queue."""

    def test_observe_source_has_no_dispatch_queue_query(self):
        src = (REPO_ROOT / "sidecars" / "observatory" / "observe.py").read_text()
        assert "FROM dispatch_queue" not in src, (
            "observe.py must not issue SELECT ... FROM dispatch_queue"
        )

    def test_observe_source_has_no_dispatch_backlog_issue(self):
        """The dispatch_backlog health issue was retired alongside dispatch_queue."""
        src = (REPO_ROOT / "sidecars" / "observatory" / "observe.py").read_text()
        assert "issues.append(\"dispatch_backlog\")" not in src, (
            "observe.py _compute_health must not emit dispatch_backlog issue"
        )


class TestStatuslineDoesNotQueryDispatchCycles:
    """runtime/core/statusline.py must not query dispatch_cycles."""

    def test_statusline_source_has_no_dispatch_cycles_query(self):
        src = (REPO_ROOT / "runtime" / "core" / "statusline.py").read_text()
        assert "FROM   dispatch_cycles" not in src and "FROM dispatch_cycles" not in src, (
            "statusline.py must not issue SELECT ... FROM dispatch_cycles"
        )


class TestSnapshotSchemaStability:
    """dispatch_cycle_id, dispatch_initiative, pending_dispatches keys remain."""

    def test_statusline_snapshot_keeps_dispatch_cycle_id_key(self):
        """snapshot() must still expose dispatch_cycle_id (default None)."""
        import sys as _sys
        _sys.path.insert(0, str(REPO_ROOT))

        from runtime.core.db import connect_memory
        from runtime.core.statusline import snapshot
        from runtime.schemas import ensure_schema

        conn = connect_memory()
        try:
            ensure_schema(conn)
            snap = snapshot(conn)
        finally:
            conn.close()

        assert "dispatch_cycle_id" in snap
        assert snap["dispatch_cycle_id"] is None
        assert "dispatch_initiative" in snap
        assert snap["dispatch_initiative"] is None

    def test_observatory_report_keeps_pending_dispatches_key(self):
        """Observatory.report() must still expose pending_dispatches (always 0)."""
        import sys as _sys
        _sys.path.insert(0, str(REPO_ROOT))

        from runtime.core.db import connect_memory
        from runtime.schemas import ensure_schema
        from sidecars.observatory.observe import Observatory

        conn = connect_memory()
        try:
            ensure_schema(conn)
            obs = Observatory("observatory", conn)
            obs.observe()
            report = obs.report()
        finally:
            conn.close()

        assert "pending_dispatches" in report
        assert report["pending_dispatches"] == 0


class TestNoLiveDispatchModuleReferences:
    """No live import of runtime.core.dispatch may remain in production code.

    Distinguish from runtime.core.dispatch_engine / dispatch_shadow /
    dispatch_attempts / dispatch_hook — those are unrelated domains and
    must keep working.
    """

    def test_no_live_dispatch_imports_in_runtime_or_hooks_or_sidecars(self):
        patterns = (
            re.compile(r"^\s*import\s+runtime\.core\.dispatch\s+as", re.MULTILINE),
            re.compile(r"^\s*import\s+runtime\.core\.dispatch\s*$", re.MULTILINE),
            re.compile(r"^\s*from\s+runtime\.core\.dispatch\s+import\b", re.MULTILINE),
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
            "Live runtime.core.dispatch imports remain after retirement:\n  "
            + "\n  ".join(offenders)
        )

"""Tests for post-task.sh BLOCKED signal on critic-missing PROCESS ERROR.

DEC-CRITIC-BLOCKED-002: when dispatch_engine returns
"PROCESS ERROR: implementer critic did not run." the hookSpecificOutput
additionalContext emitted by the dispatch runtime must carry a hard
BLOCKED: marker on its own line.

This test exercises the runtime (dispatch_engine + cli.py dispatch process-stop)
end-to-end, not via bash subprocess.  The CLI output is inspected for the
hookSpecificOutput shape that post-task.sh would echo to the orchestrator.

Production sequence:
  post-task.sh reads HOOK_INPUT → calls cc-policy dispatch process-stop →
  runtime builds hookSpecificOutput → post-task.sh echoes it →
  orchestrator sees additionalContext containing BLOCKED: marker.

Real SQLite; no subprocess mocking for runtime calls.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")
sys.path.insert(0, str(_REPO_ROOT))

from runtime.core.db import connect
from runtime.schemas import ensure_schema
import runtime.core.leases as leases_mod
import runtime.core.completions as completions_mod
import runtime.core.enforcement_config as enforcement_config_mod


def _run_dispatch_process_stop(agent_type: str, project_root: str, db_path: str) -> dict:
    """Call cc-policy dispatch process-stop via subprocess (matches post-task.sh path)."""
    payload = json.dumps({"agent_type": agent_type, "project_root": project_root})
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": str(_REPO_ROOT)}
    result = subprocess.run(
        [sys.executable, _CLI, "dispatch", "process-stop"],
        input=payload,
        capture_output=True,
        text=True,
        env=env,
    )
    try:
        return json.loads(result.stdout.strip() or result.stderr.strip())
    except json.JSONDecodeError:
        return {"_raw_stdout": result.stdout, "_raw_stderr": result.stderr, "returncode": result.returncode}


@pytest.fixture
def db_path(tmp_path):
    db_file = str(tmp_path / "state.db")
    conn = connect(tmp_path / "state.db")
    ensure_schema(conn)
    conn.close()
    return db_file


def test_post_task_emits_blocked_signal_on_process_error(tmp_path, db_path):
    """dispatch process-stop output contains BLOCKED: in additionalContext for critic-missing error.

    DEC-CRITIC-BLOCKED-002: the orchestrator's chain-stop rule triggers on
    BLOCKED, ERROR, or PROCESS ERROR in additionalContext.  When the critic
    is enabled but no critic_reviews row exists, the suggestion (and therefore
    additionalContext) MUST carry a BLOCKED: marker on its own line so the
    orchestrator stops even if the implementer's own response contained
    READY_FOR_REVIEWER.

    This test calls the CLI via subprocess (exactly as post-task.sh does) to
    verify the full pipeline from process-stop input to hookSpecificOutput.
    No subprocess mocking for runtime calls; the Codex CLI itself is not invoked.
    """
    project_root = str(tmp_path / "feature-worktree")
    workflow_id = "wf-blocked-signal-001"

    # Set up state via direct module calls on a separate connection
    conn = connect(Path(db_path))
    ensure_schema(conn)
    lease = leases_mod.issue(
        conn,
        role="implementer",
        worktree_path=project_root,
        workflow_id=workflow_id,
    )
    lease_id = lease["lease_id"]
    completions_mod.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="implementer",
        payload={
            "IMPL_STATUS": "complete",
            "IMPL_RESULT": "READY_FOR_REVIEWER",
        },
    )
    # Explicitly enable critic
    enforcement_config_mod.set_(
        conn,
        "critic_enabled_implementer_stop",
        "true",
        scope=f"workflow={workflow_id}",
        actor_role="planner",
    )
    conn.close()

    # Call dispatch process-stop as post-task.sh would
    out = _run_dispatch_process_stop("implementer", project_root, db_path)

    assert out.get("status") == "ok", f"Expected status=ok, got: {out}"

    # Check the structured error field
    assert out.get("next_role") is None, (
        f"Expected next_role=None when critic missing, got {out.get('next_role')!r}"
    )
    assert out.get("error") is not None, "Expected error field to be set"
    assert "PROCESS ERROR: implementer critic did not run" in str(out.get("error")), (
        f"Expected PROCESS ERROR in error field, got: {out.get('error')!r}"
    )

    # The hookSpecificOutput.additionalContext must carry the BLOCKED: marker
    hook_output = out.get("hookSpecificOutput", {})
    additional_context = hook_output.get("additionalContext", "")
    assert "BLOCKED:" in additional_context, (
        f"Expected 'BLOCKED:' in hookSpecificOutput.additionalContext "
        f"(DEC-CRITIC-BLOCKED-002), got: {additional_context!r}"
    )
    assert "PROCESS ERROR: implementer critic did not run" in additional_context, (
        f"Expected PROCESS ERROR line preserved in additionalContext, "
        f"got: {additional_context!r}"
    )
    # The BLOCKED: and PROCESS ERROR must be on separate lines
    lines = additional_context.splitlines()
    blocked_lines = [line for line in lines if line.startswith("BLOCKED:")]
    process_error_lines = [line for line in lines if line.startswith("PROCESS ERROR:")]
    assert len(blocked_lines) >= 1, (
        f"Expected at least one 'BLOCKED:' line in additionalContext, lines: {lines}"
    )
    assert len(process_error_lines) >= 1, (
        f"Expected at least one 'PROCESS ERROR:' line in additionalContext, lines: {lines}"
    )

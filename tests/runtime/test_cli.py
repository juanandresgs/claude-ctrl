"""Integration tests for runtime/cli.py via subprocess.

Each test invokes `python3 runtime/cli.py` with real arguments and validates
JSON output. Uses a temporary file-based SQLite DB (not the user's state.db).
This is the compound-interaction test that exercises the real production
sequence end-to-end through the CLI boundary.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: Subprocess tests verify the full stack: arg parsing -> domain
  module -> SQLite -> JSON serialization. They catch integration failures
  that unit tests (which call domain functions directly) cannot catch, such
  as import errors, argparse misconfiguration, or wrong field names in JSON
  output. Each test uses a fresh tmp DB via CLAUDE_POLICY_DB env override.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

# Path to the cli.py under test
_WORKTREE = Path(__file__).resolve().parent.parent.parent
_CLI = str(_WORKTREE / "runtime" / "cli.py")


def run(args: list[str], db_path: str, extra_env: dict[str, str] | None = None) -> tuple[int, dict]:
    """Run cc-policy with the given args, return (exit_code, parsed_json)."""
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db_path,
        "PYTHONPATH": str(_WORKTREE),
        **(extra_env or {}),
    }
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    # Success output on stdout; error output on stderr
    output = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output}
    return result.returncode, parsed


@pytest.fixture
def db(tmp_path):
    """Return a path to a fresh temporary database file."""
    return str(tmp_path / "test-state.db")


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------


def test_schema_ensure(db):
    code, out = run(["schema", "ensure"], db)
    assert code == 0
    assert out["status"] == "ok"


def test_init_alias(db):
    code, out = run(["init"], db)
    assert code == 0
    assert out["status"] == "ok"


# ---------------------------------------------------------------------------
# Critic review
# ---------------------------------------------------------------------------


def test_critic_review_submit_and_latest(db):
    code, out = run(
        [
            "critic-review",
            "submit",
            "--workflow-id",
            "wf-cli-critic-001",
            "--lease-id",
            "lease-cli-001",
            "--verdict",
            "TRY_AGAIN",
            "--summary",
            "Need one more pass.",
            "--detail",
            "Coverage is still missing on the main path.",
            "--fingerprint",
            "fp-cli-001",
            "--metadata",
            '{"hook":"cli-test"}',
        ],
        db,
    )
    assert code == 0, out
    assert out["verdict"] == "TRY_AGAIN"
    assert out["resolution"]["next_role"] == "implementer"
    assert out["metadata"]["hook"] == "cli-test"

    code, latest = run(
        ["critic-review", "latest", "--workflow-id", "wf-cli-critic-001"],
        db,
    )
    assert code == 0, latest
    assert latest["workflow_id"] == "wf-cli-critic-001"
    assert latest["lease_id"] == "lease-cli-001"
    assert latest["verdict"] == "TRY_AGAIN"


# ---------------------------------------------------------------------------
# Marker
# ---------------------------------------------------------------------------


def test_marker_set_and_get_active(db):
    code, out = run(["marker", "set", "agent-1", "implementer"], db)
    assert code == 0
    assert out["status"] == "ok"

    code, out = run(["marker", "get-active"], db)
    assert code == 0
    assert out["found"] is True
    assert out["role"] == "implementer"


def test_marker_set_without_project_root_defaults_to_resolved_root(db, tmp_path):
    """A21 regression: `marker set` without --project-root must default to the
    CLI-resolved project root (args → CLAUDE_PROJECT_DIR env → git toplevel →
    normalize_path) so a subsequent scoped `marker get-active --project-root`
    query finds the marker.

    Pre-A21: set stored project_root=NULL, and get-active --project-root=<X>
    returned found=False because NULL did not match equality against X. This
    surfaced in A19R when the orchestrator's guardian marker was silently
    invisible to the lease-visibility path until re-set with an explicit flag.

    Post-A21: omitting --project-root picks up CLAUDE_PROJECT_DIR (the canonical
    session root), so the scoped lookup matches deterministically.
    """
    from runtime.core.policy_utils import normalize_path

    fake_root = str(tmp_path / "fake-proj")
    os.makedirs(fake_root, exist_ok=True)
    normalized = normalize_path(fake_root)

    # Emulate a normal repo session: CLAUDE_PROJECT_DIR is set.
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db,
        "PYTHONPATH": str(_WORKTREE),
        "CLAUDE_PROJECT_DIR": fake_root,
    }

    # marker set without --project-root
    result = subprocess.run(
        [sys.executable, _CLI, "marker", "set", "agent-noroot", "guardian"],
        capture_output=True, text=True, env=env,
    )
    assert result.returncode == 0, result.stderr

    # Scoped get-active under the resolved root must find the marker.
    result = subprocess.run(
        [sys.executable, _CLI, "marker", "get-active", "--project-root", normalized],
        capture_output=True, text=True, env=env,
    )
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout.strip())
    assert data.get("found") is True, (
        f"scoped get-active must find the marker persisted with defaulted "
        f"project_root; got {data!r}"
    )
    assert data.get("agent_id") == "agent-noroot"
    assert data.get("role") == "guardian"
    assert data.get("project_root") == normalized, (
        f"marker row must carry the defaulted project_root, not NULL; got "
        f"{data.get('project_root')!r}"
    )


def test_marker_deactivate(db):
    run(["marker", "set", "agent-1", "implementer"], db)
    code, out = run(["marker", "deactivate", "agent-1"], db)
    assert code == 0

    code, out = run(["marker", "get-active"], db)
    assert out["found"] is False


def test_marker_get_active_empty(db):
    code, out = run(["marker", "get-active"], db)
    assert code == 0
    assert out["found"] is False


# ---------------------------------------------------------------------------
# Event
# ---------------------------------------------------------------------------


def test_event_emit_and_query(db):
    code, out = run(["event", "emit", "tkt.start", "--source", "tkt-006", "--detail", "began"], db)
    assert code == 0
    assert out["status"] == "ok"
    assert isinstance(out["id"], int)

    code, out = run(["event", "query"], db)
    assert code == 0
    assert out["count"] == 1
    assert out["items"][0]["type"] == "tkt.start"


def test_event_query_type_filter(db):
    run(["event", "emit", "type.a"], db)
    run(["event", "emit", "type.b"], db)
    code, out = run(["event", "query", "--type", "type.a"], db)
    assert code == 0
    assert out["count"] == 1
    assert out["items"][0]["type"] == "type.a"


def test_event_query_limit(db):
    for _ in range(5):
        run(["event", "emit", "evt"], db)
    code, out = run(["event", "query", "--limit", "2"], db)
    assert code == 0
    assert out["count"] == 2


# ---------------------------------------------------------------------------
# Worktree
# ---------------------------------------------------------------------------


def test_worktree_register_list_remove(db):
    code, out = run(["worktree", "register", "/path/a", "feature/a", "--ticket", "TKT-1"], db)
    assert code == 0

    code, out = run(["worktree", "list"], db)
    assert code == 0
    assert out["count"] == 1
    assert out["items"][0]["path"] == "/path/a"

    code, out = run(["worktree", "remove", "/path/a"], db)
    assert code == 0

    code, out = run(["worktree", "list"], db)
    assert out["count"] == 0


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------


def test_dispatch_full_lifecycle(db):
    legacy_actions = (
        "enqueue",
        "next",
        "start",
        "complete",
        "cycle-start",
        "cycle-current",
    )
    for action in legacy_actions:
        code, out = run(["dispatch", action, "--help"], db)
        assert code != 0
        assert f"invalid choice: '{action}'" in out["_raw"]


# ---------------------------------------------------------------------------
# Statusline
# ---------------------------------------------------------------------------


def test_statusline_snapshot_keys(db):
    # Populate some state
    run(["marker", "set", "agent-1", "implementer"], db)
    run(["worktree", "register", "/wt/a", "feature/a"], db)

    code, out = run(["statusline", "snapshot"], db)
    assert code == 0
    assert out["status"] == "ok"
    for key in (
        "active_agent",
        "worktree_count",
        "dispatch_status",
        "dispatch_initiative",
        "recent_event_count",
        "snapshot_at",
    ):
        assert key in out, f"missing key: {key}"
    # W-CONV-4: proof_status/proof_workflow removed from snapshot
    assert "proof_status" not in out
    assert "proof_workflow" not in out


def test_statusline_snapshot_empty_db(db):
    """Snapshot must return safe defaults on an empty database."""
    code, out = run(["statusline", "snapshot"], db)
    assert code == 0
    # W-CONV-4: proof_status/proof_workflow no longer in snapshot
    assert "proof_status" not in out
    assert "proof_workflow" not in out
    assert out["active_agent"] is None
    assert out["worktree_count"] == 0


# ---------------------------------------------------------------------------
# Latency
# ---------------------------------------------------------------------------


def test_statusline_snapshot_latency_under_300ms(db):
    """cc-policy statusline snapshot should stay sub-300ms on a warm DB."""
    run(["marker", "set", "agent-lat", "implementer"], db)

    samples = []
    for _ in range(3):
        start = time.perf_counter()
        code, out = run(["statusline", "snapshot"], db)
        samples.append((time.perf_counter() - start) * 1000)
        assert code == 0
        assert out["status"] == "ok"

    elapsed_ms = min(samples)
    formatted = ", ".join(f"{sample:.1f}ms" for sample in samples)
    print(f"\n  statusline snapshot latency samples: {formatted}; best={elapsed_ms:.1f}ms")
    assert elapsed_ms < 300, f"best latency {elapsed_ms:.1f}ms exceeds 300ms threshold"

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


def test_issue_file_cli_routes_through_capture_authority(db, tmp_path):
    todo_sh = tmp_path / "todo.sh"
    todo_sh.write_text("#!/usr/bin/env bash\necho 'https://github.com/org/repo/issues/55'\n")
    todo_sh.chmod(0o755)

    code, out = run(
        [
            "issue",
            "file",
            "--kind",
            "follow_up",
            "--scope",
            "project",
            "--title",
            "cli follow-up",
            "--body",
            "body",
            "--project-root",
            str(tmp_path),
        ],
        db,
        extra_env={"CLAUDE_TODO_SH": str(todo_sh)},
    )

    assert code == 0, out
    assert out["disposition"] == "filed"
    assert out["scope"] == "project"
    assert out["issue_url"] == "https://github.com/org/repo/issues/55"

    code, listed = run(["issue", "list"], db)
    assert code == 0, listed
    assert listed["count"] == 1
    assert listed["items"][0]["title"] == "cli follow-up"


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


def test_critic_run_lifecycle_and_metrics_cli(db):
    code, started = run(
        [
            "critic-run",
            "start",
            "--workflow-id",
            "wf-cli-critic-run-001",
            "--lease-id",
            "lease-cli-run-001",
            "--provider",
            "codex",
        ],
        db,
    )
    assert code == 0, started
    assert started["status"] == "started"
    run_id = started["run_id"]

    code, progressed = run(
        [
            "critic-run",
            "progress",
            "--run-id",
            run_id,
            "--message",
            "Provider status: codex ready.",
            "--phase",
            "provider",
            "--status",
            "provider_ready",
        ],
        db,
    )
    assert code == 0, progressed
    assert progressed["status"] == "provider_ready"

    code, completed = run(
        [
            "critic-run",
            "complete",
            "--run-id",
            run_id,
            "--verdict",
            "READY_FOR_REVIEWER",
            "--summary",
            "Ready for reviewer.",
            "--metrics",
            '{"try_again_streak":0,"retry_limit":2}',
        ],
        db,
    )
    assert code == 0, completed
    assert completed["status"] == "completed"
    assert completed["verdict"] == "READY_FOR_REVIEWER"

    code, latest = run(
        ["critic-run", "latest", "--workflow-id", "wf-cli-critic-run-001"],
        db,
    )
    assert code == 0, latest
    assert latest["found"] is True
    assert latest["run_id"] == run_id

    code, metrics = run(
        ["critic-run", "metrics", "--workflow-id", "wf-cli-critic-run-001"],
        db,
    )
    assert code == 0, metrics
    assert metrics["total_runs"] == 1
    assert metrics["ready_for_reviewer"] == 1
    assert metrics["loopback_rate"] == 0.0


# ---------------------------------------------------------------------------
# Session activity / enforcement gaps
# ---------------------------------------------------------------------------


def test_session_activity_tracks_prompts_and_changed_files_in_db(db, tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    changed = project / "src" / "app.ts"
    changed.parent.mkdir()
    changed.write_text("export const x = 1;\n")

    code, first = run(
        [
            "session-activity",
            "prompt",
            "--project-root",
            str(project),
            "--session-id",
            "sess-cli-001",
        ],
        db,
    )
    assert code == 0, first
    assert first["prompt_count"] == 1

    code, second = run(
        [
            "session-activity",
            "prompt",
            "--project-root",
            str(project),
            "--session-id",
            "sess-cli-001",
        ],
        db,
    )
    assert code == 0, second
    assert second["prompt_count"] == 2

    code, recorded = run(
        [
            "session-activity",
            "change-record",
            "--project-root",
            str(project),
            "--session-id",
            "sess-cli-001",
            "--file-path",
            str(changed),
        ],
        db,
    )
    assert code == 0, recorded
    assert recorded["count"] == 1
    assert recorded["items"][0]["file_path"] == str(changed.resolve())

    code, listed = run(
        [
            "session-activity",
            "change-list",
            "--project-root",
            str(project),
            "--session-id",
            "sess-cli-001",
        ],
        db,
    )
    assert code == 0, listed
    assert listed["count"] == 1


def test_enforcement_gap_cli_records_counts_and_clears(db, tmp_path):
    project = tmp_path / "project"
    project.mkdir()

    for _ in range(2):
        code, out = run(
            [
                "enforcement-gap",
                "record",
                "--project-root",
                str(project),
                "--gap-type",
                "unsupported",
                "--ext",
                "java",
                "--tool",
                "none",
            ],
            db,
        )
        assert code == 0, out

    code, counted = run(
        [
            "enforcement-gap",
            "count",
            "--project-root",
            str(project),
            "--gap-type",
            "unsupported",
            "--ext",
            "java",
        ],
        db,
    )
    assert code == 0, counted
    assert counted["count"] == 2

    code, listed = run(["enforcement-gap", "list", "--project-root", str(project)], db)
    assert code == 0, listed
    assert listed["count"] == 1
    assert listed["items"][0]["ext"] == "java"

    code, cleared = run(
        [
            "enforcement-gap",
            "clear",
            "--project-root",
            str(project),
            "--gap-type",
            "unsupported",
            "--ext",
            "java",
        ],
        db,
    )
    assert code == 0, cleared
    assert cleared["cleared"] is True

    code, counted = run(
        [
            "enforcement-gap",
            "count",
            "--project-root",
            str(project),
            "--gap-type",
            "unsupported",
            "--ext",
            "java",
        ],
        db,
    )
    assert code == 0, counted
    assert counted["count"] == 0


def test_lint_state_cli_stores_cache_and_breaker_in_db(db, tmp_path):
    project = tmp_path / "project"
    project.mkdir()

    code, empty = run(
        [
            "lint-state",
            "cache-get",
            "--project-root",
            str(project),
            "--ext",
            "py",
            "--config-mtime",
            "100",
        ],
        db,
    )
    assert code == 0, empty
    assert empty["found"] is False

    code, cached = run(
        [
            "lint-state",
            "cache-set",
            "--project-root",
            str(project),
            "--ext",
            ".py",
            "--linter",
            "ruff",
            "--config-mtime",
            "100",
        ],
        db,
    )
    assert code == 0, cached
    assert cached["linter"] == "ruff"

    code, fresh = run(
        [
            "lint-state",
            "cache-get",
            "--project-root",
            str(project),
            "--ext",
            "py",
            "--config-mtime",
            "100",
        ],
        db,
    )
    assert code == 0, fresh
    assert fresh["found"] is True
    assert fresh["linter"] == "ruff"

    code, stale = run(
        [
            "lint-state",
            "cache-get",
            "--project-root",
            str(project),
            "--ext",
            "py",
            "--config-mtime",
            "101",
        ],
        db,
    )
    assert code == 0, stale
    assert stale["found"] is False

    code, breaker = run(
        [
            "lint-state",
            "breaker-set",
            "--project-root",
            str(project),
            "--ext",
            "py",
            "--state",
            "open",
            "--failure-count",
            "3",
            "--updated-at",
            "123",
        ],
        db,
    )
    assert code == 0, breaker
    assert breaker["state"] == "open"
    assert breaker["failure_count"] == 3

    code, breaker = run(
        ["lint-state", "breaker-get", "--project-root", str(project), "--ext", "py"],
        db,
    )
    assert code == 0, breaker
    assert breaker["found"] is True
    assert breaker["state"] == "open"


def test_preserved_context_cli_saves_and_consumes_once(db, tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    env = {"CLAUDE_POLICY_DB": db, "PYTHONPATH": str(_WORKTREE)}

    save = subprocess.run(
        [
            sys.executable,
            _CLI,
            "preserved-context",
            "save",
            "--project-root",
            str(project),
            "--session-id",
            "sess-preserve-001",
        ],
        input="Plan: active\nModified this session: app.ts\n",
        capture_output=True,
        text=True,
        env=env,
    )
    assert save.returncode == 0, save.stderr
    saved = json.loads(save.stdout)
    assert saved["found"] is True

    code, consumed = run(
        [
            "preserved-context",
            "consume",
            "--project-root",
            str(project),
            "--session-id",
            "sess-preserve-001",
        ],
        db,
    )
    assert code == 0, consumed
    assert consumed["found"] is True
    assert "Modified this session" in consumed["context_text"]

    code, consumed_again = run(
        [
            "preserved-context",
            "consume",
            "--project-root",
            str(project),
            "--session-id",
            "sess-preserve-001",
        ],
        db,
    )
    assert code == 0, consumed_again
    assert consumed_again["found"] is False


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

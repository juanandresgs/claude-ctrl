"""Focused integration tests for ``scripts/claudex-watchdog.sh --once``.

@decision DEC-CLAUDEX-WATCHDOG-TESTS-001
Title: Watchdog Codex-handoff persistence is pinned by a focused subprocess test
Status: proposed
Rationale: The bridge watchdog is the only surface that writes
  ``.claude/claudex/pending-review.json``, and it runs in a loop under
  normal operation. Up to this point its persistence behaviour was only
  exercised ad hoc during live runs, which meant a regression in the
  handoff codepath could ship silently. This test pins the wrapper-level
  contract that the watchdog emits and clears the pending-review artifact
  purely from a single ``--once`` tick, and that ``claudex-bridge-status.sh``
  surfaces that artifact when it exists.

  Isolation strategy:
    * A fresh tmp directory is initialised as an empty git repo so that
      ``git rev-parse --show-toplevel`` resolves to the fake repo inside
      the test — this is how the script derives its PID_DIR.
    * BRAID_ROOT is redirected to a per-test tmp dir containing a fake
      ``runs/`` tree. The watchdog's broker short-circuit (`[[ -S sock ]]`)
      is satisfied by binding a real AF_UNIX socket file at the expected
      path; the auto-submit short-circuit is satisfied by writing the test
      runner's own PID into ``auto-submit.pid`` so ``kill -0`` succeeds.
    * With both short-circuits in place, the test never forks a real
      broker, auto-submit daemon, or tmux process.

  The test is skipped when ``bash`` or ``jq`` is not on PATH — the
  watchdog uses both, and a host without them cannot exercise the script
  anyway.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_WATCHDOG = _REPO_ROOT / "scripts" / "claudex-watchdog.sh"
_STATUS = _REPO_ROOT / "scripts" / "claudex-bridge-status.sh"
_PROGRESS_MONITOR = _REPO_ROOT / "scripts" / "claudex-progress-monitor.sh"


pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None or shutil.which("jq") is None,
    reason="claudex-watchdog.sh requires bash and jq",
)


# ---------------------------------------------------------------------------
# Fixture: fake repo + fake BRAID_ROOT with broker/auto-submit short-circuits
# ---------------------------------------------------------------------------


@pytest.fixture
def bridge_env(tmp_path):
    """Set up an isolated fake repo + BRAID_ROOT tree for watchdog testing.

    Returns a dict with the key paths the test needs to seed / inspect.

    Note on the BRAID_ROOT path choice: the watchdog pre-creates an
    AF_UNIX socket at ``runs/braidd.sock``. macOS caps ``sun_path`` at
    roughly 104 bytes, and pytest's default ``tmp_path`` is already
    ~100 bytes deep before we add any suffixes. We therefore place the
    fake braid tree under ``tempfile.mkdtemp()`` (which honours
    ``$TMPDIR`` and yields a much shorter ~62-byte prefix on macOS) and
    explicitly clean it up in the fixture teardown. The fake repo can
    stay under the normal ``tmp_path`` because it never hosts a socket.
    """
    fake_repo = tmp_path / "fake-repo"
    fake_braid = Path(tempfile.mkdtemp(prefix="cxwd-"))
    (fake_repo / ".claude" / "claudex").mkdir(parents=True)
    (fake_repo / "scripts").mkdir(parents=True)
    (fake_braid / "runs").mkdir(parents=True)

    # Initialise the fake repo as a git repo so `git rev-parse --show-toplevel`
    # resolves to it when we cd there.
    subprocess.run(
        ["git", "init", "--quiet", str(fake_repo)],
        check=True,
        capture_output=True,
    )
    # Minimal git config so `git rev-parse` does not warn about missing user.
    subprocess.run(
        ["git", "-C", str(fake_repo), "config", "user.email", "test@example.com"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(fake_repo), "config", "user.name", "Test"],
        check=True,
        capture_output=True,
    )

    # Broker short-circuit: the watchdog skips broker restart when the
    # expected socket path is an AF_UNIX socket on disk. Bind + close leaves
    # the socket inode behind on both macOS and Linux.
    sock_path = fake_braid / "runs" / "braidd.sock"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.bind(str(sock_path))
    except PermissionError:
        pytest.skip("sandbox disallows AF_UNIX socket bind needed for watchdog test")
    finally:
        s.close()
    assert sock_path.exists(), "failed to pre-create fake broker socket"

    # Auto-submit short-circuit: the watchdog skips auto-submit restart when
    # the pid file points at a live pid. Use the test runner's own pid.
    (fake_repo / ".claude" / "claudex" / "auto-submit.pid").write_text(
        f"{os.getpid()}\n"
    )

    env = {
        "repo": fake_repo,
        "braid": fake_braid,
        "pid_dir": fake_repo / ".claude" / "claudex",
        "runs": fake_braid / "runs",
        "pending_review": fake_repo / ".claude" / "claudex" / "pending-review.json",
        "handoff_flag": fake_repo / ".claude" / "claudex" / "ready-for-codex.flag",
        "auto_submit_log": fake_repo / ".claude" / "claudex" / "auto-submit.log",
        "progress_snapshot": fake_repo / ".claude" / "claudex" / "progress-monitor.latest.json",
        "progress_alert": fake_repo / ".claude" / "claudex" / "progress-monitor.alert.json",
        "dispatch_stall_state": fake_repo / ".claude" / "claudex" / "dispatch-stall.state.json",
        "dispatch_recovery_state": fake_repo / ".claude" / "claudex" / "dispatch-recovery.state.json",
        "dispatch_recovery_log": fake_repo / ".claude" / "claudex" / "dispatch-recovery.log",
        "relay_prompt_recovery_state": fake_repo / ".claude" / "claudex" / "relay-prompt-recovery.state.json",
        "supervisor_recovery_state": fake_repo / ".claude" / "claudex" / "supervisor-recovery.state.json",
        "supervisor_recovery_log": fake_repo / ".claude" / "claudex" / "supervisor-recovery.log",
        "dispatch_recovery_script": fake_repo / "scripts" / "claudex-dispatch-recover.sh",
        "restart_script": fake_repo / "scripts" / "claudex-supervisor-restart.sh",
        "sock": sock_path,
    }
    try:
        yield env
    finally:
        # The fake_braid tree lives outside pytest's tmp_path, so we must
        # remove it explicitly. Best-effort: a stray file should never
        # break the test run.
        shutil.rmtree(fake_braid, ignore_errors=True)


def _seed_run(
    bridge_env: dict,
    *,
    run_id: str,
    state: str,
    control_mode: str = "supervised",
    tmux_target: str = "",
    instruction_id: str | None = None,
    response_payload: dict | None = None,
    updated_at: str | None = None,
) -> Path:
    """Seed an active run under bridge_env['runs'] and return the run dir."""
    runs = bridge_env["runs"]
    run_dir = runs / run_id
    (run_dir / "responses").mkdir(parents=True)
    (run_dir / "queue").mkdir(parents=True)

    if updated_at is None:
        updated_at = "2026-04-08T00:00:00Z"

    (run_dir / "run.json").write_text(
        json.dumps(
            {
                "run_id": run_id,
                "project_root": str(bridge_env["repo"]),
                "project_slug": "fake",
                "tmux_target": tmux_target,
                "created_at": updated_at,
                "completed_at": None,
                "transcript_path": str(run_dir / "transcript.jsonl"),
            }
        )
    )
    (run_dir / "status.json").write_text(
        json.dumps(
            {
                "state": state,
                "control_mode": control_mode,
                "instruction_id": instruction_id,
                "updated_at": updated_at,
            }
        )
    )

    if response_payload is not None:
        # The watchdog picks the lexicographically last *.json in responses/.
        (run_dir / "responses" / "0001-resp.json").write_text(
            json.dumps(response_payload)
        )

    (runs / "active-run").write_text(f"{run_id}\n")
    return run_dir


def _run_watchdog_once(
    bridge_env: dict,
    *,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    """Invoke the watchdog with --once, CWD=fake repo, BRAID_ROOT override."""
    env = {
        **os.environ,
        "BRAID_ROOT": str(bridge_env["braid"]),
        "CLAUDEX_STATE_DIR": str(bridge_env["pid_dir"]),
        # Drop poll/grace so the tick stays cheap; --once avoids the loop
        # anyway, but tighten in case a future refactor changes that.
        "CLAUDEX_WATCHDOG_POLL_INTERVAL": "1",
        "CLAUDEX_WATCHDOG_QUEUE_GRACE_SECONDS": "1",
        "CLAUDEX_WATCHDOG_POKE_COOLDOWN_SECONDS": "1",
    }
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(_WATCHDOG), "--once"],
        cwd=str(bridge_env["repo"]),
        env=env,
        capture_output=True,
        text=True,
    )


def _pid_is_live(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _wait_for_path(path: Path, timeout_seconds: float = 2.0) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if path.exists():
            return True
        time.sleep(0.05)
    return path.exists()


def _run_progress_monitor_once(
    bridge_env: dict,
    *,
    tmux_output: str = "",
    tmux_exit: int = 0,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    """Invoke the progress monitor with a fake tmux binary."""
    fake_bin = bridge_env["repo"] / "fake-bin"
    fake_bin.mkdir(exist_ok=True)
    fake_tmux = fake_bin / "tmux"
    fake_tmux.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"capture-pane\" ]]; then\n"
        "  printf '%s' \"${CLAUDEX_FAKE_TMUX_CAPTURE:-}\"\n"
        "  exit \"${CLAUDEX_FAKE_TMUX_EXIT:-0}\"\n"
        "fi\n"
        "exit 64\n"
    )
    fake_tmux.chmod(0o755)

    env = {
        **os.environ,
        "BRAID_ROOT": str(bridge_env["braid"]),
        "CLAUDEX_STATE_DIR": str(bridge_env["pid_dir"]),
        "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
        "CLAUDEX_FAKE_TMUX_CAPTURE": tmux_output,
        "CLAUDEX_FAKE_TMUX_EXIT": str(tmux_exit),
    }
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(_PROGRESS_MONITOR), "--once", "--codex-target", "fake:1.1"],
        cwd=str(bridge_env["repo"]),
        env=env,
        capture_output=True,
        text=True,
    )


def test_watchdog_dedupes_auto_submit_when_pidfile_and_pgrep_disagree(bridge_env):
    fake_repo = bridge_env["repo"]
    fake_scripts = fake_repo / "scripts"
    fake_scripts.mkdir(exist_ok=True)
    marker = fake_repo / ".claude" / "claudex" / "auto-submit-started.marker"
    fake_auto_submit = fake_scripts / "claudex-auto-submit.sh"
    fake_auto_submit.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"printf 'started\\n' >> {marker}\n"
        "sleep 30\n"
    )
    fake_auto_submit.chmod(0o755)

    proc_a = subprocess.Popen(["sleep", "30"])
    proc_b = subprocess.Popen(["sleep", "30"])
    replacement_pid = None
    try:
        (bridge_env["pid_dir"] / "auto-submit.pid").write_text(f"{proc_a.pid}\n")

        fake_bin = fake_repo / "fake-bin"
        fake_bin.mkdir(exist_ok=True)
        fake_pgrep = fake_bin / "pgrep"
        fake_pgrep.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf '%s\\n' \"$CLAUDEX_FAKE_PGREP_OUTPUT\"\n"
        )
        fake_pgrep.chmod(0o755)

        result = _run_watchdog_once(
            bridge_env,
            extra_env={
                "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
                "CLAUDEX_ALLOW_PGREP_FALLBACK": "1",
                "CLAUDEX_FAKE_PGREP_OUTPUT": f"{proc_a.pid}\n{proc_b.pid}",
            },
        )
        assert result.returncode == 0, result.stderr
        assert "auto-submit drift detected" in result.stderr
        assert "auto-submit not running; restarting daemon" in result.stderr

        assert _wait_for_path(marker), "replacement auto-submit daemon was not started"

        replacement_pid = int((bridge_env["pid_dir"] / "auto-submit.pid").read_text().strip())
        assert replacement_pid not in {proc_a.pid, proc_b.pid}
        assert _pid_is_live(replacement_pid), "replacement auto-submit pid is not live"
    finally:
        for proc in (proc_a, proc_b):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    proc.kill()
        if replacement_pid is not None:
            try:
                os.kill(replacement_pid, 15)
            except ProcessLookupError:
                pass


def test_watchdog_nudges_lodged_relay_prompt_before_dispatch_recovery(bridge_env):
    run_dir = _seed_run(
        bridge_env,
        run_id="run-lodged-relay",
        state="queued",
        tmux_target="fake:1.2",
        instruction_id="iid-lodged",
        updated_at="2026-04-08T00:00:00Z",
    )
    (run_dir / "queue" / "iid-lodged.json").write_text(
        json.dumps(
            {
                "instruction_id": "iid-lodged",
                "text": "queued slice",
                "queued_at": "2026-04-08T00:00:00Z",
            }
        )
    )

    fake_bin = bridge_env["repo"] / "fake-bin-tmux"
    fake_bin.mkdir(exist_ok=True)
    send_log = bridge_env["pid_dir"] / "tmux-send.log"
    fake_tmux = fake_bin / "tmux"
    fake_tmux.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "case \"${1:-}\" in\n"
        "  capture-pane)\n"
        "    printf '%s' \"${CLAUDEX_FAKE_TMUX_CAPTURE:-}\"\n"
        "    ;;\n"
        "  send-keys)\n"
        "    printf '%s\\n' \"$*\" >> \"${CLAUDEX_FAKE_TMUX_SEND_LOG}\"\n"
        "    ;;\n"
        "  *)\n"
        "    exit 64\n"
        "    ;;\n"
        "esac\n"
    )
    fake_tmux.chmod(0o755)

    result = _run_watchdog_once(
        bridge_env,
        extra_env={
            "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
            "CLAUDEX_FAKE_TMUX_CAPTURE": "Claude Code v2.1.104\n❯ __BRAID_RELAY__\n",
            "CLAUDEX_FAKE_TMUX_SEND_LOG": str(send_log),
        },
    )

    assert result.returncode == 0, result.stderr
    assert send_log.read_text().strip().endswith("send-keys -t fake:1.2 Enter")
    assert "relay prompt is lodged in fake:1.2; nudging Enter for iid-lodged" in result.stderr

    recovery_state = json.loads(bridge_env["relay_prompt_recovery_state"].read_text())
    assert recovery_state["run_id"] == "run-lodged-relay"
    assert recovery_state["instruction_id"] == "iid-lodged"
    assert recovery_state["tmux_target"] == "fake:1.2"


def _install_fake_supervisor_restart(bridge_env: dict) -> None:
    bridge_env["restart_script"].write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$*\" >> "
        f"\"{bridge_env['supervisor_recovery_log']}\"\n"
    )
    bridge_env["restart_script"].chmod(0o755)


def _install_fake_dispatch_recovery(bridge_env: dict) -> None:
    bridge_env["dispatch_recovery_script"].write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$*\" >> "
        f"\"{bridge_env['dispatch_recovery_log']}\"\n"
    )
    bridge_env["dispatch_recovery_script"].chmod(0o755)


# ---------------------------------------------------------------------------
# 1. Persistence on waiting_for_codex
# ---------------------------------------------------------------------------


class TestPendingReviewPersistence:
    def test_waiting_for_codex_writes_pending_review_with_full_payload(
        self, bridge_env
    ):
        run_id = "run-20260408T001122Z-abcd1234"
        instruction_id = "inst-777-demo"
        completed_at = "2026-04-08T00:11:33Z"
        transcript_path = "/tmp/fake/transcript.jsonl"
        response_text = (
            "line one of the response\n"
            "line two explaining what shipped\n"
            "line three with evidence\n"
            "line four wrapping up"
        )

        _seed_run(
            bridge_env,
            run_id=run_id,
            state="waiting_for_codex",
            response_payload={
                "instruction_id": instruction_id,
                "completed_at": completed_at,
                "transcript_path": transcript_path,
                "response": response_text,
            },
            updated_at="2026-04-08T00:11:40Z",
        )

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0, (
            f"watchdog --once failed: stdout={result.stdout!r} "
            f"stderr={result.stderr!r}"
        )

        pending = bridge_env["pending_review"]
        assert pending.exists(), (
            "pending-review.json was not written on waiting_for_codex"
        )

        payload = json.loads(pending.read_text())

        # Core identity fields.
        assert payload["run_id"] == run_id
        assert payload["state"] == "waiting_for_codex"
        assert payload["instruction_id"] == instruction_id
        assert payload["completed_at"] == completed_at
        assert payload["transcript_path"] == transcript_path
        assert payload["response_available"] is True

        # response_path must point at the seeded response file.
        seeded_response = (
            bridge_env["runs"] / run_id / "responses" / "0001-resp.json"
        )
        assert payload["response_path"] == str(seeded_response)

        # Preview must be non-empty and capped at 8 lines per the watchdog
        # jq expression. Here we supplied 4 lines, so all 4 should appear.
        preview = payload["response_preview"]
        assert isinstance(preview, str)
        assert preview.strip() != "", "response_preview must be non-empty"
        assert "line one of the response" in preview
        assert "line four wrapping up" in preview

        # The handoff flag file should also be present in the same tick —
        # this is the older breadcrumb that the pending-review artifact
        # supplements. Its existence is part of the same handoff contract.
        assert bridge_env["handoff_flag"].exists()
        flag_contents = bridge_env["handoff_flag"].read_text()
        assert run_id in flag_contents
        assert "waiting_for_codex" in flag_contents

    def test_completed_inflight_with_response_is_reconciled_to_review_handoff(
        self, bridge_env
    ):
        run_id = "run-20260408T001300Z-reconcile"
        instruction_id = "inst-reconcile-1"
        completed_at = "2026-04-08T00:13:10Z"

        run_dir = _seed_run(
            bridge_env,
            run_id=run_id,
            state="inflight",
            instruction_id=instruction_id,
            updated_at="2026-04-08T00:13:05Z",
        )
        (run_dir / "responses" / f"{instruction_id}.json").write_text(
            json.dumps(
                {
                    "instruction_id": instruction_id,
                    "completed_at": completed_at,
                    "transcript_path": "/tmp/fake/transcript.jsonl",
                    "response": "completed already, but inflight never cleared",
                }
            )
        )
        (run_dir / "inflight.json").write_text(
            json.dumps(
                {
                    "instruction_id": instruction_id,
                    "text": "do the thing",
                    "queued_at": "2026-04-08T00:13:00Z",
                    "submitted_at": "2026-04-08T00:13:01Z",
                }
            )
        )

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0, (
            f"watchdog --once failed on stale inflight reconcile: stderr={result.stderr!r}"
        )
        assert "reconciled stale completed inflight" in result.stderr
        assert not (run_dir / "inflight.json").exists(), (
            "watchdog did not clear stale inflight after matching response existed"
        )

        status_payload = json.loads((run_dir / "status.json").read_text())
        assert status_payload["state"] == "waiting_for_codex"
        assert status_payload["control_mode"] == "review"
        assert status_payload["instruction_id"] is None
        assert status_payload["updated_at"] == completed_at

        assert bridge_env["pending_review"].exists(), (
            "reconciled completed inflight must surface the pending review artifact"
        )
        pending_payload = json.loads(bridge_env["pending_review"].read_text())
        assert pending_payload["instruction_id"] == instruction_id
        assert pending_payload["completed_at"] == completed_at


# ---------------------------------------------------------------------------
# 2. Clearance when not waiting_for_codex
# ---------------------------------------------------------------------------


class TestPendingReviewClearance:
    def test_non_waiting_state_clears_pending_review_artifact(self, bridge_env):
        run_id = "run-20260408T002200Z-beefcafe"

        # First tick: seed waiting_for_codex to create the artifact.
        _seed_run(
            bridge_env,
            run_id=run_id,
            state="waiting_for_codex",
            response_payload={
                "instruction_id": "inst-pre",
                "completed_at": "2026-04-08T00:22:01Z",
                "transcript_path": "/tmp/fake/transcript.jsonl",
                "response": "first pass",
            },
            updated_at="2026-04-08T00:22:02Z",
        )
        first = _run_watchdog_once(bridge_env)
        assert first.returncode == 0
        assert bridge_env["pending_review"].exists(), (
            "setup failed: first tick must create the pending_review artifact"
        )

        # Second tick: overwrite status.json with a non-waiting state.
        (bridge_env["runs"] / run_id / "status.json").write_text(
            json.dumps({"state": "running", "updated_at": "2026-04-08T00:22:10Z"})
        )

        second = _run_watchdog_once(bridge_env)
        assert second.returncode == 0, (
            f"watchdog --once failed on clearance tick: stderr={second.stderr!r}"
        )

        assert not bridge_env["pending_review"].exists(), (
            "pending-review.json was not cleared when state left waiting_for_codex"
        )
        # The handoff flag should also be cleared on the same tick.
        assert not bridge_env["handoff_flag"].exists()

    def test_user_driving_is_handed_back_and_handoff_still_persists(self, bridge_env):
        run_id = "run-20260408T002240Z-handback"
        resume_script = bridge_env["braid"] / "resume.sh"
        resume_script.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "RUNS_DIR=\"${BRIDGE_RUNS_DIR:-$2}\"\n"
            "POINTER=\"${RUNS_DIR}/active-run\"\n"
            "RUN_ID=\"$(tr -d '[:space:]' < \"$POINTER\")\"\n"
            "STATUS_JSON=\"${RUNS_DIR}/${RUN_ID}/status.json\"\n"
            "jq '.control_mode = \"watching\"' \"$STATUS_JSON\" > \"${STATUS_JSON}.tmp\"\n"
            "mv \"${STATUS_JSON}.tmp\" \"$STATUS_JSON\"\n"
        )
        resume_script.chmod(0o755)

        _seed_run(
            bridge_env,
            run_id=run_id,
            state="waiting_for_codex",
            control_mode="user_driving",
            response_payload={
                "instruction_id": "inst-handback",
                "completed_at": "2026-04-08T00:22:41Z",
                "transcript_path": "/tmp/fake/transcript.jsonl",
                "response": "handback should preserve this review",
            },
            updated_at="2026-04-08T00:22:45Z",
        )

        tick = _run_watchdog_once(
            bridge_env,
            extra_env={"CLAUDEX_AUTO_HAND_BACK_USER_DRIVING": "1"},
        )
        assert tick.returncode == 0, (
            f"watchdog --once failed on user_driving handback: stderr={tick.stderr!r}"
        )

        status_payload = json.loads(
            (bridge_env["runs"] / run_id / "status.json").read_text()
        )
        assert status_payload["control_mode"] == "watching"
        assert bridge_env["pending_review"].exists()
        pending_payload = json.loads(bridge_env["pending_review"].read_text())
        assert pending_payload["instruction_id"] == "inst-handback"

    def test_no_active_run_does_not_create_pending_review(self, bridge_env):
        # No active-run pointer at all — the watchdog should exit cleanly
        # and must not create the artifact as a side effect.
        assert not (bridge_env["runs"] / "active-run").exists()

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0
        assert not bridge_env["pending_review"].exists()
        assert not bridge_env["handoff_flag"].exists()


# ---------------------------------------------------------------------------
# 3. bridge-status.sh surfaces the pending_review block
# ---------------------------------------------------------------------------


class TestBridgeStatusSurface:
    def test_status_script_prints_pending_review_when_artifact_exists(
        self, bridge_env
    ):
        run_id = "run-20260408T003300Z-deadbeef"
        instruction_id = "inst-status-surface"

        _seed_run(
            bridge_env,
            run_id=run_id,
            state="waiting_for_codex",
            response_payload={
                "instruction_id": instruction_id,
                "completed_at": "2026-04-08T00:33:10Z",
                "transcript_path": "/tmp/fake/transcript.jsonl",
                "response": "status script should see this",
            },
            updated_at="2026-04-08T00:33:15Z",
        )

        # Populate the artifact via a real watchdog tick so we exercise the
        # same code path users hit in production.
        tick = _run_watchdog_once(bridge_env)
        assert tick.returncode == 0
        assert bridge_env["pending_review"].exists()

        env = {**os.environ, "BRAID_ROOT": str(bridge_env["braid"]), "CLAUDEX_STATE_DIR": str(bridge_env["pid_dir"])}
        status = subprocess.run(
            ["bash", str(_STATUS)],
            cwd=str(bridge_env["repo"]),
            env=env,
            capture_output=True,
            text=True,
        )
        assert status.returncode == 0, (
            f"bridge-status.sh failed: stderr={status.stderr!r}"
        )
        stdout = status.stdout
        assert "--- pending_review ---" in stdout, (
            f"status script did not surface pending_review block:\n{stdout}"
        )
        assert run_id in stdout
        assert instruction_id in stdout

    def test_status_script_omits_pending_review_when_absent(self, bridge_env):
        # No seeding — no artifact, no pending_review block expected.
        env = {**os.environ, "BRAID_ROOT": str(bridge_env["braid"]), "CLAUDEX_STATE_DIR": str(bridge_env["pid_dir"])}
        status = subprocess.run(
            ["bash", str(_STATUS)],
            cwd=str(bridge_env["repo"]),
            env=env,
            capture_output=True,
            text=True,
        )
        assert status.returncode == 0
        assert "--- pending_review ---" not in status.stdout


# ---------------------------------------------------------------------------
# 4. Progress monitor + status observability
# ---------------------------------------------------------------------------


class TestProgressMonitorSurface:
    def test_empty_codex_pane_capture_is_alerted(self, bridge_env):
        _seed_run(
            bridge_env,
            run_id="run-progress-empty-pane",
            state="inflight",
            updated_at="2026-04-08T00:40:00Z",
        )

        tick = _run_progress_monitor_once(bridge_env, tmux_output="")
        assert tick.returncode == 0, (
            f"progress-monitor --once failed: stdout={tick.stdout!r} "
            f"stderr={tick.stderr!r}"
        )

        snapshot = json.loads(bridge_env["progress_snapshot"].read_text())
        assert snapshot["summary"] == "alert"
        assert snapshot["monitor_interval_seconds"] == 1800
        assert any(
            issue["code"] == "codex_pane_empty" for issue in snapshot["issues"]
        ), snapshot

    def test_stopped_codex_supervisor_is_alerted_while_run_active(self, bridge_env):
        _seed_run(
            bridge_env,
            run_id="run-progress-stopped-supervisor",
            state="queued",
            updated_at="2026-04-08T00:41:00Z",
        )

        tick = _run_progress_monitor_once(
            bridge_env,
            tmux_output="• Stop hook (stopped)\n",
        )
        assert tick.returncode == 0, (
            f"progress-monitor --once failed: stdout={tick.stdout!r} "
            f"stderr={tick.stderr!r}"
        )

        snapshot = json.loads(bridge_env["progress_snapshot"].read_text())
        assert snapshot["summary"] == "alert"
        assert any(
            issue["code"] == "codex_supervisor_stopped"
            for issue in snapshot["issues"]
        ), snapshot

    def test_open_interaction_gate_is_alerted(self, bridge_env):
        run_id = "run-progress-gate"
        run_dir = _seed_run(
            bridge_env,
            run_id=run_id,
            state="inflight",
            instruction_id="inst-gate",
            updated_at="2026-04-08T00:42:00Z",
        )
        (run_dir / "interaction-gate.json").write_text(
            json.dumps(
                {
                    "gate_id": "gate-1",
                    "status": "open",
                    "gate_type": "provider_overload",
                    "instruction_id": "inst-gate",
                    "tmux_target": "fake:1.2",
                    "prompt_excerpt": "API Error: overloaded_error",
                }
            )
        )

        tick = _run_progress_monitor_once(bridge_env, tmux_output="codex sees a gate")
        assert tick.returncode == 0, (
            f"progress-monitor --once failed: stdout={tick.stdout!r} "
            f"stderr={tick.stderr!r}"
        )

        snapshot = json.loads(bridge_env["progress_snapshot"].read_text())
        assert snapshot["summary"] == "alert"
        assert snapshot["bridge_state"] == "interaction_gate"
        assert any(
            issue["code"] == "interaction_gate_open" for issue in snapshot["issues"]
        ), snapshot

    def test_status_script_degrades_old_or_inconsistent_progress_snapshot(
        self, bridge_env
    ):
        run_id = "run-progress-health"
        instruction_id = "inst-progress-health"

        _seed_run(
            bridge_env,
            run_id=run_id,
            state="waiting_for_codex",
            response_payload={
                "instruction_id": instruction_id,
                "completed_at": "2026-04-08T00:41:10Z",
                "transcript_path": "/tmp/fake/transcript.jsonl",
                "response": "status script should treat old monitor truth as degraded",
            },
            updated_at="2026-04-08T00:41:15Z",
        )
        tick = _run_watchdog_once(bridge_env)
        assert tick.returncode == 0

        bridge_env["progress_snapshot"].write_text(
            json.dumps(
                {
                    "sampled_at": "2026-04-08T00:00:00Z",
                    "codex_target": "fake:1.1",
                    "monitor_interval_seconds": 300,
                    "active_run_id": run_id,
                    "bridge_state": "inflight",
                    "bridge_updated_at": "2026-04-08T00:00:00Z",
                    "latest_response_file": None,
                    "latest_response_instruction_id": None,
                    "pending_review_run_id": None,
                    "pending_review_instruction_id": None,
                    "codex_excerpt_hash": "1234",
                    "codex_excerpt": "working",
                    "issues": [],
                    "advancing": True,
                    "stale": False,
                    "summary": "healthy",
                }
            )
        )

        env = {**os.environ, "BRAID_ROOT": str(bridge_env["braid"]), "CLAUDEX_STATE_DIR": str(bridge_env["pid_dir"])}
        status = subprocess.run(
            ["bash", str(_STATUS)],
            cwd=str(bridge_env["repo"]),
            env=env,
            capture_output=True,
            text=True,
        )
        assert status.returncode == 0, (
            f"bridge-status.sh failed: stderr={status.stderr!r}"
        )
        stdout = status.stdout
        assert "progress_monitor_snapshot_age_ok: false" in stdout
        assert "progress_monitor_snapshot_state_match: false" in stdout
        assert "progress_monitor_snapshot_pending_review_match: false" in stdout
        assert "progress_monitor_snapshot_health: degraded" in stdout


# ---------------------------------------------------------------------------
class TestSupervisorAutoRecovery:
    def test_watchdog_restarts_supervisor_once_for_current_progress_alert(
        self, bridge_env
    ):
        run_id = "run-supervisor-alert"
        _install_fake_supervisor_restart(bridge_env)

        _seed_run(
            bridge_env,
            run_id=run_id,
            state="inflight",
            updated_at="2026-04-08T00:50:00Z",
        )
        bridge_env["progress_alert"].write_text(
            json.dumps(
                {
                    "sampled_at": "2026-04-08T00:50:01Z",
                    "codex_target": "fake:1.1",
                    "monitor_interval_seconds": 300,
                    "active_run_id": run_id,
                    "bridge_state": "inflight",
                    "bridge_updated_at": "2026-04-08T00:50:00Z",
                    "latest_response_file": None,
                    "latest_response_instruction_id": None,
                    "pending_review_run_id": None,
                    "pending_review_instruction_id": None,
                    "codex_excerpt_hash": None,
                    "codex_excerpt": "",
                    "issues": [{"code": "codex_pane_empty", "severity": "error"}],
                    "advancing": False,
                    "stale": False,
                    "summary": "alert",
                }
            )
        )

        first = _run_watchdog_once(bridge_env)
        assert first.returncode == 0, (
            f"watchdog --once failed during supervisor recovery: stderr={first.stderr!r}"
        )
        restart_lines = bridge_env["supervisor_recovery_log"].read_text().splitlines()
        assert restart_lines == ["--codex-target fake:1.1"]

        second = _run_watchdog_once(bridge_env)
        assert second.returncode == 0
        restart_lines = bridge_env["supervisor_recovery_log"].read_text().splitlines()
        assert restart_lines == ["--codex-target fake:1.1"], (
            "watchdog retried identical supervisor recovery without cooldown expiry"
        )

        recovery_state = json.loads(bridge_env["supervisor_recovery_state"].read_text())
        assert recovery_state["run_id"] == run_id
        assert recovery_state["codex_target"] == "fake:1.1"
        assert recovery_state["reason"] == "progress_alert:alert"
        assert recovery_state["status"] == "restarted"

    def test_watchdog_restarts_supervisor_for_stale_progress_snapshot(
        self, bridge_env
    ):
        run_id = "run-supervisor-stale-snapshot"
        _install_fake_supervisor_restart(bridge_env)

        _seed_run(
            bridge_env,
            run_id=run_id,
            state="inflight",
            updated_at="2026-04-08T01:00:00Z",
        )
        bridge_env["progress_snapshot"].write_text(
            json.dumps(
                {
                    "sampled_at": "2026-04-08T00:00:00Z",
                    "codex_target": "fake:1.1",
                    "monitor_interval_seconds": 300,
                    "active_run_id": run_id,
                    "bridge_state": "inflight",
                    "bridge_updated_at": "2026-04-08T00:00:00Z",
                    "latest_response_file": None,
                    "latest_response_instruction_id": None,
                    "pending_review_run_id": None,
                    "pending_review_instruction_id": None,
                    "codex_excerpt_hash": "1234",
                    "codex_excerpt": "working",
                    "issues": [],
                    "advancing": True,
                    "stale": False,
                    "summary": "healthy",
                }
            )
        )

        tick = _run_watchdog_once(bridge_env)
        assert tick.returncode == 0, (
            f"watchdog --once failed on stale snapshot recovery: stderr={tick.stderr!r}"
        )
        restart_lines = bridge_env["supervisor_recovery_log"].read_text().splitlines()
        assert restart_lines == ["--codex-target fake:1.1"]

        recovery_state = json.loads(bridge_env["supervisor_recovery_state"].read_text())
        assert recovery_state["reason"] == "progress_snapshot_stale"
        assert recovery_state["status"] == "restarted"


# ---------------------------------------------------------------------------
class TestDispatchStallDetection:
    def test_watchdog_marks_dispatch_stalled_when_queue_times_out_unclaimed(
        self, bridge_env
    ):
        run_id = "run-dispatch-stall"
        run_dir = _seed_run(
            bridge_env,
            run_id=run_id,
            state="queued",
            tmux_target="fake:1.2",
            instruction_id="inst-stalled",
            updated_at="2026-04-08T00:50:00Z",
        )
        (run_dir / "queue" / "inst-stalled.json").write_text(
            json.dumps(
                {
                    "instruction_id": "inst-stalled",
                    "text": "stalled instruction",
                    "queued_at": "2026-04-08T00:50:00Z",
                }
            )
        )
        bridge_env["auto_submit_log"].write_text(
            "\n".join(
                [
                    "[auto-submit] Queued work detected. Sending sentinel to fake:1.2",
                    "[auto-submit] Waiting for inflight to complete...",
                    "[auto-submit] Timeout waiting for inflight — sentinel may not have reached Claude.",
                ]
                * 4
            )
            + "\n"
        )

        tick = _run_watchdog_once(bridge_env)
        assert tick.returncode == 0, (
            f"watchdog --once failed on dispatch-stall tick: stderr={tick.stderr!r}"
        )
        assert bridge_env["dispatch_stall_state"].exists()
        payload = json.loads(bridge_env["dispatch_stall_state"].read_text())

        assert payload["state"] == "dispatch_stalled"
        assert payload["run_id"] == run_id
        assert payload["instruction_id"] == "inst-stalled"
        assert payload["tmux_target"] == "fake:1.2"
        assert payload["timeout_count"] >= 3

        env = {**os.environ, "BRAID_ROOT": str(bridge_env["braid"]), "CLAUDEX_STATE_DIR": str(bridge_env["pid_dir"])}
        status = subprocess.run(
            ["bash", str(_STATUS)],
            cwd=str(bridge_env["repo"]),
            env=env,
            capture_output=True,
            text=True,
        )
        assert status.returncode == 0
        assert "dispatch_stall_active: true" in status.stdout
        assert "dispatch_stall_instruction_match: true" in status.stdout
        assert "recovery_command: ./scripts/claudex-dispatch-recover.sh" in status.stdout

    def test_watchdog_recovers_dispatch_stall_once(self, bridge_env):
        run_id = "run-dispatch-recover"
        run_dir = _seed_run(
            bridge_env,
            run_id=run_id,
            state="queued",
            tmux_target="fake:1.2",
            instruction_id="inst-recover",
            updated_at="2026-04-08T00:55:00Z",
        )
        (run_dir / "queue" / "inst-recover.json").write_text(
            json.dumps(
                {
                    "instruction_id": "inst-recover",
                    "text": "recover this instruction",
                    "queued_at": "2026-04-08T00:55:00Z",
                }
            )
        )
        bridge_env["auto_submit_log"].write_text(
            "\n".join(
                [
                    "[auto-submit] Queued work detected. Sending sentinel to fake:1.2",
                    "[auto-submit] Waiting for inflight to complete...",
                    "[auto-submit] Timeout waiting for inflight — sentinel may not have reached Claude.",
                ]
                * 4
            )
            + "\n"
        )
        _install_fake_dispatch_recovery(bridge_env)

        first = _run_watchdog_once(bridge_env)
        assert first.returncode == 0, (
            f"watchdog --once failed on dispatch recovery: stderr={first.stderr!r}"
        )
        assert bridge_env["dispatch_recovery_log"].read_text().splitlines() == [
            "--run-id run-dispatch-recover"
        ]

        second = _run_watchdog_once(bridge_env)
        assert second.returncode == 0
        assert bridge_env["dispatch_recovery_log"].read_text().splitlines() == [
            "--run-id run-dispatch-recover"
        ]

        recovery_state = json.loads(bridge_env["dispatch_recovery_state"].read_text())
        assert recovery_state["run_id"] == run_id
        assert recovery_state["instruction_id"] == "inst-recover"
        assert recovery_state["reason"] == "dispatch_stalled"
        assert recovery_state["status"] == "recovered"


# ---------------------------------------------------------------------------
# 5. Refresh semantics: pending-review.json must track the LATEST response
#    file for the active run, even when the handoff flag does not change.
#
# Regression rationale: the repo-local bridge was observed with
# ``pending-review.json`` lagging behind a newer Claude response while
# state remained ``waiting_for_codex``. A correct watchdog must re-pick
# the latest response file on every tick that sees ``waiting_for_codex``,
# not only on ticks where the handoff flag's (run_id, updated_at) pair
# has advanced.
# ---------------------------------------------------------------------------


class TestPendingReviewRefreshWithinSameState:
    def test_refreshes_when_newer_response_lands_in_same_waiting_state(
        self, bridge_env
    ):
        run_id = "run-refresh"

        # First tick: seed an initial "old" response. The default
        # _seed_run helper writes `0001-resp.json`; we rename it so that
        # its filename sorts *before* the new response we add below
        # (the watchdog picks the lexicographically last response file).
        _seed_run(
            bridge_env,
            run_id=run_id,
            state="waiting_for_codex",
            response_payload={
                "instruction_id": "inst-AAAA-old",
                "completed_at": "2026-04-08T00:00:00Z",
                "transcript_path": "/tmp/fake/transcript.jsonl",
                "response": "old response content",
            },
            updated_at="2026-04-08T00:00:10Z",
        )
        responses_dir = bridge_env["runs"] / run_id / "responses"
        (responses_dir / "0001-resp.json").rename(
            responses_dir / "1000000000-AAAA.json"
        )

        first = _run_watchdog_once(bridge_env)
        assert first.returncode == 0

        first_payload = json.loads(bridge_env["pending_review"].read_text())
        assert first_payload["instruction_id"] == "inst-AAAA-old"

        # Now a NEWER response lands for the same active run. Crucially,
        # status.json is NOT updated — updated_at stays at 00:00:10Z so
        # ``touch_handoff_flag`` is a no-op this tick. The watchdog must
        # still refresh ``pending-review.json`` to reflect the new file.
        (responses_dir / "2000000000-BBBB.json").write_text(
            json.dumps(
                {
                    "instruction_id": "inst-BBBB-new",
                    "completed_at": "2026-04-08T00:00:20Z",
                    "transcript_path": "/tmp/fake/transcript.jsonl",
                    "response": "new response content",
                }
            )
        )

        second = _run_watchdog_once(bridge_env)
        assert second.returncode == 0, (
            f"watchdog --once failed on refresh tick: stderr={second.stderr!r}"
        )

        second_payload = json.loads(bridge_env["pending_review"].read_text())
        assert second_payload["instruction_id"] == "inst-BBBB-new", (
            "pending-review.json did not refresh to the newer response: "
            f"{second_payload}"
        )
        assert second_payload["completed_at"] == "2026-04-08T00:00:20Z"
        assert (
            second_payload["response_path"]
            == str(responses_dir / "2000000000-BBBB.json")
        )
        assert "new response content" in second_payload["response_preview"]


# ---------------------------------------------------------------------------
# 6. Long-running self-exec on script drift
#
# This is the test that covers the active-run regression class: a
# long-running watchdog had been started before the pending-review
# persistence logic was added, and bash kept executing the stale
# in-memory function table, so ``pending-review.json`` was never written
# even though ``touch_handoff_flag`` ran on every tick.
#
# The fix (DEC-CLAUDEX-BRIDGE-SELF-EXEC-001) makes the watchdog detect
# that its own script file was modified since it was loaded and re-exec
# itself to pick up the new code. This test starts a real background
# bash watchdog pointed at a *copy* of claudex-watchdog.sh whose
# ``write_pending_review`` function has been neutered, verifies that
# pending-review.json does NOT appear under the stale version, then
# overwrites the script with the real full version and waits for the
# watchdog to re-exec and produce the artifact.
# ---------------------------------------------------------------------------


def _wait_until(predicate, *, timeout: float, description: str) -> None:
    """Busy-wait with polling until ``predicate`` returns truthy or timeout."""
    import time as _t

    deadline = _t.time() + timeout
    while _t.time() < deadline:
        if predicate():
            return
        _t.sleep(0.1)
    raise AssertionError(f"timed out after {timeout}s waiting for {description}")


def _make_neutered_watchdog(real_script_text: str) -> str:
    """Return a copy of the watchdog script with ``write_pending_review``
    replaced by a no-op that keeps the rest of the control flow intact.
    """
    import re

    # The function's closing brace is the first `}` at column 0 after the
    # function signature. All inner `}` characters are either inside
    # single-quoted jq expressions or indented.
    pattern = re.compile(
        r"write_pending_review\(\) \{.*?\n\}",
        re.DOTALL,
    )
    neutered = pattern.sub(
        "write_pending_review() {\n"
        "  # NEUTERED FOR TEST — DEC-CLAUDEX-BRIDGE-SELF-EXEC-001\n"
        "  return 0\n"
        "}",
        real_script_text,
        count=1,
    )
    assert neutered != real_script_text, (
        "regex did not neuter write_pending_review — script shape changed"
    )
    # Sanity: the marker comment must survive.
    assert "NEUTERED FOR TEST" in neutered
    return neutered


class TestWatchdogSelfExecOnScriptDrift:
    def test_long_running_watchdog_reexecs_when_script_file_changes(
        self, bridge_env
    ):
        real_script_text = Path(_WATCHDOG).read_text()
        neutered_text = _make_neutered_watchdog(real_script_text)

        # Place a writable copy of the script inside the fake braid dir
        # so we can overwrite it without perturbing the repo tree. We use
        # the same short-path directory we already rely on for the
        # AF_UNIX socket. The watchdog sources claudex-common.sh from its
        # own directory (see scripts/claudex-watchdog.sh:37), so the lib
        # must be copied alongside the script copy for the sourced path
        # to resolve under set -e.
        script_copy = bridge_env["braid"] / "watchdog-under-test.sh"
        script_copy.write_text(neutered_text)
        script_copy.chmod(0o755)
        common_lib_src = _REPO_ROOT / "scripts" / "claudex-common.sh"
        shutil.copyfile(
            common_lib_src, bridge_env["braid"] / "claudex-common.sh"
        )

        # Seed a complete waiting_for_codex run. The neutered watchdog
        # should still advance the handoff flag but must not write
        # pending-review.json while the stale code is running.
        run_id = "run-self-exec"
        _seed_run(
            bridge_env,
            run_id=run_id,
            state="waiting_for_codex",
            response_payload={
                "instruction_id": "inst-self-exec",
                "completed_at": "2026-04-08T00:00:00Z",
                "transcript_path": "/tmp/fake/transcript.jsonl",
                "response": "self-exec payload",
            },
            updated_at="2026-04-08T00:00:05Z",
        )

        env = {
            **os.environ,
            "BRAID_ROOT": str(bridge_env["braid"]),
            "CLAUDEX_STATE_DIR": str(bridge_env["pid_dir"]),
            # Tight poll so the test runs fast.
            "CLAUDEX_WATCHDOG_POLL_INTERVAL": "1",
        }

        proc = subprocess.Popen(
            ["bash", str(script_copy)],
            cwd=str(bridge_env["repo"]),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            # Wait for at least one tick of the neutered code. The
            # handoff flag is proof that the script is actively ticking.
            _wait_until(
                lambda: bridge_env["handoff_flag"].exists(),
                timeout=6.0,
                description="handoff flag to appear under neutered watchdog",
            )

            # With the neutered write_pending_review, the artifact must
            # NOT exist yet, even though the handoff flag does. This is
            # the exact symptom the repo-local bridge was showing.
            assert not bridge_env["pending_review"].exists(), (
                "neutered v1 watchdog should not have written "
                "pending-review.json"
            )

            # Ensure the overwrite bumps the mtime in a way even a
            # 1-second-granularity stat will notice. On some filesystems
            # a write that lands in the same second as the previous
            # write leaves mtime unchanged.
            import time as _t

            _t.sleep(1.2)
            script_copy.write_text(real_script_text)
            script_copy.chmod(0o755)
            # Belt-and-suspenders: explicitly set mtime to now.
            os.utime(str(script_copy), None)

            # Wait for the self-exec to fire on the next tick and for
            # the re-exec'd watchdog to write pending-review.json.
            _wait_until(
                lambda: bridge_env["pending_review"].exists(),
                timeout=10.0,
                description=(
                    "pending-review.json to appear after script self-exec"
                ),
            )

            payload = json.loads(bridge_env["pending_review"].read_text())
            assert payload["run_id"] == run_id
            assert payload["instruction_id"] == "inst-self-exec"
            assert payload["response_available"] is True
            assert payload["response_preview"].strip() != ""
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)


# Cleanup is handled by the bridge_env fixture via shutil.rmtree on the
# fake_braid tempdir; the fake_repo tree is cleaned by pytest's tmp_path.


# ---------------------------------------------------------------------------
# expire_stale_dispatch_attempts: watchdog sweep integration
# ---------------------------------------------------------------------------

pytestmark_skip_no_python = pytest.mark.skipif(
    shutil.which("python3") is None,
    reason="expire_stale_dispatch_attempts requires python3",
)


def _make_state_db(bridge_env: dict):
    """Create .claude/state.db with Phase 2b schema in the fake repo."""
    import sqlite3 as _sqlite3
    import sys as _sys
    import os as _os

    # Ensure runtime package is importable (same sys.path the subprocess uses).
    repo = Path(__file__).resolve().parent.parent.parent
    env_path = _os.environ.get("PYTHONPATH", "")
    if str(repo) not in env_path.split(":"):
        import sys
        if str(repo) not in sys.path:
            sys.path.insert(0, str(repo))

    from runtime.schemas import ensure_schema

    db_path = bridge_env["repo"] / ".claude" / "state.db"
    conn = _sqlite3.connect(str(db_path))
    conn.row_factory = _sqlite3.Row
    ensure_schema(conn)
    conn.close()
    return db_path


def _insert_pending_attempt(db_path, *, timeout_at: int):
    """Insert a minimal pending dispatch_attempts row via dispatch_hook."""
    import sqlite3 as _sqlite3

    repo = Path(__file__).resolve().parent.parent.parent
    import sys
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))

    from runtime.schemas import ensure_schema
    from runtime.core.dispatch_hook import record_agent_dispatch

    conn = _sqlite3.connect(str(db_path))
    conn.row_factory = _sqlite3.Row
    ensure_schema(conn)
    row = record_agent_dispatch(
        conn, "sess-wdg-01", "general-purpose", "stale wdg task",
        timeout_at=timeout_at,
    )
    conn.close()
    return row


def _read_attempt_status(db_path, attempt_id: str) -> str:
    import sqlite3 as _sqlite3

    conn = _sqlite3.connect(str(db_path))
    conn.row_factory = _sqlite3.Row
    row = conn.execute(
        "SELECT status FROM dispatch_attempts WHERE attempt_id = ?", (attempt_id,)
    ).fetchone()
    conn.close()
    return row["status"] if row else "NOT_FOUND"


class TestExpireStaleDispatchAttempts:
    def test_no_db_does_not_fail(self, bridge_env):
        """Watchdog tick succeeds even when state.db does not exist."""
        db = bridge_env["repo"] / ".claude" / "state.db"
        assert not db.exists()

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0, (
            f"watchdog failed with no state.db: stderr={result.stderr!r}"
        )

    def test_stale_pending_attempt_transitioned_to_timed_out(self, bridge_env):
        """A pending attempt with past timeout_at is marked timed_out by watchdog tick."""
        import time as _time

        db_path = _make_state_db(bridge_env)
        past = int(_time.time()) - 3600
        row = _insert_pending_attempt(db_path, timeout_at=past)
        attempt_id = row["attempt_id"]

        assert _read_attempt_status(db_path, attempt_id) == "pending"

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0, (
            f"watchdog failed: stderr={result.stderr!r}"
        )

        assert _read_attempt_status(db_path, attempt_id) == "timed_out"

    def test_future_timeout_attempt_not_expired(self, bridge_env):
        """A pending attempt with future timeout_at is NOT expired by the watchdog tick."""
        import time as _time

        db_path = _make_state_db(bridge_env)
        future = int(_time.time()) + 3600
        row = _insert_pending_attempt(db_path, timeout_at=future)
        attempt_id = row["attempt_id"]

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0

        assert _read_attempt_status(db_path, attempt_id) == "pending"

    def test_stale_attempt_logged(self, bridge_env):
        """Watchdog logs a message when it expires at least one attempt."""
        import time as _time

        db_path = _make_state_db(bridge_env)
        past = int(_time.time()) - 3600
        _insert_pending_attempt(db_path, timeout_at=past)

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0
        assert "expired" in result.stderr and "stale dispatch attempt" in result.stderr

    def test_no_stale_attempt_no_log_noise(self, bridge_env):
        """Watchdog does not log an expire message when nothing is stale."""
        db_path = _make_state_db(bridge_env)
        # No stale attempts seeded.

        result = _run_watchdog_once(bridge_env)
        assert result.returncode == 0
        assert "stale dispatch attempt" not in result.stderr

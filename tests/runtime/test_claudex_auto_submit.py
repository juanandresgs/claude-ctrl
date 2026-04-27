"""Focused subprocess tests for ``scripts/claudex-auto-submit.sh``.

These tests pin the readiness gate that prevents the bridge from typing
``__BRAID_RELAY__`` into the worker pane before Claude is actually ready to
consume it as a submitted prompt.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest


_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_AUTO_SUBMIT = _REPO_ROOT / "scripts" / "claudex-auto-submit.sh"


pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None or shutil.which("jq") is None,
    reason="claudex-auto-submit.sh requires bash and jq",
)


@pytest.fixture
def auto_submit_env(tmp_path):
    fake_braid = tmp_path / "fake-braid"
    run_dir = fake_braid / "runs" / "run-1"
    queue_dir = run_dir / "queue"
    queue_dir.mkdir(parents=True)
    (fake_braid / "runs" / "active-run").write_text("run-1\n")
    (run_dir / "run.json").write_text(
        json.dumps(
            {
                "run_id": "run-1",
                "project_root": str(_REPO_ROOT),
                "project_slug": "claude-ctrl",
                "tmux_target": "fake:1.2",
                "created_at": "2026-04-10T00:00:00Z",
                "completed_at": None,
            }
        )
    )
    (run_dir / "status.json").write_text(
        json.dumps(
            {
                "state": "queued",
                "control_mode": "supervised",
                "instruction_id": "iid-1",
                "updated_at": "2026-04-10T00:00:00Z",
            }
        )
    )
    (queue_dir / "iid-1.json").write_text(
        json.dumps(
            {
                "instruction_id": "iid-1",
                "text": "hello from queue",
                "queued_at": "2026-04-10T00:00:00Z",
            }
        )
    )

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    send_log = tmp_path / "tmux-send.log"
    fake_tmux = fake_bin / "tmux"
    fake_tmux.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "case \"${1:-}\" in\n"
        "  has-session)\n"
        "    exit 0\n"
        "    ;;\n"
        "  display-message)\n"
        "    printf '%s' \"${CLAUDEX_FAKE_TMUX_COMMAND:-}\"\n"
        "    ;;\n"
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

    state_dir = fake_braid / "state"
    state_dir.mkdir()
    env = {
        **os.environ,
        "BRAID_ROOT": str(fake_braid),
        "CLAUDEX_STATE_DIR": str(state_dir),
        "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
        "CLAUDEX_FAKE_TMUX_SEND_LOG": str(send_log),
    }
    return {
        "env": env,
        "run_dir": run_dir,
        "send_log": send_log,
        "state_dir": state_dir,
    }


def _run_once(auto_submit_env, *, command: str, capture: str) -> subprocess.CompletedProcess:
    env = {
        **auto_submit_env["env"],
        "CLAUDEX_FAKE_TMUX_COMMAND": command,
        "CLAUDEX_FAKE_TMUX_CAPTURE": capture,
    }
    return subprocess.run(
        ["bash", str(_AUTO_SUBMIT), "--once"],
        cwd=str(_REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_once_does_not_send_when_worker_is_still_shell(auto_submit_env):
    result = _run_once(
        auto_submit_env,
        command="zsh",
        capture='export BRAID_ROOT="/tmp/x"; ./scripts/claudex-claude-launch.sh\n',
    )
    assert result.returncode == 0
    assert not auto_submit_env["send_log"].exists()
    assert "not ready for relay yet" in result.stderr


def test_once_submits_when_relay_prompt_is_already_present(auto_submit_env):
    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture="Claude Code v2.1.100\n❯ __BRAID_RELAY__\n",
    )
    assert result.returncode == 0
    assert auto_submit_env["send_log"].read_text().strip().endswith(
        "send-keys -t fake:1.2 Enter"
    )
    assert "Relay prompt is still live in fake:1.2; submitting it in place." in result.stderr


def test_once_does_not_re_nudge_lodged_prompt_within_backoff_window(auto_submit_env):
    (auto_submit_env["run_dir"] / "auto-submit-enter.state.json").write_text(
        json.dumps(
            {
                "instruction_id": "iid-1",
                "sent_at_epoch": 4102444799,
            }
        )
    )

    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture="Claude Code v2.1.100\n❯ __BRAID_RELAY__\n",
    )

    assert result.returncode == 0
    assert not auto_submit_env["send_log"].exists()
    assert "Submit nudge already sent recently for iid-1" in result.stderr


def test_once_ignores_historical_relay_text_when_live_prompt_is_empty(auto_submit_env):
    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture=(
            "Claude Code v2.1.100\n"
            "❯ __BRAID_RELAY__\n"
            "Slice 0040 — PASS.\n"
            "The second __BRAID_RELAY__ carried no instruction payload.\n"
            "❯ \n"
            "  ⏵⏵ bypass permissions on\n"
        ),
    )
    assert result.returncode == 0
    assert auto_submit_env["send_log"].read_text().strip().endswith(
        "send-keys -t fake:1.2 __BRAID_RELAY__ Enter"
    )
    assert "Queued work detected. Sending sentinel to fake:1.2" in result.stderr


def test_once_does_not_send_when_claude_has_queued_messages(auto_submit_env):
    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture=(
            "Claude Code v2.1.100\n"
            "❯ __BRAID_RELAY__\n"
            "⏺ Standing by.\n"
            "❯ \n"
            "Press up to edit queued messages\n"
            "  ⏵⏵ bypass permissions on\n"
        ),
    )

    assert result.returncode == 0
    assert not auto_submit_env["send_log"].exists()
    assert "Relay prompt already present" in result.stderr


def test_once_ignores_historical_queued_messages_footer_outside_live_prompt_region(
    auto_submit_env,
):
    history = "".join(f"history line {i:02d}\n" for i in range(45))
    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture=(
            "Claude Code v2.1.100\n"
            "❯ __BRAID_RELAY__\n"
            "⏺ Standing by.\n"
            "❯ Press up to edit queued messages\n"
            f"{history}"
            "Slice 0041 - PASS.\n"
            "❯ \n"
            "  ⏵⏵ bypass permissions on\n"
        ),
    )

    assert result.returncode == 0
    assert auto_submit_env["send_log"].read_text().strip().endswith(
        "send-keys -t fake:1.2 __BRAID_RELAY__ Enter"
    )
    assert "Queued work detected. Sending sentinel to fake:1.2" in result.stderr


def test_once_sends_when_worker_prompt_is_ready(auto_submit_env):
    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture="Claude Code v2.1.100\n❯ \n  ⏵⏵ bypass permissions on\n",
    )
    assert result.returncode == 0
    assert auto_submit_env["send_log"].read_text().strip().endswith(
        "send-keys -t fake:1.2 __BRAID_RELAY__ Enter"
    )
    assert "Queued work detected. Sending sentinel to fake:1.2" in result.stderr


def test_once_does_not_resend_same_instruction_within_backoff_window(auto_submit_env):
    (auto_submit_env["run_dir"] / "auto-submit.state.json").write_text(
        json.dumps(
            {
                "instruction_id": "iid-1",
                "sent_at_epoch": 4102444799,
            }
        )
    )

    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture="Claude Code v2.1.100\n❯ \n  ⏵⏵ bypass permissions on\n",
    )

    assert result.returncode == 0
    assert not auto_submit_env["send_log"].exists()
    assert "Relay already sent recently for iid-1" in result.stderr


def test_once_pauses_when_open_interaction_gate_exists(auto_submit_env):
    (auto_submit_env["run_dir"] / "interaction-gate.json").write_text(
        json.dumps(
            {
                "gate_id": "gate-1",
                "status": "open",
                "gate_type": "provider_overload",
                "instruction_id": "iid-1",
                "tmux_target": "fake:1.2",
            }
        )
    )

    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture="Claude Code v2.1.100\n❯ \n  ⏵⏵ bypass permissions on\n",
    )

    assert result.returncode == 0
    assert not auto_submit_env["send_log"].exists()
    assert "Open interaction gate (provider_overload)" in result.stderr


def test_once_recovers_stale_inflight_with_existing_response(auto_submit_env):
    run_dir = auto_submit_env["run_dir"]
    (run_dir / "inflight.json").write_text(
        json.dumps(
            {
                "instruction_id": "iid-1",
                "text": "already responded",
                "queued_at": "2026-04-10T00:00:00Z",
                "submitted_at": "2026-04-10T00:01:00Z",
            }
        )
    )
    responses_dir = run_dir / "responses"
    responses_dir.mkdir()
    (responses_dir / "iid-1.json").write_text(json.dumps({"instruction_id": "iid-1"}))

    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture="Claude Code v2.1.100\n❯ \n  ⏵⏵ bypass permissions on\n",
    )

    assert result.returncode == 0
    assert not (run_dir / "inflight.json").exists()
    assert not (run_dir / "queue" / "iid-1.json").exists()
    assert (run_dir / "recovery" / "stale-inflight" / "iid-1.json").exists()
    assert (run_dir / "recovery" / "stale-queued" / "iid-1.json").exists()
    status = json.loads((run_dir / "status.json").read_text())
    assert status["state"] == "waiting_for_codex"
    assert status["control_mode"] == "review"
    assert status["instruction_id"] is None
    assert "Recovered stale inflight iid-1" in result.stderr


def test_once_archives_stale_queued_head_with_existing_response(auto_submit_env):
    run_dir = auto_submit_env["run_dir"]
    queue_dir = run_dir / "queue"
    (queue_dir / "iid-2.json").write_text(
        json.dumps(
            {
                "instruction_id": "iid-2",
                "text": "next real work",
                "queued_at": "2026-04-10T00:02:00Z",
            }
        )
    )
    responses_dir = run_dir / "responses"
    responses_dir.mkdir()
    (responses_dir / "iid-1.json").write_text(json.dumps({"instruction_id": "iid-1"}))

    result = _run_once(
        auto_submit_env,
        command="2.1.100",
        capture="Claude Code v2.1.100\n❯ \n  ⏵⏵ bypass permissions on\n",
    )

    assert result.returncode == 0
    assert not (queue_dir / "iid-1.json").exists()
    assert (run_dir / "recovery" / "stale-queued" / "iid-1.json").exists()
    assert auto_submit_env["send_log"].read_text().strip().endswith(
        "send-keys -t fake:1.2 __BRAID_RELAY__ Enter"
    )
    state = json.loads((run_dir / "auto-submit.state.json").read_text())
    assert state["instruction_id"] == "iid-2"
    assert "Archived 1 stale queued entry" in result.stderr



def test_long_running_auto_submit_exits_on_sigterm_and_releases_singleton(auto_submit_env):
    env = {
        **auto_submit_env["env"],
        "CLAUDEX_FAKE_TMUX_COMMAND": "zsh",
        "CLAUDEX_FAKE_TMUX_CAPTURE": "shell not ready",
        "CLAUDEX_AUTO_SUBMIT_INTERVAL": "10",
    }
    proc = subprocess.Popen(
        ["bash", str(_AUTO_SUBMIT)],
        cwd=str(_REPO_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.time() + 3
        pid_file = auto_submit_env["state_dir"] / "auto-submit.pid"
        while time.time() < deadline and not pid_file.exists():
            time.sleep(0.05)
        assert pid_file.exists(), "auto-submit did not publish pid file"
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            raise AssertionError("auto-submit swallowed SIGTERM and kept running")
        assert proc.returncode == 143
        assert not pid_file.exists()
        assert not (auto_submit_env["state_dir"] / "auto-submit.lock.d").exists()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=3)


def test_long_running_auto_submit_exits_when_singleton_lock_is_reassigned(
    auto_submit_env,
):
    env = {
        **auto_submit_env["env"],
        "CLAUDEX_FAKE_TMUX_COMMAND": "zsh",
        "CLAUDEX_FAKE_TMUX_CAPTURE": "shell not ready",
        "BRIDGE_POLL_INTERVAL": "1",
    }
    proc = subprocess.Popen(
        ["bash", str(_AUTO_SUBMIT)],
        cwd=str(_REPO_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        state_dir = auto_submit_env["state_dir"]
        pid_file = state_dir / "auto-submit.pid"
        lock_pid_file = Path(auto_submit_env["env"]["BRAID_ROOT"]) / "runs" / ".auto-submit.lock.d" / "pid"

        deadline = time.time() + 3
        while time.time() < deadline and (not pid_file.exists() or not lock_pid_file.exists()):
            time.sleep(0.05)
        assert pid_file.exists(), "auto-submit did not publish pid file"
        assert lock_pid_file.exists(), "auto-submit did not publish lock owner"

        lock_pid_file.write_text(f"{os.getpid()}\n")

        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            raise AssertionError("auto-submit kept running after losing singleton ownership")

        assert proc.returncode == 0
        stderr = (proc.stderr.read() if proc.stderr is not None else "") or ""
        assert "Lost singleton lock" in stderr
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=3)


def test_launchers_delegate_auto_submit_lifecycle_to_watchdog() -> None:
    bridge_up = (_REPO_ROOT / "scripts" / "claudex-bridge-up.sh").read_text()
    overnight_start = (_REPO_ROOT / "scripts" / "claudex-overnight-start.sh").read_text()

    assert 'nohup "$AUTO_SUBMIT_SCRIPT"' not in bridge_up
    assert 'bash ./scripts/claudex-auto-submit.sh' not in overnight_start
    assert 'nohup "${ROOT}/scripts/claudex-watchdog.sh"' in bridge_up
    assert 'bash ./scripts/claudex-watchdog.sh --tmux-target' in overnight_start
    assert 'watchdog.pid' in overnight_start

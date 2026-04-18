import json
import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts" / "claudex-common.sh"


def _helper(function_name: str, root: Path, braid_root: Path) -> str:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            f'. "{HELPER}"; {function_name} "{root}" "{braid_root}"',
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _helper3(
    function_name: str,
    root: Path,
    explicit: str = "",
    state_dir_hint: str = "",
) -> str:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'. "{HELPER}"; '
                f'{function_name} "{root}" "{explicit}" "{state_dir_hint}"'
            ),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def test_default_repo_lane_uses_shared_state_dir(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    root.mkdir()

    assert _helper("claudex_state_dir", root, root / ".b2r") == str(root / ".claude" / "claudex")


def test_named_b2r_lane_gets_isolated_state_dir(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    root.mkdir()

    assert _helper("claudex_state_dir", root, root / ".b2r-v2-stable") == str(
        root / ".claude" / "claudex" / "b2r-v2-stable"
    )


def test_external_non_b2r_root_stays_on_shared_state_dir(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    root.mkdir()
    external = tmp_path / "external-braid-root"
    external.mkdir()

    assert _helper("claudex_state_dir", root, external) == str(root / ".claude" / "claudex")


def test_resolve_braid_root_uses_single_named_lane_hint(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    lane_dir = root / ".claude" / "claudex" / "b2r-v2-stable"
    lane_dir.mkdir(parents=True)
    hinted_braid = tmp_path / "braid-v2-stable"
    hinted_braid.mkdir()
    (lane_dir / "braid-root").write_text(f"{hinted_braid}\n")

    assert _helper3("claudex_resolve_braid_root", root) == str(hinted_braid)


def test_supervisor_restart_resolves_codex_target_without_explicit_flag(
    tmp_path: Path,
) -> None:
    braid_root = tmp_path / "braid"
    state_dir = tmp_path / "state"
    run_dir = braid_root / "runs" / "run-supervisor-restart"
    fake_bin = tmp_path / "bin"
    fake_tmux = fake_bin / "tmux"

    run_dir.mkdir(parents=True)
    state_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)

    (braid_root / "runs" / "active-run").write_text("run-supervisor-restart\n")
    (run_dir / "run.json").write_text(
        json.dumps(
            {
                "run_id": "run-supervisor-restart",
                "project_root": str(REPO_ROOT),
                "project_slug": "claudex-cutover-soak",
                "tmux_target": "fake:1.2",
                "claude_pane_id": "%12",
                "codex_target": "fake:1.1",
                "codex_pane_id": "%11",
                "created_at": "2026-04-18T00:00:00Z",
                "completed_at": None,
            }
        )
    )
    (run_dir / "status.json").write_text(
        json.dumps(
            {
                "state": "waiting_for_codex",
                "control_mode": "review",
                "instruction_id": None,
                "updated_at": "2026-04-18T00:00:00Z",
            }
        )
    )

    fake_tmux.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "cmd=\"${1:-}\"\n"
        "case \"$cmd\" in\n"
        "  display-message)\n"
        "    target=\"${4:-}\"\n"
        "    fmt=\"${5:-}\"\n"
        "    if [[ \"$fmt\" == '#{pane_id}' ]]; then\n"
        "      case \"$target\" in\n"
        "        fake:1.1) printf '%%11\\n' ;;\n"
        "        fake:1.2) printf '%%12\\n' ;;\n"
        "        *) exit 1 ;;\n"
        "      esac\n"
        "      exit 0\n"
        "    fi\n"
        "    if [[ \"$fmt\" == '#{session_name}:#{window_index}.#{pane_index}' ]]; then\n"
        "      case \"$target\" in\n"
        "        %11) printf 'fake:1.1\\n' ;;\n"
        "        %12) printf 'fake:1.2\\n' ;;\n"
        "        *) exit 1 ;;\n"
        "      esac\n"
        "      exit 0\n"
        "    fi\n"
        "    exit 1\n"
        "    ;;\n"
        "  list-panes)\n"
        "    case \"${3:-}\" in\n"
        "      fake:1.1|fake:1.2) printf '0\\n' ;;\n"
        "      *) exit 1 ;;\n"
        "    esac\n"
        "    ;;\n"
        "  *)\n"
        "    exit 64\n"
        "    ;;\n"
        "esac\n"
    )
    fake_tmux.chmod(0o755)

    env = {
        **os.environ,
        "BRAID_ROOT": str(braid_root),
        "CLAUDEX_STATE_DIR": str(state_dir),
        "CLAUDEX_RUNTIME_CLI": str(REPO_ROOT / "runtime" / "cli.py"),
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
        "PYTHONPATH": (
            f"{REPO_ROOT}{os.pathsep}{os.environ['PYTHONPATH']}"
            if os.environ.get("PYTHONPATH")
            else str(REPO_ROOT)
        ),
    }

    result = subprocess.run(
        [
            "bash",
            "scripts/claudex-supervisor-restart.sh",
            "--dry-run",
            "--no-monitor",
            "--no-approver",
            "--no-worker-approver",
            "--no-transport",
        ],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "codex_target: fake:1.1" in result.stdout
    assert "session: fake" in result.stdout


def test_codex_approver_ignores_model_upgrade_prompt_when_existing_option_is_offscreen() -> None:
    prompt = (
        "Introducing GPT-5.4\n\n"
        "Choose how you'd like Codex to proceed.\n\n"
        "1. Try new model\n"
    )

    result = subprocess.run(
        [
            "bash",
            "scripts/claudex-codex-approver.sh",
            "--classify-stdin",
        ],
        cwd=REPO_ROOT,
        input=prompt,
        capture_output=True,
        text=True,
        check=True,
    )

    assert result.stdout.strip() == "ignore"


def test_codex_model_guard_handles_offscreen_existing_model_prompt(
    tmp_path: Path,
) -> None:
    fake_bin = tmp_path / "bin"
    fake_tmux = fake_bin / "tmux"
    send_log = tmp_path / "tmux-send.log"
    fake_bin.mkdir(parents=True)

    fake_tmux.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "case \"${1:-}\" in\n"
        "  list-panes)\n"
        "    exit 0\n"
        "    ;;\n"
        "  capture-pane)\n"
        "    cat <<'EOF'\n"
        "Introducing GPT-5.4\n"
        "\n"
        "Choose how you'd like Codex to proceed.\n"
        "\n"
        "1. Try new model\n"
        "EOF\n"
        "    ;;\n"
        "  select-pane)\n"
        "    printf '%s\\n' \"$*\" >> \"${CLAUDEX_FAKE_TMUX_SEND_LOG}\"\n"
        "    ;;\n"
        "  send-keys)\n"
        "    printf '%s\\n' \"$*\" >> \"${CLAUDEX_FAKE_TMUX_SEND_LOG}\"\n"
        "    ;;\n"
        "  *)\n"
        "    exit 0\n"
        "    ;;\n"
        "esac\n"
    )
    fake_tmux.chmod(0o755)

    env = {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
        "CLAUDEX_FAKE_TMUX_SEND_LOG": str(send_log),
        "CLAUDEX_CODEX_MODEL_GUARD_TIMEOUT_SECONDS": "1",
        "CLAUDEX_CODEX_MODEL_GUARD_POLL_SECONDS": "0.1",
        "CLAUDEX_CODEX_MODEL_GUARD_RETRY_SECONDS": "999",
    }

    result = subprocess.run(
        [
            "bash",
            "scripts/claudex-codex-model-guard.sh",
            "fake:1.1",
        ],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    logged = send_log.read_text()
    assert "select-pane -t fake:1.1 -e" in logged
    assert "send-keys -t fake:1.1 Down" in logged
    assert "send-keys -t fake:1.1 Enter" in logged


def test_overnight_start_detaches_helper_daemons_before_exec_watchdog() -> None:
    script = (REPO_ROOT / "scripts" / "claudex-overnight-start.sh").read_text(
        encoding="utf-8"
    )

    assert (
        'nohup bash "$ROOT/scripts/claudex-codex-model-guard.sh" "$CODEX_PANE_TARGET"'
        in script
    )
    assert (
        'nohup bash "$ROOT/scripts/claudex-codex-approver.sh" --tmux-target "$CODEX_PANE_TARGET"'
        in script
    )
    assert (
        'nohup bash "$ROOT/scripts/claudex-worker-approver.sh" --tmux-target "$CLAUDE_PANE_TARGET"'
        in script
    )
    assert 'exec bash ./scripts/claudex-watchdog.sh --tmux-target \\"$CLAUDE_PANE_TARGET\\"' in script

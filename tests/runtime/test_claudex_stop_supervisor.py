from __future__ import annotations

import json
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
STOP_HOOK = REPO_ROOT / ".codex" / "hooks" / "stop_supervisor.py"


def init_git_repo(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "--quiet", str(path)], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(path), "config", "user.email", "test@example.com"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(path), "config", "user.name", "Test User"],
        check=True,
        capture_output=True,
    )


def seed_prompt(repo: Path, text: str = "supervisor prompt text") -> None:
    prompt_path = repo / ".codex" / "prompts"
    prompt_path.mkdir(parents=True, exist_ok=True)
    (prompt_path / "claudex_supervisor.txt").write_text(text)


def seed_active_run(
    runs_dir: Path,
    *,
    run_id: str = "run-stop-hook",
    state: str = "waiting_for_codex",
    control_mode: str = "supervised",
) -> None:
    run_dir = runs_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    (runs_dir / "active-run").write_text(f"{run_id}\n")
    (run_dir / "run.json").write_text(json.dumps({"run_id": run_id}))
    (run_dir / "status.json").write_text(
        json.dumps(
            {
                "state": state,
                "control_mode": control_mode,
                "updated_at": "2026-04-08T06:10:00Z",
            }
        )
    )


def seed_pending_review(
    repo: Path,
    *,
    run_id: str = "run-stop-hook",
    instruction_id: str = "inst-review",
    completed_at: str = "2026-04-08T06:12:00Z",
) -> None:
    pending_dir = repo / ".claude" / "claudex"
    pending_dir.mkdir(parents=True, exist_ok=True)
    (pending_dir / "pending-review.json").write_text(
        json.dumps(
            {
                "run_id": run_id,
                "instruction_id": instruction_id,
                "completed_at": completed_at,
                "state": "waiting_for_codex",
            }
        )
    )


def seed_review_cursor(
    runs_dir: Path,
    *,
    run_id: str = "run-stop-hook",
    instruction_id: str = "inst-review",
    completed_at: str = "2026-04-08T06:12:00Z",
) -> None:
    run_dir = runs_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "codex-review-cursor.json").write_text(
        json.dumps(
            {
                "instruction_id": instruction_id,
                "completed_at": completed_at,
            }
        )
    )


def run_stop_hook(repo: Path, runs_dir: Path, payload: dict | None = None):
    env = {"BRIDGE_STATE_DIR": str(runs_dir)}
    env["CLAUDEX_SUPERVISOR"] = "1"
    return subprocess.run(
        ["/usr/bin/python3", str(STOP_HOOK)],
        cwd=repo,
        env=env,
        input=json.dumps(payload or {}),
        text=True,
        capture_output=True,
        check=True,
    )


def run_stop_hook_without_supervisor_env(
    repo: Path,
    runs_dir: Path,
    payload: dict | None = None,
):
    return subprocess.run(
        ["/usr/bin/python3", str(STOP_HOOK)],
        cwd=repo,
        env={"BRIDGE_STATE_DIR": str(runs_dir)},
        input=json.dumps(payload or {}),
        text=True,
        capture_output=True,
        check=True,
    )


def test_stop_hook_allows_normal_stop_when_no_active_bridge_run(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo)
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()

    result = run_stop_hook(repo, runs_dir)
    payload = json.loads(result.stdout)

    assert payload == {"continue": False}


def test_stop_hook_allows_normal_stop_for_non_supervisor_sessions(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "should not be used")
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="waiting_for_codex")

    result = run_stop_hook_without_supervisor_env(repo, runs_dir)
    payload = json.loads(result.stdout)

    assert payload == {"continue": False}


def test_stop_hook_rearms_codex_when_bridge_is_waiting_for_review(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "project-specific supervisor loop")
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="waiting_for_codex")

    result = run_stop_hook(repo, runs_dir)
    payload = json.loads(result.stdout)

    assert payload["decision"] == "block"
    assert "project-specific supervisor loop" in payload["reason"]


def test_stop_hook_ignores_stop_hook_active_and_keeps_session_alive(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "keep blocking")
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="queued")

    result = run_stop_hook(repo, runs_dir, payload={"stop_hook_active": True})
    payload = json.loads(result.stdout)

    assert payload["decision"] == "block"
    assert payload["reason"] == "keep blocking"


def test_stop_hook_keeps_session_alive_when_bridge_is_user_driving(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "stay supervising")
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="waiting_for_codex", control_mode="user_driving")

    result = run_stop_hook(repo, runs_dir)
    payload = json.loads(result.stdout)

    assert payload["decision"] == "block"
    assert payload["reason"] == "stay supervising"


def test_stop_hook_rearms_from_pending_review_even_if_state_is_idle(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "review artifact exists")
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="idle")
    seed_pending_review(repo)

    result = run_stop_hook(repo, runs_dir)
    payload = json.loads(result.stdout)

    assert payload["decision"] == "block"
    assert payload["reason"] == "review artifact exists"


def test_stop_hook_allows_stop_for_consumed_pending_review(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "should not be used after consumed review")
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="waiting_for_codex")
    seed_pending_review(repo)
    seed_review_cursor(runs_dir)

    result = run_stop_hook(repo, runs_dir)
    payload = json.loads(result.stdout)

    assert payload == {"continue": False}


def test_stop_hook_allows_stop_when_dispatch_is_marked_stalled(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "should not be used while dispatch is stalled")
    (repo / ".claude" / "claudex").mkdir(parents=True, exist_ok=True)
    (repo / ".claude" / "claudex" / "dispatch-stall.state.json").write_text(
        json.dumps({"run_id": "run-stop-hook", "state": "dispatch_stalled"})
    )
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="queued")

    result = run_stop_hook(repo, runs_dir)
    payload = json.loads(result.stdout)

    assert payload == {"continue": False}


def test_stop_hook_allows_terminal_supervisor_stop_token(tmp_path):
    repo = tmp_path / "repo"
    init_git_repo(repo)
    seed_prompt(repo, "should not be used after explicit terminal stop")
    runs_dir = tmp_path / "runs"
    runs_dir.mkdir()
    seed_active_run(runs_dir, state="waiting_for_codex")

    result = run_stop_hook(
        repo,
        runs_dir,
        payload={"last_assistant_message": "CLAUDEX_SUPERVISOR_STOP\nStopping here."},
    )
    payload = json.loads(result.stdout)

    assert payload == {"continue": False}

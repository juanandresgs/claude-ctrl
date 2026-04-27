#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


SUPERVISOR_ENV_VAR = "CLAUDEX_SUPERVISOR"
TERMINAL_STOP_TOKEN = "CLAUDEX_SUPERVISOR_STOP"


def repo_root() -> Path:
    return Path(
        subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
        ).strip()
    )


def read_json(path: Path):
    if not path.exists():
        return None
    return json.loads(path.read_text())


def read_text(path: Path):
    if not path.exists():
        return ""
    return path.read_text().strip()


def resolve_state_dir(root: Path) -> Path:
    env_state_dir = os.environ.get("CLAUDEX_STATE_DIR")
    if env_state_dir:
        return Path(env_state_dir)
    return root / ".claude" / "claudex"


def resolve_runs_dir(root: Path, state_dir: Path) -> Path:
    candidates = []

    env_runs_dir = os.environ.get("BRIDGE_STATE_DIR")
    if env_runs_dir:
        candidates.append(Path(env_runs_dir))

    env_braid_root = os.environ.get("BRAID_ROOT")
    if env_braid_root:
        candidates.append(Path(env_braid_root) / "runs")

    for marker in (state_dir / "braid-root", root / ".claude" / "claudex" / "braid-root"):
        marker_value = read_text(marker)
        if marker_value:
            candidates.append(Path(marker_value) / "runs")

    candidates.append(state_dir / "runs")

    for candidate in candidates:
        if candidate.exists():
            return candidate

    return candidates[0]


def active_run_status(runs_dir: Path):
    pointer = runs_dir / "active-run"
    if not pointer.exists():
        return None, None, None

    run_id = pointer.read_text().strip()
    if not run_id:
        return None, None, None

    run_dir = runs_dir / run_id
    run = read_json(run_dir / "run.json")
    status = read_json(run_dir / "status.json")
    return run_id, run, status


def review_matches_cursor(review, cursor) -> bool:
    if review is None or cursor is None:
        return False

    review_instruction = str(review.get("instruction_id") or "").strip()
    cursor_instruction = str(cursor.get("instruction_id") or "").strip()
    if not review_instruction or review_instruction != cursor_instruction:
        return False

    review_completed_at = str(review.get("completed_at") or "").strip()
    cursor_completed_at = str(cursor.get("completed_at") or "").strip()
    if review_completed_at and cursor_completed_at:
        return review_completed_at == cursor_completed_at
    return True


def continuation_prompt(root: Path) -> str:
    prompt_dir = root / ".codex" / "prompts"
    supervisor_prompt = read_text(prompt_dir / "claudex_supervisor.txt")
    stop_loop_prompt = read_text(prompt_dir / "claudex_stop_loop.txt")

    if supervisor_prompt and stop_loop_prompt:
        return (
            f"{supervisor_prompt}\n\n"
            "Stop-hook continuation supplement:\n"
            f"{stop_loop_prompt}"
        )
    if supervisor_prompt:
        return supervisor_prompt
    if stop_loop_prompt:
        return stop_loop_prompt
    raise FileNotFoundError("No Codex supervisor prompt found in .codex/prompts")


def main() -> int:
    payload = {}
    if not sys.stdin.isatty():
        raw = sys.stdin.read()
        if raw.strip():
            payload = json.loads(raw)

    if os.environ.get(SUPERVISOR_ENV_VAR) != "1":
        print(json.dumps({"continue": False}))
        return 0

    last_assistant_message = str(payload.get("last_assistant_message") or "")
    if TERMINAL_STOP_TOKEN in last_assistant_message:
        print(json.dumps({"continue": False}))
        return 0

    root = repo_root()
    state_dir = resolve_state_dir(root)
    runs_dir = resolve_runs_dir(root, state_dir)
    run_id, _run, status = active_run_status(runs_dir)
    dispatch_stall = read_json(state_dir / "dispatch-stall.state.json")

    # No active bridge run: allow Codex to stop normally.
    if not run_id or not status:
        print(json.dumps({"continue": False}))
        return 0

    if dispatch_stall and dispatch_stall.get("run_id") == run_id:
        print(json.dumps({"continue": False}))
        return 0

    state = status.get("state")
    pending_review_path = state_dir / "pending-review.json"
    pending_review_json = read_json(pending_review_path)
    if pending_review_json is not None:
        pending_run_id = str(pending_review_json.get("run_id") or "").strip()
        if pending_run_id and pending_run_id != run_id:
            pending_review_json = None

    if pending_review_json is not None:
        cursor = read_json(runs_dir / run_id / "codex-review-cursor.json")
        if review_matches_cursor(pending_review_json, cursor):
            # The review cursor records that the bridge already delivered this
            # artifact to Codex. That suppresses duplicate "new review" logic,
            # but it does NOT mean the supervisor lane is done. Keep the
            # dedicated seat alive while the run itself remains active.
            pending_review_json = None

    pending_review = pending_review_json is not None
    should_continue = state in {"queued", "inflight", "waiting_for_codex", "idle"} or pending_review

    if not should_continue:
        print(json.dumps({"continue": False}))
        return 0

    # Infinite self-continuation is intentional for the operator session:
    # if the bridge is active, keep Codex inside the supervisor loop.
    # stop_hook_active is still passed through in the payload, but we do not
    # use it as a brake here.
    print(
        json.dumps(
            {
                "decision": "block",
                "reason": continuation_prompt(root),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

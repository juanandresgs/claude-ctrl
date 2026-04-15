#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


DEFAULT_RUNS_DIR = Path(os.environ.get("BRIDGE_STATE_DIR", "/Users/turla/Code/braid/runs"))
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


def continuation_prompt(root: Path) -> str:
    prompt_dir = root / ".codex" / "prompts"
    for name in ("claudex_stop_loop.txt", "claudex_supervisor.txt"):
        prompt_path = prompt_dir / name
        if prompt_path.exists():
            return prompt_path.read_text().strip()
    raise FileNotFoundError("No Codex stop-loop prompt found in .codex/prompts")


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
    run_id, _run, status = active_run_status(DEFAULT_RUNS_DIR)
    dispatch_stall = read_json(root / ".claude" / "claudex" / "dispatch-stall.state.json")

    # No active bridge run: allow Codex to stop normally.
    if not run_id or not status:
        print(json.dumps({"continue": False}))
        return 0

    if dispatch_stall and dispatch_stall.get("run_id") == run_id:
        print(json.dumps({"continue": False}))
        return 0

    state = status.get("state")
    pending_review_path = root / ".claude" / "claudex" / "pending-review.json"
    pending_review_json = read_json(pending_review_path)

    # If the review artifact's (instruction_id, completed_at) already match the
    # review cursor under the active run, Codex has acted on this review and
    # does not need to be rearmed — regardless of bridge state.  The bridge may
    # not have transitioned state yet, but there is no supervisor work to do.
    if pending_review_json is not None:
        cursor = read_json(DEFAULT_RUNS_DIR / run_id / "codex-review-cursor.json")
        if (
            cursor is not None
            and cursor.get("instruction_id") == pending_review_json.get("instruction_id")
            and cursor.get("completed_at") == pending_review_json.get("completed_at")
        ):
            print(json.dumps({"continue": False}))
            return 0

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

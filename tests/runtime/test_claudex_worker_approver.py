from __future__ import annotations

import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "claudex-worker-approver.sh"


def classify(capture: str, *, allow_push: bool = False) -> str:
    env = os.environ.copy()
    env["BRAID_ROOT"] = str(REPO_ROOT / ".b2r-test")
    if allow_push:
        env["CLAUDEX_WORKER_APPROVER_ALLOW_PUSH"] = "1"
    proc = subprocess.run(
        ["bash", str(SCRIPT), "--classify-stdin"],
        input=capture,
        text=True,
        capture_output=True,
        cwd=REPO_ROOT,
        env=env,
        check=True,
    )
    return proc.stdout.strip()


def test_worker_approver_allows_routine_prompt() -> None:
    capture = """\
Field 1/1
Tool call needs your approval. Reason: Request attempts to run tests and modify roadmap in active workspace; requires explicit user approval before executing potentially impactful tool actions.

text: Bounded validation slice only.

1. Allow   Run the tool and continue.
2. Cancel  Cancel this tool call
enter to submit | esc to cancel
"""
    assert classify(capture) == "allow"


def test_worker_approver_denies_destructive_prompt() -> None:
    capture = """\
Field 1/1
Tool call needs your approval. Reason: Request attempts to run git reset --hard and clean workspace state.

1. Allow   Run the tool and continue.
2. Cancel  Cancel this tool call
enter to submit | esc to cancel
"""
    assert classify(capture) == "deny"


def test_worker_approver_denies_push_by_default() -> None:
    capture = """\
Field 1/1
Tool call needs your approval. Reason: Request attempts to git push checkpoint branch to remote.

1. Allow   Run the tool and continue.
2. Cancel  Cancel this tool call
enter to submit | esc to cancel
"""
    assert classify(capture) == "deny"


def test_worker_approver_allows_push_when_enabled() -> None:
    capture = """\
Field 1/1
Tool call needs your approval. Reason: Request attempts to git push checkpoint branch to remote.

1. Allow   Run the tool and continue.
2. Cancel  Cancel this tool call
enter to submit | esc to cancel
"""
    assert classify(capture, allow_push=True) == "allow"


def test_worker_approver_allows_directory_trust_prompt() -> None:
    capture = """\
Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection.

1. Yes, continue
2. No, quit

Press enter to continue
"""
    assert classify(capture) == "trust"

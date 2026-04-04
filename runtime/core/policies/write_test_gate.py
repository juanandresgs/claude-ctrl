"""write_test_gate policy — escalating test-failure gate for source writes.

Port of hooks/test-gate.sh (165 lines).

Reads test_state from PolicyContext (already resolved by build_context()).
Manages strike counts via a flat file under project_root/.claude/.test-gate-strikes.

Logic:
  - No test state → ALLOW
  - test_state.found = False → ALLOW
  - test_state.status == pass/pass_complete → ALLOW + reset strikes
  - test_state stale (>600s old) → ALLOW
  - test_state failing and fresh:
      Strike 1 → ALLOW with advisory feedback
      Strike 2+ → DENY
  - Test files always ALLOW (so fixes can proceed)
  - Non-source files always ALLOW

@decision DEC-PE-W5-002
Title: write_test_gate reads test_state from PolicyContext, manages strikes via flat file
Status: accepted
Rationale: test-gate.sh read test_state via rt_test_state_get (SQLite).
  PolicyContext already carries the resolved test_state record from build_context(),
  so the policy is a pure function of request.context.test_state. The only
  stateful side effect is the strikes flat file under .claude/ — this is
  intentionally local to the project and reset on passing tests, matching the
  original shell hook's behavior exactly. Priority 650 places this after WHO/plan
  checks but before doc_gate at 700.
"""

from __future__ import annotations

import os
import time
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import is_skippable_path, is_source_file

# Stale threshold: results older than this many seconds are ignored
_STALE_THRESHOLD_SECS = 600

_PASS_STATUSES = frozenset({"pass", "pass_complete"})


# ---------------------------------------------------------------------------
# Test file detection (mirrors is_test_file() in test-gate.sh)
# ---------------------------------------------------------------------------


def _is_test_file(file_path: str) -> bool:
    """Return True if file_path looks like a test file."""
    return (
        ".test." in file_path
        or ".spec." in file_path
        or "__tests__/" in file_path
        or file_path.endswith("_test.go")
        or file_path.endswith("_test.py")
        or os.path.basename(file_path).startswith("test_")
        or "/tests/" in file_path
        or "/test/" in file_path
    )


# ---------------------------------------------------------------------------
# Strikes file helpers
# ---------------------------------------------------------------------------


def _strikes_path(project_root: str) -> str:
    return os.path.join(project_root, ".claude", ".test-gate-strikes")


def _read_strikes(project_root: str) -> int:
    path = _strikes_path(project_root)
    try:
        raw = open(path).read().strip()
        return int(raw.split("|")[0])
    except Exception:
        return 0


def _write_strikes(project_root: str, count: int) -> None:
    path = _strikes_path(project_root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"{count}|{int(time.time())}")


def _reset_strikes(project_root: str) -> None:
    path = _strikes_path(project_root)
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


# ---------------------------------------------------------------------------
# Policy function
# ---------------------------------------------------------------------------


def check_test_gate_pretool(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Gate source writes when tests are failing.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/ (meta-infrastructure)
      - File is not a source file
      - File is a skippable path
      - File is a test file (exempt so fixes can proceed)
      - No test state in context (cold start)
      - test_state.found = False
      - test_state.status is passing
      - test_state is stale (>600s old)

    Escalating action when tests are fresh-failing:
      Strike 1 → feedback (advisory warning)
      Strike 2+ → deny
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    project_root = request.context.project_root or ""

    # Skip meta-infrastructure
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    # Only enforce on source files
    if not is_source_file(file_path):
        return None

    # Skip vendor, node_modules, etc.
    if is_skippable_path(file_path):
        return None

    # Test files are always exempt — fixes must proceed
    if _is_test_file(file_path):
        return None

    # --- Resolve test state from PolicyContext ---
    ts = request.context.test_state
    if ts is None:
        return None

    found = ts.get("found", False)
    if not found:
        return None

    status = ts.get("status", "unknown")

    # Tests passing → allow + reset strikes
    if status in _PASS_STATUSES:
        if project_root:
            _reset_strikes(project_root)
        return None

    # Stale results → allow
    updated_at = ts.get("updated_at", 0) or 0
    now = int(time.time())
    age = now - updated_at
    if age > _STALE_THRESHOLD_SECS:
        return None

    # --- Tests failing and fresh — apply escalating strikes ---
    current_strikes = _read_strikes(project_root) if project_root else 0
    new_strikes = current_strikes + 1
    if project_root:
        _write_strikes(project_root, new_strikes)

    fail_count = ts.get("fail_count", 0) or 0

    if new_strikes >= 2:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Tests are still failing ({fail_count} failures, {age}s ago). "
                f"You have written source code {new_strikes} times without fixing tests. "
                "Fix the failing tests before continuing. Test files are exempt from this gate."
            ),
            policy_name="test_gate_pretool",
        )

    # Strike 1: advisory feedback
    return PolicyDecision(
        action="feedback",
        reason=(
            f"Tests are failing ({fail_count} failures, {age}s ago). "
            "Consider fixing tests before writing more source code. "
            "Next source write without fixing tests will be blocked."
        ),
        policy_name="test_gate_pretool",
    )

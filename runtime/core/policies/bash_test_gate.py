"""Policy: bash_test_gate — deny merge/commit when tests have not passed.

Port of guard.sh lines 250-283 (Checks 8 and 9).

Two registered policies share this module:
  bash_test_gate_merge  (priority=800) — gates git merge
  bash_test_gate_commit (priority=850) — gates git commit

@decision DEC-PE-W3-007
Title: bash_test_gate enforces test-pass requirement before commit/merge
Status: accepted
Rationale: Sacred Practice #4 — nothing is done until tested. The runtime
  test_state record is the sole authority for whether tests have passed for a
  project (WS3: SQLite authority, written by test-runner.sh). Both merge and
  commit require test_state.status == 'pass' or 'pass_complete'. Meta-repo
  is exempt: ~/.claude config edits do not have a test suite in this sense.
  Admin recovery (merge --abort) is also exempt — it is not a landing operation.
"""

from __future__ import annotations

from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest

_PASS_STATUSES = frozenset({"pass", "pass_complete"})


def _test_state_ok(request: PolicyRequest) -> tuple[bool, str]:
    """Return (ok, status_str) from the PolicyContext test_state."""
    ts = request.context.test_state
    if ts is None:
        return False, "not_found"
    status = ts.get("status", "unknown")
    return status in _PASS_STATUSES, status


def check_merge(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Gate git merge on test_state == pass/pass_complete.

    Skips:
      - meta_repo
      - merge --abort (admin recovery, not a landing operation)

    Source: guard.sh lines 250-266 (Check 8).
    """
    intent = request.command_intent
    if intent is None:
        return None

    invocation = intent.git_invocation
    if invocation is None or invocation.subcommand != "merge":
        return None

    # Admin recovery exemption.
    if "--abort" in invocation.args:
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    ok, status = _test_state_ok(request)
    if not ok:
        if status == "not_found":
            return PolicyDecision(
                action="deny",
                reason=(
                    "Cannot merge: no test results found in runtime. "
                    "Run the project's test suite first."
                ),
                policy_name="bash_test_gate_merge",
            )
        return PolicyDecision(
            action="deny",
            reason=(f"Cannot merge: test status is '{status}'. Tests must pass before merging."),
            policy_name="bash_test_gate_merge",
        )

    return None


def check_commit(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Gate git commit on test_state == pass/pass_complete.

    Skips:
      - meta_repo (resolved from target dir of the commit command)

    Source: guard.sh lines 268-283 (Check 9).
    """
    intent = request.command_intent
    if intent is None:
        return None

    invocation = intent.git_invocation
    if invocation is None or invocation.subcommand != "commit":
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    ok, status = _test_state_ok(request)
    if not ok:
        if status == "not_found":
            return PolicyDecision(
                action="deny",
                reason=(
                    "Cannot commit: no test results found in runtime. "
                    "Run the project's test suite first."
                ),
                policy_name="bash_test_gate_commit",
            )
        return PolicyDecision(
            action="deny",
            reason=(
                f"Cannot commit: test status is '{status}'. Tests must pass before committing."
            ),
            policy_name="bash_test_gate_commit",
        )

    return None


def register(registry) -> None:
    """Register both test gate checks into the given PolicyRegistry."""
    registry.register(
        "bash_test_gate_merge",
        check_merge,
        event_types=["Bash", "PreToolUse"],
        priority=800,
    )
    registry.register(
        "bash_test_gate_commit",
        check_commit,
        event_types=["Bash", "PreToolUse"],
        priority=850,
    )

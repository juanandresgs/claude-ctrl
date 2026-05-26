"""v6 landing readiness policy tests."""

from __future__ import annotations

from runtime.core.policies.bash_eval_readiness import check
from tests.runtime.policies.conftest import make_context, make_request


def test_commit_denied_without_v6_landing_readiness():
    req = make_request("git commit -m land", context=make_context(landing_readiness=None))
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "v6_landing_readiness" in decision.reason


def test_commit_allowed_with_ready_v6_landing_readiness_no_sha_check():
    ctx = make_context(landing_readiness={"status": "ready", "head_sha": ""})
    req = make_request("git commit -m land", context=ctx)
    assert check(req) is None


def test_pending_legacy_eval_state_no_longer_allows_landing():
    ctx = make_context(
        eval_state={"status": "ready_for_guardian", "head_sha": ""},
        landing_readiness={"status": "blocked", "head_sha": ""},
    )
    req = make_request("git commit -m land", context=ctx)
    decision = check(req)
    assert decision is not None
    assert "blocked" in decision.reason

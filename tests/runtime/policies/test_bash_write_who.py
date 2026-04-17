"""Unit tests for bash_write_who policy."""

from __future__ import annotations

from runtime.core.policies.bash_write_who import check
from tests.runtime.policies.conftest import make_context, make_request


def _ctx(role: str, *, is_meta_repo: bool = False):
    return make_context(actor_role=role, is_meta_repo=is_meta_repo)


def test_orchestrator_apply_patch_source_denied():
    req = make_request(
        "apply_patch <<'PATCH'\n"
        "*** Begin Patch\n"
        "*** Update File: src/app.py\n"
        "@@\n"
        "-old\n"
        "+new\n"
        "*** End Patch\n"
        "PATCH",
        context=_ctx(""),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_write_who"
    assert "source files" in decision.reason


def test_implementer_apply_patch_source_allowed():
    req = make_request(
        "apply_patch <<'PATCH'\n"
        "*** Begin Patch\n"
        "*** Update File: src/app.py\n"
        "@@\n"
        "-old\n"
        "+new\n"
        "*** End Patch\n"
        "PATCH",
        context=_ctx("implementer"),
    )
    assert check(req) is None


def test_orchestrator_redirection_source_denied():
    req = make_request(
        "echo 'print(1)' > src/main.py",
        context=_ctx(""),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_write_who"


def test_planner_governance_patch_allowed():
    req = make_request(
        "apply_patch <<'PATCH'\n"
        "*** Begin Patch\n"
        "*** Update File: MASTER_PLAN.md\n"
        "@@\n"
        "-old\n"
        "+new\n"
        "*** End Patch\n"
        "PATCH",
        context=_ctx("planner"),
    )
    assert check(req) is None


def test_orchestrator_governance_patch_denied():
    req = make_request(
        "apply_patch <<'PATCH'\n"
        "*** Begin Patch\n"
        "*** Update File: MASTER_PLAN.md\n"
        "@@\n"
        "-old\n"
        "+new\n"
        "*** End Patch\n"
        "PATCH",
        context=_ctx(""),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "governance" in decision.reason


def test_implementer_constitution_file_denied():
    req = make_request(
        "apply_patch <<'PATCH'\n"
        "*** Begin Patch\n"
        "*** Update File: runtime/cli.py\n"
        "@@\n"
        "-old\n"
        "+new\n"
        "*** End Patch\n"
        "PATCH",
        context=_ctx("implementer"),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "constitution-level" in decision.reason


def test_planner_constitution_file_allowed():
    req = make_request(
        "apply_patch <<'PATCH'\n"
        "*** Begin Patch\n"
        "*** Update File: runtime/cli.py\n"
        "@@\n"
        "-old\n"
        "+new\n"
        "*** End Patch\n"
        "PATCH",
        context=_ctx("planner"),
    )
    assert check(req) is None


def test_non_source_target_allowed():
    req = make_request(
        "echo hello > notes.txt",
        context=_ctx(""),
    )
    assert check(req) is None


def test_meta_repo_bypass():
    req = make_request(
        "echo 'print(1)' > src/main.py",
        context=_ctx("", is_meta_repo=True),
    )
    assert check(req) is None


def test_register_wires_policy():
    from runtime.core.policies.bash_write_who import register
    from runtime.core.policy_engine import PolicyRegistry

    registry = PolicyRegistry()
    register(registry)
    info = next(p for p in registry.list_policies() if p.name == "bash_write_who")
    assert info.priority == 275
    assert "Bash" in info.event_types or "PreToolUse" in info.event_types


def test_default_registry_ordering_between_worktree_nesting_and_git_who():
    """Pin: in the default policy stack, bash_write_who sits at priority 275,
    strictly after bash_worktree_nesting (250) and strictly before bash_git_who
    (300). This ordering is load-bearing: the write-side WHO gate must fire
    before git-level WHO enforcement, so a shell-driven source mutation is
    denied on capability grounds rather than on lease/git grounds."""
    from runtime.core.policies import register_all
    from runtime.core.policy_engine import PolicyRegistry

    registry = PolicyRegistry()
    register_all(registry)
    policies = {p.name: p.priority for p in registry.list_policies()}

    assert policies.get("bash_write_who") == 275, (
        f"bash_write_who must register at priority 275; got {policies.get('bash_write_who')!r}"
    )
    assert policies["bash_worktree_nesting"] < policies["bash_write_who"], (
        "bash_worktree_nesting must precede bash_write_who in priority order"
    )
    assert policies["bash_write_who"] < policies["bash_git_who"], (
        "bash_write_who must precede bash_git_who in priority order"
    )
    # No other default policy may collide with priority 275.
    collisions = [name for name, prio in policies.items()
                  if prio == 275 and name != "bash_write_who"]
    assert collisions == [], (
        f"Priority 275 slot must be exclusive to bash_write_who; collisions: {collisions}"
    )

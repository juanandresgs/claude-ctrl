"""Shared fixtures for bash policy unit tests.

All tests construct PolicyContext and PolicyRequest by hand — no DB I/O.
"""

from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from runtime.core.authority_registry import capabilities_for
from runtime.core.policy_engine import PolicyContext, PolicyRequest


def make_context(*, is_meta_repo=False, project_root="/project",
                 workflow_id="feature-test", lease=None, scope=None,
                 eval_state=None, test_state=None, binding=None,
                 branch="feature/test", actor_role="implementer",
                 worktree_lease_suppressed_roles=frozenset()) -> PolicyContext:
    return PolicyContext(
        actor_role=actor_role, actor_id="agent-test",
        workflow_id=workflow_id,
        worktree_path="/project/.worktrees/feature-test",
        branch=branch, project_root=project_root,
        is_meta_repo=is_meta_repo, lease=lease, scope=scope,
        eval_state=eval_state, test_state=test_state, binding=binding,
        dispatch_phase=None,
        capabilities=capabilities_for(actor_role),
        worktree_lease_suppressed_roles=frozenset(worktree_lease_suppressed_roles),
    )


def make_request(command, *, context=None, cwd="/project/.worktrees/feature-test",
                 event_type="PreToolUse") -> PolicyRequest:
    if context is None:
        context = make_context()
    return PolicyRequest(
        event_type=event_type, tool_name="Bash",
        tool_input={"command": command},
        context=context, cwd=cwd,
    )

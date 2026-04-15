"""write_who policy — only stages with CAN_WRITE_SOURCE may write source files.

Mirrors: hooks/write-guard.sh (98 lines)

@decision DEC-PE-W2-002
Title: write_who is a pure Python port of write-guard.sh (DEC-FORK-005)
Status: accepted
Rationale: The original shell hook (write-guard.sh) closed the gap where any
  agent could write source files before the git commit gate triggered. This
  Python port preserves the same semantics: only the implementer role is
  authorized to write source files. Role is read from context.actor_role,
  which build_context() resolves from the active lease, agent_marker, or
  CLI-injected actor_role field. Priority 200 matches the second position in
  the CHECKS list in pre-write.sh (after branch_guard at 100).

@decision DEC-PE-W2-CAP-001
Title: write_who uses CAN_WRITE_SOURCE capability gate (Phase 3 migration)
Status: accepted
Rationale: Raw role-name checks ("implementer") are a policy-scattered
  authority for write authorization. Migrating to capability gates means the
  authority_registry is the single place that declares which stages may write
  source files. New stages or aliases only need to be declared there.
  context.capabilities is populated by build_context() via
  authority_registry.capabilities_for(resolved_role) so this policy remains
  a pure function with no I/O.
"""

from __future__ import annotations

import os
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_SOURCE
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import is_skippable_path, is_source_file


def write_who(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny source-file writes from any actor lacking CAN_WRITE_SOURCE capability.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/ (meta-infrastructure)
      - File is not a source file
      - File is a skippable path
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    # Skip meta-infrastructure
    project_root = request.context.project_root
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    # WHO enforcement applies only to source files
    if not is_source_file(file_path):
        return None

    # Skip test/config/vendor/generated paths
    if is_skippable_path(file_path):
        return None

    if CAN_WRITE_SOURCE in request.context.capabilities:
        return None  # Authorized

    # All other roles: deny
    role = request.context.actor_role or ""
    role_label = role if role else "orchestrator (no active agent)"

    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: {role_label} cannot write source files. "
            "Only the implementer agent may write source code.\n\n"
            "Action: Dispatch an implementer agent for this change."
        ),
        policy_name="write_who",
    )

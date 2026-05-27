"""write_who policy — gate source writes to implementer or Guardian small-source.

Mirrors: hooks/write-guard.sh (98 lines)

@decision DEC-PE-W2-002
Title: write_who is a pure Python port of write-guard.sh (DEC-FORK-005)
Status: accepted
Rationale: The original shell hook (write-guard.sh) closed the gap where any
  agent could write source files before the git commit gate triggered. This
  Python port preserves the same normal-write semantics while adding the
  bounded Guardian small-source lane. Role is read from context.actor_role,
  which build_context() resolves from the active lease, agent_marker, or
  CLI-injected actor_role field. Priority 200 matches the second position in
  the CHECKS list in pre-write.sh (after branch_guard at 100).
"""

from __future__ import annotations

import os
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policies.fast_path import guardian_small_source_write_allowed
from runtime.core.policy_utils import is_skippable_path, is_source_file


def write_who(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny source-file writes outside implementer or Guardian small-source lanes.

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

    role = request.context.actor_role or ""

    if role == "implementer":
        return None  # Authorized
    if guardian_small_source_write_allowed(request, file_path):
        return None

    # All other roles: deny
    role_label = role if role else "orchestrator (no active agent)"

    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: {role_label} cannot write source files through this lane. "
            "Source writes require either an implementer in the provisioned worktree "
            "or Guardian small-source mode for a bounded fix.\n\n"
            "Action: For a bounded <=2 file source fix, launch Guardian in "
            "small-source mode with the exact proposed patch and focused test. "
            "Guardian may apply it directly only if it remains narrow; "
            "otherwise Guardian must require provision -> implementer. Do not "
            "retry the source edit from the orchestrator."
        ),
        policy_name="write_who",
    )

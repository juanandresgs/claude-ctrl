#!/usr/bin/env bash
# Fail-closed WorktreeCreate hook.
#
# @decision DEC-GUARD-WT-009
# Title: Harness-managed worktree creation is disabled
# Status: accepted
# Rationale: The Agent tool's `isolation: "worktree"` parameter and
#   EnterWorktree tool both create worktrees outside our hook chain (in
#   /tmp by default), bypassing pre-bash.sh and the bash_worktree_creation
#   policy. Per INIT-GUARD-WT, Guardian is the sole worktree authority.
#   This hook fails closed on any harness-managed worktree creation request,
#   forcing all worktree creation through `cc-policy worktree provision`.
# Adjacent components: bash_worktree_creation.py policy (denies `git
#   worktree add` from non-guardian roles via pre-bash.sh); guardian agent
#   (uses cc-policy worktree provision to create worktrees in
#   .worktrees/feature-<name>).

set -euo pipefail

cat <<'EOF' >&2
DENIED: Harness-managed worktree creation is disabled.

Worktree creation is reserved for Guardian. Use the dispatch chain:
  planner → guardian (provision) → implementer → reviewer → guardian (merge)

Guardian provisions worktrees via:
  cc-policy worktree provision --workflow-id <W> --feature-name <F> --project-root <P>

Do NOT use:
  - `isolation: "worktree"` on Agent tool calls
  - The EnterWorktree tool
  - `git worktree add` from non-guardian roles
EOF

exit 2

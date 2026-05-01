#!/usr/bin/env bash
set -euo pipefail

# Post-bash source-mutation readiness invalidation (Invariant #15).
# PostToolUse hook — matcher: Bash
#
# Closes the Bash shell-mutation bypass in evaluation_state readiness
# invalidation: any Bash command that modifies a source file after
# evaluator clearance must reset the evaluation_state from
# ready_for_guardian → pending, just as track.sh does for Write|Edit.
#
# track.sh handles Write|Edit by reading tool_input.file_path (known
# at pre-tool time). Bash commands do not expose a file_path; they may
# produce source mutations through arbitrary shell operations. This hook
# runs post-execution and detects mutations by comparing the session's
# tracked-file set: if git reports any modified/untracked source files
# under the project root that are in scope, the clearance is stale.
#
# @decision DEC-EVAL-006
# @title post-bash.sh closes the Bash bypass for evaluation_state readiness
# @status accepted
# @rationale DEC-EVAL-001 (evaluation.py invalidate_if_ready) and
#   DEC-EVAL-005 (track.sh is the sole Write|Edit invalidator) only
#   cover Write|Edit tool mutations. A Bash command like
#   `sed -i ...` or `python3 gen.py > src.py` bypasses track.sh entirely.
#   post-bash.sh is the PostToolUse Bash counterpart: it detects any
#   source-file change visible to git after the command executes and
#   calls rt_eval_invalidate so the evaluation clearance is revoked.
#   Design deliberately mirrors track.sh (DEC-EVAL-005) and uses
#   lease-first identity (DEC-WS1-TRACK-001) for the same reasons.
#   Does NOT re-implement bash_workflow_scope semantics — the pre-tool
#   gate has already denied out-of-scope Bash mutations; this hook only
#   sees in-scope execution results.
#   Does NOT parse Bash command semantics — that is command_intent's job.
#   (DEC-CLAUDEX-HOOK-MANIFEST-001: hook_manifest is the sole authority
#   for the repo-local hook adapter surface.)

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)

PROJECT_ROOT=$(bash_payload_project_root "$HOOK_INPUT" 2>/dev/null || echo "")
if [[ -n "$PROJECT_ROOT" && -d "$PROJECT_ROOT" ]]; then
    export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"
fi

printf '%s' "$HOOK_INPUT" | cc_policy hook bash-post >/dev/null 2>&1 || true

exit 0

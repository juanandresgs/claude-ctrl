#!/usr/bin/env bash
# Hook library bootstrapper — sources log.sh and context-lib.sh.
#
# Usage: source "$(dirname "$0")/source-lib.sh"
#
# All 29 hooks source this file to get logging and context utilities.
# Direct sourcing from the hooks/ directory — simple and reliable.
#
# @decision DEC-SRCLIB-001
# @title Direct hook library sourcing (replaces session-scoped caching)
# @status accepted
# @rationale The previous caching mechanism (d6635ce) cached hook libraries
#   per session to prevent race conditions during concurrent git merges. However,
#   when cache population failed (permissions, disk full, missing session ID),
#   the source commands for log.sh and context-lib.sh were never reached. Since
#   all 29 hooks source this file, a single cache failure bricked the entire
#   hook system with no recovery path. Direct sourcing eliminates the failure
#   mode entirely. The theoretical git-merge race condition is mitigated by
#   session-init.sh's smoke test that validates library sourcing on startup.

# CWD recovery: if the shell's CWD was deleted (e.g., worktree removal between
# hook invocations), recover before any hook logic runs. Without this, $PWD
# lookups fail with ENOENT and all subsequent detect_project_root() calls
# return garbage. This guard runs before sourcing log.sh so it is always active.
[[ ! -d "${PWD:-}" ]] && { cd "${HOME}" 2>/dev/null || cd /; }

_SRCLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${_SRCLIB_DIR}/log.sh"
source "${_SRCLIB_DIR}/context-lib.sh"

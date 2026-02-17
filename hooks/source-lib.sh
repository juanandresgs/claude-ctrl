#!/usr/bin/env bash
# Session-scoped library snapshot bootstrapper.
# Replaces direct sourcing of log.sh and context-lib.sh with cached copies
# to prevent race conditions during concurrent git merges.
#
# Usage: source "$(dirname "$0")/source-lib.sh"
#
# On first invocation per session, atomically copies log.sh and context-lib.sh
# into ~/.claude/.hook-cache/<session-key>/ and sources from there.
# Subsequent invocations in the same session source from the cached copies,
# avoiding any window where a concurrent git merge may leave the files incomplete.
#
# @decision DEC-SRCLIB-001
# @title Session-scoped hook library caching
# @status accepted
# @rationale Git merges write files non-atomically. A concurrent session can
#   read a partially-written context-lib.sh and crash with a syntax error.
#   Caching libraries per session on first invocation (via atomic cp+mv) eliminates
#   this race window. The session key uses CLAUDE_SESSION_ID with a PID fallback,
#   matching the pattern used throughout context-lib.sh. Cache dir lives outside
#   the repo (.hook-cache/) so it is never committed. session-end.sh removes the
#   session cache on clean exit; session-init.sh prunes caches older than 24h
#   from crashed sessions.

_SRCLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CACHE_KEY="${CLAUDE_SESSION_ID:-$$}"
_CACHE_DIR="${HOME}/.claude/.hook-cache/${_CACHE_KEY}"

if [[ ! -f "${_CACHE_DIR}/log.sh" ]]; then
    mkdir -p "${_CACHE_DIR}"
    # Atomic copy: write to tmp, then mv into place to prevent partial reads
    for _lib in log.sh context-lib.sh; do
        cp "${_SRCLIB_DIR}/${_lib}" "${_CACHE_DIR}/${_lib}.tmp.$$"
        mv "${_CACHE_DIR}/${_lib}.tmp.$$" "${_CACHE_DIR}/${_lib}"
    done
fi

# Source from session-local cache — immune to concurrent git merge writes
source "${_CACHE_DIR}/log.sh"
source "${_CACHE_DIR}/context-lib.sh"

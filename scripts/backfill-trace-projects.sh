#!/usr/bin/env bash
# backfill-trace-projects.sh — Backfill null project_name entries in traces/index.jsonl
#
# Delegates to backfill-trace-projects.py for the heavy lifting.
# Python3 is required; fails loudly if not available (no silent degradation).
#
# Usage:
#   bash scripts/backfill-trace-projects.sh [--trace-store=PATH] [--dry-run]
#
# @decision DEC-BACKFILL-002
# @title Shell wrapper delegates to Python for JSON/timestamp work
# @status accepted
# @rationale The backfill algorithm requires timestamp comparison, binary search,
#   and JSON manipulation across 896 entries. Python's stdlib handles this
#   trivially; pure bash+jq would require 896 subprocess calls. The shell wrapper
#   provides the conventional entry point (scripts/*.sh) while Python does the work.
#   Fails loudly if python3 is absent — never silently degrades (#127).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found. Install Python 3 and retry." >&2
    exit 1
fi

exec python3 "${SCRIPT_DIR}/backfill-trace-projects.py" "$@"

#!/usr/bin/env bash
# Capture wrapper: passthrough hook that logs raw Claude runtime payloads.
# Reads stdin (hook input JSON), writes it to payloads/<event>_<timestamp>.json,
# then exits 0 so the real hook chain continues unblocked.
# Usage: capture-wrapper.sh <event_type>
# DEC-FORK-011: capture uses wrapper scripts, not production hook edits.
set -euo pipefail

# @decision DEC-CAP-001
# @title Capture wrapper: passthrough with payload logging
# @status accepted
# @rationale TKT-001 requires observing raw hook payloads without modifying
# production hooks. This wrapper reads stdin, writes the full JSON to a
# timestamped file in the payloads/ directory, then exits 0 so the real hook
# chain continues unblocked. The event type is supplied as $1 by the
# install-capture.sh wiring so each file is namespaced per-event.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$SCRIPT_DIR/payloads"

# EVENT_TYPE is passed as first argument by install-capture.sh
EVENT_TYPE="${1:-unknown}"

# Read stdin fully — hooks receive input once on stdin
RAW_INPUT=$(cat)

# Ensure payloads directory exists
mkdir -p "$PAYLOAD_DIR"

# Timestamp in ISO-compatible format, safe for filenames
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

PAYLOAD_FILE="$PAYLOAD_DIR/${EVENT_TYPE}_${TIMESTAMP}.json"

# Write the raw payload; pretty-print if jq is available
if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$RAW_INPUT" | jq '.' > "$PAYLOAD_FILE" 2>/dev/null \
        || printf '%s\n' "$RAW_INPUT" > "$PAYLOAD_FILE"
else
    printf '%s\n' "$RAW_INPUT" > "$PAYLOAD_FILE"
fi

# Pass through — exit 0 with no output means "allow, no additional context"
exit 0

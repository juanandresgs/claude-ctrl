#!/usr/bin/env bash
# install-capture.sh: prepend capture-wrapper.sh to every hook chain in a
# copy of settings.json for manual payload observation sessions.
# Does NOT modify the live settings.json — works on a copy only.
# Usage: ./install-capture.sh [path/to/settings.json] [output/path]
# Defaults: reads $REPO_ROOT/settings.json, writes settings.capture.json
#
# @decision DEC-CAP-002
# @title Capture install modifies only a settings copy, never the live file
# @status accepted
# @rationale Modifying the live settings.json risks breaking the running
# governance layer. Working on a copy means capture is always opt-in and
# reversible. DEC-FORK-011 requires capture to be removable without merge risk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

INPUT_SETTINGS="${1:-$REPO_ROOT/settings.json}"
OUTPUT_SETTINGS="${2:-$REPO_ROOT/settings.capture.json}"
CAPTURE_SCRIPT="$SCRIPT_DIR/capture-wrapper.sh"

if [[ ! -f "$INPUT_SETTINGS" ]]; then
    echo "ERROR: settings.json not found at $INPUT_SETTINGS" >&2
    exit 1
fi

if [[ ! -x "$CAPTURE_SCRIPT" ]]; then
    chmod +x "$CAPTURE_SCRIPT"
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found in PATH" >&2
    exit 1
fi

# Build the jq program that prepends a capture entry to every hook array.
# Each capture entry passes the event name as $1 so files are namespaced.
# The event_name is derived from the hook key (SessionStart, PreToolUse, etc.)
# We use with_entries() to traverse every event key and prepend a capture hook
# as the first entry in every "hooks" array found under that event.
jq --arg capture_script "$CAPTURE_SCRIPT" '
  .hooks |= with_entries(
    .key as $event |
    .value |= map(
      .hooks |= [
        {
          "type": "command",
          "command": ($capture_script + " " + $event),
          "timeout": 3
        }
      ] + .
    )
  )
' "$INPUT_SETTINGS" > "$OUTPUT_SETTINGS"

echo "Capture settings written to: $OUTPUT_SETTINGS"
echo ""
echo "To run a capture session:"
echo "  1. Back up your active settings.json"
echo "  2. Copy $OUTPUT_SETTINGS over settings.json"
echo "  3. Run a Claude session normally — all hook events will be captured"
echo "  4. Check $SCRIPT_DIR/payloads/ for captured JSON payloads"
echo "  5. Restore your original settings.json when done"
echo ""
echo "Capture wrapper: $CAPTURE_SCRIPT"
echo "Payload directory: $SCRIPT_DIR/payloads/"

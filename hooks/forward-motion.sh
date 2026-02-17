#!/usr/bin/env bash
set -euo pipefail

# Forward motion check for assistant responses.
# Stop hook — runs when Claude finishes responding.
#
# DECISION: Replace AI agent with deterministic regex. Rationale: The forward
# motion check is a simple pattern match (?, "want me to", "shall I", etc.)
# that doesn't require semantic understanding. Shell regex saves 10s + tokens
# per session end with identical accuracy. Status: accepted.
#
# Checks the last paragraph of the assistant's response for forward motion
# indicators: questions, offers, suggestions. Returns exit 2 (feedback) only
# if the response ends with a bare completion statement and no forward motion.

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)

# Extract the transcript/response text from hook input
RESPONSE=$(echo "$HOOK_INPUT" | jq -r '.assistant_response // empty' 2>/dev/null)

# If we can't get the response text, pass (when in doubt, ok)
[[ -z "$RESPONSE" ]] && exit 0

# Get the last paragraph (last non-empty block of text)
LAST_PARA=$(echo "$RESPONSE" | awk '
    BEGIN { para="" }
    /^[[:space:]]*$/ { if (para != "") prev=para; para=""; next }
    { para = (para == "") ? $0 : para "\n" $0 }
    END { if (para != "") print para; else if (prev != "") print prev }
')

# If we can't extract a last paragraph, pass
[[ -z "$LAST_PARA" ]] && exit 0

# Check for forward motion indicators (case-insensitive)
if echo "$LAST_PARA" | grep -qiE '\?|want me to|shall I|let me know|would you like|should I|next step|what do you think|ready to|happy to|I can also|feel free|go ahead'; then
    exit 0
fi

# Check for bare completion statements without any forward motion
if echo "$LAST_PARA" | grep -qiE '\b(done|finished|completed|all set|that.s it|wrapped up)\b'; then
    # Double check — no question mark anywhere in last paragraph?
    if ! echo "$LAST_PARA" | grep -qF '?'; then
        echo "Response lacks forward motion. End with a question, suggestion, or offer to continue." >&2
        exit 2
    fi
fi

# When in doubt, pass
exit 0

#!/usr/bin/env bash
# Documentation enforcement gate — no-op adapter (PE-W5).
#
# This hook previously enforced file header and @decision annotation rules.
# PE-W5 migrated that logic to runtime/core/policies/write_doc_gate.py,
# registered at priority 700 in the PolicyRegistry.
#
# The policy now fires automatically when pre-write.sh calls
# ``cc-policy evaluate`` for every Write|Edit event. This hook remains
# wired in settings.json (hook wiring unchanged per PE-W5 constraint)
# but exits immediately — no duplicate enforcement.
#
# To verify coverage: cc-policy policy list | jq '.policies[] | select(.name=="doc_gate")'

exit 0

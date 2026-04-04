#!/usr/bin/env bash
# Mock detection gate — no-op adapter (PE-W5).
#
# This hook previously enforced an escalating mock-detection gate for test
# file writes. PE-W5 migrated that logic to runtime/core/policies/write_mock_gate.py,
# registered at priority 500 in the PolicyRegistry.
#
# The policy now fires automatically when pre-write.sh calls
# ``cc-policy evaluate`` for every Write|Edit event. This hook remains
# wired in settings.json (hook wiring unchanged per PE-W5 constraint)
# but exits immediately — no duplicate enforcement.
#
# To verify coverage: cc-policy policy list | jq '.policies[] | select(.name=="mock_gate")'
#
# @decision DEC-MOCK-001
# Title: Escalating mock detection gate
# Status: accepted
# Rationale: Sacred Practice #5 says "Real unit tests, not mocks." arXiv 2602.00409
#   found agents mock 95% of test doubles vs humans at 91%. Prose instructions drift
#   (anthropics/claude-code#18660), so deterministic hooks are the only reliable
#   enforcement. Escalating strikes match the proven test-gate.sh pattern.
#   PE-W5: enforcement now runs via the policy engine, not this shell hook.

exit 0

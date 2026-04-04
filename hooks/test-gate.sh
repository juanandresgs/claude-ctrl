#!/usr/bin/env bash
# Test-failure gate — no-op adapter (PE-W5).
#
# This hook previously enforced an escalating test-failure gate for source
# code writes. PE-W5 migrated that logic to runtime/core/policies/write_test_gate.py,
# registered at priority 600 in the PolicyRegistry.
#
# The policy now fires automatically when pre-write.sh calls
# ``cc-policy evaluate`` for every Write|Edit event. This hook remains
# wired in settings.json (hook wiring unchanged per PE-W5 constraint)
# but exits immediately — no duplicate enforcement.
#
# To verify coverage: cc-policy policy list | jq '.policies[] | select(.name=="test_gate")'
#
# @decision DEC-WS3-GATE-001
# Title: test-gate.sh reads SQLite runtime, not .test-status flat file
# Status: accepted
# Rationale: .test-status was written by test-runner.sh as a flat-file bridge.
#   WS3 migrated test state to SQLite via rt_test_state_get. This hook was the
#   last live enforcement reader of the flat file. Converging to rt_test_state_get
#   ensures a single authority for test state across all hooks.
#
# @decision DEC-GUARD-SKIP-001
# Title: .claude/ skip uses project-rooted path, not substring match
# Status: accepted
# Rationale: substring match on .claude/ exempts ANY file with that segment
#   in its absolute path, including project source files when the repo lives
#   under ~/.claude. Project-rooted check ensures only the project's own
#   .claude config tree is skipped.

exit 0

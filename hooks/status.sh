#!/usr/bin/env bash
# Status reporting for Living Documentation system
#
# @decision DEC-HOOKS-001
# @title Unified status reporting for Living Documentation hooks
# @status accepted
# @rationale Provides consistent output format across all hooks, enabling
#            automated parsing and user-friendly console feedback.
#            Format: [STAGE] message - where STAGE is GATE, DECISION, SURFACE, or OUTCOME

status() {
    local stage="$1"
    local message="$2"
    echo "[$stage] $message"
}

# Export for use by other scripts that source this file
export -f status

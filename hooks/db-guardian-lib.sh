#!/usr/bin/env bash
# db-guardian-lib.sh — JSON handoff protocol for the Database Guardian agent
#
# Provides structured request/response serialization for the DB-GUARDIAN-REQUIRED
# handoff flow. pre-bash.sh emits a DB-GUARDIAN-REQUIRED signal when it denies
# a destructive database command; the orchestrator parses this signal and dispatches
# the Database Guardian agent with a validated request constructed via these functions.
#
# Architecture:
#   pre-bash.sh (deny) → emit DB-GUARDIAN-REQUIRED JSON → orchestrator →
#   _dbg_format_request() → Database Guardian agent → _dbg_format_response()
#
# This library has no external dependencies beyond bash builtins and jq.
# It is loaded lazily via require_db_guardian() in source-lib.sh.
#
# Request schema (JSON):
#   operation_type       — schema_alter|query|data_mutation|migration
#   description          — human-readable explanation of intent
#   query                — SQL statement to execute
#   target_database      — database name or connection identifier
#   target_environment   — production|staging|development|local
#   context_snapshot     — affected_tables[], estimated_row_count, cascade_risk
#   requires_approval    — bool: whether user approval is required before execution
#   reversibility_info   — reversible, rollback_method, recovery_checkpoint
#
# Response schema (JSON):
#   status               — executed|denied|approval_required
#   execution_id         — unique identifier for this operation
#   result               — rows_affected, data[]
#   policy_decision      — rule_matched, action, reason
#   simulation_result    — explain_output, estimated_impact, cascade_effects[]
#
# @decision DEC-DBGUARD-002
# @title db-guardian-lib.sh as pure bash JSON marshalling layer
# @status accepted
# @rationale The Database Guardian agent needs a machine-readable handoff format
#   that pre-bash.sh can emit inline (in the deny message) without spawning a
#   subprocess. Using jq for generation would add a subprocess call to every
#   denied database command — significant overhead in the hot path. Instead,
#   this library provides bash functions that produce JSON via printf/heredoc
#   with minimal escaping. The consumer (the agent) uses jq to parse the JSON,
#   which is acceptable since agents run outside the hook hot path.
#   The separation of formatting (lib) from agent logic (db-guardian.md) makes
#   the schema testable in isolation without an agent session.
#
# @decision DEC-DBGUARD-003
# @title Pipe-delimited return format for _dbg_parse_response()
# @status accepted
# @rationale Bash functions cannot return structured data — they can only print
#   to stdout. The caller needs multiple fields (status, rule_matched, reason,
#   rows_affected). Options: (1) global variables (set side effects, breaks
#   subshells), (2) JSON stdout + jq parse at call site (adds jq subprocess),
#   (3) delimited string (no subprocess, no side effects). We chose (3):
#   "status|rule_matched|reason|rows_affected". The caller uses IFS='|' read
#   to split. Documented in the function header so callers know the format.

# Guard: prevent re-sourcing
[[ -n "${_DB_GUARDIAN_LIB_LOADED:-}" ]] && return 0
_DB_GUARDIAN_LIB_LOADED=1
_DB_GUARDIAN_LIB_VERSION=1

# Valid values for schema enforcement
_DBG_VALID_OP_TYPES="schema_alter query data_mutation migration"
_DBG_VALID_ENVIRONMENTS="production staging development local"
_DBG_VALID_STATUSES="executed denied approval_required"
_DBG_VALID_ACTIONS="deny allow escalate"
_DBG_VALID_ROLLBACK_METHODS="transaction rollback|backup restore|none"

# ---------------------------------------------------------------------------
# _dbg_validate_request JSON_STRING
#
# Validates a Database Guardian request JSON against the required schema.
# Checks: all required fields present, operation_type valid, target_environment
# valid, query non-empty, reversibility_info complete.
#
# Returns: "valid" on success, "invalid:<reason>" on failure.
# Exit code: 0 on valid, 1 on invalid.
#
# Usage:
#   result=$(_dbg_validate_request "$request_json")
#   if [[ "$result" != "valid" ]]; then
#     echo "Validation failed: ${result#invalid:}"
#   fi
# ---------------------------------------------------------------------------
_dbg_validate_request() {
    local json_string="$1"

    # Empty input check
    if [[ -z "$json_string" ]]; then
        echo "invalid:empty request"
        return 1
    fi

    # Verify jq is available for JSON parsing
    if ! command -v jq >/dev/null 2>&1; then
        # Fallback: basic string checks when jq is unavailable
        if ! echo "$json_string" | grep -q '"operation_type"'; then
            echo "invalid:missing required field: operation_type"
            return 1
        fi
        if ! echo "$json_string" | grep -q '"query"'; then
            echo "invalid:missing required field: query"
            return 1
        fi
        if ! echo "$json_string" | grep -q '"target_environment"'; then
            echo "invalid:missing required field: target_environment"
            return 1
        fi
        echo "valid"
        return 0
    fi

    # Validate JSON is parseable
    if ! echo "$json_string" | jq empty 2>/dev/null; then
        echo "invalid:malformed JSON"
        return 1
    fi

    # Required field: operation_type
    local op_type
    op_type=$(echo "$json_string" | jq -r '.operation_type // empty' 2>/dev/null)
    if [[ -z "$op_type" ]]; then
        echo "invalid:missing required field: operation_type"
        return 1
    fi
    # Validate operation_type value
    local valid_op=false
    for _valid in $_DBG_VALID_OP_TYPES; do
        [[ "$op_type" == "$_valid" ]] && valid_op=true && break
    done
    if [[ "$valid_op" == "false" ]]; then
        echo "invalid:unknown operation_type '$op_type'; must be one of: $_DBG_VALID_OP_TYPES"
        return 1
    fi

    # Required field: query
    local query
    query=$(echo "$json_string" | jq -r '.query // empty' 2>/dev/null)
    if [[ -z "$query" ]]; then
        echo "invalid:missing required field: query (cannot be empty)"
        return 1
    fi

    # Required field: target_environment
    local target_env
    target_env=$(echo "$json_string" | jq -r '.target_environment // empty' 2>/dev/null)
    if [[ -z "$target_env" ]]; then
        echo "invalid:missing required field: target_environment"
        return 1
    fi
    # Validate target_environment value
    local valid_env=false
    for _valid in $_DBG_VALID_ENVIRONMENTS; do
        [[ "$target_env" == "$_valid" ]] && valid_env=true && break
    done
    if [[ "$valid_env" == "false" ]]; then
        echo "invalid:unknown target_environment '$target_env'; must be one of: $_DBG_VALID_ENVIRONMENTS"
        return 1
    fi

    # Required field: description
    local description
    description=$(echo "$json_string" | jq -r '.description // empty' 2>/dev/null)
    if [[ -z "$description" ]]; then
        echo "invalid:missing required field: description"
        return 1
    fi

    # Required field: target_database
    local target_db
    target_db=$(echo "$json_string" | jq -r '.target_database // empty' 2>/dev/null)
    if [[ -z "$target_db" ]]; then
        echo "invalid:missing required field: target_database"
        return 1
    fi

    # Required field: reversibility_info
    local rev_info
    rev_info=$(echo "$json_string" | jq -r '.reversibility_info // empty' 2>/dev/null)
    if [[ -z "$rev_info" ]]; then
        echo "invalid:missing required field: reversibility_info"
        return 1
    fi
    # reversibility_info must have reversible field (use has() since false is a valid value)
    local reversible_exists
    reversible_exists=$(echo "$json_string" | jq -r 'if .reversibility_info | has("reversible") then "yes" else "no" end' 2>/dev/null || echo "no")
    if [[ "$reversible_exists" != "yes" ]]; then
        echo "invalid:reversibility_info missing required field: reversible"
        return 1
    fi
    # reversibility_info must have rollback_method field
    local rollback_method
    rollback_method=$(echo "$json_string" | jq -r '.reversibility_info.rollback_method // empty' 2>/dev/null)
    if [[ -z "$rollback_method" ]]; then
        echo "invalid:reversibility_info missing required field: rollback_method"
        return 1
    fi

    echo "valid"
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_format_request OPERATION_TYPE DESCRIPTION QUERY TARGET_DB TARGET_ENV
#                     [AFFECTED_TABLES] [EST_ROW_COUNT] [CASCADE_RISK]
#                     [REQUIRES_APPROVAL] [REVERSIBLE] [ROLLBACK_METHOD]
#                     [RECOVERY_CHECKPOINT]
#
# Constructs a properly formatted Database Guardian request JSON.
# All required fields must be provided. Optional context_snapshot and
# reversibility_info fields use safe defaults when omitted.
#
# Positional arguments:
#   $1  operation_type       — schema_alter|query|data_mutation|migration
#   $2  description          — human-readable intent
#   $3  query                — SQL statement
#   $4  target_database      — database name
#   $5  target_environment   — production|staging|development|local
#   $6  affected_tables      — comma-separated table names (default: "")
#   $7  estimated_row_count  — integer (default: 0)
#   $8  cascade_risk         — true|false (default: false)
#   $9  requires_approval    — true|false (default: true for production, false otherwise)
#   $10 reversible           — true|false (default: false)
#   $11 rollback_method      — transaction rollback|backup restore|none (default: none)
#   $12 recovery_checkpoint  — snapshot ID or timestamp (default: "")
#
# Returns: JSON string on stdout
# ---------------------------------------------------------------------------
_dbg_format_request() {
    local op_type="${1:-}"
    local description="${2:-}"
    local query="${3:-}"
    local target_db="${4:-}"
    local target_env="${5:-}"
    local affected_tables="${6:-}"
    local est_row_count="${7:-0}"
    local cascade_risk="${8:-false}"
    local requires_approval="${9:-true}"
    local reversible="${10:-false}"
    local rollback_method="${11:-none}"
    local recovery_checkpoint="${12:-}"

    # Normalize cascade_risk to valid JSON boolean
    case "$cascade_risk" in
        true|1|yes)  cascade_risk="true"  ;;
        false|0|no|"") cascade_risk="false" ;;
        *)           cascade_risk="false" ;;
    esac

    # Normalize reversible to valid JSON boolean
    case "$reversible" in
        true|1|yes)  reversible="true"  ;;
        false|0|no|"") reversible="false" ;;
        *)           reversible="false" ;;
    esac

    # Normalize requires_approval to valid JSON boolean
    case "$requires_approval" in
        true|1|yes)  requires_approval="true"  ;;
        false|0|no)  requires_approval="false" ;;
        *)           requires_approval="true"  ;;
    esac

    # Normalize est_row_count to integer
    if ! [[ "$est_row_count" =~ ^[0-9]+$ ]]; then
        est_row_count=0
    fi

    # Build affected_tables JSON array
    local tables_json="[]"
    if [[ -n "$affected_tables" ]]; then
        # Convert comma-separated string to JSON array using jq or manual construction
        if command -v jq >/dev/null 2>&1; then
            tables_json=$(echo "$affected_tables" | tr ',' '\n' | jq -R . | jq -s . 2>/dev/null || echo "[]")
        else
            # Manual construction for environments without jq
            tables_json="["
            local first=true
            while IFS= read -r -d',' table; do
                table="${table## }"
                table="${table%% }"
                [[ -z "$table" ]] && continue
                [[ "$first" == "false" ]] && tables_json+=","
                tables_json+="\"${table}\""
                first=false
            done <<< "${affected_tables},"
            tables_json+="]"
        fi
    fi

    # Escape string fields for safe JSON embedding
    local _escape_json
    _escape_json() {
        # Escape backslash, double-quote, newline, tab, carriage return
        printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr -d '\r' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//'
    }

    local esc_description esc_query esc_target_db esc_recovery
    if command -v jq >/dev/null 2>&1; then
        esc_description=$(jq -Rr '.' <<< "$description" 2>/dev/null || printf '%s' "$description")
        esc_query=$(jq -Rr '.' <<< "$query" 2>/dev/null || printf '%s' "$query")
        esc_target_db=$(jq -Rr '.' <<< "$target_db" 2>/dev/null || printf '%s' "$target_db")
        esc_recovery=$(jq -Rr '.' <<< "$recovery_checkpoint" 2>/dev/null || printf '%s' "$recovery_checkpoint")
    else
        esc_description=$(_escape_json "$description")
        esc_query=$(_escape_json "$query")
        esc_target_db=$(_escape_json "$target_db")
        esc_recovery=$(_escape_json "$recovery_checkpoint")
    fi

    printf '{
  "operation_type": "%s",
  "description": "%s",
  "query": "%s",
  "target_database": "%s",
  "target_environment": "%s",
  "context_snapshot": {
    "affected_tables": %s,
    "estimated_row_count": %s,
    "cascade_risk": %s
  },
  "requires_approval": %s,
  "reversibility_info": {
    "reversible": %s,
    "rollback_method": "%s",
    "recovery_checkpoint": "%s"
  }
}' \
        "$op_type" \
        "$esc_description" \
        "$esc_query" \
        "$esc_target_db" \
        "$target_env" \
        "$tables_json" \
        "$est_row_count" \
        "$cascade_risk" \
        "$requires_approval" \
        "$reversible" \
        "$rollback_method" \
        "$esc_recovery"
}

# ---------------------------------------------------------------------------
# _dbg_parse_response JSON_STRING
#
# Extracts key fields from a Database Guardian response JSON.
# Returns a pipe-delimited string for easy bash consumption.
#
# Returns: "status|rule_matched|reason|rows_affected"
#   - status       — executed|denied|approval_required (empty if missing)
#   - rule_matched — policy rule ID (empty if missing)
#   - reason       — policy decision reason (empty if missing)
#   - rows_affected — integer (0 if missing or non-integer)
#
# Usage:
#   IFS='|' read -r status rule reason rows <<< "$(_dbg_parse_response "$response_json")"
#
# Exit code: 0 on success, 1 if JSON is malformed or empty
# ---------------------------------------------------------------------------
_dbg_parse_response() {
    local json_string="$1"

    if [[ -z "$json_string" ]]; then
        echo "|||0"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        # Fallback: regex extraction when jq unavailable
        local status rule reason rows_affected
        status=$(echo "$json_string" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"' || echo "")
        rule=$(echo "$json_string" | grep -oE '"rule_matched"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"' || echo "")
        reason=$(echo "$json_string" | grep -oE '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"' || echo "")
        rows_affected=$(echo "$json_string" | grep -oE '"rows_affected"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' || echo "0")
        printf '%s|%s|%s|%s\n' "$status" "$rule" "$reason" "$rows_affected"
        return 0
    fi

    # Validate JSON is parseable
    if ! echo "$json_string" | jq empty 2>/dev/null; then
        echo "|||0"
        return 1
    fi

    local status rule_matched reason rows_affected

    status=$(echo "$json_string" | jq -r '.status // empty' 2>/dev/null || echo "")
    rule_matched=$(echo "$json_string" | jq -r '.policy_decision.rule_matched // empty' 2>/dev/null || echo "")
    reason=$(echo "$json_string" | jq -r '.policy_decision.reason // empty' 2>/dev/null || echo "")
    rows_affected=$(echo "$json_string" | jq -r '.result.rows_affected // 0' 2>/dev/null || echo "0")

    # Ensure rows_affected is a valid integer
    if ! [[ "$rows_affected" =~ ^[0-9]+$ ]]; then
        rows_affected=0
    fi

    printf '%s|%s|%s|%s\n' "$status" "$rule_matched" "$reason" "$rows_affected"
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_format_response STATUS EXECUTION_ID RULE_MATCHED ACTION REASON
#                       [ROWS_AFFECTED] [EXPLAIN_OUTPUT] [ESTIMATED_IMPACT]
#
# Constructs a properly formatted Database Guardian response JSON.
#
# Positional arguments:
#   $1  status           — executed|denied|approval_required
#   $2  execution_id     — unique identifier for this operation
#   $3  rule_matched     — policy rule ID that was applied
#   $4  action           — deny|allow|escalate
#   $5  reason           — human-readable explanation of the decision
#   $6  rows_affected    — integer (default: 0)
#   $7  explain_output   — raw EXPLAIN output (default: "")
#   $8  estimated_impact — human-readable impact estimate (default: "")
#
# Returns: JSON string on stdout
# ---------------------------------------------------------------------------
_dbg_format_response() {
    local status="${1:-denied}"
    local execution_id="${2:-}"
    local rule_matched="${3:-}"
    local action="${4:-deny}"
    local reason="${5:-}"
    local rows_affected="${6:-0}"
    local explain_output="${7:-}"
    local estimated_impact="${8:-}"

    # Normalize rows_affected to integer
    if ! [[ "$rows_affected" =~ ^[0-9]+$ ]]; then
        rows_affected=0
    fi

    # Generate execution_id if not provided
    if [[ -z "$execution_id" ]]; then
        execution_id="dbg-$(date +%s)-$$"
    fi

    # Escape string fields
    local esc_rule esc_reason esc_explain esc_impact
    if command -v jq >/dev/null 2>&1; then
        esc_rule=$(jq -Rr '.' <<< "$rule_matched" 2>/dev/null || printf '%s' "$rule_matched")
        esc_reason=$(jq -Rr '.' <<< "$reason" 2>/dev/null || printf '%s' "$reason")
        esc_explain=$(jq -Rr '.' <<< "$explain_output" 2>/dev/null || printf '%s' "$explain_output")
        esc_impact=$(jq -Rr '.' <<< "$estimated_impact" 2>/dev/null || printf '%s' "$estimated_impact")
    else
        esc_rule="$rule_matched"
        esc_reason="$reason"
        esc_explain="$explain_output"
        esc_impact="$estimated_impact"
    fi

    printf '{
  "status": "%s",
  "execution_id": "%s",
  "result": {
    "rows_affected": %s,
    "data": []
  },
  "policy_decision": {
    "rule_matched": "%s",
    "action": "%s",
    "reason": "%s"
  },
  "simulation_result": {
    "explain_output": "%s",
    "estimated_impact": "%s",
    "cascade_effects": []
  }
}' \
        "$status" \
        "$execution_id" \
        "$rows_affected" \
        "$esc_rule" \
        "$action" \
        "$esc_reason" \
        "$esc_explain" \
        "$esc_impact"
}

# ---------------------------------------------------------------------------
# _dbg_emit_guardian_required OPERATION_TYPE DENIED_COMMAND DENY_REASON TARGET_ENV
#
# Emits a DB-GUARDIAN-REQUIRED signal for inclusion in pre-bash.sh deny messages.
# This is the machine-readable trigger that causes the orchestrator to dispatch
# the Database Guardian agent.
#
# The caller (pre-bash.sh) appends this to the human-readable deny message so that
# the orchestrator can parse the JSON and construct a full request.
#
# Returns: formatted signal string on stdout
# ---------------------------------------------------------------------------
_dbg_emit_guardian_required() {
    local op_type="${1:-data_mutation}"
    local denied_cmd="${2:-}"
    local deny_reason="${3:-}"
    local target_env="${4:-unknown}"

    # Truncate long commands for the signal (full command is in the deny context)
    local cmd_preview
    if [[ ${#denied_cmd} -gt 200 ]]; then
        cmd_preview="${denied_cmd:0:200}..."
    else
        cmd_preview="$denied_cmd"
    fi

    # Escape for JSON
    local esc_cmd esc_reason
    if command -v jq >/dev/null 2>&1; then
        esc_cmd=$(jq -Rr '.' <<< "$cmd_preview" 2>/dev/null || printf '%s' "$cmd_preview")
        esc_reason=$(jq -Rr '.' <<< "$deny_reason" 2>/dev/null || printf '%s' "$deny_reason")
    else
        esc_cmd=$(printf '%s' "$cmd_preview" | sed 's/"/\\"/g')
        esc_reason=$(printf '%s' "$deny_reason" | sed 's/"/\\"/g')
    fi

    printf '\nDB-GUARDIAN-REQUIRED: {"operation_type":"%s","denied_command":"%s","deny_reason":"%s","target_environment":"%s"}' \
        "$op_type" \
        "$esc_cmd" \
        "$esc_reason" \
        "$target_env"
}

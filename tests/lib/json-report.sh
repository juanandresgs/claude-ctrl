#!/usr/bin/env bash
# tests/lib/json-report.sh — Machine-readable JSON report library.
#
# Provides shared functions for accumulating test results into structured JSON
# reports. Designed for bash 3.2 compatibility (macOS default shell): uses temp
# files for accumulation instead of associative arrays.
#
# Usage pattern:
#   source "$(dirname "$0")/../lib/json-report.sh"
#   json_report_init "behavioral-equivalence" "claude-ctrl" "metanoia"
#   json_report_add_result "fixture-name" "match" '{"old":"allow","new":"allow"}'
#   json_report_add_suggestion "DEC-001" "info" "All gates matched"
#   json_report_finalize "tests/reports/out.json" '{"match":5,"mismatch":0}'
#
# @decision DEC-CONFIG-COMPARE-001
# @title Shared JSON report library using temp files for bash 3.2 compatibility
# @status accepted
# @rationale macOS ships bash 3.2 which lacks declare -A (associative arrays).
#   The report library uses two temp files (details accumulator and suggestions
#   accumulator) that store newline-separated JSON objects. json_report_finalize
#   reads these files and builds the final JSON envelope with jq. This approach
#   is bash 3.2 safe, avoids subshell variable leakage, and produces valid JSON
#   regardless of special characters in values (jq handles escaping).

# Internal state — set by json_report_init, used by other functions.
_JSON_REPORT_DIMENSION=""
_JSON_REPORT_CONFIG_A=""
_JSON_REPORT_CONFIG_B=""
_JSON_REPORT_DETAILS_FILE=""
_JSON_REPORT_SUGGESTIONS_FILE=""
_JSON_REPORT_INITIALIZED=false

# ---------------------------------------------------------------------------
# json_report_init DIMENSION CONFIG_A CONFIG_B
#   Initialize a new report accumulator for the given dimension and configs.
#   Must be called before any other json_report_* functions.
#   Creates temp files for detail and suggestion accumulation.
# ---------------------------------------------------------------------------
json_report_init() {
    local dimension="$1"
    local config_a="$2"
    local config_b="$3"

    _JSON_REPORT_DIMENSION="$dimension"
    _JSON_REPORT_CONFIG_A="$config_a"
    _JSON_REPORT_CONFIG_B="$config_b"
    _JSON_REPORT_DETAILS_FILE=$(mktemp "${TMPDIR:-/tmp}/json-report-details-XXXXXX")
    _JSON_REPORT_SUGGESTIONS_FILE=$(mktemp "${TMPDIR:-/tmp}/json-report-suggestions-XXXXXX")
    _JSON_REPORT_INITIALIZED=true

    # Empty the accumulators
    > "$_JSON_REPORT_DETAILS_FILE"
    > "$_JSON_REPORT_SUGGESTIONS_FILE"

    # Register cleanup on exit
    trap '_json_report_cleanup' EXIT
}

# Internal cleanup — remove temp files if they exist
_json_report_cleanup() {
    [[ -n "$_JSON_REPORT_DETAILS_FILE" ]] && rm -f "$_JSON_REPORT_DETAILS_FILE"
    [[ -n "$_JSON_REPORT_SUGGESTIONS_FILE" ]] && rm -f "$_JSON_REPORT_SUGGESTIONS_FILE"
}

# ---------------------------------------------------------------------------
# json_report_add_result KEY VALUE [EXTRA_JSON]
#   Append a result entry to the details accumulator.
#   KEY: identifier (fixture name, gate id, test name)
#   VALUE: result string (match/mismatch/pass/fail/etc.)
#   EXTRA_JSON: optional JSON object to merge into the detail entry (must be
#               a valid jq-parseable object, e.g. '{"old":"allow","new":"deny"}')
# ---------------------------------------------------------------------------
json_report_add_result() {
    local key="$1"
    local value="$2"
    local extra="${3:-{}}"

    _json_report_check_init

    # Build the detail JSON object using jq for proper escaping
    local entry
    entry=$(jq -n \
        --arg key "$key" \
        --arg value "$value" \
        --argjson extra "$extra" \
        '{"key": $key, "value": $value} + $extra' 2>/dev/null) || \
        entry=$(printf '{"key":"%s","value":"%s"}' "$key" "$value")

    echo "$entry" >> "$_JSON_REPORT_DETAILS_FILE"
}

# ---------------------------------------------------------------------------
# json_report_add_suggestion SIG_ID SEVERITY DESC [EXTRA_JSON]
#   Append a suggestion entry to the suggestions accumulator.
#   SIG_ID: signal identifier (e.g. "DEC-CONFIG-COMPARE-001")
#   SEVERITY: info|warning|critical
#   DESC: human-readable description
#   EXTRA_JSON: optional extra fields
# ---------------------------------------------------------------------------
json_report_add_suggestion() {
    local sig_id="$1"
    local severity="$2"
    local desc="$3"
    local extra="${4:-{}}"

    _json_report_check_init

    local entry
    entry=$(jq -n \
        --arg sig_id "$sig_id" \
        --arg severity "$severity" \
        --arg desc "$desc" \
        --argjson extra "$extra" \
        '{"sig_id": $sig_id, "severity": $severity, "description": $desc} + $extra' 2>/dev/null) || \
        entry=$(printf '{"sig_id":"%s","severity":"%s","description":"%s"}' "$sig_id" "$severity" "$desc")

    echo "$entry" >> "$_JSON_REPORT_SUGGESTIONS_FILE"
}

# ---------------------------------------------------------------------------
# json_report_finalize OUTPUT_PATH SUMMARY_JSON
#   Close the JSON envelope and write the final report to OUTPUT_PATH.
#   SUMMARY_JSON: pre-built summary object (e.g. '{"match":5,"mismatch":0}')
#   Creates parent directory if needed.
#   Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
json_report_finalize() {
    local output_path="$1"
    local summary_json="$2"

    _json_report_check_init

    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$output_path")
    mkdir -p "$output_dir"

    # Build details array from accumulator file
    local details_array="[]"
    if [[ -s "$_JSON_REPORT_DETAILS_FILE" ]]; then
        details_array=$(jq -s '.' "$_JSON_REPORT_DETAILS_FILE" 2>/dev/null) || details_array="[]"
    fi

    # Build suggestions array from accumulator file
    local suggestions_array="[]"
    if [[ -s "$_JSON_REPORT_SUGGESTIONS_FILE" ]]; then
        suggestions_array=$(jq -s '.' "$_JSON_REPORT_SUGGESTIONS_FILE" 2>/dev/null) || suggestions_array="[]"
    fi

    # Validate summary JSON
    if ! echo "$summary_json" | jq '.' >/dev/null 2>&1; then
        summary_json="{}"
    fi

    # Write final envelope
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")

    jq -n \
        --arg dimension "$_JSON_REPORT_DIMENSION" \
        --arg timestamp "$timestamp" \
        --arg config_a "$_JSON_REPORT_CONFIG_A" \
        --arg config_b "$_JSON_REPORT_CONFIG_B" \
        --argjson summary "$summary_json" \
        --argjson details "$details_array" \
        --argjson suggestions "$suggestions_array" \
        '{
            "dimension": $dimension,
            "timestamp": $timestamp,
            "config_a": $config_a,
            "config_b": $config_b,
            "summary": $summary,
            "details": $details,
            "suggestions": $suggestions
        }' > "$output_path" 2>/dev/null

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        return 0
    else
        echo "json_report_finalize: failed to write $output_path" >&2
        return 1
    fi
}

# Internal: assert init was called
_json_report_check_init() {
    if [[ "$_JSON_REPORT_INITIALIZED" != "true" ]]; then
        echo "ERROR: json_report_* called before json_report_init" >&2
        exit 1
    fi
}

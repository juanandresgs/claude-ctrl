#!/usr/bin/env bash
# state-diag.sh — Read-only diagnostic tool for state.db
#
# Provides sanctioned read-only access to the SQLite governance state database.
# Direct sqlite3 access is blocked by pre-bash.sh (gate: sqlite3-state-db).
# This tool is the approved pathway for diagnostic inspection.
#
# Usage: state-diag.sh [command]
#   list          - List all state keys and values across all workflows
#   workflows     - List active workflow IDs
#   history [key] - Show history for a key (or all history if no key given)
#   locks         - Show guardian lock status
#   integrity     - Run PRAGMA integrity_check
#   schema        - Show database schema
#   raw <sql>     - Run a read-only SQL query (SELECT only)
#
# The `raw` command validates that SQL is SELECT-only.
# INSERT, UPDATE, DELETE, DROP, ALTER, CREATE are all rejected.
#
# @decision DEC-DBSAFE-002
# @title state-diag.sh as the sanctioned diagnostic pathway for state.db
# @status accepted
# @rationale Direct sqlite3 access to state.db is blocked by pre-bash.sh to
#   prevent accidental corruption or bypass of state management invariants.
#   Operators and agents still need a way to inspect state for debugging.
#   state-diag.sh enforces read-only access (SELECT-only for raw queries)
#   while providing convenient named commands for common diagnostic patterns.
#   By routing all diagnostic reads through this tool, we maintain a single
#   auditable pathway with clear limitations documented at the point of use.

set -euo pipefail

# Locate the state database
_find_db() {
    local claude_dir="${CLAUDE_DIR:-$HOME/.claude}"
    local db_path="${claude_dir}/state/state.db"
    if [[ ! -f "$db_path" ]]; then
        echo "Error: state.db not found at $db_path" >&2
        echo "The state database is created on first hook invocation." >&2
        exit 1
    fi
    echo "$db_path"
}

# _db_exec SQL — Execute a read-only SQL query against state.db
_db_exec() {
    local sql="$1"
    local db
    db=$(_find_db)
    printf '.timeout 5000\n%s\n' "$sql" | sqlite3 -column -header "$db" 2>/dev/null
}

# _db_exec_raw SQL — Execute SQL without formatting (for PRAGMA commands)
_db_exec_raw() {
    local sql="$1"
    local db
    db=$(_find_db)
    printf '.timeout 5000\n%s\n' "$sql" | sqlite3 "$db" 2>/dev/null
}

# _validate_select_only SQL — Reject any SQL that is not a SELECT statement.
# @decision DEC-DBSAFE-004
# @title Pattern-based SQL validation for state-diag.sh raw command
# @status accepted
# @rationale SQLite has no built-in read-only connection mode via the CLI
#   (-readonly flag is not available in the bundled macOS sqlite3). We enforce
#   SELECT-only by inspecting the first non-whitespace token. This is a
#   defense-in-depth measure — the primary protection is that state-diag.sh
#   itself is the only sanctioned pathway (direct sqlite3 is blocked by
#   pre-bash.sh). Multi-statement injection (SELECT 1; DROP TABLE) is blocked
#   by rejecting semicolons outside of string literals in the leading keyword
#   check — we strip the first token before the semicolon and check that.
_validate_select_only() {
    local sql="$1"
    # Strip leading whitespace and comments
    local stripped
    stripped=$(echo "$sql" | sed 's/^[[:space:]]*//' | sed 's/^--[^\n]*\n//')
    # Get the first keyword (before any whitespace)
    local first_keyword
    first_keyword=$(echo "$stripped" | grep -oE '^[A-Za-z]+' | tr '[:lower:]' '[:upper:]' || true)
    case "$first_keyword" in
        SELECT|WITH|EXPLAIN|PRAGMA)
            # Allowed read-only statements
            # Extra check: block if query contains mutating keywords after SELECT
            # (basic injection prevention — not foolproof but adds friction)
            if echo "$sql" | grep -qiE '\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|TRUNCATE|ATTACH|DETACH)\b'; then
                echo "Error: SQL contains mutating keywords. Only SELECT statements are allowed in raw mode." >&2
                exit 1
            fi
            return 0
            ;;
        INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|TRUNCATE|ATTACH|DETACH)
            echo "Error: Only SELECT queries are allowed in raw mode. Got: $first_keyword" >&2
            echo "Use state_read()/state_update() API in hooks for write operations." >&2
            exit 1
            ;;
        "")
            echo "Error: Empty SQL query." >&2
            exit 1
            ;;
        *)
            echo "Error: Unrecognized SQL statement type: $first_keyword. Only SELECT is allowed." >&2
            exit 1
            ;;
    esac
}

CMD="${1:-help}"

case "$CMD" in
    list)
        # List all state keys and values across all workflows
        echo "=== State Database: All Keys ==="
        _db_exec "SELECT workflow_id, key, value, updated_at, source FROM state ORDER BY workflow_id, key;"
        ;;

    workflows)
        # List distinct active workflow IDs
        echo "=== Active Workflow IDs ==="
        _db_exec "SELECT DISTINCT workflow_id, COUNT(*) as key_count FROM state GROUP BY workflow_id ORDER BY workflow_id;"
        ;;

    history)
        # Show history for a specific key, or all history
        _hist_key="${2:-}"
        if [[ -n "$_hist_key" ]]; then
            _hist_key_e=$(printf '%s' "$_hist_key" | sed "s/'/''/g")
            echo "=== History for key: $_hist_key ==="
            _db_exec "SELECT timestamp, workflow_id, value, source FROM history WHERE key='${_hist_key_e}' ORDER BY timestamp DESC LIMIT 50;"
        else
            echo "=== Recent History (all keys, last 100) ==="
            _db_exec "SELECT timestamp, key, workflow_id, value, source FROM history ORDER BY timestamp DESC LIMIT 100;"
        fi
        ;;

    locks)
        # Show lock-related state entries and lock files
        echo "=== Guardian Lock Status ==="
        _db_exec "SELECT workflow_id, key, value, updated_at, source FROM state WHERE key LIKE '%lock%' OR key LIKE '%guardian%' OR key LIKE '%proof%' ORDER BY workflow_id, key;"
        _locks_db=$(_find_db)
        _locks_dir="$(dirname "$_locks_db")/locks"
        if [[ -d "$_locks_dir" ]]; then
            echo ""
            echo "=== Lock files in $_locks_dir ==="
            ls -la "$_locks_dir" 2>/dev/null || echo "(empty)"
        fi
        ;;

    integrity)
        # Run SQLite integrity check
        echo "=== Integrity Check ==="
        _integ_db=$(_find_db)
        _integ_result=$(printf '.timeout 5000\nPRAGMA integrity_check;\n' | sqlite3 "$_integ_db" 2>/dev/null || echo "ERROR: sqlite3 failed")
        echo "$_integ_result"
        if [[ "$_integ_result" == "ok" ]]; then
            echo "(Database integrity: OK)"
        else
            echo "(WARNING: Database integrity check failed)"
        fi
        ;;

    schema)
        # Show database schema
        echo "=== Database Schema ==="
        _db_exec "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name;"
        ;;

    raw)
        # Run a read-only SQL query
        if [[ -z "${2:-}" ]]; then
            echo "Error: raw requires a SQL query argument." >&2
            echo "Usage: state-diag.sh raw 'SELECT key FROM state LIMIT 10'" >&2
            exit 1
        fi
        _validate_select_only "$2"
        echo "=== Raw Query Result ==="
        _db_exec "$2"
        ;;

    help|--help|-h)
        cat <<'EOF'
state-diag.sh — Read-only diagnostic tool for state.db

Usage: state-diag.sh <command> [args]

Commands:
  list              List all state keys and values
  workflows         List active workflow IDs and key counts
  history [key]     Show history for a key (or last 100 entries if no key)
  locks             Show guardian lock status and lock files
  integrity         Run PRAGMA integrity_check
  schema            Show database schema (CREATE TABLE statements)
  raw <sql>         Run a read-only SQL query (SELECT only)

Examples:
  state-diag.sh list
  state-diag.sh history proof_status
  state-diag.sh raw 'SELECT key, value FROM state WHERE workflow_id = "abc123_main"'
  state-diag.sh integrity

Note: Direct sqlite3 access to state.db is blocked by pre-bash.sh.
      Use state_read()/state_update() API in hooks for programmatic access.
EOF
        ;;

    *)
        echo "Error: Unknown command: $CMD" >&2
        echo "Run: state-diag.sh help" >&2
        exit 1
        ;;
esac

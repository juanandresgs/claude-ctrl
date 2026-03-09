#!/usr/bin/env bash
# db-safety-lib.sh — Modular database safety check library for pre-bash.sh
#
# @modality database
#
# This library provides all database CLI detection, environment classification,
# and risk assessment functions. It is loaded on demand via require_db_safety()
# in source-lib.sh — zero overhead when no database CLI is detected.
#
# Architecture: each database CLI has a dedicated handler function. The dispatch
# point in pre-bash.sh calls _db_detect_cli() first; if the result is "none",
# the entire section exits early with zero further overhead. This design allows
# Wave 2 to add per-CLI handlers without touching pre-bash.sh's core logic.
#
# @decision DEC-DBSAFE-001
# @title Modular database check architecture with zero-overhead early exit
# @status accepted
# @rationale Database safety checks need to handle multiple CLI tools (psql, mysql,
#   sqlite3, mongosh, redis-cli, cockroach) with different risk profiles and
#   environment-tiered responses. Embedding all logic in pre-bash.sh would bloat the
#   file and make it harder to add new CLI handlers. Instead, the detection loop in
#   pre-bash.sh provides a single dispatch point: if no DB CLI is detected, the
#   entire database section is skipped with one string comparison. db-safety-lib.sh
#   holds all database-specific logic and is loaded lazily via require_db_safety().
#   This follows the established require_*() pattern from DEC-SPLIT-002.
#
# @decision DEC-DBSAFE-002
# @title Environment-tiered response: production=deny all, staging=deny destructive,
#        dev/local=advisory only
# @status accepted
# @rationale The appropriate response to a risky database command varies by
#   environment. Blocking SELECT on production would be overly aggressive; blocking
#   DROP TABLE on dev would be unnecessarily disruptive. The tiering is:
#   - production/unknown + deny-risk → hard deny (irreversible in prod)
#   - production/unknown + advisory-risk → deny with explanation (data loss risk)
#   - staging + deny-risk → hard deny (shared data, still dangerous)
#   - staging + advisory-risk → log warning, allow (staging mistakes are recoverable)
#   - development/local + deny-risk → log warning, allow (local data is disposable)
#   - development/local + advisory-risk → allow silently (low signal in dev)
#   Unknown environment is treated as production (fail-safe default).

# Guard: prevent re-sourcing
[[ -n "${_DB_SAFETY_LIB_LOADED:-}" ]] && return 0
_DB_SAFETY_LIB_LOADED=1
_DB_SAFETY_LIB_VERSION=1

# ---------------------------------------------------------------------------
# _db_detect_cli COMMAND
#
# Identifies which database CLI tool is being invoked in the given command.
# Returns one of: psql, mysql, sqlite3, mongosh, redis-cli, cockroach, none
#
# Handles:
#   - Bare CLI name at command start (psql ..., mysql ...)
#   - CLI after path prefix (/usr/bin/psql, /usr/local/bin/mysql)
#   - CLI after sudo (sudo psql ..., sudo -u postgres psql ...)
#   - Quoted arguments (psql -c "SELECT ..." )
#   - Chain commands (cmd && psql ...)
#
# Returns "none" for non-database commands — caller exits early on "none".
# ---------------------------------------------------------------------------
_db_detect_cli() {
    local cmd="$1"

    # Strip comments and quotes for pattern matching (same as pre-bash.sh _stripped_cmd)
    local stripped
    stripped=$(printf '%s' "$cmd" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g" | sed -E '/^[[:space:]]*#/d; s/[[:space:]]#.*$//')

    # Pattern: match CLI tools as standalone words, allowing:
    #   - word boundary at start/after spaces/after path separator
    #   - preceding: start of string, whitespace, &&, ||, ;, (, |
    #   - optional path prefix: /path/to/cli or ./cli
    local cli_pattern='(^|[[:space:]]|&&|\|\|?|;|\(|/)(%s)([[:space:]]|$|;|&&|\|)'

    # Check each CLI in priority order (most specific first)
    local cli
    for cli in psql mysql sqlite3 mongosh redis-cli cockroach; do
        if printf '%s' "$stripped" | grep -qE "$(printf "$cli_pattern" "$cli")"; then
            printf '%s' "$cli"
            return 0
        fi
    done

    printf 'none'
    return 0
}

# ---------------------------------------------------------------------------
# _db_detect_environment
#
# Identifies the environment type from environment variables and connection strings.
# Returns one of: production, staging, development, local, unknown
#
# Detection priority:
#   1. APP_ENV, RAILS_ENV, NODE_ENV, FLASK_ENV, ENVIRONMENT (explicit env vars)
#   2. DATABASE_URL hostname patterns (prod/staging/dev indicators)
#   3. PGHOST patterns
#   4. Default: unknown (treated as production by tiering logic)
# ---------------------------------------------------------------------------
_db_detect_environment() {
    # Priority 1: explicit environment variables (check in order of specificity)
    local env_val=""
    for env_var in APP_ENV RAILS_ENV NODE_ENV FLASK_ENV ENVIRONMENT; do
        env_val="${!env_var:-}"
        if [[ -n "$env_val" ]]; then
            break
        fi
    done

    if [[ -n "$env_val" ]]; then
        # Normalize to lowercase for case-insensitive matching (bash 3.2 compatible: use tr)
        local env_lower
        env_lower=$(printf '%s' "$env_val" | tr '[:upper:]' '[:lower:]')
        # Normalize to canonical environment names
        case "$env_lower" in
            prod|production)               printf 'production'; return 0 ;;
            staging|stage|preprod|pre-prod) printf 'staging';    return 0 ;;
            dev|development)               printf 'development'; return 0 ;;
            local|test|testing|ci)         printf 'local';       return 0 ;;
            *)
                # Unknown value — fall through to URL detection
                ;;
        esac
    fi

    # Priority 2: DATABASE_URL hostname patterns
    local db_url="${DATABASE_URL:-}"
    if [[ -n "$db_url" ]]; then
        # Extract hostname from URL: protocol://user:pass@hostname:port/db
        local hostname
        hostname=$(printf '%s' "$db_url" | sed -E 's|^[^:]+://([^:@/]+:[^@]+@)?([^/:]+).*|\2|' 2>/dev/null || true)

        if [[ -n "$hostname" ]]; then
            # Production indicators in hostname
            if printf '%s' "$hostname" | grep -qiE '(^|[-_.])prod([-_.]|$)|production|rds\.amazonaws\.com|\.azure\.com|\.gcp\.com|neon\.tech|supabase\.co'; then
                printf 'production'; return 0
            fi
            # Staging indicators
            if printf '%s' "$hostname" | grep -qiE '(^|[-_.])stag([-_.]|$)|staging|preprod|pre-prod'; then
                printf 'staging'; return 0
            fi
            # Development/local indicators
            if printf '%s' "$hostname" | grep -qiE 'localhost|127\.|0\.0\.0\.0|\.local$|(^|[-_.])dev([-_.]|$)'; then
                printf 'development'; return 0
            fi
        fi
    fi

    # Priority 3: PGHOST patterns (PostgreSQL-specific)
    local pghost="${PGHOST:-}"
    if [[ -n "$pghost" ]]; then
        if printf '%s' "$pghost" | grep -qiE '(^|[-_.])prod([-_.]|$)|production|rds\.amazonaws\.com'; then
            printf 'production'; return 0
        fi
        if printf '%s' "$pghost" | grep -qiE 'localhost|127\.|0\.0\.0\.0|/var/run/postgresql|/tmp'; then
            printf 'local'; return 0
        fi
    fi

    # Default: unknown (treated as production by tiering logic — fail-safe)
    printf 'unknown'
    return 0
}

# ---------------------------------------------------------------------------
# _db_classify_risk COMMAND CLI_TYPE
#
# Classifies a database command as: safe, advisory, or deny.
# Returns a string: "<risk_level>:<reason>"
#
# Risk levels:
#   deny     — irreversible data destruction (DROP, TRUNCATE, FLUSHALL, etc.)
#   advisory — risky but potentially reversible (DELETE without WHERE, etc.)
#   safe     — read operations (SELECT, SHOW, EXPLAIN, etc.)
#
# The caller (dispatch in pre-bash.sh) combines risk level with environment tier
# to decide the actual response (hard deny vs. warning vs. silent allow).
# ---------------------------------------------------------------------------
_db_classify_risk() {
    local cmd="$1"
    local cli_type="$2"

    # Normalize to uppercase for SQL pattern matching
    local cmd_upper
    cmd_upper=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')

    case "$cli_type" in
        psql|mysql|sqlite3|cockroach)
            # --- SQL risk patterns ---
            # DENY: irreversible DDL destruction
            if printf '%s' "$cmd_upper" | grep -qE '\bDROP[[:space:]]+(TABLE|DATABASE|SCHEMA|INDEX|VIEW|SEQUENCE|FUNCTION|PROCEDURE|TRIGGER)\b'; then
                printf 'deny:DROP %s permanently destroys database objects with no built-in rollback' \
                    "$(printf '%s' "$cmd_upper" | grep -oE 'DROP[[:space:]]+[A-Z]+' | head -1)"
                return 0
            fi
            # DENY: TRUNCATE removes all rows, no rollback in most engines
            if printf '%s' "$cmd_upper" | grep -qE '\bTRUNCATE\b'; then
                printf 'deny:TRUNCATE permanently removes all rows from a table with no rollback path'
                return 0
            fi
            # DENY: ALTER TABLE DROP COLUMN is irreversible
            if printf '%s' "$cmd_upper" | grep -qE '\bALTER[[:space:]]+TABLE\b.*\bDROP[[:space:]]+COLUMN\b'; then
                printf 'deny:ALTER TABLE DROP COLUMN permanently removes a column and its data'
                return 0
            fi
            # ADVISORY: DELETE without WHERE affects all rows
            if printf '%s' "$cmd_upper" | grep -qE '\bDELETE[[:space:]]+FROM\b' && \
               ! printf '%s' "$cmd_upper" | grep -qE '\bWHERE\b'; then
                printf 'advisory:DELETE without WHERE clause will remove all rows in the table'
                return 0
            fi
            # ADVISORY: UPDATE without WHERE affects all rows
            if printf '%s' "$cmd_upper" | grep -qE '\bUPDATE\b.*\bSET\b' && \
               ! printf '%s' "$cmd_upper" | grep -qE '\bWHERE\b'; then
                printf 'advisory:UPDATE without WHERE clause will modify all rows in the table'
                return 0
            fi
            ;;

        redis-cli)
            # --- Redis risk patterns ---
            # DENY: FLUSHALL removes ALL keys across all databases
            if printf '%s' "$cmd_upper" | grep -qE '\bFLUSHALL\b'; then
                printf 'deny:FLUSHALL permanently deletes all keys across all Redis databases'
                return 0
            fi
            # DENY: FLUSHDB removes all keys in current database
            if printf '%s' "$cmd_upper" | grep -qE '\bFLUSHDB\b'; then
                printf 'deny:FLUSHDB permanently deletes all keys in the current Redis database'
                return 0
            fi
            # DENY: CONFIG SET can alter running server in dangerous ways
            if printf '%s' "$cmd_upper" | grep -qE '\bCONFIG[[:space:]]+SET\b'; then
                printf 'deny:CONFIG SET modifies live Redis server configuration'
                return 0
            fi
            # DENY: SHUTDOWN stops the Redis server
            if printf '%s' "$cmd_upper" | grep -qE '\bSHUTDOWN\b'; then
                printf 'deny:SHUTDOWN stops the Redis server'
                return 0
            fi
            # ADVISORY: DEL multiple keys
            if printf '%s' "$cmd_upper" | grep -qE '\bDEL\b'; then
                printf 'advisory:DEL removes one or more keys permanently'
                return 0
            fi
            ;;

        mongosh)
            # --- MongoDB risk patterns ---
            # DENY: dropDatabase removes entire database
            if printf '%s' "$cmd" | grep -qE 'dropDatabase\(\s*\)'; then
                printf 'deny:dropDatabase() permanently destroys the entire database'
                return 0
            fi
            # DENY: drop() on a collection
            if printf '%s' "$cmd" | grep -qE '\.(drop|dropCollection)\(\s*\)'; then
                printf 'deny:drop()/dropCollection() permanently destroys a collection and all its documents'
                return 0
            fi
            # DENY: deleteMany with empty filter matches all documents
            if printf '%s' "$cmd" | grep -qE 'deleteMany\(\s*\{\s*\}\s*\)'; then
                printf 'deny:deleteMany({}) deletes all documents in the collection'
                return 0
            fi
            # ADVISORY: deleteMany with non-empty filter
            if printf '%s' "$cmd" | grep -qE 'deleteMany\('; then
                printf 'advisory:deleteMany() will permanently remove matching documents'
                return 0
            fi
            # ADVISORY: deleteOne
            if printf '%s' "$cmd" | grep -qE 'deleteOne\('; then
                printf 'advisory:deleteOne() will permanently remove a document'
                return 0
            fi
            ;;
    esac

    # Default: safe (reads, creates, inserts, etc.)
    printf 'safe:'
    return 0
}

# ---------------------------------------------------------------------------
# _db_format_deny REASON SUGGESTION
#
# Formats a deny message consistently for database safety denials.
# The output is passed to emit_deny() in pre-bash.sh.
# ---------------------------------------------------------------------------
_db_format_deny() {
    local reason="$1"
    local suggestion="${2:-}"

    printf 'DB-SAFETY DENY — %s' "$reason"
    if [[ -n "$suggestion" ]]; then
        printf '\n\nSuggestion: %s' "$suggestion"
    fi
}

# ---------------------------------------------------------------------------
# _db_format_advisory REASON
#
# Formats an advisory message for database safety warnings.
# The output is used in hook advisory emissions.
# ---------------------------------------------------------------------------
_db_format_advisory() {
    local reason="$1"
    printf 'DB-SAFETY ADVISORY — %s' "$reason"
}

# ---------------------------------------------------------------------------
# Per-CLI handler stubs
# These will be populated in Wave 2 with full validation logic.
# For now they delegate to _db_classify_risk for basic classification.
# ---------------------------------------------------------------------------

# _db_check_psql COMMAND ENV
# PostgreSQL-specific handler stub
_db_check_psql() {
    local cmd="$1"
    local env="${2:-unknown}"
    _db_classify_risk "$cmd" "psql"
}

# _db_check_mysql COMMAND ENV
# MySQL/MariaDB-specific handler stub
_db_check_mysql() {
    local cmd="$1"
    local env="${2:-unknown}"
    _db_classify_risk "$cmd" "mysql"
}

# _db_check_sqlite3 COMMAND ENV
# SQLite-specific handler stub
_db_check_sqlite3() {
    local cmd="$1"
    local env="${2:-unknown}"
    _db_classify_risk "$cmd" "sqlite3"
}

# _db_check_redis COMMAND ENV
# Redis-specific handler stub
_db_check_redis() {
    local cmd="$1"
    local env="${2:-unknown}"
    _db_classify_risk "$cmd" "redis-cli"
}

# _db_check_mongo COMMAND ENV
# MongoDB-specific handler stub
_db_check_mongo() {
    local cmd="$1"
    local env="${2:-unknown}"
    _db_classify_risk "$cmd" "mongosh"
}

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
_DB_SAFETY_LIB_VERSION=3

# Load state-lib for KV dual-write (DEC-V4-KV-001).
# require_state is a no-op if state-lib is already loaded (idempotent guard).
# Called here at load time so all functions below can use state_read/state_update.
# Wrapped in a subshell-safe guard: if require_state is not yet in scope (i.e., this
# lib is sourced before source-lib.sh in tests), we skip silently — flat-file path works.
if type require_state &>/dev/null 2>&1; then
    require_state
fi

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
    local cli_pattern_prefix='(^|[[:space:]]|&&|\|\|?|;|\(|/)('
    local cli_pattern_suffix=')([[:space:]]|$|;|&&|\|)'

    # Check each CLI in priority order (most specific first)
    local cli
    for cli in psql mysql sqlite3 mongosh redis-cli cockroach; do
        if printf '%s' "$stripped" | grep -qE "${cli_pattern_prefix}${cli}${cli_pattern_suffix}"; then
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

# =============================================================================
# WAVE 2A — Per-CLI handler full implementations (B1)
#
# @decision DEC-DBSAFE-004
# @title Per-CLI handlers add RCE/code-execution patterns on top of classify_risk
# @status accepted
# @rationale _db_classify_risk handles universal SQL risk patterns (DROP, TRUNCATE,
#   DELETE without WHERE). Per-CLI handlers add CLI-specific patterns that are not
#   SQL commands: psql shell escapes, mysql file I/O, sqlite3 dot-commands, redis
#   Lua scripting, and mongosh cluster management. The call order is:
#     1. _db_classify_risk (common SQL patterns) — return early if deny/advisory found
#     2. CLI-specific RCE/code-execution patterns
#   This ensures common patterns are never missed and CLI-specific logic only fires
#   when the common check returns safe.
#
# @decision DEC-DBSAFE-005
# @title CLI-specific patterns focus on code execution / RCE vectors
# @status accepted
# @rationale The most dangerous CLI-specific risks are not data destruction (already
#   covered by classify_risk) but arbitrary code execution: psql \! runs shell commands,
#   mysql SOURCE executes SQL files, redis EVAL runs Lua, sqlite3 .shell is a full
#   shell escape. These patterns bypass all SQL-level safety guards and can exfiltrate
#   data, install malware, or pivot to other systems. All receive "deny" classification.
# =============================================================================

# ---------------------------------------------------------------------------
# _db_check_psql COMMAND ENV
#
# PostgreSQL-specific risk handler. Checks:
#   1. Common SQL patterns via _db_classify_risk (DROP, TRUNCATE, etc.)
#   2. \! shell escape — executes arbitrary shell commands
#   3. COPY ... TO PROGRAM — RCE via shell pipeline
#   4. CREATE EXTENSION — loads arbitrary C code into the server process
#
# Returns: "<risk_level>:<reason>" (same format as _db_classify_risk)
# ---------------------------------------------------------------------------
_db_check_psql() {
    local cmd="$1"
    local env="${2:-unknown}"

    # Step 1: Common SQL patterns (DROP, TRUNCATE, DELETE without WHERE, etc.)
    local _common_risk
    _common_risk=$(_db_classify_risk "$cmd" "psql")
    local _common_level="${_common_risk%%:*}"
    if [[ "$_common_level" == "deny" || "$_common_level" == "advisory" ]]; then
        printf '%s' "$_common_risk"
        return 0
    fi

    # Step 2: psql-specific RCE vectors

    # \! executes arbitrary shell commands from within psql interactive mode
    # Also matches quoted forms like "\!" and psql -c "\! cmd"
    if printf '%s' "$cmd" | grep -qE '\\\\!|\\!'; then
        printf 'deny:psql \\! shell escape executes arbitrary shell commands — this is an RCE vector'
        return 0
    fi

    # COPY ... TO PROGRAM executes a shell command to receive query output
    # Matches: COPY table TO PROGRAM 'cmd' and variants
    local cmd_upper
    cmd_upper=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')
    if printf '%s' "$cmd_upper" | grep -qE '\bCOPY\b.*\bTO\b[[:space:]]+PROGRAM\b'; then
        printf 'deny:psql COPY ... TO PROGRAM executes a shell command — this is an RCE vector that can exfiltrate data or run arbitrary code'
        return 0
    fi

    # CREATE EXTENSION loads a shared library (.so) into the PostgreSQL server process
    # This can execute arbitrary C code with server privileges
    if printf '%s' "$cmd_upper" | grep -qE '\bCREATE[[:space:]]+EXTENSION\b'; then
        printf 'deny:psql CREATE EXTENSION loads a shared library into the server process — can execute arbitrary C code with server privileges'
        return 0
    fi

    printf 'safe:'
    return 0
}

# ---------------------------------------------------------------------------
# _db_check_mysql COMMAND ENV
#
# MySQL/MariaDB-specific risk handler. Checks:
#   1. Common SQL patterns via _db_classify_risk
#   2. LOAD DATA INFILE — reads arbitrary files from the server filesystem
#   3. INTO OUTFILE / INTO DUMPFILE — writes arbitrary files on the server
#   4. SOURCE — executes an SQL file, allowing arbitrary SQL file execution
#
# Returns: "<risk_level>:<reason>" (same format as _db_classify_risk)
# ---------------------------------------------------------------------------
_db_check_mysql() {
    local cmd="$1"
    local env="${2:-unknown}"

    # Step 1: Common SQL patterns
    local _common_risk
    _common_risk=$(_db_classify_risk "$cmd" "mysql")
    local _common_level="${_common_risk%%:*}"
    if [[ "$_common_level" == "deny" || "$_common_level" == "advisory" ]]; then
        printf '%s' "$_common_risk"
        return 0
    fi

    # Step 2: MySQL-specific file I/O and execution vectors

    local cmd_upper
    cmd_upper=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')

    # LOAD DATA INFILE reads arbitrary server-side files into a table
    # LOAD DATA LOCAL INFILE reads client-side files (still dangerous)
    if printf '%s' "$cmd_upper" | grep -qE '\bLOAD[[:space:]]+DATA\b.*\bINFILE\b'; then
        printf 'deny:mysql LOAD DATA INFILE reads arbitrary files from the server filesystem — data exfiltration vector'
        return 0
    fi

    # SELECT ... INTO OUTFILE / INTO DUMPFILE writes arbitrary server-side files
    if printf '%s' "$cmd_upper" | grep -qE '\bINTO[[:space:]]+(OUTFILE|DUMPFILE)\b'; then
        printf 'deny:mysql INTO OUTFILE/DUMPFILE writes arbitrary files on the server filesystem — can overwrite system files or create web shells'
        return 0
    fi

    # SOURCE executes an external SQL file — arbitrary SQL file execution
    # Matches: SOURCE /path/to/file.sql or \. /path/to/file.sql
    if printf '%s' "$cmd_upper" | grep -qE '\bSOURCE\b[[:space:]]+\S'; then
        printf 'deny:mysql SOURCE executes an external SQL file — arbitrary SQL file execution vector'
        return 0
    fi

    printf 'safe:'
    return 0
}

# ---------------------------------------------------------------------------
# _db_mysql_ddl_advisory COMMAND
#
# Returns an advisory string when a MySQL DDL operation is detected, or empty
# string if no DDL is present. Called AFTER _db_check_mysql() to emit additional
# context about MySQL's auto-commit behavior for DDL statements.
#
# MySQL auto-commits DDL: Unlike Postgres, MySQL does NOT support transactional DDL.
# ALTER TABLE, DROP TABLE, CREATE TABLE are committed immediately and cannot be
# rolled back via ROLLBACK — even if executed inside an explicit transaction.
#
# Returns: advisory message string or empty string
#
# @decision DEC-DBSAFE-B12-001
# @title MySQL DDL advisory is a separate function, not embedded in _db_check_mysql
# @status accepted
# @rationale _db_check_mysql() returns a single "level:reason" string. Adding
#   an advisory alongside a deny or safe result would require changing the return
#   protocol for all callers. A companion function emitting the advisory is cleaner:
#   pre-bash.sh calls it immediately after _db_check_mysql() and emits the advisory
#   independently. This follows the pattern of _db_detect_migration_advisory().
# ---------------------------------------------------------------------------
_db_mysql_ddl_advisory() {
    local cmd="$1"

    local cmd_upper
    cmd_upper=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')

    # ALTER TABLE, DROP TABLE, CREATE TABLE — all are auto-committed DDL in MySQL
    if printf '%s' "$cmd_upper" | grep -qE '\b(ALTER[[:space:]]+TABLE|DROP[[:space:]]+TABLE|CREATE[[:space:]]+TABLE)\b'; then
        printf 'MySQL auto-commits DDL operations. ALTER/DROP/CREATE cannot be rolled back via transaction. Verify backup before proceeding.'
        return 0
    fi

    printf ''
    return 0
}

# ---------------------------------------------------------------------------
# _db_check_sqlite3 COMMAND ENV
#
# SQLite-specific risk handler. Checks:
#   1. Common SQL patterns via _db_classify_risk
#   2. .shell / .system — execute arbitrary shell commands
#   3. .import with pipe (| prefix) — executes a command as import source
#   4. .restore — overwrites the current database from a backup file
#
# Returns: "<risk_level>:<reason>" (same format as _db_classify_risk)
# ---------------------------------------------------------------------------
_db_check_sqlite3() {
    local cmd="$1"
    local env="${2:-unknown}"

    # Step 1: Common SQL patterns
    local _common_risk
    _common_risk=$(_db_classify_risk "$cmd" "sqlite3")
    local _common_level="${_common_risk%%:*}"
    if [[ "$_common_level" == "deny" || "$_common_level" == "advisory" ]]; then
        printf '%s' "$_common_risk"
        return 0
    fi

    # Step 2: SQLite dot-command shell escapes

    # .shell and .system both execute arbitrary shell commands
    if printf '%s' "$cmd" | grep -qE '\.(shell|system)[[:space:]]'; then
        printf 'deny:sqlite3 .shell/.system dot-commands execute arbitrary shell commands — full shell escape from SQLite context'
        return 0
    fi

    # .import with | prefix executes a command and imports its stdout as data
    # Format: .import '| command args' tablename
    if printf '%s' "$cmd" | grep -qE '\.import[[:space:]].*\|'; then
        printf 'deny:sqlite3 .import with pipe executes a shell command to produce import data — code execution vector'
        return 0
    fi

    # .restore overwrites the current database file from a backup
    # Can be used to replace a known-good DB with a malicious one
    if printf '%s' "$cmd" | grep -qE '\.restore\b'; then
        printf 'deny:sqlite3 .restore overwrites the current database from a backup file — can replace DB contents irreversibly'
        return 0
    fi

    printf 'safe:'
    return 0
}

# ---------------------------------------------------------------------------
# _db_check_redis COMMAND ENV
#
# Redis-specific risk handler. Checks:
#   1. Common Redis patterns via _db_classify_risk (FLUSHALL, FLUSHDB, etc.)
#   2. EVAL / EVALSHA — execute arbitrary Lua scripts in the Redis runtime
#   3. MODULE LOAD — loads a shared library with arbitrary C code
#   4. DEBUG commands — debug sleep/reload/crash can harm server availability
#
# Returns: "<risk_level>:<reason>" (same format as _db_classify_risk)
# ---------------------------------------------------------------------------
_db_check_redis() {
    local cmd="$1"
    local env="${2:-unknown}"

    # Step 1: Common Redis patterns (FLUSHALL, FLUSHDB, CONFIG SET, SHUTDOWN, DEL)
    local _common_risk
    _common_risk=$(_db_classify_risk "$cmd" "redis-cli")
    local _common_level="${_common_risk%%:*}"
    if [[ "$_common_level" == "deny" || "$_common_level" == "advisory" ]]; then
        printf '%s' "$_common_risk"
        return 0
    fi

    # Step 2: Redis-specific code execution vectors

    local cmd_upper
    cmd_upper=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')

    # EVAL executes arbitrary Lua scripts within the Redis runtime
    # EVALSHA executes a cached Lua script by SHA hash
    if printf '%s' "$cmd_upper" | grep -qE '\b(EVAL|EVALSHA)\b'; then
        printf 'deny:redis EVAL/EVALSHA executes arbitrary Lua scripts in the Redis runtime — code execution vector with access to all Redis data'
        return 0
    fi

    # MODULE LOAD loads a shared library (.so) into the Redis process
    # Redis modules run with full server privileges and can execute arbitrary C code
    if printf '%s' "$cmd_upper" | grep -qE '\bMODULE[[:space:]]+LOAD\b'; then
        printf 'deny:redis MODULE LOAD loads a shared library into the Redis process — executes arbitrary C code with server privileges'
        return 0
    fi

    # DEBUG commands can harm server availability (sleep, reload, crash, etc.)
    if printf '%s' "$cmd_upper" | grep -qE '\bDEBUG\b'; then
        printf 'deny:redis DEBUG command can cause server downtime (DEBUG sleep/reload/crash) or expose sensitive internals'
        return 0
    fi

    printf 'safe:'
    return 0
}

# ---------------------------------------------------------------------------
# _db_check_mongo COMMAND ENV
#
# MongoDB-specific risk handler. Checks:
#   1. Common MongoDB patterns via _db_classify_risk (dropDatabase, drop, deleteMany)
#   2. rs.reconfig() — reconfigures a replica set (can cause data loss / split-brain)
#   3. sh.shardCollection() — shards a collection (irreversible schema operation)
#
# Returns: "<risk_level>:<reason>" (same format as _db_classify_risk)
# ---------------------------------------------------------------------------
_db_check_mongo() {
    local cmd="$1"
    local env="${2:-unknown}"

    # Step 1: Common MongoDB patterns (dropDatabase, drop, deleteMany, deleteOne)
    local _common_risk
    _common_risk=$(_db_classify_risk "$cmd" "mongosh")
    local _common_level="${_common_risk%%:*}"
    if [[ "$_common_level" == "deny" || "$_common_level" == "advisory" ]]; then
        printf '%s' "$_common_risk"
        return 0
    fi

    # Step 2: MongoDB cluster administration (destructive / irreversible operations)

    # rs.reconfig() changes replica set membership — can cause data loss, split-brain,
    # or make the replica set non-functional if done incorrectly
    if printf '%s' "$cmd" | grep -qE 'rs\.reconfig\s*\('; then
        printf 'deny:mongosh rs.reconfig() reconfigures the replica set — can cause data loss, split-brain, or replica set failure'
        return 0
    fi

    # sh.shardCollection() shards a collection — irreversible and requires careful planning
    if printf '%s' "$cmd" | grep -qE 'sh\.shardCollection\s*\('; then
        printf 'deny:mongosh sh.shardCollection() shards a collection — irreversible operation requiring careful shard key planning'
        return 0
    fi

    printf 'safe:'
    return 0
}

# =============================================================================
# WAVE 2A — Non-interactive TTY fail-safe (B3)
#
# @decision DEC-DBSAFE-006
# @title TTY fail-safe: auto-deny destructive DB ops in non-interactive mode
# @status accepted
# @rationale AI agents execute commands non-interactively — stdin is a pipe, not a
#   TTY. Human operators at a terminal get interactive confirmation prompts before
#   destructive operations; agents bypass those prompts entirely. The ! -t 0 check
#   identifies this case. When an agent pipes a destructive database command without
#   a TTY, we auto-deny and route through Database Guardian (which requires explicit
#   human approval). Advisory-level risks are not auto-denied in non-interactive mode
#   because they are potentially recoverable and blocking them would be too disruptive
#   for normal agent workflows (SELECTs, INSERTs, monitored DELETEs with WHERE, etc.).
# =============================================================================

# ---------------------------------------------------------------------------
# _db_is_non_interactive
#
# Returns 0 (true) if stdin is NOT a TTY (non-interactive execution).
# AI agents typically pipe commands, so ! -t 0 is true in agent contexts.
# Human operators at a terminal have a TTY attached (! -t 0 is false).
#
# Usage: _db_is_non_interactive && echo "non-interactive"
# ---------------------------------------------------------------------------
_db_is_non_interactive() {
    [[ ! -t 0 ]]
}

# ---------------------------------------------------------------------------
# _db_check_tty RISK_LEVEL RISK_RESULT
#
# Checks if the current execution is non-interactive AND the risk level is deny.
# If so, returns a deny string for the caller to act on.
# Returns empty string if no TTY-based denial is warranted.
#
# Args:
#   RISK_LEVEL  — "deny", "advisory", or "safe"
#   RISK_RESULT — full "<level>:<reason>" string from classify_risk or per-CLI handler
#
# Returns: "deny:<reason>" if non-interactive + deny, else empty string.
#
# @decision DEC-DBSAFE-006 (see above)
# ---------------------------------------------------------------------------
_db_check_tty() {
    local risk_level="$1"
    local risk_result="$2"

    # Only auto-deny for "deny" risk in non-interactive mode
    # Advisory risks are allowed through with normal environment tiering
    if [[ "$risk_level" == "deny" ]] && _db_is_non_interactive; then
        local reason="${risk_result#*:}"
        printf 'deny:Non-interactive execution detected. Destructive database operation blocked: %s. Run interactively or route through Database Guardian.' "$reason"
        return 0
    fi

    # Safe or advisory, or interactive TTY — no TTY-based denial
    printf ''
    return 0
}

# =============================================================================
# WAVE 2A — Forced safety flags (B4)
#
# @decision DEC-DBSAFE-007
# @title Deny-with-correction pattern for missing CLI safety flags
# @status accepted
# @rationale psql's ON_ERROR_STOP=1 prevents partial execution when a multi-statement
#   script encounters an error — without it, psql continues executing after an error,
#   leaving the database in a partially-modified state. mysql's --safe-updates
#   prevents unbounded UPDATE/DELETE (those without a WHERE clause or LIMIT) —
#   without it, a typo can wipe an entire table. Both flags are standard operational
#   best practices. The deny-with-correction pattern (same as Check 1 /tmp/ redirect
#   and Check 3 --force-with-lease) provides the corrected command so the agent can
#   immediately retry with the right flags instead of requiring manual intervention.
#   NOTE: updatedInput is NOT supported in PreToolUse hooks (see DEC-GUARD-REWRITE-001),
#   so the corrected command appears in the deny reason text, not as an auto-correction.
#   One-liner commands (-c / -e flags) are exempt — ON_ERROR_STOP is less useful for
#   single-statement executions and --safe-updates is session-scoped anyway.
# =============================================================================

# ---------------------------------------------------------------------------
# _db_inject_safety_flags COMMAND
#
# Checks if CLI-specific safety flags are present. If missing, returns
# "deny:<corrected_command>" with the flag added to the command.
# Returns empty string if flags are already present or CLI is exempt.
#
# Supported CLIs:
#   psql  — requires -v ON_ERROR_STOP=1 (unless using -c one-liner)
#   mysql — requires --safe-updates (unless using -e one-liner)
#
# Returns: "deny:<message_with_corrected_command>" or empty string
# ---------------------------------------------------------------------------
_db_inject_safety_flags() {
    local cmd="$1"

    # Only applies to psql and mysql
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()(psql)([[:space:]]|$|;|&&|\|)'; then
        # psql one-liner check: if -c flag is present, skip (single statement, less relevant)
        if printf '%s' "$cmd" | grep -qE '\bpsql\b.*[[:space:]]-c[[:space:]]'; then
            printf ''
            return 0
        fi

        # Check if ON_ERROR_STOP is already present (flag or env var)
        if printf '%s' "$cmd" | grep -qE 'ON_ERROR_STOP'; then
            printf ''
            return 0
        fi

        # Missing ON_ERROR_STOP — deny with corrected command
        # Insert -v ON_ERROR_STOP=1 immediately after 'psql'
        local corrected
        corrected=$(printf '%s' "$cmd" | sed -E 's/(^|[[:space:]])(psql)([[:space:]]|$)/\1\2 -v ON_ERROR_STOP=1\3/')
        printf 'deny:psql is missing -v ON_ERROR_STOP=1 (stops execution on first error, preventing partial script execution). Run instead: %s' "$corrected"
        return 0
    fi

    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()(mysql)([[:space:]]|$|;|&&|\|)'; then
        # mysql one-liner check: if -e flag is present, skip (single statement)
        if printf '%s' "$cmd" | grep -qE '\bmysql\b.*[[:space:]]-e[[:space:]]'; then
            printf ''
            return 0
        fi

        # Check if --safe-updates or its alias --i-am-a-dummy or --no-safe-updates is present
        if printf '%s' "$cmd" | grep -qE '(--safe-updates|--i-am-a-dummy|--no-safe-updates)'; then
            printf ''
            return 0
        fi

        # Missing --safe-updates — deny with corrected command
        local corrected
        corrected=$(printf '%s' "$cmd" | sed -E 's/(^|[[:space:]])(mysql)([[:space:]]|$)/\1\2 --safe-updates\3/')
        printf 'deny:mysql is missing --safe-updates (prevents unbounded UPDATE/DELETE without WHERE clause). Run instead: %s' "$corrected"
        return 0
    fi

    # Not psql or mysql — no flag injection
    printf ''
    return 0
}

# =============================================================================
# Wave 2b: Multi-vector database infrastructure safety functions
#
# @decision DEC-DBSAFE-W2B-001
# @title Four-function multi-vector safety layer for non-CLI database infrastructure
# @status accepted
# @rationale Database infrastructure can be destroyed by tools that are NOT database
#   CLIs — migration frameworks that wipe schemas, IaC tools that tear down DB instances,
#   container orchestration that deletes persistent volumes, and ORM patterns that bypass
#   migration management. Wave 2b adds four detectors (B5-B8) that fire in pre-bash.sh
#   BEFORE the existing DB CLI section, catching these vectors early. Each function
#   returns a standardized result string: "allow", "deny:<reason>", or "advisory:<reason>".
#   Migration frameworks (B5) are ALLOWED through — they are intentional schema changes —
#   but advisory flags are emitted for especially dangerous variants (flyway clean,
#   alembic downgrade base, drizzle-kit push --force) and for any migration in production.
#
# @decision DEC-DBSAFE-W2B-002
# @title _db_detect_migration returns framework name, advisory is separate function
# @status accepted
# @rationale Separating detection (returns framework name / "none") from advisory
#   classification (_db_detect_migration_advisory) keeps the detection function
#   pure and testable in isolation. pre-bash.sh can call detection first for the
#   quick-exit gate, then call advisory only when a framework was detected.
#   This matches the pattern established by _db_detect_cli + _db_classify_risk.
# =============================================================================

# ---------------------------------------------------------------------------
# _db_detect_migration COMMAND
#
# Recognizes migration framework commands and returns the framework name.
# Migration commands are ALLOWED through (they are intentional schema changes),
# but callers should also invoke _db_detect_migration_advisory for special-case
# advisory warnings.
#
# Returns: "<framework_name>" if detected, "none" if not.
#
# Supported frameworks:
#   rails    — rails db:migrate, rails db:rollback, rails db:schema:load, rake db:*
#   django   — python/python3 manage.py migrate|makemigrations
#   alembic  — alembic upgrade|downgrade|revision
#   prisma   — prisma migrate deploy|dev, prisma db push
#   flyway   — flyway migrate|repair|clean
#   liquibase — liquibase update|rollback
#   sequelize — npx sequelize-cli db:migrate
#   knex     — npx knex migrate:latest|migrate:rollback
#   typeorm  — typeorm migration:run
#   goose    — goose up|down
#   golang-migrate — migrate -path
#   drizzle-kit — drizzle-kit push|generate|migrate
# ---------------------------------------------------------------------------
_db_detect_migration() {
    local cmd="$1"

    # Rails: rails db:migrate, rails db:rollback, rails db:schema:load
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()rails[[:space:]]+(db:(migrate|rollback|schema:|reset|seed)|db:[a-z])'; then
        printf 'rails'; return 0
    fi
    # Rake: rake db:migrate, rake db:rollback, rake db:*
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()rake[[:space:]]+db:[a-z]'; then
        printf 'rails'; return 0
    fi

    # Django: python/python3 manage.py migrate|makemigrations
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()python3?[[:space:]]+manage\.py[[:space:]]+(migrate|makemigrations)'; then
        printf 'django'; return 0
    fi

    # Alembic: alembic upgrade|downgrade|revision
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()alembic[[:space:]]+(upgrade|downgrade|revision)'; then
        printf 'alembic'; return 0
    fi

    # Prisma: prisma migrate deploy|dev, prisma db push
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()prisma[[:space:]]+(migrate[[:space:]]+(deploy|dev)|db[[:space:]]+push)'; then
        printf 'prisma'; return 0
    fi

    # Flyway: flyway migrate|repair|clean
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()flyway[[:space:]]+(migrate|repair|clean)([[:space:]]|$)'; then
        printf 'flyway'; return 0
    fi

    # Liquibase: liquibase update|rollback
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()liquibase[[:space:]]+(update|rollback)'; then
        printf 'liquibase'; return 0
    fi

    # Sequelize: npx sequelize-cli db:migrate
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()npx[[:space:]]+sequelize-cli[[:space:]]+db:migrate'; then
        printf 'sequelize'; return 0
    fi

    # Knex: npx knex migrate:latest|migrate:rollback
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()npx[[:space:]]+knex[[:space:]]+migrate:(latest|rollback)'; then
        printf 'knex'; return 0
    fi

    # TypeORM: typeorm migration:run
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()typeorm[[:space:]]+migration:run'; then
        printf 'typeorm'; return 0
    fi

    # Goose: goose up|down
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()goose[[:space:]]+(up|down)([[:space:]]|$)'; then
        printf 'goose'; return 0
    fi

    # golang-migrate: migrate -path
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()migrate[[:space:]]+-path'; then
        printf 'golang-migrate'; return 0
    fi

    # Drizzle Kit: drizzle-kit push|generate|migrate
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()drizzle-kit[[:space:]]+(push|generate|migrate)'; then
        printf 'drizzle-kit'; return 0
    fi

    printf 'none'
    return 0
}

# ---------------------------------------------------------------------------
# _db_detect_migration_advisory COMMAND
#
# Returns an advisory message string for especially dangerous migration variants,
# or an empty string if no advisory applies.
#
# Special cases flagged as advisory (not deny — the commands are still allowed):
#   drizzle-kit push --force  → "drizzle-kit push --force skips confirmation"
#   alembic downgrade base    → "alembic downgrade base reverts ALL migrations"
#   flyway clean              → "flyway clean drops all objects in the configured schemas"
#   production env + any migration → "Production migration detected. Ensure this is intentional."
#
# Production check fires after special-case check so both can appear if applicable.
# Callers that need just the advisory string can pipe or capture this output.
# ---------------------------------------------------------------------------
_db_detect_migration_advisory() {
    local cmd="$1"
    local advisory=""

    # Special case: drizzle-kit push --force
    if printf '%s' "$cmd" | grep -qE 'drizzle-kit[[:space:]]+push.*--force'; then
        advisory="drizzle-kit push --force skips confirmation"
    fi

    # Special case: alembic downgrade base
    if printf '%s' "$cmd" | grep -qE 'alembic[[:space:]]+downgrade[[:space:]]+base'; then
        advisory="alembic downgrade base reverts ALL migrations"
    fi

    # Special case: flyway clean (destructive — drops all DB objects)
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()flyway[[:space:]]+clean([[:space:]]|$)'; then
        advisory="flyway clean drops all objects in the configured schemas"
    fi

    # Production environment advisory (appended after special cases)
    local env
    env=$(_db_detect_environment)
    if [[ "$env" == "production" || "$env" == "unknown" ]]; then
        # Only append production advisory when this is actually a migration command
        local framework
        framework=$(_db_detect_migration "$cmd")
        if [[ "$framework" != "none" ]]; then
            if [[ -n "$advisory" ]]; then
                advisory="${advisory}. Production migration detected. Ensure this is intentional."
            else
                advisory="Production migration detected. Ensure this is intentional."
            fi
        fi
    fi

    printf '%s' "$advisory"
    return 0
}

# ---------------------------------------------------------------------------
# _db_detect_iac COMMAND
#
# Detects Infrastructure-as-Code commands that can destroy database infrastructure.
# Returns: "deny:<reason>", "advisory:<reason>", or "allow"
#
# Decision matrix:
#   terraform destroy              → deny (always)
#   terraform apply -auto-approve  → deny (bypasses human review)
#   terraform apply                → allow (terraform prompts interactively)
#   terraform plan                 → allow (read-only)
#   pulumi destroy                 → deny (always)
#   pulumi up --yes                → deny (bypasses confirmation)
#   pulumi up                      → allow (pulumi prompts interactively)
#   aws cloudformation delete-stack → deny (always)
#
# @decision DEC-DBSAFE-W2B-003
# @title terraform apply without -auto-approve is ALLOW (interactive prompt is the gate)
# @status accepted
# @rationale terraform apply prompts "Do you want to perform these actions?" before
#   executing. This human-in-the-loop confirmation is sufficient protection for
#   interactive use. Only -auto-approve bypasses it — that variant is denied.
#   terraform destroy always denies because there is no "selective" destroy;
#   it tears down all resources matching the state file.
# ---------------------------------------------------------------------------
_db_detect_iac() {
    local cmd="$1"

    # terraform destroy — always deny
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()terraform[[:space:]]+destroy'; then
        printf 'deny:terraform destroy tears down all infrastructure defined in the state file'
        return 0
    fi

    # terraform apply -auto-approve — deny (bypasses human review)
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()terraform[[:space:]]+apply.*-auto-approve'; then
        printf 'deny:terraform apply -auto-approve bypasses the human review prompt — infrastructure changes must be reviewed interactively'
        return 0
    fi

    # terraform apply (without -auto-approve) — allow (interactive prompt is the gate)
    # terraform plan — allow (read-only)
    # These are caught by the generic terraform check below only if explicitly denied above.
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()terraform[[:space:]]+(apply|plan)'; then
        printf 'allow'; return 0
    fi

    # pulumi destroy — always deny
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()pulumi[[:space:]]+destroy'; then
        printf 'deny:pulumi destroy tears down all infrastructure in the current stack'
        return 0
    fi

    # pulumi up --yes — deny (bypasses confirmation)
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()pulumi[[:space:]]+up.*--yes'; then
        printf 'deny:pulumi up --yes bypasses the confirmation prompt — infrastructure changes must be reviewed interactively'
        return 0
    fi

    # pulumi up (without --yes) — allow
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()pulumi[[:space:]]+up([[:space:]]|$)'; then
        printf 'allow'; return 0
    fi

    # aws cloudformation delete-stack — always deny
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()aws[[:space:]]+cloudformation[[:space:]]+delete-stack'; then
        printf 'deny:aws cloudformation delete-stack permanently destroys the CloudFormation stack and all its resources'
        return 0
    fi

    printf 'allow'
    return 0
}

# ---------------------------------------------------------------------------
# _db_detect_container COMMAND
#
# Detects container/volume destruction commands that can destroy persistent
# database storage.
#
# Returns: "deny:<reason>", "advisory:<reason>", or "allow"
#
# Decision matrix:
#   docker-compose down -v / --volumes → deny (deletes named volumes)
#   docker compose down -v / --volumes → deny (v2 plugin syntax)
#   docker-compose down (no flag)      → allow (stops containers, keeps volumes)
#   docker compose down (no flag)      → allow
#   docker volume rm                   → deny (always)
#   docker volume prune                → deny (removes ALL unused volumes)
#   docker volume ls/inspect           → allow (read-only)
#   kubectl delete pvc                 → deny (PVC deletion may trigger data loss)
#   kubectl delete pv                  → deny
#
# @decision DEC-DBSAFE-W2B-004
# @title Both docker-compose v1 and docker compose v2 syntax handled
# @status accepted
# @rationale Docker Compose v1 uses the hyphenated binary name (docker-compose).
#   Docker Compose v2 ships as a Docker CLI plugin using space-separated syntax
#   (docker compose). Both are in active use as of 2024. The -v / --volumes flag
#   check must cover both syntaxes. The grep pattern matches both with a single
#   expression by matching "docker[-[:space:]]compose".
# ---------------------------------------------------------------------------
_db_detect_container() {
    local cmd="$1"

    # docker-compose down -v / --volumes (v1 hyphenated binary)
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()docker-compose[[:space:]]+down'; then
        if printf '%s' "$cmd" | grep -qE 'docker-compose[[:space:]]+down.*(-v\b|--volumes\b)'; then
            printf 'deny:docker-compose down -v deletes named volumes, permanently destroying persistent database data'
            return 0
        fi
        printf 'allow'; return 0
    fi

    # docker compose down -v / --volumes (v2 plugin syntax)
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()docker[[:space:]]+compose[[:space:]]+down'; then
        if printf '%s' "$cmd" | grep -qE 'docker[[:space:]]+compose[[:space:]]+down.*(-v\b|--volumes\b)'; then
            printf 'deny:docker compose down -v deletes named volumes, permanently destroying persistent database data'
            return 0
        fi
        printf 'allow'; return 0
    fi

    # docker volume rm — always deny
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()docker[[:space:]]+volume[[:space:]]+rm([[:space:]]|$)'; then
        printf 'deny:docker volume rm permanently deletes the named volume and all data it contains'
        return 0
    fi

    # docker volume prune — always deny
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()docker[[:space:]]+volume[[:space:]]+prune([[:space:]]|$)'; then
        printf 'deny:docker volume prune removes ALL unused volumes — this may delete database volumes that are not currently attached to a running container'
        return 0
    fi

    # kubectl delete pvc — deny
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()kubectl[[:space:]]+delete[[:space:]]+pvc([[:space:]]|$)'; then
        printf 'deny:kubectl delete pvc deletes a PersistentVolumeClaim — data loss depends on the ReclaimPolicy (Retain vs Delete). Verify the PV ReclaimPolicy before proceeding.'
        return 0
    fi

    # kubectl delete pv — deny
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()kubectl[[:space:]]+delete[[:space:]]+pv([[:space:]]|$)'; then
        printf 'deny:kubectl delete pv deletes a PersistentVolume — this may permanently destroy the underlying storage'
        return 0
    fi

    printf 'allow'
    return 0
}

# ---------------------------------------------------------------------------
# _db_detect_orm COMMAND
#
# Detects ORM destructive patterns in bash command strings.
# Best-effort detection — catches what is visible in the command string.
#
# Returns: "deny:<reason>", "advisory:<reason>", or "allow"
#
# Patterns detected:
#   sequelize.sync({ force: true })  → advisory (drops+recreates all tables)
#   db.metadata.drop_all()           → advisory (SQLAlchemy drops all tables)
#   npm run seed                     → advisory if production environment
#   python seed.py                   → advisory if production environment
#
# @decision DEC-DBSAFE-W2B-005
# @title ORM detection is advisory-only (not deny) due to best-effort nature
# @status accepted
# @rationale ORM patterns are embedded in application code invoked via CLI.
#   We can only inspect the command string, not the code being executed.
#   False positives (a "seed" script that is read-only, a sync with force
#   that is intentional in dev) would create friction without clear benefit.
#   Advisory is appropriate: the user sees the warning and can confirm intent.
#   Seed scripts in production are the highest-risk detected pattern — they
#   can populate unexpected data or truncate existing data depending on
#   implementation. Production-env gating is the primary useful signal.
# ---------------------------------------------------------------------------
_db_detect_orm() {
    local cmd="$1"

    # sequelize.sync({ force: true }) — drops and recreates all tables
    if printf '%s' "$cmd" | grep -qE 'sequelize\.sync\(\s*\{[^}]*force\s*:\s*true'; then
        printf 'advisory:sequelize.sync({ force: true }) drops and recreates all tables, permanently destroying existing data'
        return 0
    fi

    # db.metadata.drop_all() — SQLAlchemy drops all tables
    if printf '%s' "$cmd" | grep -qE 'drop_all\s*\('; then
        printf 'advisory:drop_all() drops all tables defined in the SQLAlchemy metadata — permanent data loss'
        return 0
    fi

    # Seed scripts in production — advisory
    local env
    env=$(_db_detect_environment)
    if [[ "$env" == "production" || "$env" == "unknown" ]]; then
        # npm run seed
        if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()npm[[:space:]]+run[[:space:]]+seed([[:space:]]|$)'; then
            printf 'advisory:Running a seed script in production may overwrite or corrupt existing data. Verify this is intentional.'
            return 0
        fi
        # python seed.py (or python3 seed.py)
        if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|&&|\|\|?|;|\()python3?[[:space:]]+seed\.py([[:space:]]|$)'; then
            printf 'advisory:Running a seed script in production may overwrite or corrupt existing data. Verify this is intentional.'
            return 0
        fi
    fi

    printf 'allow'
    return 0
}

# ---------------------------------------------------------------------------
# _db_op_type_from_cli CLI_NAME COMMAND
#
# Maps a database CLI + command text to a Database Guardian operation_type.
# Used by pre-bash.sh to populate the DB-GUARDIAN-REQUIRED signal so the
# orchestrator can construct a typed handoff request for the Guardian agent.
#
# Returns one of: schema_alter | query | data_mutation | migration
# ---------------------------------------------------------------------------
_db_op_type_from_cli() {
    local cli_name="${1:-}"
    local cmd="${2:-}"

    # Detect schema-altering operations (DDL)
    if printf '%s' "$cmd" | grep -qiE '\b(ALTER[[:space:]]+TABLE|CREATE[[:space:]]+(TABLE|INDEX|VIEW|SCHEMA)|DROP[[:space:]]+(TABLE|VIEW|INDEX|SCHEMA)|RENAME[[:space:]]+TABLE|ADD[[:space:]]+COLUMN|DROP[[:space:]]+COLUMN|MODIFY[[:space:]]+COLUMN)\b'; then
        printf 'schema_alter'
        return 0
    fi

    # Detect data mutations (DML write ops)
    # Note: UPDATE uses [[:alnum:]] without trailing \b — \w+\b would require a word
    # boundary after a single character match, which always fails mid-word. The other
    # patterns naturally end at word boundaries via the mandatory keyword suffix.
    if printf '%s' "$cmd" | grep -qiE '\b(INSERT[[:space:]]+INTO|DELETE[[:space:]]+FROM|TRUNCATE[[:space:]]+TABLE|REPLACE[[:space:]]+INTO|UPSERT[[:space:]]+INTO)\b' || \
       printf '%s' "$cmd" | grep -qiE '\bUPDATE[[:space:]]+[[:alnum:]_]'; then
        printf 'data_mutation'
        return 0
    fi

    # Detect migration-like invocations (CLI flag patterns)
    if printf '%s' "$cmd" | grep -qiE '(--migrate|migrate|migration|schema[_-]update|upgrade|downgrade)'; then
        printf 'migration'
        return 0
    fi

    # Default: read query
    printf 'query'
    return 0
}

# =============================================================================
# WAVE 5 — Hook-layer polish (B9, B10, B11, B12, E6 support)
#
# @decision DEC-DBSAFE-W5-001
# @title Wave 5 adds schema change advisory, credential redaction, session stats,
#        MySQL DDL autocommit warning, and MCP credential partitioning advisory
# @status accepted
# @rationale Waves 1-4 handle structural safety (deny/allow/advisory for destructive ops).
#   Wave 5 adds UX-layer polish:
#     B9:  Schema changes in non-local environments warrant visibility even when not denied.
#          ALTER TABLE / CREATE INDEX in production/staging → advisory (not a block).
#     B10: Credentials in deny/advisory messages expose secrets in logs.
#          Redact all password-carrying fields before any message emission.
#     B11: Session-level aggregation lets stop.sh surface a summary ("3 blocked today")
#          to give the user a daily safety picture without hunting through logs.
#     B12: MySQL silently auto-commits DDL — unlike Postgres which can wrap DDL in
#          a transaction for easy rollback. A targeted advisory prevents surprises.
#     E6:  MCP servers with write access to production databases should use separate
#          read-only / read-write credentials. One-shot advisory on first DB MCP call.
#
# @decision DEC-DBSAFE-W5-002
# @title Stats file format: one counter per line as "KEY=VALUE", greppable
# @status accepted
# @rationale A simple KEY=VALUE format (one per line) allows:
#   - Atomic reads via grep: grep "^checked=" .db-safety-stats | cut -d= -f2
#   - Atomic writes: file is rewritten atomically with temp+mv pattern
#   - Shell parsing without external tools (no jq dependency)
#   - Portability to bash 3.2 (macOS default) without associative arrays
#   Counter categories: checked (every DB detection), blocked (every deny),
#   warned (every advisory emission).
# =============================================================================

# ---------------------------------------------------------------------------
# _db_detect_schema_change COMMAND
#
# Detects schema-modifying SQL in a command string.
# Returns "schema:<description>" if a schema-altering statement is found,
# or "none" if no schema change is detected.
#
# Detected statements:
#   ALTER TABLE   — modifies column/index structure
#   CREATE INDEX  — adds an index (can be slow in prod on large tables)
#   DROP INDEX    — removes an index (affects query performance)
#   CREATE TABLE  — adds a new table
#   RENAME TABLE  — renames an existing table
#
# Schema changes in production/staging merit awareness even when the risk
# classification returns "safe" (they are not destructive, but they affect
# shared schema state and can cause production incidents).
#
# Returns: "schema:<description>" or "none"
# ---------------------------------------------------------------------------
_db_detect_schema_change() {
    local cmd="$1"

    local cmd_upper
    cmd_upper=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')

    if printf '%s' "$cmd_upper" | grep -qE '\bALTER[[:space:]]+TABLE\b'; then
        printf 'schema:ALTER TABLE'; return 0
    fi
    if printf '%s' "$cmd_upper" | grep -qE '\bCREATE[[:space:]]+INDEX\b'; then
        printf 'schema:CREATE INDEX'; return 0
    fi
    if printf '%s' "$cmd_upper" | grep -qE '\bDROP[[:space:]]+INDEX\b'; then
        printf 'schema:DROP INDEX'; return 0
    fi
    if printf '%s' "$cmd_upper" | grep -qE '\bCREATE[[:space:]]+TABLE\b'; then
        printf 'schema:CREATE TABLE'; return 0
    fi
    if printf '%s' "$cmd_upper" | grep -qE '\bRENAME[[:space:]]+TABLE\b'; then
        printf 'schema:RENAME TABLE'; return 0
    fi

    printf 'none'
    return 0
}

# ---------------------------------------------------------------------------
# _db_redact_credentials COMMAND_STRING
#
# Sanitizes database connection credentials in a command string for safe
# display in deny/advisory messages and log output.
#
# Redaction patterns:
#   postgresql://user:password@host/db  → postgresql://user:***@host/db
#   mysql://user:password@host/db       → mysql://user:***@host/db
#   mongodb://user:password@host/db     → mongodb://user:***@host/db
#   -p password / -p<password>          → -p ***
#   --password=secret                   → --password=***
#   PGPASSWORD=secret                   → PGPASSWORD=***
#   MYSQL_PWD=secret                    → MYSQL_PWD=***
#   DATABASE_URL=postgres://u:pass@h    → DATABASE_URL=***
#
# @decision DEC-DBSAFE-W5-003
# @title Redact before emit: always sanitize the command in deny/advisory messages
# @status accepted
# @rationale Hook deny messages are captured in shell logs, transcript files, and
#   potentially sent to remote observability systems. Passwords in those paths are
#   security incidents. Redaction at the library boundary (before _db_format_deny /
#   _db_format_advisory) ensures no caller can accidentally emit plaintext credentials.
#   sed is used (not awk/python) to preserve bash 3.2 portability.
# ---------------------------------------------------------------------------
_db_redact_credentials() {
    local cmd="$1"

    # URI format: protocol://user:password@host → protocol://user:***@host
    # Handles postgresql://, mysql://, mongodb://, postgres://
    # Use # delimiter to avoid conflict with | alternation in the pattern on macOS BSD sed.
    cmd=$(printf '%s' "$cmd" | sed -E 's#(postgresql|postgres|mysql|mongodb)://([^:@]+):[^@]*@#\1://\2:***@#g')

    # -p password (space-separated, mysql/mongosh style)
    # Matches: -p<space>something but not -p at end of string
    cmd=$(printf '%s' "$cmd" | sed -E 's/-p[[:space:]]+[^[:space:]]+/-p ***/g')

    # -p<password> (no space, mysql -pmypassword)
    # Must come AFTER the space-separated form to avoid double-redaction
    cmd=$(printf '%s' "$cmd" | sed -E 's/-p([^[:space:]-][^[:space:]]*)/-p***/g')

    # --password=secret
    cmd=$(printf '%s' "$cmd" | sed -E 's/--password=[^[:space:]]*/--password=***/g')

    # PGPASSWORD=secret
    cmd=$(printf '%s' "$cmd" | sed -E 's/PGPASSWORD=[^[:space:]]*/PGPASSWORD=***/g')

    # MYSQL_PWD=secret
    cmd=$(printf '%s' "$cmd" | sed -E 's/MYSQL_PWD=[^[:space:]]*/MYSQL_PWD=***/g')

    # DATABASE_URL=... (entire value redacted — may contain embedded credentials)
    cmd=$(printf '%s' "$cmd" | sed -E 's/DATABASE_URL=[^[:space:]]*/DATABASE_URL=***/g')

    printf '%s' "$cmd"
    return 0
}

# ---------------------------------------------------------------------------
# _db_format_deny REASON SUGGESTION
#
# Formats a deny message consistently for database safety denials.
# Credentials in the reason/suggestion are redacted before formatting.
# The output is passed to emit_deny() in pre-bash.sh.
# ---------------------------------------------------------------------------
_db_format_deny() {
    local reason="$1"
    local suggestion="${2:-}"

    # Redact any credentials that may appear in the reason text
    reason=$(_db_redact_credentials "$reason")

    printf 'DB-SAFETY DENY — %s' "$reason"
    if [[ -n "$suggestion" ]]; then
        printf '\n\nSuggestion: %s' "$suggestion"
    fi
}

# ---------------------------------------------------------------------------
# _db_format_advisory REASON
#
# Formats an advisory message for database safety warnings.
# Credentials in the reason are redacted before formatting.
# The output is used in hook advisory emissions.
# ---------------------------------------------------------------------------
_db_format_advisory() {
    local reason="$1"

    # Redact any credentials that may appear in the advisory text
    reason=$(_db_redact_credentials "$reason")

    printf 'DB-SAFETY ADVISORY — %s' "$reason"
}

# ---------------------------------------------------------------------------
# _db_increment_stat CATEGORY
#
# Increments a named counter in the db-safety stats.
# Dual-write: SQLite KV (primary, DEC-V4-KV-001) + flat-file fallback.
#
# Categories: checked | blocked | warned
#   checked — every DB CLI or MCP DB tool detection
#   blocked — every deny emission
#   warned  — every advisory emission
#
# KV keys: db_safety_checked, db_safety_blocked, db_safety_warned
# Flat-file: ${CLAUDE_DIR:-$HOME/.claude}/.db-safety-stats (KEY=VALUE, one per line)
#
# Read path (KV primary → flat-file fallback):
#   1. Try state_read "db_safety_<category>"
#   2. If empty, read from flat-file
# Write path (dual-write):
#   1. state_update "db_safety_<category>" with incremented value
#   2. Atomic temp+mv write to flat-file (preserves all three counters)
#
# @decision DEC-V4-KV-001
# @title Dual-write db-safety stats to SQLite KV + flat-file
# @status accepted
# @rationale Flat-file .db-safety-stats requires read-modify-write with temp+mv for
#   atomicity — each increment reads all 3 counters, increments one, and rewrites all.
#   SQLite KV state_update is atomic per-key (BEGIN IMMEDIATE) — no read-modify-write
#   needed for individual key increments. KV is now the primary read source;
#   flat-file is kept as fallback during migration window and for tools that read it
#   directly (stop.sh, observatory). Session-end.sh deletes KV keys (session-scoped).
# ---------------------------------------------------------------------------
_db_increment_stat() {
    local category="${1:-checked}"
    local stats_file="${CLAUDE_DIR:-$HOME/.claude}/.db-safety-stats"

    # Map category to KV key name
    local kv_key
    case "$category" in
        checked) kv_key="db_safety_checked" ;;
        blocked) kv_key="db_safety_blocked" ;;
        warned)  kv_key="db_safety_warned"  ;;
        *)       kv_key="db_safety_checked" ;;
    esac

    # --- KV primary path: read current value from SQLite ---
    local kv_val=""
    if type state_read &>/dev/null 2>&1; then
        kv_val=$(state_read "$kv_key" 2>/dev/null || echo "")
    fi

    # --- Flat-file read for fallback and for maintaining sibling counters ---
    local checked=0 blocked=0 warned=0
    if [[ -f "$stats_file" ]]; then
        local _v
        _v=$(grep "^checked=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && checked="$_v"
        _v=$(grep "^blocked=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && blocked="$_v"
        _v=$(grep "^warned=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && warned="$_v"
    fi

    # Use KV value if present (more reliable — survives concurrent writes better)
    if [[ "$kv_val" =~ ^[0-9]+$ ]]; then
        case "$category" in
            checked) checked="$kv_val" ;;
            blocked) blocked="$kv_val" ;;
            warned)  warned="$kv_val"  ;;
        esac
    fi

    # Increment the requested counter
    case "$category" in
        checked) checked=$(( checked + 1 )) ;;
        blocked) blocked=$(( blocked + 1 )) ;;
        warned)  warned=$(( warned + 1 )) ;;
    esac

    # --- KV write (primary, DEC-V4-KV-001) ---
    if type state_update &>/dev/null 2>&1; then
        case "$category" in
            checked) state_update "db_safety_checked" "$checked" "db-safety" 2>/dev/null || true ;;
            blocked) state_update "db_safety_blocked" "$blocked" "db-safety" 2>/dev/null || true ;;
            warned)  state_update "db_safety_warned"  "$warned"  "db-safety" 2>/dev/null || true ;;
        esac
    fi

    # --- Flat-file write (fallback, atomic temp+mv) ---
    local tmp_file="${stats_file}.tmp.$$"
    {
        printf 'checked=%d\n' "$checked"
        printf 'blocked=%d\n' "$blocked"
        printf 'warned=%d\n'  "$warned"
    } > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$stats_file" 2>/dev/null || true

    return 0
}

# ---------------------------------------------------------------------------
# _db_session_summary
#
# Returns a human-readable summary of db-safety stats for the current session.
# Read path: SQLite KV primary (DEC-V4-KV-001) → flat-file fallback.
#
# Returns: "Database safety: N commands checked, N blocked, N warnings"
# Returns empty string if no database operations occurred this session.
#
# Integration point for stop.sh:
#   Add to stop.sh's summary block:
#     require_db_safety
#     _DB_STAT_SUMMARY=$(_db_session_summary)
#     if [[ -n "$_DB_STAT_SUMMARY" ]]; then
#         CONTEXT_PARTS+=("$_DB_STAT_SUMMARY")
#     fi
# ---------------------------------------------------------------------------
_db_session_summary() {
    local stats_file="${CLAUDE_DIR:-$HOME/.claude}/.db-safety-stats"

    local checked=0 blocked=0 warned=0

    # --- KV primary read (DEC-V4-KV-001) ---
    local _kv_checked="" _kv_blocked="" _kv_warned=""
    if type state_read &>/dev/null 2>&1; then
        _kv_checked=$(state_read "db_safety_checked" 2>/dev/null || echo "")
        _kv_blocked=$(state_read "db_safety_blocked" 2>/dev/null || echo "")
        _kv_warned=$(state_read "db_safety_warned"   2>/dev/null || echo "")
    fi

    if [[ "$_kv_checked" =~ ^[0-9]+$ || "$_kv_blocked" =~ ^[0-9]+$ || "$_kv_warned" =~ ^[0-9]+$ ]]; then
        # KV has data — use it as primary
        [[ "$_kv_checked" =~ ^[0-9]+$ ]] && checked="$_kv_checked"
        [[ "$_kv_blocked" =~ ^[0-9]+$ ]] && blocked="$_kv_blocked"
        [[ "$_kv_warned"  =~ ^[0-9]+$ ]] && warned="$_kv_warned"
    elif [[ -f "$stats_file" ]]; then
        # --- Flat-file fallback ---
        local _v
        _v=$(grep "^checked=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && checked="$_v"
        _v=$(grep "^blocked=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && blocked="$_v"
        _v=$(grep "^warned=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && warned="$_v"
    fi

    # Only emit if there were any database operations this session
    if [[ "$checked" -eq 0 && "$blocked" -eq 0 && "$warned" -eq 0 ]]; then
        printf ''
        return 0
    fi

    printf 'Database safety: %d commands checked, %d blocked, %d warnings' \
        "$checked" "$blocked" "$warned"
    return 0
}

# ---------------------------------------------------------------------------
# _db_read_session_stats
#
# Returns the raw key=value stats for programmatic consumption.
# Read path: SQLite KV primary (DEC-V4-KV-001) → flat-file fallback.
# Callers can source the output or use grep to extract individual values.
#
# Integration point for stop.sh:
#   Provides a stable API for reading session stats without coupling to
#   the internal file format. Call _db_session_summary() for display.
# ---------------------------------------------------------------------------
_db_read_session_stats() {
    local stats_file="${CLAUDE_DIR:-$HOME/.claude}/.db-safety-stats"

    local checked=0 blocked=0 warned=0

    # --- KV primary read (DEC-V4-KV-001) ---
    local _kv_checked="" _kv_blocked="" _kv_warned=""
    if type state_read &>/dev/null 2>&1; then
        _kv_checked=$(state_read "db_safety_checked" 2>/dev/null || echo "")
        _kv_blocked=$(state_read "db_safety_blocked" 2>/dev/null || echo "")
        _kv_warned=$(state_read "db_safety_warned"   2>/dev/null || echo "")
    fi

    if [[ "$_kv_checked" =~ ^[0-9]+$ || "$_kv_blocked" =~ ^[0-9]+$ || "$_kv_warned" =~ ^[0-9]+$ ]]; then
        # KV has data — use as primary
        [[ "$_kv_checked" =~ ^[0-9]+$ ]] && checked="$_kv_checked"
        [[ "$_kv_blocked" =~ ^[0-9]+$ ]] && blocked="$_kv_blocked"
        [[ "$_kv_warned"  =~ ^[0-9]+$ ]] && warned="$_kv_warned"
    elif [[ -f "$stats_file" ]]; then
        # --- Flat-file fallback ---
        local _v
        _v=$(grep "^checked=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && checked="$_v"
        _v=$(grep "^blocked=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && blocked="$_v"
        _v=$(grep "^warned=" "$stats_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ "$_v" =~ ^[0-9]+$ ]] && warned="$_v"
    fi

    printf 'checked=%d\nblocked=%d\nwarned=%d\n' "$checked" "$blocked" "$warned"
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_emit_guardian_required OPERATION_TYPE DENIED_COMMAND DENY_REASON TARGET_ENV
#
# Emits a DB-GUARDIAN-REQUIRED signal for inclusion in pre-bash.sh deny messages.
# This is the machine-readable trigger that causes the orchestrator to dispatch
# the Database Guardian agent (if one is ever dispatched).
#
# The caller (pre-bash.sh, pre-mcp.sh) appends this to the human-readable deny
# message so that the orchestrator can parse the JSON and construct a full request.
#
# Relocated from db-guardian-lib.sh (Wave 3a) as part of dead-code removal:
#   db-guardian-lib.sh had zero invocations across 1,093 traces. This function
#   is a safety signal, not an agent function — it belongs in the safety library.
#
# @decision DEC-PERF-001
# @title Relocate _dbg_emit_guardian_required to db-safety-lib.sh
# @status accepted
# @rationale db-guardian-lib.sh (1,161 lines, ~12.8KB) was fully built but never
#   dispatched across 1,093 recorded traces. The only active callers were in
#   pre-bash.sh and pre-mcp.sh, both of which already load db-safety-lib.sh via
#   require_db_safety. Moving this single function here preserves all safety
#   signal behavior while allowing the entire db-guardian agent layer to be
#   removed. See Issue #247.
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

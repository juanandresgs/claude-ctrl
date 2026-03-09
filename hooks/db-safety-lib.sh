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

#!/usr/bin/env bash
###############################################################################
# db-sync-data.sh - Refresh selected local MySQL/MariaDB table data from production
#
# Part of: MySQL Migration Tools
#
# Workflow:
#   1. Create separate production/local DDL dumps via db-dump.sh --ddl.
#   2. Compare them via compare-ddl.py and collect compatible table names.
#   3. Export production DATA ONLY for exactly those tables.
#   4. Replace their local rows without modifying local table definitions.
#
# Usage:
#   ./db-sync-data.sh --dry-run    # Analyze schemas; do not change any data.
#   ./db-sync-data.sh              # Analyze, export, and ask before local import.
#   ./db-sync-data.sh --yes        # Same as above, without confirmation prompt.
#
# Notes:
#   - Requires Bash 3.2+, Python 3, mysql/mariadb, and mysqldump/mariadb-dump.
#   - Production credentials MUST be read-only. This script never writes there.
#   - Exports and backups can contain sensitive data. Run directories are private.
#   - Imports are transactional only when all selected LOCAL tables use InnoDB.
#   - Both database schemas must remain unchanged while this workflow runs.
#   - compare-ddl.py must be available next to this script.
###############################################################################
set -euo pipefail
umask 077

# ============================================================================
#  CONFIGURATION - Edit this section for your environment
# ============================================================================

# Credential profiles (files are located next to db-dump.sh):
#   .silkcards-production-ro.credentials.sh
#   .silkcards-local.credentials.sh
PRODUCTION_PROFILE="silkcards-production-ro"
LOCAL_PROFILE="silkcards-local"

# Schema dump names created for every run. Both filenames MUST end in .ddl.sql.
PRODUCTION_DDL_NAME="silkcards.ddl.sql"
LOCAL_DDL_NAME="silkcards-gj-local.ddl.sql"

# Executables. Use "mariadb" / "mariadb-dump" if the traditional names are absent.
MYSQL_BIN="mysql"
MYSQLDUMP_BIN="mysqldump"
PYTHON_BIN="python3"

# Script paths are resolved relative to the directory containing this script.
# Empty values mean: use the matching script next to db-sync-data.sh.
DB_DUMP_SCRIPT=""
COMPARE_DDL_SCRIPT=""

# Each execution gets a new private directory under this root. Generated SQL
# files and a local data backup are retained so failures can be investigated.
WORK_ROOT=""  # Default: <script-directory>/_sync

# Require an interactive confirmation of the LOCAL database name before writing.
# Use --yes to bypass the prompt, e.g. in a trusted automated environment.
REQUIRE_CONFIRMATION=1

# Save original local rows for all selected tables BEFORE deleting anything.
# Recommended: 1. This backup is separate from the production data dump.
BACKUP_LOCAL_DATA=1

# Safety guards (defaults are deliberately strict):
# A foreign key between selected and non-selected tables can leave dangling
# references after a partial refresh, even with FOREIGN_KEY_CHECKS=0.
ALLOW_FK_BOUNDARIES=0

# Local INSERT/DELETE triggers may change OTHER tables as a side effect.
# Such changes would not necessarily roll back if the trigger touches MyISAM.
ALLOW_LOCAL_TRIGGERS=0

# Non-InnoDB local tables do not provide transaction rollback guarantees.
# Setting this to 1 permits the import, but a failed load may leave partial data.
ALLOW_NON_INNODB=0

# ============================================================================
#  END OF CONFIGURATION - No edits should normally be needed below this line
# ============================================================================

# ----------------------------- COMMON HELPERS -------------------------------

log_info() { printf '[INFO] %s\n' "$*"; }
log_ok()   { printf '[ OK ] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_err()  { printf '[FAIL] %s\n' "$*" >&2; }
die()      { log_err "$*"; exit 1; }

show_help() {
    cat <<'HELP'
Usage: db-sync-data.sh [--dry-run | --yes] [--help]

  --dry-run   Export and compare both DDL files, inspect compatibility and
              database dependencies, but do NOT dump or import table data.
  --yes       Skip the LOCAL database name confirmation before importing.
  -h, --help  Show this help.

Edit the CONFIGURATION section at the top of the script before running.
The original local rows are REPLACED for selected compatible tables.
HELP
}

DRY_RUN=0
ASSUME_YES=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help) show_help; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

# Resolve symlinks and paths without GNU readlink -f (absent on stock macOS).
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
DB_DUMP_SCRIPT="${DB_DUMP_SCRIPT:-$SCRIPT_DIR/db-dump.sh}"
COMPARE_DDL_SCRIPT="${COMPARE_DDL_SCRIPT:-$SCRIPT_DIR/compare-ddl.py}"
WORK_ROOT="${WORK_ROOT:-$SCRIPT_DIR/_sync}"

# All files written by this run are kept; only short-lived authentication files
# and the inter-process lock are removed on exit.
RUN_DIR=""
LOCK_DIR=""
PRODUCTION_AUTH=""
LOCAL_AUTH=""
IMPORT_STARTED=0

on_exit() {
    status=$?
    trap - EXIT
    [ -z "$PRODUCTION_AUTH" ] || rm -f -- "$PRODUCTION_AUTH"
    [ -z "$LOCAL_AUTH" ] || rm -f -- "$LOCAL_AUTH"
    [ -z "$LOCK_DIR" ] || rmdir "$LOCK_DIR" 2>/dev/null || true

    if [ "$status" -ne 0 ]; then
        log_err "Workflow stopped (exit $status)."
        if [ "$IMPORT_STARTED" -eq 1 ]; then
            log_warn "If the import failed, check the LOCAL DB. InnoDB changes"
            log_warn "should roll back on disconnect; other engines may not."
        fi
        [ -z "$RUN_DIR" ] || log_warn "Run files were kept in: $RUN_DIR"
    fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_program() {
    command -v "$1" >/dev/null 2>&1 || die "Required program not found: $1"
}

# Put shell-sourced credentials in client option files instead of passing their
# password as a command-line argument. mysql/mysqldump require --defaults-file
# to be the FIRST option. Quoting preserves spaces, #, quotes, and backslashes.
cnf_quote() {
    local value="$1"
    case "$value" in
        *$'\n'*|*$'\r'*) die "Newlines are not supported in database credentials" ;;
    esac
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

write_client_auth() {
    local file="$1" host="$2" port="$3" user="$4" pass="$5"
    {
        printf '[client]\n'
        printf 'host='; cnf_quote "$host"; printf '\n'
        printf 'port=%s\n' "$port"
        printf 'user='; cnf_quote "$user"; printf '\n'
        printf 'password='; cnf_quote "$pass"; printf '\n'
        printf 'default-character-set=utf8mb4\n'
    } > "$file"
    chmod 600 "$file"
}

# Profiles use the SAME variables as db-dump.sh. Source each one in turn and
# copy the values to distinct names; do not confuse production with local.
load_profile() {
    local role="$1" profile="$2" file
    file="$SCRIPT_DIR/.$profile.credentials.sh"
    [ -r "$file" ] || die "Credentials file is missing or unreadable: $file"

    unset dbHost dbPort dbName dbUser dbPass dbTablePrefix || true
    # shellcheck disable=SC1090
    . "$file"

    [ -n "${dbName:-}" ] || die "dbName is not set in $file"
    [ -n "${dbUser:-}" ] || die "dbUser is not set in $file"
    [ -n "${dbPass:-}" ] || die "dbPass must be set for noninteractive use: $file"

    if [ "$role" = 'production' ]; then
        PRODUCTION_HOST="${dbHost:-localhost}"
        PRODUCTION_PORT="${dbPort:-3306}"
        PRODUCTION_DB="$dbName"
        PRODUCTION_USER="$dbUser"
        PRODUCTION_PASS="$dbPass"
    else
        LOCAL_HOST="${dbHost:-localhost}"
        LOCAL_PORT="${dbPort:-3306}"
        LOCAL_DB="$dbName"
        LOCAL_USER="$dbUser"
        LOCAL_PASS="$dbPass"
    fi
}

# SQL string literals in metadata queries: double single quotes and backslashes.
# These database names come from trusted local credential profiles, not the dump.
sql_literal() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

# Quote a MySQL identifier. A compatible table name is supplied as a LINE in
# compare-ddl.py's output, never passed through shell word-splitting.
sql_identifier() {
    local value="$1"
    value=${value//\`/\`\`}
    printf '`%s`' "$value"
}

# Query one of the two connections. --defaults-file must be first.
query_production() {
    "$MYSQL_BIN" "--defaults-file=$PRODUCTION_AUTH" \
        --batch --raw --skip-column-names "$PRODUCTION_DB" -e "$1"
}
query_local() {
    "$MYSQL_BIN" "--defaults-file=$LOCAL_AUTH" \
        --batch --raw --skip-column-names "$LOCAL_DB" -e "$1"
}

# A matching item in the comparison list means that the table will be touched.
is_selected() {
    grep -Fqx -- "$1" "$TABLE_LIST_FILE"
}

# The same non-DDL options are used for both production extraction and the
# optional local backup. No CREATE/DROP, triggers, routines, events or USE.
data_dump() {
    local auth_file="$1" db_name="$2" output="$3"
    shift 3
    "$MYSQLDUMP_BIN" "--defaults-file=$auth_file" \
        --default-character-set=utf8mb4 \
        --single-transaction --quick --skip-lock-tables \
        --no-create-info --no-create-db --skip-add-drop-table \
        --skip-triggers --skip-routines --skip-events \
        --skip-add-locks --skip-disable-keys --skip-no-autocommit \
        --complete-insert --hex-blob --no-tablespaces \
        -- "$db_name" "$@" > "$output"
}

# -------------------------- PRE-FLIGHT CHECKS -------------------------------

[ "$PRODUCTION_PROFILE" != "$LOCAL_PROFILE" ] || die "Production and local profiles must differ"
require_program "$MYSQL_BIN"
require_program "$MYSQLDUMP_BIN"
require_program "$PYTHON_BIN"
[ -f "$DB_DUMP_SCRIPT" ] || die "db-dump.sh not found: $DB_DUMP_SCRIPT"
[ -f "$COMPARE_DDL_SCRIPT" ] || die "compare-ddl.py not found: $COMPARE_DDL_SCRIPT"

mkdir -p "$WORK_ROOT"
LOCK_DIR="$WORK_ROOT/.db-sync-data.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Another sync may be running (lock exists): $LOCK_DIR"
fi

RUN_DIR="$WORK_ROOT/$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -m 700 "$RUN_DIR"
PRODUCTION_AUTH="$RUN_DIR/.production-client.cnf"
LOCAL_AUTH="$RUN_DIR/.local-client.cnf"

load_profile production "$PRODUCTION_PROFILE"
load_profile local "$LOCAL_PROFILE"
write_client_auth "$PRODUCTION_AUTH" "$PRODUCTION_HOST" "$PRODUCTION_PORT" \
    "$PRODUCTION_USER" "$PRODUCTION_PASS"
write_client_auth "$LOCAL_AUTH" "$LOCAL_HOST" "$LOCAL_PORT" \
    "$LOCAL_USER" "$LOCAL_PASS"

log_info "Production (read only): $PRODUCTION_HOST:$PRODUCTION_PORT/$PRODUCTION_DB"
log_info "Local (destination):   $LOCAL_HOST:$LOCAL_PORT/$LOCAL_DB"
log_info "Run directory:         $RUN_DIR"

# Protect against accidentally pointing both credential profiles to the same
# server and database. Two different host aliases may resolve to one server.
PRODUCTION_ID=$(query_production 'SELECT CONCAT(@@hostname, "/", @@port, "/", @@server_id, "/", DATABASE());')
LOCAL_ID=$(query_local 'SELECT CONCAT(@@hostname, "/", @@port, "/", @@server_id, "/", DATABASE());')
[ "$PRODUCTION_ID" != "$LOCAL_ID" ] || die "Source and destination appear to be the SAME database"

# ------------------------- STEP 1: DDL EXPORT -------------------------------

PRODUCTION_DDL="$RUN_DIR/$PRODUCTION_DDL_NAME"
LOCAL_DDL="$RUN_DIR/$LOCAL_DDL_NAME"

log_info "STEP 1/4: Export production DDL (read-only, no optimization, no Git push)"
MYSQLDUMP_BIN="$MYSQLDUMP_BIN" bash "$DB_DUMP_SCRIPT" \
    --ddl --skip-optimize --no-archive --strict "$PRODUCTION_DDL" "$PRODUCTION_PROFILE"
[ -s "$PRODUCTION_DDL" ] || die "Production DDL is missing or empty"

log_info "STEP 1/4: Export local DDL (no optimization, no Git push)"
MYSQLDUMP_BIN="$MYSQLDUMP_BIN" bash "$DB_DUMP_SCRIPT" \
    --ddl --skip-optimize --no-archive --strict "$LOCAL_DDL" "$LOCAL_PROFILE"
[ -s "$LOCAL_DDL" ] || die "Local DDL is missing or empty"

# ------------------------ STEP 2: DDL COMPARISON -----------------------------

log_info "STEP 2/4: Compare normalized table structures"
"$PYTHON_BIN" "$COMPARE_DDL_SCRIPT" \
    --production "$PRODUCTION_DDL" \
    --local "$LOCAL_DDL" \
    --out-dir "$RUN_DIR"

TABLE_LIST_FILE="$RUN_DIR/compatible-tables.txt"
[ -f "$TABLE_LIST_FILE" ] || die "Comparison did not produce compatible-tables.txt"

# macOS includes Bash 3.2, which lacks mapfile/readarray. Read into an indexed
# array with a regular loop instead; keep each name as ONE argument for mysqldump.
TABLES=()
while IFS= read -r table || [ -n "$table" ]; do
    [ -n "$table" ] || continue
    case "$table" in
        *$'\r'*|*$'\t'*) die "Unsupported control character in table name: $table" ;;
    esac
    TABLES+=("$table")
done < "$TABLE_LIST_FILE"
[ "${#TABLES[@]}" -gt 0 ] || die "No compatible tables. Nothing will be imported."
log_ok "Found ${#TABLES[@]} compatible tables"

# ------------------- SAFETY: LOCAL ENGINE / FK / TRIGGERS --------------------

LOCAL_DB_LITERAL=$(sql_literal "$LOCAL_DB")
ENGINE_LIST_FILE="$RUN_DIR/local-table-engines.tsv"
FK_LIST_FILE="$RUN_DIR/local-foreign-keys.tsv"
TRIGGER_LIST_FILE="$RUN_DIR/local-triggers.tsv"

query_local "SELECT TABLE_NAME, COALESCE(ENGINE, '') FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = $LOCAL_DB_LITERAL AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME;" > "$ENGINE_LIST_FILE"
query_local "SELECT TABLE_SCHEMA, TABLE_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_NAME IS NOT NULL AND (TABLE_SCHEMA = $LOCAL_DB_LITERAL OR REFERENCED_TABLE_SCHEMA = $LOCAL_DB_LITERAL);" > "$FK_LIST_FILE"
query_local "SELECT EVENT_OBJECT_TABLE, TRIGGER_NAME FROM INFORMATION_SCHEMA.TRIGGERS WHERE TRIGGER_SCHEMA = $LOCAL_DB_LITERAL AND EVENT_MANIPULATION IN ('INSERT', 'DELETE');" > "$TRIGGER_LIST_FILE"

# Double-check that local engine information is complete for every selected
# table; a DDL export alone is not proof that no concurrent change occurred.
NON_INNODB=0
for table in "${TABLES[@]}"; do
    engine=''
    while IFS=$'\t' read -r name value; do
        if [ "$name" = "$table" ]; then
            engine="$value"
            break
        fi
    done < "$ENGINE_LIST_FILE"
    [ -n "$engine" ] || die "Local table is missing or has unknown engine: $table"
    if [ "$engine" != 'InnoDB' ]; then
        NON_INNODB=$((NON_INNODB + 1))
        log_warn "Non-transactional or unsupported local engine: $table ($engine)"
    fi
done
if [ "$NON_INNODB" -gt 0 ] && [ "$ALLOW_NON_INNODB" -ne 1 ]; then
    die "$NON_INNODB selected tables are not InnoDB (set ALLOW_NON_INNODB=1 only if you accept partial-import risk)"
fi
if [ "$NON_INNODB" -gt 0 ] && [ "$BACKUP_LOCAL_DATA" -ne 1 ]; then
    die "Non-InnoDB import requires BACKUP_LOCAL_DATA=1"
fi

# Reject links across the selection boundary (in either direction). With these
# links, a partial refresh could break references to a skipped local table.
BOUNDARY_COUNT=0
while IFS=$'\t' read -r child_db child_table parent_db parent_table; do
    [ -n "$child_db" ] || continue
    child_selected=0
    parent_selected=0
    if [ "$child_db" = "$LOCAL_DB" ] && is_selected "$child_table"; then
        child_selected=1
    fi
    if [ "$parent_db" = "$LOCAL_DB" ] && is_selected "$parent_table"; then
        parent_selected=1
    fi
    if [ "$child_selected" -ne "$parent_selected" ]; then
        BOUNDARY_COUNT=$((BOUNDARY_COUNT + 1))
        log_warn "FK crosses selected/unselected boundary: $child_db.$child_table -> $parent_db.$parent_table"
    fi
done < "$FK_LIST_FILE"
if [ "$BOUNDARY_COUNT" -gt 0 ] && [ "$ALLOW_FK_BOUNDARIES" -ne 1 ]; then
    die "$BOUNDARY_COUNT foreign key boundaries detected (set ALLOW_FK_BOUNDARIES=1 to explicitly accept this risk)"
fi

# Triggers are independent schema objects; compare-ddl.py compares CREATE TABLE
# definitions only. INSERT/DELETE triggers may change skipped tables.
TRIGGER_COUNT=0
while IFS=$'\t' read -r table trigger; do
    [ -n "$table" ] || continue
    if is_selected "$table"; then
        TRIGGER_COUNT=$((TRIGGER_COUNT + 1))
        log_warn "Selected local table has an active trigger: $table / $trigger"
    fi
done < "$TRIGGER_LIST_FILE"
if [ "$TRIGGER_COUNT" -gt 0 ] && [ "$ALLOW_LOCAL_TRIGGERS" -ne 1 ]; then
    die "$TRIGGER_COUNT triggers affect selected tables (set ALLOW_LOCAL_TRIGGERS=1 to explicitly accept this risk)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log_ok "Dry run complete. No table data was exported or modified."
    log_info "Selected tables: $TABLE_LIST_FILE"
    exit 0
fi

# ---------------------- STEP 3: PRODUCTION DATA DUMP -------------------------

PRODUCTION_DATA="$RUN_DIR/production-compatible-data.sql"
log_info "STEP 3/4: Export DATA ONLY for ${#TABLES[@]} compatible production tables"
data_dump "$PRODUCTION_AUTH" "$PRODUCTION_DB" "$PRODUCTION_DATA" "${TABLES[@]}"
[ -s "$PRODUCTION_DATA" ] || die "Production data dump is missing or empty"

# The dump must be an INSERT-only script with session SET statements. Never
# import a dump containing schema changes, database switches or transaction
# boundaries that might implicitly commit DELETE statements inside our wrapper.
if LC_ALL=C grep -Eni '^[[:space:]]*(CREATE|ALTER|DROP|TRUNCATE|RENAME|LOCK|UNLOCK|COMMIT|ROLLBACK|START|BEGIN|USE|DELETE|UPDATE|REPLACE|LOAD|CALL|GRANT|REVOKE)[[:space:];]|^[[:space:]]*SET[[:space:]]+(SESSION[[:space:]]+)?AUTOCOMMIT[[:space:]]*=' "$PRODUCTION_DATA" > "$RUN_DIR/rejected-statements.txt"; then
    die "Unexpected SQL in production data dump; see rejected-statements.txt"
fi
rm -f "$RUN_DIR/rejected-statements.txt"

# This backup is created BEFORE any deletion. It is useful even though
# successful InnoDB-only imports run in a single transaction.
if [ "$BACKUP_LOCAL_DATA" -eq 1 ]; then
    LOCAL_BACKUP="$RUN_DIR/local-before-sync-data.sql"
    log_info "Backing up original local rows for ${#TABLES[@]} tables"
    data_dump "$LOCAL_AUTH" "$LOCAL_DB" "$LOCAL_BACKUP" "${TABLES[@]}"
    [ -s "$LOCAL_BACKUP" ] || die "Local backup is missing or empty"
fi

# --------------------- STEP 4: LOCAL DATA IMPORT -----------------------------

if [ "$REQUIRE_CONFIRMATION" -eq 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "Interactive confirmation required. Run with --yes when unattended."
    printf '\nThis will DELETE and REPLACE rows in %s LOCAL tables.\n' "${#TABLES[@]}"
    printf 'Production: %s:%s/%s (READ ONLY)\n' "$PRODUCTION_HOST" "$PRODUCTION_PORT" "$PRODUCTION_DB"
    printf 'Local:      %s:%s/%s (WRITABLE)\n' "$LOCAL_HOST" "$LOCAL_PORT" "$LOCAL_DB"
    printf 'Type the LOCAL database name (%s) to confirm: ' "$LOCAL_DB"
    IFS= read -r confirmation
    [ "$confirmation" = "$LOCAL_DB" ] || die "Confirmation did not match; import cancelled"
fi

log_info "STEP 4/4: Replace local rows in compatible tables (preserve local DDL)"
log_info "Disabling foreign_key_checks only for this import session."

# For InnoDB, all DELETE/INSERT statements occur in one transaction. The dump
# is produced with --skip-add-locks, --skip-disable-keys, --skip-no-autocommit,
# so it should contain no SQL that ends the transaction before the final COMMIT.
# mysql's default behavior (no --force) aborts on SQL errors. The disconnected
# session then rolls back the open InnoDB transaction.
IMPORT_STARTED=1
{
    printf 'SET SESSION FOREIGN_KEY_CHECKS=0;\n'
    printf 'START TRANSACTION;\n'
    for table in "${TABLES[@]}"; do
        printf 'DELETE FROM %s;\n' "$(sql_identifier "$table")"
    done
    cat "$PRODUCTION_DATA"
    printf '\nCOMMIT;\n'
    printf 'SET SESSION FOREIGN_KEY_CHECKS=1;\n'
} | "$MYSQL_BIN" "--defaults-file=$LOCAL_AUTH" \
        --default-character-set=utf8mb4 --batch "$LOCAL_DB"
IMPORT_STARTED=0

log_ok "Import completed: ${#TABLES[@]} local tables refreshed."
log_info "Comparison reports and SQL files: $RUN_DIR"

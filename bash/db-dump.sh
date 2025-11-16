#!/bin/bash
###############################################################################
#  Database Dump Utility (db-dump.sh)
#
#  Part of: MySQL Migration Tools
#  Copyright (c) 2025 utilmind
#  https://github.com/utilmind/MySQL-migration-tools
#
#  Description:
#      Safe, portable, prefix-aware MySQL/MariaDB dump tool.
#      - Supports per-environment configuration files.
#      - Supports selective table exports:
#          * explicit table list (3rd parameter), OR
#          * prefix-based selection via dbTablePrefix.
#      - Generates reproducible UTF-8 dumps with consistent CREATE TABLE clauses.
#      - Optionally post-processes dumps with Python to restore original
#        charset/collation/table options for cross-server imports.
#      - Compresses resulting dump into .rar archive.
#      - Optionally runs table optimization via "optimize-tables.sh" (can be
#        disabled with --skip-optimize).
#
#  Usage:
#      ./db-dump.sh [--skip-optimize] dump-name.sql [configuration-name] ["table1 table2 ..."]
#
#  License: MIT
#  (c) utilmind, 2012-2025
#    15.10.2024: Each dump have date, don't overwrite past days backups. Old backups can be deleted by garbage collector.
#    26.08.2025: Multiple table prefixes.
#    15.11.2025: Request password if not specified in configuration;
#                Process dump to remove MySQL compatibility comments
#                + provide missing details (server defaults) to the 'CREATE TABLE' statements
#                  (to solve issues with collations on import).
#                (These features require Python3+ installed.)
###############################################################################
set -euo pipefail

# CONFIGURATION
# Optionally specify table prefixes to export.
# Specify them only as bash array, even if only one prefix is used. Strings are not accepted.
# Alternatively these table prefixes can be specified in `.configuration-name.credentials.sh` file.
#dbTablePrefix=('table_prefix1_' 'table_prefix2_' 'bot_' 'email_' 'user_')


# ---------------- BUILD DUMP OPTIONS (COMMON_OPTS) ----------------

# Dump options common for all databases
# NOTE: These options affect every dump produced by this script.
#       Keep them conservative for maximum compatibility.
COMMON_OPTS=(
    --routines
    --events
    --triggers
    --single-transaction
    --quick
)

# --routines/--events/--triggers: include stored routines, events, and triggers.
# --single-transaction: take a consistent snapshot without locking tables (InnoDB only).
# --quick: stream rows row-by-row to reduce memory usage on large tables. (--single-transaction w/o row-by-row streaming can be slow and overload RAM.)

# Continue the dump even if some statements fail. Check the LOG file afterwards.
COMMON_OPTS+=( --force )

# Use UTF-8 for the client/server connection.
# NOTE that MySQL does NOT emit explicit COLLATE clauses in `CREATE TABLE` for columns/tables that use
# the database default collation. Such dumps implicitly depend on the original server defaults. If you
# import them on a server with different defaults, uniqueness and comparison rules may change.
# The post-processing step (REMOVE_COMPATIBILITY_COMMENTS=1) restores the original charset and collation
# into each `CREATE TABLE` to prevent this.
COMMON_OPTS+=( --default-character-set=utf8mb4 )

# Include standard non-default CREATE TABLE options (e.g., ROW_FORMAT) for portability.
COMMON_OPTS+=( --create-options )

# Store BLOBs as hex strings. Makes dumps larger but safer/readable in text editors.
# Comment the next line out if you prefer smaller files.
COMMON_OPTS+=( --hex-blob )

# Make dumps more portable between servers (managed MySQL, MariaDB, different versions).
# Avoid embedding tablespace directives in CREATE TABLE.
COMMON_OPTS+=( --no-tablespaces )

# Do NOT inject SET @@GLOBAL.GTID_PURGED into the dump (safer for imports into existing replicas).
COMMON_OPTS+=( --set-gtid-purged=OFF )

# If dumping from MySQL 8.x to older MySQL/MariaDB where COLUMN_STATISTICS is absent, OR...
# If you're dumping MariaDB server using mysqldump executable from MySQL, suppress the column stats.
# (Because MariaDB doesn't have the column statistics and this option is enabled by default in MySQL 8+.)
COMMON_OPTS+=( --column-statistics=0 )

# ===== Optional, uncomment/remove as needed =====

# Preserve server local time zone behavior (usually NOT recommended). By default, mysqldump sets UTC.
# Only use if your target server lacks time zone tables or you have a strong reason to avoid UTC.
# COMMON_OPTS+=( --skip-tz-utc )

# For repeatable imports and better compression, order rows by PRIMARY KEY (if present):
# COMMON_OPTS+=( --order-by-primary )

# In pure InnoDB environments, you can skip metadata locks on non-transactional tables:
# COMMON_OPTS+=( --skip-lock-tables )

# Drop and recreate the database before importing a full dump (NOT for partial/table-only imports):
# COMMON_OPTS+=( --add-drop-database )

# Use one INSERT per row (easier diff/merge; slower/larger). Default is multi-row extended inserts.
# COMMON_OPTS+=( --skip-extended-insert )

# ========================  !! INSTALLATION INSTRUCTIONS !!  ===========================
#   - Set up on crontab: crontab -e
#
#     Daily crontab, to make daily backups at 5 AM
#       min     hour    day     month   weekday
#       0       5       *       *       *
#
#   - Also check out the server timezone to set up correct hours for
#     the crontab: $> cat /etc/timezone
#       BTW...
#           - Check current server time: $> date
#           - List of available timezones: $> timedatectl list-timezones
#           - Change the timezone: $> sudo timedatectl set-timezone America/New_York
#               (or $> sudo timedatectl set-timezone America/Los_Angeles)
#               Or, better, just keep default UTC timezone to avoid confusions
#               and asynchronization of server instance time with database server time.
# ======================================================================================

# ANSI colors (disabled if NO_COLOR is set or output is not a TTY)
# ------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_INFO="\033[1;34m"
    COLOR_WARN="\033[1;33m"
    COLOR_ERROR="\033[1;31m"
    COLOR_OK="\033[1;32m"
    COLOR_RESET="\033[0m"
else
    COLOR_INFO=""
    COLOR_WARN=""
    COLOR_ERROR=""
    COLOR_OK=""
    COLOR_RESET=""
fi

log_info()  { printf "%b[INFO]%b %s\n"  "$COLOR_INFO" "$COLOR_RESET" "$*"; }
log_warn()  { printf "%b[WARN]%b %s\n"  "$COLOR_WARN" "$COLOR_RESET" "$*"; }
log_error() { printf "%b[ERROR]%b %s\n" "$COLOR_ERROR" "$COLOR_RESET" "$*"; }
log_ok()    { printf "%b[OK]%b %s\n"    "$COLOR_OK" "$COLOR_RESET" "$*"; }


# FUNCTIONS
# ------------
print_help() {
  scriptName=$(basename "$0")
  cat << EOF
Usage:
    $scriptName [--skip-optimize] dump-name.sql [configuration-name] ["table1 table2 ..."]

Options:
    --skip-optimize
        Do not run optimize-tables.sh before dumping (skip MyISAM OPTIMIZE / InnoDB ANALYZE).

Arguments:
    dump-name.sql (Required)
        The exported filename can automatically contain current date.
        If filename contains '@', it will be replaced with current date YYYYMMDD.
        Example:
            $scriptName exported_data_@.sql my-config
        (So this tool can be executed by the crontab to produce daily files with unique names.)

    configuration-name (Optional)
        Used to locate credentials file with name ".configuration-name.credentials.sh"
        placed in the same directory as this script.
        If not provided, then ".credentials.sh" will be used.

    explicit tables list (Optional, third parameter)
        Quoted space-separated list of tables to export.
        If provided, dbTablePrefix is ignored and tables are taken exactly from this list.
        Example:
            $scriptName dump.sql my-config "table1 table2 table_user stats"

    DB credentials file example (.credentials.sh or .configuration-name.credentials.sh):

        #!/bin/bash
        dbHost='localhost'
        dbPort=3306
        dbName='your_database_name'
        dbUser='your_database_user'
        dbPass='your-password'
        # dbPass can be omitted; in this case the script will ask for it interactively.

        # Optional: you can override default table prefixes for this DB:
        # dbTablePrefix=('table_prefix1_' 'table_prefix2_' 'bot_' 'email_' 'user_')

(c) utilmind, 2012-2025

EOF
}

# ---------------- PARAMETER PARSING ----------------

# No parameters at all -> show help
if [ $# -eq 0 ]; then
    print_help
    exit 1
fi

run_optimize=1

# Handle optional flags (-h / --help / --skip-optimize)
while [[ "${1-}" == -* ]] ; do
    case "$1" in
        -?|-h|-help|--help)
            print_help
            exit 0
            ;;
        --skip-optimize)
            run_optimize=0
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            log_error "Invalid parameter: '$1'"
            exit 1
            ;;
    esac
done

# Now we expect:
#   1) dump-name.sql (required)
#   2) configuration-name (optional)
#   3) explicit tables list (optional, quoted)
if [ $# -lt 1 ]; then
    scriptName=$(basename "$0")
    log_error "Missing required parameters."
    echo "Usage: $scriptName [--skip-optimize] dump-name.sql [configuration-name] [\"table1 table2 ...\"]"
    exit 1
fi

dumpTemplate="$1"
dbConfigName="${2:-}"       # may be empty
tablesListRaw="${3:-}"      # may be empty (quoted space-separated list of tables)


# ---------------- BASIC PATHS / FILENAMES ----------------

thisScript=$(readlink -f "$0") # alternative is $(realpath "$0"), if "realpath" is installed
scriptDir=$(dirname "$thisScript")

# Temporary directory for helper files (table lists, metadata, etc.)
tempDir="$scriptDir/_temp"
mkdir -p "$tempDir"

myisamTablesFilename="$tempDir/_${dbConfigName}-optimize_tables.txt"   # used only by optimize-tables.sh
innoDBTablesFilename="$tempDir/_${dbConfigName}-analyze_tables.txt"    # used only by optimize-tables.sh
allTablesFilename="$tempDir/_${dbConfigName}-export_tables.txt"
tablesMetaFilename="$tempDir/_${dbConfigName}-tables_meta.tsv"

current_date=$(date +"%Y%m%d")
targetFilename=$(echo "$dumpTemplate" | sed "s/@/${current_date}/g")


# ---------------- LOAD CREDENTIALS ----------------

if [ -n "$dbConfigName" ]; then
    credentialsFile="$scriptDir/.${dbConfigName}.credentials.sh"
else
    credentialsFile="$scriptDir/.credentials.sh"
fi

if [ ! -r "$credentialsFile" ]; then
    log_error "Credentials file '$credentialsFile' not found or not readable."
    echo "Please create it with DB connection settings:"
    echo "  dbHost, dbPort, dbName, dbUser, [dbPass], [dbTablePrefix]"
    exit 1
fi

# Expected variables:
#   dbHost, dbPort, dbName, dbUser, optional dbPass, optional dbTablePrefix
. "$credentialsFile"

# If dbName is not defined in credentials, we can fall back to dbConfigName (if set).
if [ -z "${dbName:-}" ]; then
    if [ -n "$dbConfigName" ]; then
        dbName="$dbConfigName"
    else
        log_error "'dbName' is not defined in credentials file '$credentialsFile' and no configuration-name argument was provided."
        exit 1
    fi
fi

# Ask for password if it is not defined or empty
if [ -z "${dbPass:-}" ]; then
    read -s -p "Enter password for MySQL user '$dbUser' (database '$dbName'): " dbPass
    echo
fi

# Common MySQL connection options (used for mysql, mysqlcheck, mysqldump)
mysqlConnOpts=(
    --host="$dbHost"
    --port="$dbPort"
    --user="$dbUser"
    --password="$dbPass"
)


# --------- OPTIONAL TABLE OPTIMIZATION / ANALYZE (if not skipped with --skip-optimize) ---------

optScript="$scriptDir/optimize-tables.sh"
if [ "$run_optimize" -eq 1 ]; then
    if [ -x "$optScript" ]; then
        if [ -n "$tablesListRaw" ]; then
            # Explicit tables list: pass configuration name (may be empty) and tables string
            log_info "Running table optimization (explicit table list) via $optScript ..."
            if [ -n "$dbConfigName" ]; then
                "$optScript" "$dbConfigName" "$tablesListRaw"
            else
                "$optScript" "" "$tablesListRaw"
            fi
        else
            # No explicit table list: rely on dbTablePrefix inside optimize-tables.sh
            log_info "Running table optimization (prefix-based) via $optScript ..."
            if [ -n "$dbConfigName" ]; then
                "$optScript" "$dbConfigName"
            else
                "$optScript"
            fi
        fi
    else
        log_info "Table optimization script not found or not executable: $optScript"
        log_info "Skipping MyISAM optimization and InnoDB analyze."
    fi
fi


# ---------------- TABLE LIST / METADATA PREPARATION ----------------

tablesListInClause=""
declare -a explicitTables=()

if [ -n "$tablesListRaw" ]; then
    # Explicit tables mode: ignore dbTablePrefix
    read -r -a explicitTables <<< "$tablesListRaw"

    if [ ${#explicitTables[@]} -eq 0 ]; then
        log_error "Explicit table list (third parameter) is empty after parsing."
        exit 1
    fi

    for t in "${explicitTables[@]}"; do
        esc=${t//\'/\'\'}   # escape single quotes
        if [ -z "$tablesListInClause" ]; then
            tablesListInClause="'$esc'"
        else
            tablesListInClause="$tablesListInClause, '$esc'"
        fi
    done

    # ---- GENERATE TABLE METADATA TSV (EXPLICIT TABLES) ----
    log_info "Dumping table metadata for selected tables to '$tablesMetaFilename' ..."
    if ! mysql "${mysqlConnOpts[@]}" -N \
        -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '$dbName'
              AND TABLE_NAME IN (${tablesListInClause})
            ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "$tablesMetaFilename"
    then
        log_warn "Failed to dump table metadata (explicit tables). TSV will be missing, CREATE TABLE enhancement may be skipped."
    fi

    # Prepare list of tables to export (one name per line)
    printf "%s\n" "${explicitTables[@]}" > "$allTablesFilename"

else
    # ---- BUILD TABLE FILTER (PREFIXES) ----

    if [ -z "${dbTablePrefix+x}" ]; then
        log_error "dbTablePrefix is not defined in the configuration and no explicit table list was provided."
        echo "Either define dbTablePrefix in the credentials file or pass explicit tables as the third parameter."
        exit 1
    fi

    like_clause=""
    for p in "${dbTablePrefix[@]}"; do
        esc=${p//\'/\'\'}     # escape single quotes
        esc=${esc//_/\\_}     # make '_' literal in LIKE
        if [ -z "$like_clause" ]; then
            like_clause="(table_name LIKE '${esc}%')"
        else
            like_clause="$like_clause OR (table_name LIKE '${esc}%')"
        fi
    done
    like_clause="($like_clause)"

    # ---- GENERATE TABLE METADATA TSV (BY PREFIX) ----
    log_info "Dumping table metadata to '$tablesMetaFilename' ..."
    if ! mysql "${mysqlConnOpts[@]}" -N \
        -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '$dbName'
              AND ${like_clause}
              AND TABLE_NAME NOT LIKE '%_backup_%'
            ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "$tablesMetaFilename"
    then
        log_warn "Failed to dump table metadata. TSV will be missing, CREATE TABLE enhancement may be skipped."
    fi

    # ---- PREPARE EXPORT TABLE LIST (BY PREFIX) ----
    mysql "${mysqlConnOpts[@]}" -N "$dbName" \
        -e "SELECT table_name
            FROM INFORMATION_SCHEMA.TABLES
            WHERE table_schema='$dbName'
              AND ${like_clause}
              AND table_name NOT LIKE '%_backup_%'
            ORDER BY table_name" > "$allTablesFilename"
fi


# ---------------- DUMP DATABASE ----------------

if [ ! -s "$allTablesFilename" ]; then
    log_warn "No tables selected for export. The resulting dump will be empty."
fi

log_info "Running mysqldump for database '$dbName' into '$targetFilename' ..."
mysqldump \
    "${mysqlConnOpts[@]}" \
    "${COMMON_OPTS[@]}" \
    "$dbName" \
    $(cat "$allTablesFilename" | xargs) \
    > "$targetFilename"


# ---------------- POST-PROCESS DUMP WITH PYTHON ----------------

# strip-mysql-compatibility-comments.py:
#   * removes old-version /*!xxxxx ... */ compatibility comments
#   * uses TSV metadata to enrich CREATE TABLE with missing ENGINE / CHARSET / COLLATION
postProcessor="$scriptDir/strip-mysql-compatibility-comments.py"

if [ -f "$postProcessor" ]; then
    if command -v python3 >/dev/null 2>&1; then
        tmpProcessed="${targetFilename%.sql}.clean.sql"
        log_info "Post-processing dump with Python script: $(basename "$postProcessor")"
        python3 "$postProcessor" "$targetFilename" "$tmpProcessed" "$tablesMetaFilename"
        mv "$tmpProcessed" "$targetFilename"
        log_ok "Dump post-processing completed."
    else
        log_warn "Python3 is not installed; skipping dump post-processing."
    fi
else
    log_warn "Dump post-processing script not found: $postProcessor; skipping."
fi


# ---------------- ARCHIVE MAINTENANCE ----------------

# First of all -- backup previous file, if it exists. Okay if it will overwrite previous file.
if [ -f "$targetFilename.rar" ]; then
    mv "$targetFilename.rar" "$targetFilename.previous.rar"
fi

# compress with gzip (compression level from 1 to 9, from fast to best)
# Use 9 (best) for automatic, scheduled backups and 5 (normal) for manual backups, when you need db now.
#gzip -9 -f "$targetFilename"

rar a -m5 -ep -df "$targetFilename.rar" "$targetFilename"
sudo chown 660 "$targetFilename.rar" || true

log_ok "Dump finished and archived as '$targetFilename.rar'."

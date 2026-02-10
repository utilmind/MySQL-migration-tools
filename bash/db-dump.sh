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
#          * prefix-based selection via dbTablePrefix, OR
#          * all tables if no dbTablePrefix and no explicit list are provided.
#      - Generates reproducible UTF-8 dumps with consistent CREATE TABLE clauses.
#      - Optionally post-processes dumps with Python to restore original
#        charset/collation/table options for cross-server imports.
#      - Compresses resulting dump into RAR archive (if available), otherwise
#        into .tar.gz archive, with rotation of previous archives.
#      - Optionally runs table optimization via "optimize-tables.sh" (can be
#        disabled with --skip-optimize).
#
#  Usage:
#      ./db-dump.sh [--no-data or --ddl] [--skip-optimize] dump-name.sql [configuration-name] ["table1 table2 ..."]
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
#    17.11.2025: If dbTablePrefix is not defined and no explicit table list is
#                provided, export all tables from the database (except *_backup_*).
#                Implement RAR-or-gzip archiving with rotation of previous archives.
###############################################################################
set -euo pipefail

# CONFIGURATION
# Optionally specify table prefixes to export.
# Specify them only as bash array, even if only one prefix is used. Strings are not accepted.
# You may define dbTablePrefix here, but values from the `.[configuration.]credentials.sh` file take priority, if specified there.
#dbTablePrefix=('table_prefix1_' 'table_prefix2_' 'bot_' 'email_' 'user_' 'order_')


# ---------------- BUILD DUMP OPTIONS (COMMON_OPTS) ----------------
# Detect or declare `mysqldump` binary
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
if ! command -v "$MYSQLDUMP_BIN" >/dev/null 2>&1; then
    log_error "mysqldump not found in PATH."
    exit 1
fi

# Read `mysqldump --help` once, to have the list of available options (to check whether specific option is available)
MYSQLDUMP_HELP="$("$MYSQLDUMP_BIN" --help 2>&1)"
# Helper: check if mysqldump supports some specific option
has_mysqldump_opt() {
    # $1 is something like '--set-gtid-purged' or '--column-statistics'
    printf '%s\n' "$MYSQLDUMP_HELP" | grep -q -- "$1"
}

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
if has_mysqldump_opt '--set-gtid-purged'; then
    COMMON_OPTS+=( --set-gtid-purged=OFF )
fi

# If dumping from MySQL 8.x to older MySQL/MariaDB where COLUMN_STATISTICS is absent, OR...
# If you're dumping MariaDB server using mysqldump executable from MySQL, suppress the column stats.
# (Because MariaDB doesn't have the column statistics and this option is enabled by default in MySQL 8+.)
# So... first check whether this option is supported by `mysqldump` and if yes, try to disable column stats.
if has_mysqldump_opt '--column-statistics'; then
  COMMON_OPTS+=( --column-statistics=0 )
fi

# ===== Optional, uncomment/remove as needed =====

# Preserve server local time zone behavior (usually NOT recommended). By default, mysqldump sets UTC.
# Only use if your target server lacks time zone tables or you have a strong reason to avoid UTC.
# if has_mysqldump_opt '--column-statistics'; then
#   COMMON_OPTS+=( --skip-tz-utc )
# fi

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
    $scriptName [--options] dump-name.sql [configuration-name] ["table1 table2 ..."]

Options:
    --no-data OR --ddl (if you prefer .ddl.sql extensions)
        Dump only database structure (no table rows). Additionally, all DROP*
        statements (DROP TABLE / DROP VIEW / DROP TRIGGER / etc.) will be
        removed from the final SQL file to make the schema safer for analysis
        tools and AI without exposing real data.
        --ddl it is a synonym for --no-data. If --ddl is used, it produce files with .ddl.sql extension.

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

    explicit tables list (Optional, after the 'configuration-name')
        Space-separated list of tables to export.
        If provided, dbTablePrefix is ignored and tables are taken exactly from this list.
        Example:
            $scriptName dump.sql my-config table1 table2 table_user stats

Behavior:
    - If explicit table list is provided (3rd parameter), only these tables are exported.
    - Else, if dbTablePrefix is defined in credentials, only tables matching these prefixes
      (and not ending with '_backup_') are exported.
    - Else, if dbTablePrefix is not defined and no explicit table list is provided,
      all tables from the database (except *_backup_*) are exported.

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

(c) utilmind, 2012-2026

EOF
}

# --------- PARAMETER PARSING (--options can be used in any position) -----------

# No parameters at all -> show help
if [ $# -eq 0 ]; then
    print_help
    exit 1
fi

run_optimize=1
structure_only=0   # when 1, dump only schema (no table rows, no DROP statements)
ddl_mode=0         # when 1, the user explicitly requested --ddl (pretty extension .ddl.sql)

positional=()  # used to collect positional options (w/o --)

while [ $# -gt 0 ]; do
    case "$1" in
        -?|-h|-help|--help)
            print_help
            exit 0
            ;;
        --skip-optimize)
            run_optimize=0
            shift
            ;;
        --no-data)
            structure_only=1
            shift
            ;;
        --ddl)
            structure_only=1
            ddl_mode=1
            shift
            ;;
        --)
            # All after are stricly positional even if started with '-'
            shift
            while [ $# -gt 0 ]; do
                positional+=("$1")
                shift
            done
            ;;
        -*)
            log_error "Invalid parameter: '$1'"
            exit 1
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

# Now expect in positional:
#   [0] dump-name.sql (required)
#   [1] configuration-name (optional)
#   [2...] explicit tables list (optional, one or multiple tables)
if [ ${#positional[@]} -lt 1 ]; then
    scriptName=$(basename "$0")
    log_error "Missing required parameters."
    echo "Usage: $scriptName [--no-data] [--skip-optimize] dump-name.sql [configuration-name] [table1 [table2 ...]]"
    exit 1
fi

dumpTemplate="${positional[0]}"
dbConfigName="${positional[1]:-}"   # may be empty

# Collect all the remaining positional arguments into one row of tables
tablesListRaw=""
if [ ${#positional[@]} -gt 2 ]; then
    for ((i = 2; i < ${#positional[@]}; i++)); do
        if [ -z "$tablesListRaw" ]; then
            tablesListRaw="${positional[i]}"
        else
            tablesListRaw="$tablesListRaw ${positional[i]}"
        fi
    done
fi


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

# If user used --ddl (not just --no-data), prefer *.ddl.sql extension for clarity.
if [ "$ddl_mode" -eq 1 ]; then
    case "$targetFilename" in
        *.ddl.sql) : ;;                 # already good
        *.sql) targetFilename="${targetFilename%.sql}.ddl.sql" ;;
        *) : ;;                         # user provided a non-.sql name; keep as-is
    esac
fi


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

# Apply defaults for host and port if not provided in credentials
dbHost="${dbHost:-localhost}"
dbPort="${dbPort:-3306}"

# If dbName is not defined in credentials, we can fall back to dbConfigName (if set).
if [ -z "${dbName:-}" ]; then
    if [ -n "$dbConfigName" ]; then
        dbName="$dbConfigName"
    else
        log_error "'dbName' is not defined in credentials file '$credentialsFile' and no configuration-name argument was provided."
        exit 1
    fi
fi

# dbUser must be defined in credentials
if [ -z "${dbUser:-}" ]; then
    log_error "'dbUser' is not defined in credentials file '$credentialsFile'."
    exit 1
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


# When structure-only dump is requested, adjust mysqldump options:
#  - --no-data: do not dump table rows
#  - --skip-add-drop-table: avoid generating DROP TABLE / DROP VIEW statements
noDropPyOption="";
if [ "$structure_only" -eq 1 ]; then
    # This is paranoid mode. All modern MySQL/MariaDB support --no-data option.
    if has_mysqldump_opt '--no-data'; then
        COMMON_OPTS+=( --no-data )
    else
        log_error "$MYSQLDUMP_BIN does not support --no-data, structure-only dump may contain data rows."
        exit 1
    fi

    # Disable DROP TABLE / DROP VIEW statements in output (if supported).
    if has_mysqldump_opt '--skip-add-drop-table'; then
        COMMON_OPTS+=( --skip-add-drop-table )
    fi

    noDropPyOption="--no-drop";
fi


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
            # No explicit table list: rely on dbTablePrefix or internal logic of optimize-tables.sh
            log_info "Running table optimization (prefix-based or full-DB) via $optScript ..."
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

    # ---- GENERATE TABLE METADATA TSV (EXPLICIT TABLES, exclude views) ----
    log_info "Dumping table metadata for selected tables to '$tablesMetaFilename' ..."
    if ! mysql "${mysqlConnOpts[@]}" -N \
        -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '$dbName'
              AND TABLE_TYPE = 'BASE TABLE'
              AND TABLE_NAME IN (${tablesListInClause})
            ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "$tablesMetaFilename"
    then
        log_warn "Failed to dump table metadata (explicit tables). TSV will be missing, CREATE TABLE enhancement may be skipped."
    fi

    # Prepare list of tables to export (one name per line)
    printf "%s\n" "${explicitTables[@]}" > "$allTablesFilename"

else
    # ---- DETERMINE FILTER: PREFIXES OR ALL TABLES (except VIEW's, only BASE TABLE's) ----
    where_clause="TABLE_SCHEMA = '$dbName'"

    if [ -n "${dbTablePrefix+x}" ]; then
        like_clause=""
        for p in "${dbTablePrefix[@]}"; do
            esc=${p//\'/\'\'}     # escape single quotes
            esc=${esc//_/\\_}     # make '_' literal in LIKE
            if [ -z "$like_clause" ]; then
                like_clause="(TABLE_NAME LIKE '${esc}%')"
            else
                like_clause="$like_clause OR (TABLE_NAME LIKE '${esc}%')"
            fi
        done
        where_clause="$where_clause AND ($like_clause)"
        # log_info "dbTablePrefix is defined; exporting only tables matching configured prefixes."
        log_info "Exporting only tables matching configured prefixes: ${dbTablePrefix[@]}."
    else
        # log_info "dbTablePrefix is not defined; exporting all tables from database '$dbName' (excluding *_backup_*)."
        log_info "Exporting ALL tables from database '$dbName' (excluding *_backup_*)."
    fi

    # Exclude backup tables in either case
    where_clause="$where_clause AND TABLE_NAME NOT LIKE '%_backup_%'"

    # ---- GENERATE TABLE METADATA TSV ----
    log_info "Dumping table metadata to '$tablesMetaFilename' ..."
    if ! mysql "${mysqlConnOpts[@]}" -N \
        -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION
            FROM INFORMATION_SCHEMA.TABLES
            WHERE ${where_clause}
              AND TABLE_TYPE = 'BASE TABLE'
            ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "$tablesMetaFilename"
    then
        log_warn "Failed to dump table metadata. TSV will be missing, CREATE TABLE enhancement may be skipped."
    fi

    # ---- PREPARE EXPORT TABLE LIST ----
    mysql "${mysqlConnOpts[@]}" -N "$dbName" \
        -e "SELECT table_name
            FROM INFORMATION_SCHEMA.TABLES
            WHERE ${where_clause}
            ORDER BY table_name" > "$allTablesFilename"
fi


# ---------------- DUMP DATABASE ----------------

if [ ! -s "$allTablesFilename" ]; then
    if [ -n "$tablesListRaw" ]; then
        # The table lists specified explicitly. But none left after filtration.
        log_warn "No tables selected for export. The resulting dump will be empty."
    elif [ -n "${dbTablePrefix+x}" ] && [ "${#dbTablePrefix[@]}" -gt 0 ]; then
        # Prefixes specified, but no tables.
        # mysqldump will dump w/o explicit tables list and will export ALL tables in result.
        log_warn "No tables found matching configured prefixes: ${dbTablePrefix[*]}."
        log_info "Falling back to exporting ALL tables from database '$dbName'."
    else
        # No prefixes and no tables
        log_warn "No tables found in database '$dbName'. The resulting dump will be empty."
    fi
fi

log_info "Running $MYSQLDUMP_BIN for database '$dbName' into '$targetFilename' ..."
"$MYSQLDUMP_BIN" \
    "${mysqlConnOpts[@]}" \
    "${COMMON_OPTS[@]}" \
    "$dbName" \
    $(cat "$allTablesFilename" | xargs) \
    > "$targetFilename"


# ---------------- POST-PROCESS DUMP WITH PYTHON ----------------

# post-process-dump.py:
#   * removes old-version /*!xxxxx ... */ compatibility comments
#   * uses TSV metadata to enrich CREATE TABLE with missing ENGINE / CHARSET / COLLATION
#   * optionally prepends USE `db_name`; statement, when --db-name is used
#   * optionally prepends a custom file to the dump, when --prepend-file is used
postProcessor="$scriptDir/post-process-dump.py"
need_fallback_use_header=0

if [ -f "$postProcessor" ]; then
    if command -v python3 >/dev/null 2>&1; then
        tmpProcessed="${targetFilename%.sql}.clean.sql"
        log_info "Post-processing dump with Python script: $(basename "$postProcessor")"
        python3 "$postProcessor" \
            --db-name "$dbName" \
            ${noDropPyOption:+$noDropPyOption} \
            "$targetFilename" \
            "$tmpProcessed" \
            "$tablesMetaFilename"
        if [ $? -eq 0 ]; then
            mv "$tmpProcessed" "$targetFilename"
            log_ok "Dump post-processing completed."
        else
            log_error "Python post-processing failed; falling back to simple USE header injection."
            # make sure we don't leave partial tmp file around if python failed mid-way
            rm -f "$tmpProcessed"
            need_fallback_use_header=1
        fi
    else
        log_warn "Python3 is not installed; falling back to simple USE header injection."
        need_fallback_use_header=1
    fi
else
    log_warn "Dump post-processing script not found: $postProcessor; falling back to simple USE header injection."
    need_fallback_use_header=1
fi

if [ "$need_fallback_use_header" -eq 1 ]; then
    # Add a "USE [database-name]" statement at the top of the dump.
    #
    #   Normally this can be achieved by using `--databases [db_name ...] --no-create-db`
    #   options of `mysqldump`, which emit a `USE` statement for each dumped database.
    #   Unfortunately, when `--databases` is used, every argument after it is treated
    #   as a database name, not as a table name. That means we cannot simultaneously
    #   use `--databases` and specify an explicit list of tables to dump.
    #   This script is designed to dump only a selected subset of tables from a single
    #   database, so we stay in the "single db + tables" mode and prepend `USE` manually.
    #
    #   The header below is mostly for convenience: it makes importing the dump
    #   on another server easier, because the target database is selected automatically.
    #
    tmpWithUse="${targetFilename%.sql}.with_use.sql"
    {
      printf '%s\n\nUSE `%s`;\n\n' \
        '-- Dump created with DB migration tools ( https://github.com/utilmind/MySQL-migration-tools )' \
        "$dbName"
      cat "$targetFilename"
    } > "$tmpWithUse"
    mv "$tmpWithUse" "$targetFilename"

    # If structure-only dump was requested, strip any remaining DROP statements
    # from the final SQL. This includes plain "DROP ..." lines and versioned
    # comments like "/*!50001 DROP ... */".
    if [ "$structure_only" -eq 1 ]; then
        log_info "Removing DROP* statements from structure-only dump ..."
        tmpNoDrop="${targetFilename%.sql}.nodrop.sql"

        # Use awk to remove lines whose first meaningful token is DROP,
        # including versioned comments which unwrap into DROP lines.
        awk '
        {
            orig = $0

            # Trim leading whitespace
            line = orig
            sub(/^[ \t]+/, "", line)

            # Case 1: line starts directly with DROP (DROP TABLE / DROP VIEW / etc.)
            up = toupper(line)
            if (substr(up,1,4) == "DROP") {
                next
            }

            # Case 2: versioned comments like "/*!50001 DROP VIEW ... */"
            if (substr(line,1,3) == "/*!") {
                # Strip "/*!<digits>" prefix
                gsub(/^\/\*![0-9]+[ \t]*/, "", line)
                sub(/^[ \t]+/, "", line)
                up = toupper(line)
                if (substr(up,1,4) == "DROP") {
                    next
                }
            }

            # Keep everything else
            print orig
        }' "$targetFilename" > "$tmpNoDrop"

        mv "$tmpNoDrop" "$targetFilename"
    fi
fi


# -------------- ARCHIVE MAINTENANCE ---------------

# Check if RAR available
if command -v rar >/dev/null 2>&1; then
    # Use RAR with rotation
    archiveFile="${targetFilename}.rar"
    archivePrev="${targetFilename}.previous.rar"

    if [ -f "$archiveFile" ]; then
        log_info "Rotating to '$archivePrev' ..."
        mv -f "$archiveFile" "$archivePrev"
    fi

    log_info "Archiving dump as '$archiveFile' ..."
    # -m5 = best compression, -ep = do not store paths
    # -df = delete SQL file. Remove that option if you want to keep SQL file after archivation.
    rar a -m5 -ep -df "$archiveFile" "$targetFilename"

else
    # Fallback: first try gzip, if no gzip either — leave just regular SQL dump.
    if command -v gzip >/dev/null 2>&1; then
        # plain gzip with rotation (btw no TAR needed, since this is single SQL file)
        archiveFile="${targetFilename}.gz"
        archivePrev="${targetFilename}.previous.gz"

        if [ -f "$archiveFile" ]; then
            log_info "Rotating to '$archivePrev' ..."
            mv -f "$archiveFile" "$archivePrev"
        fi

        # compression level 9 (best)
        if ! gzip -9 -c "$targetFilename" > "$archiveFile"; then
            log_warn "gzip compression failed; leaving original dump '$targetFilename' uncompressed."
            rm -f "$archiveFile" 2>/dev/null || true
            archiveFile="$targetFilename"
        else
            # Compression successful. Delete source .sql
            rm -f "$targetFilename"
        fi
    else
        log_warn "'rar' and 'gzip' are not available. Dump will remain uncompressed."
        archiveFile="$targetFilename"
    fi
fi

log_ok "Dump finished and archived as '$archiveFile'."

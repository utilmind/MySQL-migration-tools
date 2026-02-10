#!/bin/bash
###############################################################################
#  Table Optimization Utility (optimize-tables.sh)
#
#  Part of: MySQL Migration Tools
#  Copyright (c) 2012-2026 utilmind
#  https://github.com/utilmind/MySQL-migration-tools
#
#  Description:
#      Runs safe optimization / analyze operations for MySQL/MariaDB tables.
#      - Reads DB connection settings from ".credentials.sh" or
#        ".<configuration-name>.credentials.sh" (same directory as the script).
#      - Supports explicit table list (2nd parameter) or prefix-based selection
#        via dbTablePrefix array from credentials.
#      - If dbTablePrefix is not defined OR defined but empty, all tables in the
#        database are used (except *_backup_*).
#      - MyISAM tables -> mysqlcheck --optimize
#      - InnoDB tables -> mysqlcheck --analyze
#
#  Usage:
#      ./optimize-tables.sh [configuration-name] ["table1 table2 ..."]
#
#      configuration-name (optional)
#          Used to choose ".<configuration-name>.credentials.sh".
#          If omitted or empty, ".credentials.sh" is used.
#
#      explicit tables list (optional, second parameter)
#          Quoted, space-separated list of table names.
#          Example:
#              ./optimize-tables.sh my-config "table1 table2 table_user logs"
#
#  Behavior:
#      - If explicit table list is provided:
#            Only these tables are checked (engines are detected via
#            INFORMATION_SCHEMA.TABLES).
#      - Else, if dbTablePrefix is defined and non-empty:
#            Only tables whose names start with any of the prefixes are used
#            (excluding '*_backup_*').
#      - Else (no prefixes):
#            All tables in the database are used (excluding '*_backup_*').
#
#  NOTE:
#      - This script is intended to be called from db-dump.sh, but it can also
#        be used standalone.
#
#  License: MIT
###############################################################################
set -euo pipefail

# CONFIGURATION
# Optionally specify table prefixes to process for optimization/analyze.
# You may define dbTablePrefix here, but values from the `.[configuration.]credentials.sh` file take priority, if specified there.
#dbTablePrefix=('table_prefix1_' 'table_prefix2_' 'bot_' 'email_' 'user_' 'order_')


print_help() {
  scriptName=$(basename "$0")
  cat << EOF
Usage: $scriptName [configuration-name] ["table1 table2 table3"]

configuration-name (Optional)
    Used to locate credentials file with name ".configuration-name.credentials.sh"
    placed in the same directory as this script.
    If not provided, then ".credentials.sh" will be used.

explicit tables list (Optional, second parameter)
    Quoted space-separated list of tables to process.
    If provided, dbTablePrefix is ignored and only these tables are optimized/analyzed.

If no explicit table list is given:
    - and dbTablePrefix is defined (non-empty), only tables with these prefixes
      are processed (excluding *_backup_*),
    - otherwise, ALL tables in the database are processed (excluding *_backup_*).

Examples:
    $scriptName
        # use .credentials.sh, optimize/analyze tables (based on dbTablePrefix, if specified)

    $scriptName my-config
        # use .my-config.credentials.sh, optimize/analyze tables (based on dbTablePrefix, if specified)

    $scriptName my-config "table1 table2 stats"
        # use .my-config.credentials.sh, optimize/analyze only the listed tables

EOF
}


# ANSI colors (disabled if NO_COLOR is set or output is not a TTY)
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


# ---------------- PARAMETER PARSING ----------------

while [[ "${1-}" == -* ]] ; do
    case "$1" in
        -?|-h|-help|--help)
            print_help
            exit 0
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


dbConfigName="${1:-}"         # configuration-name (may be empty)
tablesListRaw="${2:-}"        # optional explicit table list (quoted)


# ---------------- BASIC PATHS ----------------

thisScript=$(readlink -f "$0")
scriptDir=$(dirname "$thisScript")

# Temporary directory for helper files.
tempDir="$scriptDir/_temp"
mkdir -p "$tempDir"

myisamTablesFilename="$tempDir/_${dbConfigName}-optimize_tables.txt"
innoDBTablesFilename="$tempDir/_${dbConfigName}-analyze_tables.txt"



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
#   dbHost, dbPort, dbName, dbUser, optional dbPass, optional dbTablePrefix (array)
. "$credentialsFile"

# Apply defaults for host and port if not provided in credentials
dbHost="${dbHost:-localhost}"
dbPort="${dbPort:-3306}"

# If dbName is not defined, try to use configuration name as DB name.
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

# Ask for password if missing
if [ -z "${dbPass:-}" ]; then
    read -s -p "Enter password for MySQL user '$dbUser' (database '$dbName'): " dbPass
    echo
fi

mysqlConnOpts=(
    --host="$dbHost"
    --port="$dbPort"
    --user="$dbUser"
    --password="$dbPass"
)

# Clean previous lists
: > "$myisamTablesFilename"
: > "$innoDBTablesFilename"

# ---------------- BUILD TABLE LISTS ----------------

if [ -n "$tablesListRaw" ]; then
    # ---------- EXPLICIT TABLE LIST MODE ----------
    log_info "Using explicit table list for optimization/analyze."

    declare -a explicitTables=()
    read -r -a explicitTables <<< "$tablesListRaw"

    if [ ${#explicitTables[@]} -eq 0 ]; then
        log_error "Explicit table list is empty after parsing."
        exit 1
    fi

    # Build IN clause for INFORMATION_SCHEMA query
    tablesInClause=""
    for t in "${explicitTables[@]}"; do
        esc=${t//\'/\'\'}   # escape quotes
        if [ -z "$tablesInClause" ]; then
            tablesInClause="'$esc'"
        else
            tablesInClause="$tablesInClause, '$esc'"
        fi
    done

    log_info "Detecting engines for explicitly listed tables..."
    while IFS=$'\t' read -r tbl engine; do
        case "$engine" in
            MyISAM)
                echo "$tbl" >> "$myisamTablesFilename"
                ;;
            InnoDB)
                echo "$tbl" >> "$innoDBTablesFilename"
                ;;
            *)
                log_info "Skipping table '$tbl' with unsupported engine '$engine'."
                ;;
        esac
    done < <(
        # BASE TABLE's only, no VIEW's.
        mysql "${mysqlConnOpts[@]}" -N \
            -e "SELECT TABLE_NAME, ENGINE
                FROM INFORMATION_SCHEMA.TABLES
                WHERE TABLE_SCHEMA = '$dbName'
                  AND TABLE_TYPE = 'BASE TABLE'
                  AND TABLE_NAME IN (${tablesInClause})
                ORDER BY TABLE_NAME;"
    )

else
    # ---------- PREFIX-BASED OR FULL-DB MODE ----------
    # BASE TABLE's only, no VIEW's.
    where_clause="TABLE_SCHEMA = '$dbName' AND TABLE_TYPE = 'BASE TABLE'"

    # dbTablePrefix may be undefined or an empty array.
    if [ -n "${dbTablePrefix+x}" ] && [ "${#dbTablePrefix[@]}" -gt 0 ]; then
        log_info "Optimizing only tables matching prefixes: ${#dbTablePrefix[@]}."

        like_clause=""
        for p in "${dbTablePrefix[@]}"; do
            esc=${p//\'/\'\'}        # escape quotes
            esc=${esc//_/\\_}        # escape '_' for LIKE
            if [ -z "$like_clause" ]; then
                like_clause="(TABLE_NAME LIKE '${esc}%')"
            else
                like_clause="$like_clause OR (TABLE_NAME LIKE '${esc}%')"
            fi
        done
        where_clause="$where_clause AND ($like_clause)"
    else
        # log_info "dbTablePrefix is not defined or empty; using ALL tables in '$dbName' (excluding *_backup_*)."
        log_info "Using ALL tables in '$dbName' (excluding *_backup_*)."
    fi

    # Exclude backup tables always
    where_clause="$where_clause AND TABLE_NAME NOT LIKE '%_backup_%'"

    log_info "Detecting engines for selected tables from INFORMATION_SCHEMA..."
    while IFS=$'\t' read -r tbl engine; do
        case "$engine" in
            MyISAM)
                echo "$tbl" >> "$myisamTablesFilename"
                ;;
            InnoDB)
                echo "$tbl" >> "$innoDBTablesFilename"
                ;;
            *)
                log_info "Skipping table '$tbl' with unsupported engine '$engine'."
                ;;
        esac
    done < <(
        mysql "${mysqlConnOpts[@]}" -N \
            -e "SELECT TABLE_NAME, ENGINE
                FROM INFORMATION_SCHEMA.TABLES
                WHERE ${where_clause}
                ORDER BY TABLE_NAME;"
    )
fi

# ---------------- RUN MYSQLCHECK ----------------

if [ -s "$myisamTablesFilename" ]; then
    log_info "Optimizing MyISAM tables via mysqlcheck --optimize ..."
    mysqlcheck "${mysqlConnOpts[@]}" \
        --optimize \
        "$dbName" \
        $(cat "$myisamTablesFilename")
else
    log_info "No MyISAM to optimize."
fi

if [ -s "$innoDBTablesFilename" ]; then
    log_info "Analyzing InnoDB tables via mysqlcheck --analyze ..."
    mysqlcheck "${mysqlConnOpts[@]}" \
        --analyze \
        "$dbName" \
        $(cat "$innoDBTablesFilename")
else
    log_info "No InnoDB tables to analyze."
fi

log_ok "Table optimization/analyze completed."

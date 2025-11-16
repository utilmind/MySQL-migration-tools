#!/bin/bash
set -euo pipefail


# CONFIGURATION
# Specify as bash array, even if only 1 prefix is used. Strings are not accepted. Only array is ok.
dbTablePrefix=('silk_' 'silkx_' '3dproofer_' 'bot_' 'email_')


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


# FUNCTIONS
# ------------
print_help() {
  scriptName=$(basename "$0")
  cat << EOF
Usage: $scriptName dump-name.sql [database-name]

dump-name.sql (Required)
    The exported filename can automatically contain current date.
    If filename contains '@', it will be replaced with current date YYYYMMDD.
    Example:
        $scriptName exported_data_@.sql silkcards
    (So this tool can be executed by the crontab to produce daily files with unique names.)

database-name (Optional)
    Used to locate credentials file with name ".database-name.credentials.sh"
    placed in the same directory as this script.
    If not provided, then ".credentials.sh" will be used.

    DB credentials file example (.credentials.sh or .silkcards.credentials.sh):

        #!/bin/bash
        dbHost='localhost'
        dbPort=3306
        dbName='your_database_name'
        dbUsername='your_database_user'
        dbPassword='your-password'
        # dbPassword can be omitted; in this case the script will ask for it interactively.

        # Optional: you can override default table prefixes for this DB:
        # dbTablePrefix=('table_prefix_' 'table_prefix2_')

(c) utilmind@gmail.com, 2012-2025
    15.10.2024: Each dump have date, don't overwrite past days backups. Old backups can be deleted by garbage collector.
    26.08.2025: Multiple table prefixes.
    15.11.2025: Request password if not specified in configuration;
                Process dump to remove MySQL compatibility comments
                + provide missing details (server defaults) to the 'CREATE TABLE' statements
                  (to solve issues with collations on import).
                (These features require Python3+ installed.)

EOF
}

# ---------------- PARAMETER PARSING ----------------

# No parameters at all -> show help
if [ $# -eq 0 ]; then
    print_help
    exit 1
fi

# Handle optional flags (-h / --help)
while [[ "$1" == -* ]] ; do
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
            echo "ERROR: Invalid parameter: '$1'"
            exit 1
            ;;
    esac
done

# Now we expect:
#   1) dump-name.sql (required)
#   2) database-name (optional)
if [ $# -lt 1 ]; then
    scriptName=$(basename "$0")
    echo "ERROR: Missing required parameters."
    echo "Usage: $scriptName dump-name.sql [database-name]"
    exit 1
fi

dumpTemplate="$1"
dbConfigName="${2:-}"   # may be empty

# ---------------- BASIC PATHS / FILENAMES ----------------

thisScript=$(readlink -f "$0") # alternative is $(realpath "$0"), if "realpath" is installed
scriptDir=$(dirname "$thisScript")

# Temporary directory for helper files (table lists, metadata, etc.)
tempDir="$scriptDir/_temp"
# Create $tempDir if not exists
mkdir -p "$tempDir"

# Temporary files, table lists...
myisamTablesFilename="$tempDir/_${dbConfigName}-optimize_tables.txt"
innoDBTablesFilename="$tempDir/_${dbConfigName}-analyze_tables.txt"
allTablesFilename="$tempDir/_${dbConfigName}-export_tables.txt"
# TSV with table metadata for Python post-processing.
# We keep it in the temp directory, with predictable name.
tablesMetaFilename="$tempDir/_${dbConfigName}-tables_meta.tsv"

current_date=$(date +"%Y%m%d")
targetFilename=$(echo "$dumpTemplate" | sed "s/@/${current_date}/g")


# ---------------- LOAD CREDENTIALS ----------------

# Select credentials file:
#   if database-name is given -> .database-name.credentials.sh
#   otherwise                 -> .credentials.sh
if [ -n "$dbConfigName" ]; then
    credentialsFile="$scriptDir/.${dbConfigName}.credentials.sh"
else
    credentialsFile="$scriptDir/.credentials.sh"
fi

if [ ! -r "$credentialsFile" ]; then
    echo "ERROR: Credentials file '$credentialsFile' not found or not readable."
    echo "Please create it with DB connection settings:"
    echo "  dbHost, dbPort, dbName, dbUsername, [dbPassword], [dbTablePrefix]"
    exit 1
fi

# Load DB credentials (and optional dbTablePrefix override)
# Expected variables:
#   dbHost, dbPort, dbName, dbUsername, optional dbPassword, optional dbTablePrefix
. "$credentialsFile"

# If dbName is not defined in credentials, we can fall back to dbConfigName (if set).
if [ -z "${dbName:-}" ]; then
    if [ -n "$dbConfigName" ]; then
        dbName="$dbConfigName"
    else
        echo "ERROR: 'dbName' is not defined in credentials file '$credentialsFile' and no database-name argument was provided."
        exit 1
    fi
fi

# Ask for password if it is not defined or empty
if [ -z "${dbPassword:-}" ]; then
    read -s -p "Enter password for MySQL user '$dbUsername' (database '$dbName'): " dbPassword
    echo
fi

# Common MySQL connection options (used for mysql, mysqlcheck, mysqldump)
mysqlConnOpts=(
    --host="$dbHost"
    --port="$dbPort"
    --user="$dbUsername"
    --password="$dbPassword"
)


# ---------------- BUILD TABLE FILTER (PREFIXES) ----------------

# Build SQL WHERE for multiple prefixes
# Example result: (table_name LIKE 'silk\_%' OR table_name LIKE 'beta\_%')
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


# ---------------- GENERATE TABLE METADATA TSV ----------------
# This is used by strip-mysql-compatibility-comments.py to:
#   * fill missing ENGINE / ROW_FORMAT / COLLATION in CREATE TABLE
#   * keep resulting schema as close to original server as possible.

echo "Dumping table metadata to '$tablesMetaFilename' ..."
if ! mysql "${mysqlConnOpts[@]}" -N \
    -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = '$dbName'
          AND ${like_clause}
          AND TABLE_NAME NOT LIKE '%_backup_%'
        ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "$tablesMetaFilename"
then
    echo "WARNING: Failed to dump table metadata. TSV will be missing, CREATE TABLE enhancement may be skipped." >&2
fi


# ---------------- PREPARE TABLE LISTS ----------------

# Get tables. Only BASE TABLEs with non-InnoDB/non-Memory engine can be optimized.
mysql "${mysqlConnOpts[@]}" -N "$dbName" \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema='$dbName'
          AND table_type='BASE TABLE'
          AND ENGINE = 'MyISAM'
          AND ${like_clause}
          AND table_name NOT LIKE '%_backup_%'
        ORDER BY table_name" > "$myisamTablesFilename"

# Get tables. Only BASE TABLEs with InnoDB engine for analyze (instead of optimization).
mysql "${mysqlConnOpts[@]}" -N "$dbName" \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema='$dbName'
          AND table_type='BASE TABLE'
          AND ENGINE = 'InnoDB'
          AND ${like_clause}
          AND table_name NOT LIKE '%_backup_%'
        ORDER BY table_name" > "$innoDBTablesFilename"

# Get all kinds of tables: BASE TABLEs and VIEWS for export.
mysql "${mysqlConnOpts[@]}" -N "$dbName" \
    -e "SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema='$dbName'
          AND ${like_clause}
          AND table_name NOT LIKE '%_backup_%'
        ORDER BY table_name" > "$allTablesFilename"


# ---------------- OPTIMIZE NON-INNODB TABLES ----------------

# Optimize MyISAM tables, to export data faster.
if [ -s "$myisamTablesFilename" ]; then
    echo Optimizing MyISAM tables...
    mysqlcheck --optimize --verbose \
        "${mysqlConnOpts[@]}" \
        --databases "$dbName" \
        --tables $(cat "$myisamTablesFilename" | xargs) \
    || echo "WARNING: Failed to optimize MyISAM tables (probably insufficient privileges). Continuing without optimization." >&2
fi

# Analyze InnoDB tables to optimize further queries.
if [ -s "$innoDBTablesFilename" ]; then
    echo Analyizing InnoDB tables...
    mysqlcheck --analyze --verbose \
        "${mysqlConnOpts[@]}" \
        --databases "$dbName" \
        --tables $(cat "$innoDBTablesFilename" | xargs) \
    || echo "WARNING: Failed to analyze InnoDB tables (probably insufficient privileges). Continuing without analyze." >&2
fi
# ---------------- DUMP DATABASE ----------------

# Export using COMMON_OPTS built above.
mysqldump \
    "${mysqlConnOpts[@]}" \
    "${COMMON_OPTS[@]}" \
    "$dbName" \
    $(cat "$allTablesFilename" | xargs) \
    > "$targetFilename"

# BTW, alternative syntax to export everything by databases:
# mysqldump -h [host] -u [user] -p --databases [database names] \
#     --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces \
#     --triggers --routines --events > FILENAME.sql


# ---------------- POST-PROCESS DUMP WITH PYTHON ----------------

# strip-mysql-compatibility-comments.py:
#   * removes old-version /*!xxxxx ... */ compatibility comments
#   * uses TSV metadata to enrich CREATE TABLE with missing ENGINE / CHARSET / COLLATION
postProcessor="$scriptDir/strip-mysql-compatibility-comments.py"

if [ -f "$postProcessor" ]; then
    if command -v python3 >/dev/null 2>&1; then
        tmpProcessed="${targetFilename%.sql}.clean.sql"
        #echo "Post-processing dump with Python script: $postProcessor"
        #echo "  Input : $targetFilename"
        #echo "  Output: $tmpProcessed"
        #echo "  TSV   : $tablesMetaFilename"
        python3 "$postProcessor" "$targetFilename" "$tmpProcessed" "$tablesMetaFilename"
        mv "$tmpProcessed" "$targetFilename"
    else
        echo "WARNING: Python3 is not installed; skipping dump post-processing." >&2
    fi
else
    echo "WARNING: Dump post-processing script not found: $postProcessor; skipping." >&2
fi


# ---------------- ARCHIVE MAINTENANCE ----------------

# First of all -- backup previous file, if it exists. Okay if it will overwrite previous file.
if [ -f "$targetFilename.rar" ]; then
    mv "$targetFilename.rar" "$targetFilename.previous.rar"
fi

# compress with gzip (compression level from 1 to 9, from fast to best)
# Use 9 (best) for automatic, scheduled backups and 5 (normal) for manual backups, when you need db now.
#gzip -9 -f "$targetFilename"

# compress with rar (compression level from 1 to 5, from fast to best)
# -ep = don't preserve file path
# -df = delete file after archiving
rar a -m5 -ep -df "$targetFilename.rar" "$targetFilename"
sudo chown 660 "$targetFilename.rar"

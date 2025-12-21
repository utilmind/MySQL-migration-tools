@echo off
REM ======================================================================
REM  db-dump.bat
REM
REM  Copyright (c) 2025 utilmind
REM  All rights reserved.
REM  https://github.com/utilmind/MySQL-migration-tools
REM
REM  Description:
REM    Helper script for MySQL / MariaDB database backup and migration.
REM
REM    Features:
REM      - Detects non-system databases on the server.
REM      - Dumps all or selected databases either:
REM          * into separate .sql files per database, or
REM          * into a single combined dump file.
REM      - Optionally exports MySQL users and grants into a separate file and
REM        prepends it to the FULL dump.
REM      - Optionally post-processes each dump with Python to remove old
REM        versioned compatibility comments and normalize CREATE TABLE.
REM
REM  Usage (examples):
REM      db-dump.bat
REM        - Dump all non-system databases to separate files.
REM
REM      db-dump.bat --one
REM        - Dump all non-system databases into a single SQL file
REM             (_db.sql if the target file name is not specified).
REM        - Optionally we can specify the target file name as follows:
REM             db-dump.bat --one=my-dump-name.sql
REM
REM      db-dump.bat [options] db1 db2 ...
REM        - Dump only selected databases. Other behavior depends on internal flags and CLI options.
REM             Valid options:
REM                 --one[=dump-name.sql] - dumps all into single file. Filename can be specified.
REM                 --no-users - doesn't export user grants and privileges.
REM
REM =================================================================================================

REM ================== CONFIG ==================
REM Path to bin folder containing mysql/mysqldump or mariadb/mariadb-dump (optional).
REM If empty, "mysql.exe" / "mysqldump.exe" (or "mariadb.exe" / "mariadb-dump.exe") are used from PATH.
REM If set, slash "\" will be appended automatically. Something like "SQLBIN=C:\Program Files\MariaDB 10.5\bin".)
REM ATTN! If you have MULTIPLE INSTALLATIONS of MySQL/MariaDB on this machine, it's strongly recommended
REM       to specify the exact path to the working version you are dumping from!
set "SQLBIN="
REM Run "mysql --version" to figure out the version of your default mysql.exe
REM set "SQLCLI=mariadb.exe"
set "SQLCLI=mysql.exe"
REM set "SQLDUMP=mariadb-dump.exe"
set "SQLDUMP=mysqldump.exe"

REM Output folder for dumps (will be created if missing)
set "OUTDIR=.\_db-dumps"

REM Connection params (leave DB_HOST/DB_PORT default if local)
set "DB_HOST=localhost"
set "DB_PORT=3306"
set "DB_USER=root"
REM Password: put real password here, or leave EMPTY to be prompted. Do not expose your password in public!!
set "DB_PASS="

REM Optional: local option file next to this script (NOT committed). If present, it will be passed to mysql/mysqldump via --defaults-extra-file.
REM File name (relative to this .bat): ".mysql-client.ini"
set "LOCAL_DEFAULTS_FILE=%~dp0.mysql-client.ini"
set "USE_DEFAULTS_FILE=0"
if exist "%LOCAL_DEFAULTS_FILE%" set "USE_DEFAULTS_FILE=1"

REM Optional: increase client max_allowed_packet for large rows/BLOBs.
REM Example values: 64M, 256M, 1G
set "MAX_ALLOWED_PACKET=1024M"

REM Optional: set the network buffer size for mysqldump in bytes.
REM This can help when dumping tables with large rows / BLOBs over slow or flaky connections.
REM Example values: 1048576 (1 MiB), 4194304 (4 MiB)
set "NET_BUFFER_LENGTH=4194304"

REM If 1, add --skip-ssl to all mysql/mysqldump invocations (ONLY when SSL_CA is empty).
REM Default: 0 (SSL is enabled/required if the server enforces it).
set "SKIP_SSL=0"

REM Optional: path to a trusted CA bundle (PEM). If set, it overrides SKIP_SSL.
REM Example (AWS RDS):
REM   1) Download the CA bundle (PEM) from the AWS docs:
REM      https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html
REM   2) Save it locally, e.g. (PowerShell):
REM      powershell -NoProfile -Command ^
REM        "Invoke-WebRequest -Uri 'https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem' -OutFile 'C:\certs\rds-global-bundle.pem'"
REM   3) Set SSL_CA to that file path, e.g.:
REM      set "SSL_CA=C:\certs\rds-global-bundle.pem"
set "SSL_CA="


REM Get all databases into single SQL-dump: 1 = yes, 0 = no. This option can be overridden (turned on) by `--ONE` parameter
set "ONE_MODE=0"

REM Flag: 1 when dumping ALL non-system databases (auto-detected list)
set "ALL_DB_MODE=0"

REM If you want to automatically export users/grants, set this to 1 and ensure the second .bat exists. Included in the beginning of FULL dump.
set "EXPORT_USERS_AND_GRANTS=1"

REM Dump post-processor tool (to remove MySQL compatibility comments + add missing options to the `CREATE TABLE` statements).
REM     * The MySQL Dump put compatibility comments for earlier MySQL versions (or potentially unsupported features).
REM       E.g `CREATE TRIGGER` is not supported by ancient MySQL versions.
REM       And the MySQL Dump wraps those instructons in to magic comments, like /*!50003 CREATE*/ /*!50017 DEFINER=`user`@`host`*/ /*!50003 TRIGGER ... END */,
REM       making issues with regular multiline comments /* ... */ within the triggers.
REM       We can remove those compatibility comments targeted for the legacy versions (numbers less than 5.6 or 8.0), to keep the important developers comments in the code.
REM     * Solves issues with importing tables to the servers with other database defaults (collations / charsets) by supplying `CREATE TABLE` statements with missing instructions.
REM     * Prepends the single-database dumps with USE `db_name`; statement.
REM     * Replace any standalone "SET time_zone = 'UTC';" statement with "SET time_zone = '+00:00';".
REM
REM   0 = OFF  -> keep all dumps 'as-is', as they originally exported.
REM   1 = ON   -> produce processed dumps clean of the compatibility comments and with complete CREATE TABLE instructions.
REM               * Python should be installed if this feature is used!
set "POST_PROCESS_DUMP=1"
REM The file name appendix for dumps clean of the compatibility comments. E.g. mydata.sql -> mydata.clean.sql
set "POST_PROCESS_APPENDIX=.clean"
REM Replace 'python' to 'python3' or 'py', depending under which name the Python interpreter is registered in your system.
set "POST_PROCESSOR=python ./bash/post-process-dump.py"
REM ================== END CONFIG ==================


REM Use UTF-8 encoding for output, if needed
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

REM ================== RESOLVE TOOL PATHS (SQLBIN-aware) ==================
REM Normalize SQLBIN (ensure trailing backslash) and build full executable paths.
set "SQLBIN_NORM=%SQLBIN%"
if defined SQLBIN_NORM (
  if not "%SQLBIN_NORM%"=="" (
    if not "%SQLBIN_NORM:~-1%"=="\" set "SQLBIN_NORM=!SQLBIN_NORM!\"
  )
)
if not defined SQLCLI (
  echo ERROR: SQLCLI ^(mysql.exe or mariadb.exe^) is not defined.
  goto :end
)
if not defined SQLDUMP (
  echo ERROR: SQLDUMP ^(mysqldump.exe or mariadb-dump.exe^) is not defined.
  goto :end
)

set "SQLCLI_EXE=%SQLBIN_NORM%%SQLCLI%"
set "SQLDUMP_EXE=%SQLBIN_NORM%%SQLDUMP%"

REM If SQLBIN is provided, ensure the executables exist there (fail fast).
if not "%SQLBIN_NORM%"=="" (
  if not exist "%SQLCLI_EXE%" (
    echo ERROR: %SQLCLI% not found at "%SQLBIN_NORM%".
    echo Please edit SQLBIN / SQLCLI in "%~nx0".
    goto :end
  )
  if not exist "%SQLDUMP_EXE%" (
    echo ERROR: %SQLDUMP% not found at "%SQLBIN_NORM%".
    echo Please edit SQLBIN / SQLDUMP in "%~nx0".
    goto :end
  )
)


REM ==================== READ mysqldump HELP ====================
REM Make sure that mysqldump exists in PATH
"%SQLDUMP_EXE%" --version >nul 2>&1

if errorlevel 1 (
    echo [FAIL] mysqldump not found in PATH or not executable.
    goto :end
)

REM Store mysqldump --help output in a temporary file for reuse
set "MYSQLDUMP_HELP_FILE=%TEMP%\mysqldump_help_%RANDOM%.tmp"
"%SQLDUMP_EXE%" --help >"%MYSQLDUMP_HELP_FILE%" 2>&1
if errorlevel 1 (
    echo [FAIL] Failed to execute "%SQLDUMP% --help".
    del "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
    goto :end
)


REM Dump options common for all databases
REM NOTE: These options affect every dump produced by this script.
REM       Keep them conservative for maximum compatibility.
set "COMMON_OPTS=--routines --events --triggers --single-transaction --quick"
REM Connection-related options reused across mysql and mysqldump.
REM SSL_CA has priority over SKIP_SSL (they are mutually exclusive).
set "CONN_SSL_OPTS="
if not "%SSL_CA%"=="" (
  set "CONN_SSL_OPTS=--ssl --ssl-ca=""%SSL_CA%"""
) else (
  if "%SKIP_SSL%"=="1" (
    set "CONN_SSL_OPTS=--skip-ssl"
  )
)

REM Enable compression for remote hosts by default (when DB_HOST is set and not localhost/127.0.0.1).
set "CONN_COMPRESS_OPTS="
if not "%DB_HOST%"=="" (
  if /I not "%DB_HOST%"=="localhost" if /I not "%DB_HOST%"=="127.0.0.1" (
    set "CONN_COMPRESS_OPTS=--compress"
  )
)

REM If a local defaults file is used, do not force SSL/compress settings via CLI (ini must take precedence).
if "%USE_DEFAULTS_FILE%"=="1" (
  set "CONN_SSL_OPTS="
  set "CONN_COMPRESS_OPTS="
)


REM Optional: raise packet limit for large rows/BLOBs (client-side).
REM IMPORTANT: The server-side max_allowed_packet must also allow this value.
REM Only enable this option if mysqldump actually supports it (older builds may not).
if "%USE_DEFAULTS_FILE%"=="0" if not "%MAX_ALLOWED_PACKET%"=="" (
    findstr /C:"--max-allowed-packet" "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
    if not errorlevel 1 (
        set "COMMON_OPTS=%COMMON_OPTS% --max-allowed-packet=%MAX_ALLOWED_PACKET%"
    )
)

REM If requested, set the network buffer size (mysqldump client-side) in bytes.
REM Only enable this option if mysqldump actually supports it (older builds may not).
if "%USE_DEFAULTS_FILE%"=="0" if defined NET_BUFFER_LENGTH (
    if not "%NET_BUFFER_LENGTH%"=="" (
        findstr /C:"--net-buffer-length" "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
        if not errorlevel 1 (
            set "COMMON_OPTS=%COMMON_OPTS% --net-buffer-length=%NET_BUFFER_LENGTH%"
        )
    )
)

REM === CLIENT CLI OPTIONS (mysql.exe, not mysqldump.exe) ===
REM Add certificate verification flag only when the client supports it.
set "CONN_VERIFY_CERT_OPTS="
if "%USE_DEFAULTS_FILE%"=="0" if not "%SSL_CA%"=="" (
  REM This is --help for `mysql.exe`, don't confuse with --help for mysqldump.exe above. In theory the dump and client apps may have different versions, so detect both for safety.
  set "MYSQL_HELP_FILE=%TEMP%\mysql_help_%RANDOM%.tmp"
  "%SQLCLI_EXE%" --help >"%MYSQL_HELP_FILE%" 2>&1
  if not errorlevel 1 (
    findstr /C:"--ssl-verify-server-cert" "%MYSQL_HELP_FILE%" >nul 2>&1
    if not errorlevel 1 set "CONN_VERIFY_CERT_OPTS=--ssl-verify-server-cert"
  )
  del "%MYSQL_HELP_FILE%" >nul 2>&1
  set "MYSQL_HELP_FILE="
)

REM Combined connection options for all SQL tools (mysql + mysqldump).
REM Note: packet/buffer sizing options are appended to COMMON_OPTS (mysqldump-only) after capability checks.
REM Connection options for mysql.exe (includes verify-server-cert if supported)
set "MYSQL_CONN_OPTS=%CONN_COMPRESS_OPTS% %CONN_SSL_OPTS% %CONN_VERIFY_CERT_OPTS%"
REM Connection options for mysqldump.exe (NO verify-server-cert; keep it mysql-only)
set "DUMP_CONN_OPTS=%CONN_COMPRESS_OPTS% %CONN_SSL_OPTS%"


REM --routines/--events/--triggers: include stored routines, events, and triggers.
REM --single-transaction: take a consistent snapshot without locking tables (InnoDB only).
REM --quick: stream rows row-by-row to reduce memory usage on large tables. (--single-transaction w/o row-by-row streaming can be slow and overload RAM.)

REM Continue the dump even if some statements fail. Check the LOG file afterwards. (Usually '_errors-dump.log' in the dump folder.)
set "COMMON_OPTS=%COMMON_OPTS% --force"

REM Use UTF-8 for the client/server connection.
REM NOTE that MySQL does NOT emit explicit COLLATE clauses in `CREATE TABLE` for columns/tables that use
REM the database default collation. Such dumps implicitly depend on the original server defaults. If you
REM import them on a server with different defaults, uniqueness and comparison rules may change. The
REM post-processing step (POST_PROCESS_DUMP=1) restores the original charset and collation
REM into each `CREATE TABLE` to prevent this.
set "COMMON_OPTS=%COMMON_OPTS% --default-character-set=utf8mb4"

REM Include standard non-default CREATE TABLE options (e.g., ROW_FORMAT) for portability.
set "COMMON_OPTS=%COMMON_OPTS% --create-options"

REM Store BLOBs as hex strings. Makes dumps larger but safer/readable in text editors.
REM Comment the next line out if you prefer smaller files.
set "COMMON_OPTS=%COMMON_OPTS% --hex-blob"

REM Make dumps more portable between servers (managed MySQL, MariaDB, different versions).
REM Avoid embedding tablespace directives in CREATE TABLE.
set "COMMON_OPTS=%COMMON_OPTS% --no-tablespaces"

REM NOTE: Connection options are kept separate:
REM   * MYSQL_CONN_OPTS is used only for mysql.exe calls
REM   * DUMP_CONN_OPTS is used only for mysqldump.exe calls


REM Do NOT inject SET @@GLOBAL.GTID_PURGED into the dump (safer for imports into existing replicas).
REM Only enable this option if mysqldump actually supports it (older MySQL/MariaDB may not).
findstr /C:"--set-gtid-purged" "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
if not errorlevel 1 (
    set "COMMON_OPTS=%COMMON_OPTS% --set-gtid-purged=OFF"
)

REM If dumping from MySQL 8.x to older MySQL/MariaDB where COLUMN_STATISTICS is absent, OR...
REM If you're dumping MariaDB server using mysqldump executable from MySQL, suppress the column stats.
REM (Because MariaDB doesn't have the column statistics and this option is enabled by default in MySQL 8+.)
findstr /C:"--column-statistics" "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
if not errorlevel 1 (
    set "COMMON_OPTS=%COMMON_OPTS% --column-statistics=0"
)

REM ===== Optional, uncomment as needed =====

REM Preserve server local time zone behavior (usually NOT recommended). By default, mysqldump sets UTC.
REM Only use if your target server lacks time zone tables or you have a strong reason to avoid UTC.
REM Example (also guarded by option detection):
REM   findstr /C:"--skip-tz-utc" "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
REM   if not errorlevel 1 (
REM       set "COMMON_OPTS=%COMMON_OPTS% --skip-tz-utc"
REM   )

REM For repeatable imports and better compression, order rows by PRIMARY KEY (if present):
REM set "COMMON_OPTS=%COMMON_OPTS% --order-by-primary"

REM In pure InnoDB environments, you can skip metadata locks on non-transactional tables:
REM set "COMMON_OPTS=%COMMON_OPTS% --skip-lock-tables"

REM Drop and recreate the database before importing a full dump (NOT for partial/table-only imports):
REM set "COMMON_OPTS=%COMMON_OPTS% --add-drop-database"

REM Use one INSERT per row (easier diff/merge; slower/larger). Default is multi-row extended inserts.
REM set "COMMON_OPTS=%COMMON_OPTS% --skip-extended-insert"

REM ================== END OF SETTINGS ==============


REM Cleanup temporary mysqldump --help file (no longer needed after building COMMON_OPTS)
if defined MYSQLDUMP_HELP_FILE (
  if exist "%MYSQLDUMP_HELP_FILE%" del "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
  set "MYSQLDUMP_HELP_FILE="
)

REM Filename used if we dump ALL databases
set "OUTFILE=%OUTDIR%\_db.sql"
set "ALLDATA=%OUTDIR%\_db_data.sql"
set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
REM Log file (errors from mysqldump, mysql, python, etc.)
set "LOG=%OUTDIR%\__errors-dump.log"
REM Temporary files
set "TABLE_SCHEMAS=%TEMP%\__tables-schemas.tsv"
set "DBLIST=%TEMP%\__db-list.txt"
set "DBNAMES="
set "DBNAMES_IN="

REM Flag: script was started without any CLI arguments
set "NO_ARGS=0"
REM Flag: password was requested interactively from user
set "PASS_WAS_PROMPTED=0"
if "%~1"=="" set "NO_ARGS=1"

set "DEFAULTS_OPT="
if "%USE_DEFAULTS_FILE%"=="1" (
  REM IMPORTANT: Do NOT embed extra quotes into the option value.
  REM We keep the raw path in the option and quote the whole argument at call site. So, no ""%LOCAL_DEFAULTS_FILE%"" here.
  set "DEFAULTS_OPT=--defaults-extra-file=%LOCAL_DEFAULTS_FILE%"
)



REM Show general connection info first
if defined DEFAULTS_OPT (
  echo Preparing database dump using "%LOCAL_DEFAULTS_FILE%"
) else (
  echo Preparing database dump from %DB_HOST%:%DB_PORT% on behalf of '%DB_USER%'...
)

REM === PARSE CLI ARGUMENTS BEFORE ANY USER INPUT ===
:parse_args
if "%~1"=="" goto :after_args

    set "ARG=%~1"

    REM --ONE [optional-filename]
    if /I "%ARG%"=="--ONE" (
        set "ONE_MODE=1"

        REM Check if next argument looks like a filename (not empty and not another option)
        if not "%~2"=="" (
            set "NEXT=%~2"
            if /I not "!NEXT:~0,1!"=="-" if /I not "!NEXT:~0,1!"=="/" (
                REM Decide how to build OUTFILE from NEXT
                if "!NEXT:~1,1!"==":" (
                    REM Absolute path like D:\path\file.sql
                    set "OUTFILE=!NEXT!"
                ) else if "!NEXT:~0,1!"=="\" (
                    REM Rooted path like \path\file.sql
                    set "OUTFILE=!NEXT!"
                ) else if "!NEXT:~0,1!"=="/" (
                    REM Rooted path like /path/file.sql
                    set "OUTFILE=!NEXT!"
                ) else (
                    REM Otherwise treat as a filename inside OUTDIR
                    set "OUTFILE=%OUTDIR%\!NEXT!"
                )
                REM We consumed this extra argument as a filename
                shift
            )
        )

        REM Consume the --ONE itself
        shift
        goto :parse_args
    )

    REM Disable users & grants export
    if /I "%ARG%"=="--NO-USERS" (
        set "EXPORT_USERS_AND_GRANTS=0"
        shift
        goto :parse_args
    )

    if /I "%ARG%"=="--NO-USER" (
        set "EXPORT_USERS_AND_GRANTS=0"
        shift
        goto :parse_args
    )

    REM Everything else is treated as a database name
    if defined DBNAMES (
        set "DBNAMES=%DBNAMES% %~1"
    ) else (
        set "DBNAMES=%~1"
    )

    shift
    goto :parse_args

:after_args


REM === SHOW PLANNED ACTION BEFORE ASKING FOR PASSWORD ===
for %%I in ("%OUTFILE%") do set "OUTFILE_FULL_PATH=%%~fI"
for %%I in ("%OUTDIR%") do set "OUTDIR_FULL_PATH=%%~fI"
if "%DBNAMES%"=="" (
  REM No databases provided in CLI -> will dump ALL non-system databases
  if "%ONE_MODE%"=="1" (
    echo Planned action:
    if defined DEFAULTS_OPT (
      echo   Dump ALL non-system databases ^(connection: from ini file^) into ONE file:
    ) else (
      echo   Dump ALL non-system databases from %DB_HOST%:%DB_PORT% into ONE file:
    )
    echo     "%OUTFILE_FULL_PATH%"
  ) else (
    echo Planned action:
    if defined DEFAULTS_OPT (
      echo   Dump ALL non-system databases ^(connection: from ini file^) into separate files to the following directory:
    ) else (
      echo   Dump ALL non-system databases from %DB_HOST%:%DB_PORT% into separate files to the following directory:
    )
    echo     "%OUTDIR_FULL_PATH%"
  )
) else (
  REM Databases explicitly provided by the user
  if "%ONE_MODE%"=="1" (
    echo Planned action:
    if defined DEFAULTS_OPT (
      echo   Dump databases %DBNAMES% ^(connection: from ini file^) into ONE file:
    ) else (
      echo   Dump databases %DBNAMES% from %DB_HOST%:%DB_PORT% into ONE file:
    )
    echo     "%OUTFILE_FULL_PATH%"
  ) else (
    echo Planned action:
    if defined DEFAULTS_OPT (
      echo   Dump databases %DBNAMES% ^(connection: from ini file^) into separate file^(s^) to the following directory:
    ) else (
      echo   Dump databases %DBNAMES% from %DB_HOST%:%DB_PORT% into separate file^(s^) to the following directory:
    )
    echo     "%OUTDIR_FULL_PATH%"
  )
)
echo.

if not defined DEFAULTS_OPT  (
  REM === ONLY NOW ASK FOR PASSWORD (IF NOT SET IN SCRIPT) ===
  REM If we use --defaults-extra-file, password MUST come from the ini; no prompt.
  if "%DB_PASS%"=="" (
    echo Enter password for %DB_USER%@%DB_HOST% ^(INPUT WILL BE VISIBLE^) or press Ctrl+C to terminate.
    set /p "DB_PASS=> "
    set "PASS_WAS_PROMPTED=1"
    echo.
  )

  REM === Pause only when user did NOT enter a password AND no params were given ===
  REM If we use a local ini, skip the pause.
  if "%NO_ARGS%"=="1" if "%PASS_WAS_PROMPTED%"=="0" (
    echo.
    pause
    echo.
  )
)

REM Create output directory

REM === BUILD AUTH/CONNECTION ARGUMENTS ===
REM NOTE: --defaults-extra-file MUST go first.
set "MYSQL_AUTH_OPTS="
set "DUMP_AUTH_OPTS="
if defined DEFAULTS_OPT (
  REM When using option file, do not pass hardcoded connection/SSL params on CLI (so ini can override).
  REM Quote the whole argument so paths with spaces work (e.g. C:\Program Files\...).
  set "MYSQL_AUTH_OPTS=\"%DEFAULTS_OPT%\""
  set "DUMP_AUTH_OPTS=\"%DEFAULTS_OPT%\""
  REM Also disable script-side SSL CLI options (they would override ini).
  set "MYSQL_CONN_OPTS="
  set "DUMP_CONN_OPTS="
) else (
  set "MYSQL_AUTH_OPTS=-h ""%DB_HOST%"" -P %DB_PORT% -u ""%DB_USER%"" -p%DB_PASS% %MYSQL_CONN_OPTS%"
  set "DUMP_AUTH_OPTS=-h ""%DB_HOST%"" -P %DB_PORT% -u ""%DB_USER%"" -p%DB_PASS% %DUMP_CONN_OPTS%"
)
if not exist "%OUTDIR%" mkdir "%OUTDIR%"


REM Optionally export users and grants via the separate script.
REM Important to prepare it in the beginning, to include to the _all_databases_ export.
if "%EXPORT_USERS_AND_GRANTS%"=="1" (
  REM === Exporting users and grants using dump-users-and-grants.bat ===
  REM Pass SSL options to the child script. SSL_CA has priority over SKIP_SSL.
  REM To prevent accidental "--skip-ssl"+"--ssl-ca" combos, we pass an effective SKIP_SSL=0 when SSL_CA is set.
  set "CHILD_SKIP_SSL=%SKIP_SSL%"
  if not "%SSL_CA%"=="" set "CHILD_SKIP_SSL=0"
  REM Don't skip any parameter. All positions are important. Password will not be used if %LOCAL_DEFAULTS_FILE% provided.
  if "%DB_PASS%"=="" set "DB_PASS=*"
  @call "%~dp0dump-users-and-grants.bat" "%SQLBIN%" "%DB_HOST%" "%DB_PORT%" "%DB_USER%" "%DB_PASS%" "%OUTDIR%" "%USERDUMP%" "%CHILD_SKIP_SSL%" "%SSL_CA%" "%LOCAL_DEFAULTS_FILE%"
  if not exist "%USERDUMP%" (
    REM echo WARNING: "%USERDUMP%" not found, will create dump with data only, without users/grants.
    goto :end
  )
)

REM If DB names are passed as arguments, use them directly.
REM Otherwise, query server for list of non-system DBs.
echo Getting database names from server
if "%DBNAMES%" NEQ "" goto :mode_selection

echo === Getting database list from %DB_HOST%:%DB_PORT% ...
"%SQLCLI_EXE%" %MYSQL_AUTH_OPTS% -N -B -e "SHOW DATABASES" > "%DBLIST%"
REM     this way could exclude system tables immediately, but this doesn't exports *empty* databases (w/o tables yet), which still could be important. So let's keep canonical SHOW DATABASES, then filter it.
REM AK: Alternatively we could use `SELECT DISTINCT TABLE_SCHEMA FROM information_schema.tables WHERE TABLE_SCHEMA NOT IN ("information_schema", "performance_schema", "mysql", "sys");`,
if errorlevel 1 (
  echo ERROR: Could not retrieve database list.
  goto :end
)

REM If DBNAMES is empty, we will dump ALL non-system databases.
REM If DBNAMES is NOT empty, we will validate each requested database against this list.

if "%DBNAMES%"=="" (

  REM Build a list of non-system database names into DBNAMES
  set "DBNAMES="
  for /f "usebackq delims=" %%D in ("%DBLIST%") do (
    set "DB=%%D"
    if /I not "!DB!"=="information_schema" if /I not "!DB!"=="performance_schema" if /I not "!DB!"=="sys" if /I not "!DB!"=="mysql" (
      set "DBNAMES=!DBNAMES!!DB! "
    )
  )

  del "%DBLIST%" 2>nul

  if "!DBNAMES!"=="" (
    echo No non-system databases found.
    goto :after_dumps
  )

  set "ALL_DB_MODE=1"

) else (

  REM User provided one or more database names on the CLI: validate them.
  set "VALID_DBNAMES="

  for %%D in (!DBNAMES!) do (
    REM Check if this database exists in the SHOW DATABASES output
    set "FOUND_DB="

    for /f "usebackq delims=" %%X in ("%DBLIST%") do (
      if /I "%%D"=="%%X" (
        set "FOUND_DB=1"
      )
    )

    if not defined FOUND_DB (
      echo.
      echo [WARN] Database '%%D' does not exist on %DB_HOST%:%DB_PORT%.
      choice /C YN /N /M "Continue without this database? [Y/N]: "
      if errorlevel 2 (
        echo.
        echo Aborting on user request.
        del "%DBLIST%" 2>nul
        goto :after_dumps
      ) else (
        echo Skipping database '%%D'.
      )
    ) else (
      if defined VALID_DBNAMES (
        set "VALID_DBNAMES=!VALID_DBNAMES! %%D"
      ) else (
        set "VALID_DBNAMES=%%D"
      )
    )
  )

  del "%DBLIST%" 2>nul

  if not defined VALID_DBNAMES (
    echo No valid databases remain after validation. Nothing to dump.
    goto :after_dumps
  )

  set "DBNAMES=!VALID_DBNAMES!"
)

:mode_selection
if "%ALL_DB_MODE%"=="1" (
  echo Dumping ALL databases from %DB_HOST%:%DB_PORT%: !DBNAMES!
) else (
  echo Dumping !DBNAMES! from %DB_HOST%:%DB_PORT%
)
echo.

REM Build comma-separated, quoted database list for SQL IN (...)
set "DBNAMES_IN="

for %%D in (!DBNAMES!) do (
  if defined DBNAMES_IN (
    set "DBNAMES_IN=!DBNAMES_IN!, '%%D'"
  ) else (
    set "DBNAMES_IN='%%D'"
  )
)

REM === Dump default table schemas, to be able to restore everything exactly as on original server ===
echo Dumping table metadata to '%TABLE_SCHEMAS%'...
"%SQLCLI_EXE%" %MYSQL_AUTH_OPTS% -N -B -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA IN (!DBNAMES_IN!) ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "%TABLE_SCHEMAS%"
if errorlevel 1 (
  echo ERROR: Could not dump table metadata.
  goto :end
)

echo Table metadata saved to '%TABLE_SCHEMAS%'.
echo.

REM Mode selection: separate OR single SQL dump?
if "%ONE_MODE%"=="1" goto :all_in_one

REM ================== MODE 1: ALL DATABASES SEPARATELY (DEFAULT) ==================
echo Dumping each database into its own file...

for %%D in (!DBNAMES!) do (
  call :dump_single_db "%%D"
)

goto :after_dumps


REM ================== MODE 2: ALL DATABASES INTO ONE FILE ==================
:all_in_one
REM Here we create ONE combined dump using a single mysqldump call.

if "%ALL_DB_MODE%"=="1" (
  echo Dumping ALL non-system databases into a single file...
) else (
  echo Dumping selected databases into a single file...
)

REM Raw combined dump (before post-processing)
REM Example: _db_data.sql
set "ALLDATA=%OUTDIR%\_db_data.sql"

REM Prepare the name for the cleaned dump if post-processing is enabled
if "%POST_PROCESS_DUMP%"=="1" (
  REM %%~dpnF = drive + path + name (no extension), %%~xF = extension
  for %%F in ("%ALLDATA%") do (
    set "ALLDATA_CLEAN=%%~dpnF%POST_PROCESS_APPENDIX%%%~xF"
  )
)

echo Raw output file will be: "%ALLDATA%"

REM Single mysqldump call for all databases
REM (stderr goes to log, output goes directly to ALLDATA)
"%SQLDUMP_EXE%" %DUMP_AUTH_OPTS% %COMMON_OPTS% --databases !DBNAMES! --result-file="%ALLDATA%" 2>> "%LOG%"

if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping multiple databases >> "%LOG%"
  echo [ERROR] Failed to dump multiple databases. See log: "%LOG%"
  echo.
  goto :after_dumps
) else (
  echo Combined raw dump created.
)

REM Decide what will be the final file (with or without post-processing)
set "FINAL_DUMP=%ALLDATA%"

if "%POST_PROCESS_DUMP%"=="1" (
  set "PREPEND_DUMP="

  REM If we have users+grants dump, tell post-processor to prepend it
  if "%EXPORT_USERS_AND_GRANTS%"=="1" (
    if exist "%USERDUMP%" (
      echo Post-processing and prepending users dump ^(_users_and_grants.sql^)...
      set "PREPEND_DUMP= --prepend-file ""%USERDUMP%"""
    )
  )

  echo Post-processing combined dump...
  REM IMPORTANT: here we do NOT pass --db-name, because this is a multi-database dump
  %POST_PROCESSOR%!PREPEND_DUMP! "%ALLDATA%" "%ALLDATA_CLEAN%" "%TABLE_SCHEMAS%"

  if errorlevel 1 (
    echo [WARN] Post-processing failed for "%ALLDATA%". Keeping raw dump.
    if exist "%ALLDATA_CLEAN%" del "%ALLDATA_CLEAN%" 2>nul
  ) else (
    set "FINAL_DUMP=%ALLDATA_CLEAN%"
  )
)

REM Move final dump (raw or cleaned) to OUTFILE (this is what we show in "Planned action")
if exist "%OUTFILE%" del "%OUTFILE%"
move /Y "%FINAL_DUMP%" "%OUTFILE%" >nul

REM We no longer need the raw combined dump file
if exist "%ALLDATA%" del "%ALLDATA%" >nul 2>&1

for %%I in ("%OUTFILE%") do set "FINAL_FULL=%%~fI"
echo Single dump file is: "!FINAL_FULL!"
echo.

goto :after_dumps


REM ================== FUNCTION/SUB-ROUTINE: DUMP SINGLE DATABASE ==================
REM This function used only ONCE (where we dump databases into separate files),
REM but it's nice and clean. So let's keep it separately, not embed anywhere.
:dump_single_db
setlocal

set "DBNAME=%~1"
set "TARGET=%~2"

if "%TARGET%"=="" (
  set "TARGET=%OUTDIR%\%DBNAME%.sql"
)

echo --- Dumping database '%DBNAME%' to '%TARGET%'...
REM Alternatively we could specify --result-file="%TARGET%", but we want error log anyway.
"%SQLDUMP_EXE%" %DUMP_AUTH_OPTS% %COMMON_OPTS% "%DBNAME%" 1>> "%TARGET%" 2>> "%LOG%"
if errorlevel 1 (
  REM These messages are good to search, so append the following line %LOG% to log...
  echo [%DATE% %TIME%] ERROR dumping database '%DBNAME%' >> "%LOG%"
  echo [ERROR] Failed to dump database '%DBNAME%'. See log: "%LOG%"
  endlocal
  goto :EOF
)

REM Post-process the dump if requested
if "%POST_PROCESS_DUMP%"=="1" (
  REM Build CLEAN_TARGET as: <path><name><appendix><ext>. E.g. my-dump.sql + .clean => my-dump.clean.sql
  for %%I in ("%TARGET%") do set "CLEAN_TARGET=%%~dpnI%POST_PROCESS_APPENDIX%%%~xI"

  echo Post-processing dump '%TARGET%' into '!CLEAN_TARGET!'...
  %POST_PROCESSOR% --db-name "%DBNAME%" "%TARGET%" "!CLEAN_TARGET!" "%TABLE_SCHEMAS%"
  if errorlevel 1 (
    echo [WARN] Post-processing failed for '%TARGET%'. Keeping original dump.
    if defined CLEAN_TARGET del "!CLEAN_TARGET!" 2>nul
  ) else (
    if defined CLEAN_TARGET (
        move /Y "!CLEAN_TARGET!" "%TARGET%" >nul

        for %%I in ("%TARGET%") do set "TARGET_FULL_PATH=%%~fI"
        echo Post-processing completed for '!TARGET_FULL_PATH!'.
    )
  )
)

endlocal
goto :EOF


REM ================== AFTER DUMPS ==================
:after_dumps
del "%TABLE_SCHEMAS%" 2>nul

REM ==== Summary about log file (check, whether %LOG% is empty or not) ====
set "LOGSIZE=0"
if exist "%LOG%" (
  for %%A in ("%LOG%") do set "LOGSIZE=%%~zA"
)

if %LOGSIZE% GTR 0 (
  echo Some errors or warnings were recorded in: %LOG%
) else (
  echo No errors recorded.
  del "%LOG%" >nul 2>&1
)

:end
endlocal

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
REM      - Supports optional flags to control dump modes
REM        (e.g. single-file vs per-database).
REM      - Uses configurable client and dump executables
REM        (mysql.exe / mysqldump.exe or mariadb.exe / mariadb-dump.exe).
REM      - Integrates with dump-users-and-grants.bat to include
REM        users and privileges in the migration.
REM
REM  Usage (examples):
REM      db-dump.bat
REM        - Dump all non-system databases to separate files.
REM
REM      db-dump.bat --ONE
REM        - Dump all non-system databases into a single SQL file.
REM
REM      db-dump.bat [options] db1 db2 ... [--one]
REM        - Dump only selected databases. Other behavior depends on internal flags and CLI options.
REM
REM =================================================================================================

REM ================== CONFIG ==================
REM Path to bin folder containing mysql/mysqldump or mariadb/mariadb-dump. (Optionally. Something like "SQLBIN=C:\Program Files\MariaDB 10.5\bin".)
REM ATTN! If you have MULTIPLE INSTALLATIONS of MySQL/MariaDB on your computer, please specify the exact path to the working version you are dumping from!
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

REM Get all databases into single SQL-dump: 1 = yes, 0 = no. This option can be overridden (turned on) by `--ONE` parameter
set "ONE_MODE=0"

REM If you want to automatically export users/grants, set this to 1 and ensure the second .bat exists. Included in the beginning of FULL dump.
set "EXPORT_USERS_AND_GRANTS=1"

REM Dump post-processor tool (to remove MySQL compatibility comments + add missing options to the `CREATE TABLE` statements).
REM     * The MySQL Dump put compatibility comments for earlier versions. E.g `CREATE TRIGGER` is not supported by ancient MySQL versions.
REM       And the MySQL Dump wraps those instructons in to magic comments, like /*!50003 CREATE*/ /*!50017 DEFINER=`user`@`host`*/ /*!50003 TRIGGER ... END */,
REM       making issues with regular multiline comments /* ... */ within the triggers.
REM       We can remove those compatibility comments targeted for some legacy versions (e.g. all MySQL versions lower than 8.0), to keep the important developers comments in the code.
REM     * Solves issues with importing tables to the servers with different default collations, by supplying `CREATE TABLE` statements with missing instructions.
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


REM ==================== READ mysqldump HELP ====================
REM Make sure that mysqldump exists in PATH
"%SQLDUMP%" --version >nul 2>&1
if errorlevel 1 (
    echo [FAIL] mysqldump not found in PATH or not executable.
    goto :end
)

REM Store mysqldump --help output in a temporary file for reuse
set "MYSQLDUMP_HELP_FILE=%TEMP%\mysqldump_help_%RANDOM%.tmp"
"%SQLDUMP%" --help >"%MYSQLDUMP_HELP_FILE%" 2>&1
if errorlevel 1 (
    echo [FAIL] Failed to execute "%SQLDUMP% --help".
    del "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
    goto :end
)

REM Dump options common for all databases
REM NOTE: These options affect every dump produced by this script.
REM       Keep them conservative for maximum compatibility.
set "COMMON_OPTS=--routines --events --triggers --single-transaction --quick"

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

REM ================== END CONFIG ==============

REM Cleanup temporary mysqldump --help file (no longer needed after building COMMON_OPTS)
if defined MYSQLDUMP_HELP_FILE (
  if exist "%MYSQLDUMP_HELP_FILE%" del "%MYSQLDUMP_HELP_FILE%" >nul 2>&1
  set "MYSQLDUMP_HELP_FILE="
)

REM Filename used if we dump ALL databases
set "OUTFILE=%OUTDIR%\_db.sql"
set "ALLDATA=%OUTDIR%\_db_data.sql"
set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
set "LOG=%OUTDIR%\__errors-dump.log"
REM Temporary files
set "TABLE_SCHEMAS=%TEMP%\__tables-meta.tsv"
set "DBLIST=%TEMP%\__db-list.txt"
set "DBNAMES="

REM Use UTF-8 encoding for output, if needed
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

REM Add trailing slash (\) to the end of %SQLBIN%, if it's not empty.
if defined SQLBIN (
  if not "!SQLBIN:~-1!"=="\" (
      set "SQLBIN=!SQLBIN!\"
  )

  REM Check executables. Ensure tools exist.
  if not exist "!SQLBIN!%SQLCLI%" (
    echo ERROR: %SQLCLI% not found at "!SQLBIN!".
    echo Please open the '%~nx0', and edit the configuration, particularly the path in SQLBIN variable.
    goto :end
  )
  if not exist "!SQLBIN!%SQLDUMP%" (
    echo ERROR: %SQLDUMP% not found at "!SQLBIN!".
    echo Please open the '%~nx0', and edit the configuration, particularly the SQLDUMP variable.
    goto :end
  )
)


REM Ask for password only if DB_PASS is empty
echo Preparing database dump from %DB_HOST%:%DB_PORT% on behalf of '%DB_USER%'...
if "%DB_PASS%"=="" (
  echo Enter password for %DB_USER%@%DB_HOST% ^(INPUT WILL BE VISIBLE^) or press Ctrl+C to terminate.
  set /p "DB_PASS=> "
  echo.
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"


REM === PARSE CLI ARGUMENTS ===
:parse_args
if "%~1"=="" goto :after_args
    REM --ONE in any position, case insensitive
    if /I "%~1"=="--ONE" (
      set "ONE_MODE=1"
    ) else (
      REM All others are db names
      if defined DBNAMES (
        set "DBNAMES=%DBNAMES% %~1"
      ) else (
        set "DBNAMES=%~1"
      )
    )

    shift
    goto :parse_args
:after_args


REM Optionally export users and grants via the separate script.
REM Important to prepare it in the beginning, to include to the _all_databases_ export.
if "%EXPORT_USERS_AND_GRANTS%"=="1" (
  REM === Exporting users and grants using dump-users-and-grants.bat ===
  @call "%~dp0dump-users-and-grants.bat" "%SQLBIN%" "%DB_HOST%" "%DB_PORT%" "%DB_USER%" "%DB_PASS%" "%OUTDIR%" "%USERDUMP%"
  if not exist "%USERDUMP%" (
    REM echo WARNING: "%USERDUMP%" not found, will create dump with data only, without users/grants.
    goto :end
  )
)

REM Remove previous log. (To Recycle Bin.)
del "%LOG%" 2>nul

REM If we already have the list of databases to dump, then don't retrieve names from server
if "%DBNAMES%" NEQ "" goto :mode_selection

echo === Getting database list from %DB_HOST%:%DB_PORT% ...
"%SQLBIN%%SQLCLI%" -h "%DB_HOST%" -P %DB_PORT% -u "%DB_USER%" -p%DB_PASS% -N -B -e "SHOW DATABASES" > "%DBLIST%"
REM AK: Alternatively we could use `SELECT DISTINCT TABLE_SCHEMA FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ("information_schema", "performance_schema", "mysql", "sys");`,
REM     this way could exclude system tables immediately, but this doesn't exports *empty* databases (w/o tables yet), which still could be important. So let's keep canonical SHOW DATABASES, then filter it.
if errorlevel 1 (
  echo ERROR: Could not retrieve database list.
  goto :end
)

REM Build a list of non-system database names
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

:mode_selection
echo Databases to dump: !DBNAMES!
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
echo Dumping table metadata to '%TABLE_SCHEMAS%' ...
"%SQLBIN%%SQLCLI%" -h "%DB_HOST%" -P %DB_PORT% -u "%DB_USER%" -p%DB_PASS% -N -B -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA IN (!DBNAMES_IN!) ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "%TABLE_SCHEMAS%"
if errorlevel 1 (
    echo Failed to dump table metadata.
) else (
    echo Done. Metadata saved to '%TABLE_SCHEMAS%'.
)

REM Mode selection: separate OR single SQL dump?
if "%ONE_MODE%"=="1" goto :all_in_one

REM ================== MODE 1: ALL DATABASES SEPARATELY (DEFAULT) ==================
for %%D in (!DBNAMES!) do (
  set "DB=%%D"
  set "OUTFILE=%OUTDIR%\!DB!.sql"
  echo.
  echo --- Dumping database: !DB!  ^> "!OUTFILE!"
  "%SQLBIN%%SQLDUMP%" -h "%DB_HOST%" -P %DB_PORT% -u "%DB_USER%" -p%DB_PASS% --databases "!DB!" %COMMON_OPTS% --result-file="!OUTFILE!"
  if errorlevel 1 (
    echo [%DATE% %TIME%] ERROR dumping !DB! >> "%LOG%"
    echo     ^- See "%LOG%" for details.
  ) else (
    echo     OK

    if "%POST_PROCESS_DUMP%"=="1" (
      %POST_PROCESSOR% "%OUTDIR%\!DB!.sql" "%OUTDIR%\!DB!%POST_PROCESS_APPENDIX%.sql"
    )
  )
)

echo.
echo === Database dumps are in: %OUTDIR%
echo.

goto :after_dumps


REM ================== MODE 2: ALL DATABASES INTO ONE FILE ==================
:all_in_one
echo === Dumping ALL NON-SYSTEM databases into ONE file (excluding mysql, information_schema, performance_schema, sys) ===

if "%POST_PROCESS_DUMP%"=="1" (
  REM parse the path in ALLDATA, to get the path\filename w/o extension
  for %%F in ("%ALLDATA%") do (
    rem %%~dpnF = drive + path + name (no extension)
    set "ALLDATA_CLEAN=%%~dpnF%POST_PROCESS_APPENDIX%%%~xF"
  )
)

echo Output: "%ALLDATA%"
rem "%SQLBIN%%SQLDUMP%" -h "%DB_HOST%" -P %DB_PORT% -u "%DB_USER%" -p%DB_PASS% --databases !DBNAMES! %COMMON_OPTS% --result-file="%ALLDATA%"

if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping ALL NON-SYSTEM DATABASES >> "%LOG%"
  echo     ^- See "%LOG%" for details.
) else (
  echo     OK

  if "%POST_PROCESS_DUMP%"=="1" (
    set "PREPEND_DUMP="

    if "%EXPORT_USERS_AND_GRANTS%"=="1" (
      if exist "%USERDUMP%" (
        echo Post-processing and prepending users dump ^(_users_and_grants.sql^)...
        set "PREPEND_DUMP= --prepend-file ""%USERDUMP%"""
      ) else (
        echo WARNING: users dump "%USERDUMP%" not found, running without prepend...
      )
    ) else (
      echo Post-processing dump...
    )

    rem Run post-processor (MySQL dump cleaner)
    %POST_PROCESSOR%!PREPEND_DUMP! "%ALLDATA%" "%ALLDATA_CLEAN%" "%TABLE_SCHEMAS%"

    rem Final combined dump is the processed file
    move /Y "%ALLDATA_CLEAN%" "%OUTFILE%"
  ) else (
    rem No post-processing: final dump is the raw data file
    move /Y "%ALLDATA%" "%OUTFILE%"
  )
)

echo.
echo === Database dump is in: %OUTFILE%
echo.

goto :after_dumps


REM ================== AFTER DUMPS ==================
:after_dumps
del "%TABLE_SCHEMAS%" 2>nul

if exist "%LOG%" (
  echo Some errors were recorded in: %LOG%
) else (
  echo No errors recorded.
)

:end
endlocal

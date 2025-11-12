@echo off
REM ======================================================================
REM  db-migration.bat
REM
REM  Copyright (c) 2025 utilmind
REM  All rights reserved.
REM  https://github.com/utilmind/MySQL-Migration-from-Windows-PC/
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
REM      db-migration.bat
REM        - Dump all non-system databases to separate files.
REM
REM      db-migration.bat --ONE
REM        - Dump all non-system databases into a single SQL file.
REM
REM      db-migration.bat [options] db1 db2 ... [--one]
REM        - Dump only selected databases. Other behavior depends on internal flags and CLI options.
REM
REM =================================================================================================

REM ================== CONFIG ==================
REM Path to bin folder containing mysql/mysqldump or mariadb/mariadb-dump
set "SQLBIN=C:\Program Files\MariaDB 10.5\bin"
REM set "SQLCLI=mariadb.exe"
set "SQLCLI=mysql.exe"
REM set "SQLDUMP=mariadb-dump.exe"
set "SQLDUMP=mysqldump.exe"

REM Output folder for dumps (will be created if missing)
set "OUTDIR=D:\_db-dumps"

REM Connection params (leave HOST/PORT default if local)
set "HOST=localhost"
set "PORT=3306"
set "USER=root"
REM Password: put real password here, or leave EMPTY to be prompted. Do not expose your password in public!!
set "PASS="

REM Get all databases into single SQL-dump: 1 = yes, 0 = no. This option can be overridden (turned on) by `--ONE` parameter
set "ONE_MODE=0"

REM If you want to automatically export users/grants, set this to 1 and ensure the second .bat exists. Included in the beginning of FULL dump.
set "EXPORT_USERS_AND_GRANTS=1"

REM Extended INSERTs:
REM   0 = OFF  -> add --skip-extended-insert (INSERT one record)
REM   1 = ON   -> use default dump behavior (multiple INSERT's in single block)
set "USE_EXTENDED_INSERT=1"

REM Dump options common for all databases
REM --force = continue dump even in case of errors. Dump will be prepared even if some databases/tables are crashed. (W/o crashed tables)
set "COMMON_OPTS=--single-transaction --routines --events --triggers --hex-blob --default-character-set=utf8mb4 --create-options --add-drop-database --force"
if "%USE_EXTENDED_INSERT%"=="0" (
  REM --skip-extended-insert: one-row-per-INSERT (easier to debug, avoids huge packets)
  set "COMMON_OPTS=%COMMON_OPTS% --skip-extended-insert"
)

REM Remove compatibility comments + add missing options to the `CREATE TABLE` statements.
REM     * The MySQL Dump put compatibility comments for earlier versions. E.g `CREATE TRIGGER` is not supported by ancient MySQL versions.
REM       And the MySQL Dump wraps those instructons in to magic comments, like /*!50003 CREATE*/ /*!50017 DEFINER=`user`@`host`*/ /*!50003 TRIGGER ... END */,
REM       making issues with regular multiline comments /* ... */ within the triggers.
REM       We can remove those compatibility comments targeted for some legacy versions (e.g. all MySQL versions lower than 8.0), to keep the important developers comments in the code.
REM     * This tool also solves issues with importing tables to the servers with different default collations, by supplying `CREATE TABLE` statements with missing instructions.
REM   0 = OFF  -> keep all dumps 'as-is', as they originally exported.
REM   1 = ON   -> produce processed dumps clean of the compatibility comments and with complete CREATE TABLE instructions.
REM               * Python should be installed if this feature is used!
set "REMOVE_COMPATIBILITY_COMMENTS=1"
REM The file name appendix for dumps clean of the compatibility comments. E.g. mydata.sql -> mydata.clean.sql
set "COMPATIBILITY_COMMENTS_APPENDIX=.clean"
set "COMPATIBILITY_COMMENTS_REMOVER=python strip-mysql-compatibility-comments.py"
REM ================== END CONFIG ==============

REM Filename used if we dump ALL databases
set "OUTFILE=%OUTDIR%\_db.sql"
set "ALLDATA=%OUTDIR%\_db_data.sql"
set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
set "TABLE_SCHEMAS=%OUTDIR%\_tables-meta.tsv"
set "LOG=%OUTDIR%\_errors-dump.log"
REM Temporary file for the list of databases
set "DBLIST=%OUTDIR%\^db-list.txt"
set "DBNAMES="

REM Use UTF-8 encoding for output, if needed
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

REM Check executables. Ensure tools exist.
if not exist "%SQLBIN%\%SQLCLI%" (
  echo ERROR: %SQLCLI% not found at "%SQLBIN%".
  echo Please open the '%~nx0', and edit the configuration, particularly the path in SQLBIN variable.
  goto :end
)
if not exist "%SQLBIN%\%SQLDUMP%" (
  echo ERROR: %SQLDUMP% not found at "%SQLBIN%".
  echo Please open the '%~nx0', and edit the configuration, particularly the SQLDUMP variable.
  goto :end
)

REM Ask for password only if PASS is empty
if "%PASS%"=="" (
  echo Enter password for %USER%@%HOST% ^(INPUT WILL BE VISIBLE^)
  set /p "PASS=> "
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
  @call "%~dp0dump-users-and-grants.bat" "%SQLBIN%" "%HOST%" "%PORT%" "%USER%" "%PASS%" "%OUTDIR%" "%USERDUMP%"
  if not exist "%USERDUMP%" (
    REM echo WARNING: "%USERDUMP%" not found, will create dump with data only, without users/grants.
    goto :end
  )
)

REM Remove previous log. (To Recycle Bin.)
del "%LOG%" 2>nul

REM If we already have the list of databases to dump, then don't retrieve names from server
if "%DBNAMES%" NEQ "" goto :mode_selection

echo === Getting database list from %HOST%:%PORT% ...
"%SQLBIN%\%SQLCLI%" -h "%HOST%" -P %PORT% -u "%USER%" -p%PASS% -N -B -e "SHOW DATABASES" > "%DBLIST%"
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
"%SQLBIN%\%SQLCLI%" -h "%HOST%" -P %PORT% -u "%USER%" -p%PASS% -N -B -e "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA IN (!DBNAMES_IN!) ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "%TABLE_SCHEMAS%"
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
  "%SQLBIN%\%SQLDUMP%" -h "%HOST%" -P %PORT% -u "%USER%" -p%PASS% --databases "!DB!" %COMMON_OPTS% --result-file="!OUTFILE!"
  if errorlevel 1 (
    echo [%DATE% %TIME%] ERROR dumping !DB! >> "%LOG%"
    echo     ^- See "%LOG%" for details.
  ) else (
    echo     OK

    if "%REMOVE_COMPATIBILITY_COMMENTS%"=="1" (
      %COMPATIBILITY_COMMENTS_REMOVER% "%OUTDIR%\!DB!.sql" "%OUTDIR%\!DB!%COMPATIBILITY_COMMENTS_APPENDIX%.sql"
    )
  )
)

goto :after_dumps


REM ================== MODE 2: ALL DATABASES INTO ONE FILE ==================
:all_in_one
echo === Dumping ALL NON-SYSTEM databases into ONE file (excluding mysql, information_schema, performance_schema, sys) ===

if "%REMOVE_COMPATIBILITY_COMMENTS%"=="1" (
  REM parse the path in ALLDATA, to get the path\filename w/o extension
  for %%F in ("%ALLDATA%") do (
    rem %%~dpnF = drive + path + name (no extension)
    set "ALLDATA_CLEAN=%%~dpnF%COMPATIBILITY_COMMENTS_APPENDIX%%%~xF"
  )
) else (
  set "=%ALLDATA%"
)

echo Output: "%ALLDATA%"
"%SQLBIN%\%SQLDUMP%" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases !DBNAMES! %COMMON_OPTS% --result-file="%ALLDATA%"

if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping ALL NON-SYSTEM DATABASES >> "%LOG%"
  echo     ^- See "%LOG%" for details.
) else (
  echo     OK

  if "%REMOVE_COMPATIBILITY_COMMENTS%"=="1" (
    %COMPATIBILITY_COMMENTS_REMOVER% "%ALLDATA%" "%ALLDATA_CLEAN%" "%TABLE_SCHEMAS%"
  )

  REM Combine _users_and_grants.sql + _db_data.sql (or _db_data_CLEAN.sql) into final _db.sql
  REM (This is long process if the full dump is large. So if you don't want it, just disable %EXPORT_USERS_AND_GRANTS%, set EXPORT_USERS_AND_GRANTS=0.)
  if "%EXPORT_USERS_AND_GRANTS%"=="1" (
    if exist "%USERDUMP%" (
      echo Combining "%USERDUMP%" and "%ALLDATA_CLEAN%" into "%OUTFILE%"... ^(Put users and grants before the data.^)
      (
        type "%USERDUMP%"
        echo.
        type "%ALLDATA_CLEAN%"
      ) > "%OUTFILE%"
      echo     OK, created "%OUTFILE%"
    )
  )
)

goto :after_dumps


REM ================== AFTER DUMPS ==================
:after_dumps
echo.
echo === Database dumps are in: %OUTDIR%
echo.

if exist "%LOG%" (
  echo Some errors were recorded in: %LOG%
) else (
  echo No errors recorded.
)

:end
endlocal

@echo off
REM ====== `db-migration.bat ALL` = make a full dump of all databases and users/grants ======
REM Usage:
REM   db-migration.bat                   -> dump all databases separately (+ mysql.sql)
REM   db-migration.bat --ONE             -> dump all databases into one file _databases.sql (just add `--one`, case insensitive)
REM                                          * EXCEPT system tables: `mysql`, `information_schema`, `performance_schema`, `sys`.
REM   db-migration.bat db1 db2 db3       -> dump only listed databases separately
REM   db-migration.bat --ONE db1 db2 db3 -> dump only listed databases into single SQL, _databases.sql.

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
set "COMMON_OPTS=--single-transaction --routines --events --triggers --hex-blob --default-character-set=utf8mb4 --add-drop-database --force"
if "%USE_EXTENDED_INSERT%"=="0" (
  REM --skip-extended-insert: one-row-per-INSERT (easier to debug, avoids huge packets)
  set "COMMON_OPTS=%COMMON_OPTS% --skip-extended-insert"
)
REM ================== END CONFIG ==============

REM Filename used if we dump ALL databases
set "OUTFILE=%OUTDIR%\_databases.sql"
set "ALLDATA=%OUTDIR%\_databases_data.sql"
set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
REM Temporary file for the list of databases
set "DBLIST=%OUTDIR%\^db-list.txt"
set "DBNAMES="

chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

REM Check executables. Ensure tools exist.
if not exist "%SQLBIN%\%SQLCLI%" (
  echo ERROR: %SQLCLI% not found at "%SQLBIN%".
  goto :end
)
if not exist "%SQLBIN%\%SQLDUMP%" (
  echo ERROR: %SQLDUMP% not found at "%SQLBIN%".
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
REM Important to prepare it in the beginning, to include to the _all_databases export.
if "%EXPORT_USERS_AND_GRANTS%"=="1" (
  REM === Exporting users and grants using export-users-and-grants.bat ===
  @call "%~dp0export-users-and-grants.bat" "%SQLBIN%" "%HOST%" "%PORT%" "%USER%" "%PASS%" "%OUTDIR%" "%USERDUMP%"
  if not exist "%USERDUMP%" (
    echo WARNING: "%USERDUMP%" not found, will create dump with data only, without users/grants.
  )
) else (
  set "ALLDATA=%OUTFILE%"
)


set "LOG=%OUTDIR%\_dump_errors.log"
del "%LOG%" 2>nul

REM If we already have the list of databases to dump, then don't retrieve names from server
if "%DBNAMES%" NEQ "" goto :mode_selection

echo === Getting database list from %HOST%:%PORT% ...
"%SQLBIN%\%SQLCLI%" -h "%HOST%" -P %PORT% -u "%USER%" -p%PASS% -N -B -e "SHOW DATABASES" > "%DBLIST%"
REM AK: Alternatively we could use `SELECT DISTINCT TABLE_SCHEMA FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ("information_schema", "performance_schema", "mysql", "sys");`,
REM     this way could exclude system tables immediately, but this doesn't exports *empty* databases (w/o tables yet), which still could be important. So let's keep canonical SHOW DATABASES, then filter it.
if errorlevel 1 (
  echo ERROR: Could not retrieve database list.
  goto :after_dumps
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
  )
)

goto :after_dumps


REM ================== MODE 2: ALL DATABASES INTO ONE FILE ==================
:all_in_one
echo === Dumping ALL NON-SYSTEM databases into ONE file (excluding mysql, information_schema, performance_schema, sys) ===
echo Output: "%ALLDATA%"

"%SQLBIN%\%SQLDUMP%" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases !DBNAMES! %COMMON_OPTS% --result-file="%ALLDATA%"

if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping ALL NON-SYSTEM DATABASES >> "%LOG%"
  echo     ^- See "%LOG%" for details.
) else (
  echo     OK
)

REM Combine _users_and_grants.sql + _all_databases_data.sql into _all_databases.sql
if exist "%USERDUMP%" (
  echo Combining "%USERDUMP%" and "%ALLDATA%" into "%OUTFILE%"... (* Users should be imported before the data.)
  (
    type "%USERDUMP%"
    echo.
    type "%ALLDATA%"
  ) > "%OUTFILE%"
  echo     OK, created "%OUTFILE%"
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

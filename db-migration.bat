@echo off
REM ====== `db-migration.bat ALL` = make a full dump of all databases and users/grants ======


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

REM Dump options common for all databases
REM --skip-extended-insert: one-row-per-INSERT (easier to debug, avoids huge packets)
set "COMMON_OPTS=--single-transaction --routines --events --triggers --hex-blob --default-character-set=utf8mb4 --skip-extended-insert --add-drop-database --force"

REM If you want to automatically export users/grants, set this to 1 and ensure the second .bat exists. Included in the beginning of FULL dump.
set "EXPORT_USERS_AND_GRANTS=1"
REM ============================================
REM Filename used if we dump ALL databases
set "OUTFILE=%OUTDIR%\_all_databases.sql"
set "ALLDATA=%OUTDIR%\_all_databases_data.sql"
set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
REM Temporary file for the list of databases
set "DBLIST=%OUTDIR%\^db-list.txt"


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


echo === Getting database list from %HOST%:%PORT% ...
"%SQLBIN%\%SQLCLI%" -h "%HOST%" -P %PORT% -u "%USER%" -p%PASS% -N -B -e "SHOW DATABASES" > "%DBLIST%"
REM AK: Alternatively we could use `SELECT DISTINCT TABLE_SCHEMA FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ("information_schema", "performance_schema", "mysql", "sys");`,
REM     this way could exclude system tables immediately, but this doesn't exports *empty* databases (w/o tables yet), which still could be important. So let's keep canonical SHOW DATABASES, then filter it.
if errorlevel 1 (
  echo ERROR: Could not retrieve database list.
  goto :after_dumps
)

set "LOG=%OUTDIR%\_dump_errors.log"
del "%LOG%" 2>nul

REM ================== MODE SELECTION ==================
REM Usage:
REM   db-migration.bat               -> dump all databases separately (+ mysql.sql)
REM   db-migration.bat ALL           -> dump all databases into one file _all_databases.sql (just add `all`, case insensitive)
REM                                     * EXCEPT system tables: `mysql`, `information_schema`, `performance_schema`, `sys`.
REM   db-migration.bat db1 db2 db3   -> dump only listed databases separately

if /I "%~1"=="ALL" goto :all_in_one
if "%~1"=="" goto :all_separate
goto :selected_only

REM ================== MODE 1: ALL DATABASES INTO ONE FILE ==================
:all_in_one
echo === Dumping ALL NON-SYSTEM databases into ONE file (excluding mysql, information_schema, performance_schema, sys) ===
echo Output: "%ALLDATA%"

REM Build a list of non-system database names
set "DBNAMES="
for /f "usebackq delims=" %%D in ("%DBLIST%") do (
  set "DB=%%D"
  if /I not "!DB!"=="information_schema" if /I not "!DB!"=="performance_schema" if /I not "!DB!"=="sys" if /I not "!DB!"=="mysql" (
    set "DBNAMES=!DBNAMES! !DB!"
  )
)

rem del "%DBLIST%" 2>nul

if "!DBNAMES!"=="" (
  echo No non-system databases found.
  goto :after_dumps
)

echo Databases to dump: !DBNAMES!
"%SQLBIN%\%SQLDUMP%" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases !DBNAMES! %COMMON_OPTS% --result-file="%ALLDATA%"

if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping ALL NON-SYSTEM DATABASES >> "%LOG%"
  echo     ^- See "%LOG%" for details.
) else (
  echo     OK
)

REM Combine _users_and_grants.sql + _all_databases_data.sql into _all_databases.sql
if exist "%USERDUMP%" (
  echo Merging "%USERDUMP%" and "%ALLDATA%" into "%OUTFILE%"...
  (
    type "%USERDUMP%"
    echo.
    type "%ALLDATA%"
  ) > "%OUTFILE%"
  echo     OK, created "%OUTFILE%"
)

goto :after_dumps

REM ================== MODE 3: ALL DATABASES SEPARATELY (DEFAULT) ==================
:all_separate

for /f "usebackq delims=" %%D in ("%DBLIST%") do (
  set "DB=%%D"
  REM Skip system schemas and mysql (mysql is handled via users/grants script)
  if /I not "!DB!"=="information_schema" if /I not "!DB!"=="performance_schema" if /I not "!DB!"=="sys" if /I not "!DB!"=="mysql" (
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
)

goto :after_dumps

REM ================== AFTER DUMPS ==================
:after_dumps
echo.
echo === Database dumps are in: %OUTDIR%

if exist "%LOG%" (
  echo.
  echo Some errors were recorded in: %LOG%
) else (
  echo.
  echo No errors recorded.
)

:end
endlocal

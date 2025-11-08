@echo off
REM ================== CONFIG ==================
REM Path to MariaDB folder (old server)
set "MDBBIN=C:\Program Files\MariaDB 10.5\bin"

REM Output folder for dumps (will be created if missing)
set "OUTDIR=D:\4\db_dumps_temp"

REM Connection params (leave HOST/PORT default if local)
set "HOST=localhost"
set "PORT=3306"
set "USER=root"
REM Password: put real password here, or leave EMPTY to be prompted. Do not expose your password in public!!
set "PASS="

REM Dump options common for all databases
REM --skip-extended-insert: one-row-per-INSERT (easier to debug, avoids huge packets)
set "COMMON_OPTS=--single-transaction --routines --events --triggers --hex-blob --default-character-set=utf8mb4 --skip-extended-insert --add-drop-database --force"
REM ============================================

chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

REM Ensure tools exist
if not exist "%MDBBIN%\mariadb.exe" (
  echo ERROR: mariadb.exe not found at "%MDBBIN%".
  goto :end
)
if not exist "%MDBBIN%\mariadb-dump.exe" (
  echo ERROR: mariadb-dump.exe not found at "%MDBBIN%".
  goto :end
)

REM Ask for password only if PASS is empty
if "%PASS%"=="" (
  echo Enter password for %USER%@%HOST% ^(input will be visible^)
  set /p "PASS=> "
  echo.
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

set "LOG=%OUTDIR%\_dump_errors.log"
del "%LOG%" 2>nul

REM ================== MODE SELECTION ==================
REM Usage:
REM   db-migration.bat               -> dump all databases separately (+ mysql.sql)
REM   db-migration.bat ALL           -> dump all databases into one file all_databases.sql (just add `all`, case insensitive)
REM   db-migration.bat db1 db2 db3   -> dump only listed databases separately

if /I "%~1"=="ALL" goto :all_in_one
if "%~1"=="" goto :all_separate
goto :selected_only

REM ================== MODE 1: ALL DATABASES INTO ONE FILE ==================
:all_in_one
echo === Dumping ALL databases into ONE file ===
set "OUTFILE=%OUTDIR%\all_databases.sql"
echo Output: "%OUTFILE%"

"%MDBBIN%\mariadb-dump.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% ^
  --all-databases %COMMON_OPTS% --result-file="%OUTFILE%"

if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping ALL DATABASES >> "%LOG%"
  echo     ^- See "%LOG%" for details.
) else (
  echo     OK
)
goto :done

REM ================== MODE 2: ONLY SELECTED DATABASES ==================
:selected_only
echo === Dumping SELECTED databases: %* ===

for %%D in (%*) do (
  set "DB=%%~D"
  set "OUTFILE=%OUTDIR%\!DB!.sql"
  echo.
  echo --- Dumping database: !DB!  ^> "!OUTFILE!"
  "%MDBBIN%\mariadb-dump.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases "!DB!" %COMMON_OPTS% --result-file="!OUTFILE!"
  if errorlevel 1 (
    echo [%DATE% %TIME%] ERROR dumping !DB! >> "%LOG%"
    echo     ^- See "%LOG%" for details.
  ) else (
    echo     OK
  )
)

goto :done

REM ================== MODE 3: ALL DATABASES SEPARATELY (DEFAULT) ==================
:all_separate
echo === Getting database list from %HOST%:%PORT% ...
set "DBLIST=%OUTDIR%\_dblist.txt"

REM Write databases to a file to avoid quoting issues with "Program Files"
"%MDBBIN%\mariadb.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% -N -B -e "SHOW DATABASES" > "%DBLIST%"
if errorlevel 1 (
  echo ERROR: Could not retrieve database list.
  goto :done
)

for /f "usebackq delims=" %%D in ("%DBLIST%") do (
  set "DB=%%D"
  REM Skip system schemas except mysql (we dump mysql separately after the loop)
  if /I not "!DB!"=="information_schema" if /I not "!DB!"=="performance_schema" if /I not "!DB!"=="sys" if /I not "!DB!"=="mysql" (
    set "OUTFILE=%OUTDIR%\!DB!.sql"
    echo.
    echo --- Dumping database: !DB!  ^> "!OUTFILE!"
    "%MDBBIN%\mariadb-dump.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases "!DB!" %COMMON_OPTS% --result-file="!OUTFILE!"
    if errorlevel 1 (
      echo [%DATE% %TIME%] ERROR dumping !DB! >> "%LOG%"
      echo     ^- See "%LOG%" for details.
    ) else (
      echo     OK
    )
  )
)

echo.
echo --- Dumping system grants/users database: mysql
"%MDBBIN%\mariadb-dump.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% --databases mysql %COMMON_OPTS% --result-file="%OUTDIR%\mysql.sql"
if errorlevel 1 (
  echo [%DATE% %TIME%] ERROR dumping mysql >> "%LOG%"
  echo     ^- See "%LOG%" for details.
) else (
  echo     OK
)

goto :done

REM ================== FINAL REPORT ==================
:done
echo.
echo === Done. Dumps are in: %OUTDIR%
if exist "%LOG%" (
  echo Some errors were recorded in: %LOG%
) else (
  echo No errors recorded.
)

:end
endlocal

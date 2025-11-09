@echo off
REM ============ DEFAULT CONFIG (used if no args are passed) ============
set "MDBBIN=C:\Program Files\MariaDB 10.5\bin"
set "OUTDIR=D:\4\db_dumps_temp"
set "HOST=localhost"
set "PORT=3306"
set "USER=root"
set "PASS="
REM =====================================================================

chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

REM --------- Override config from arguments if provided ----------
REM Arg1: MDBBIN, Arg2: OUTDIR, Arg3: HOST, Arg4: PORT, Arg5: USER, Arg6: PASS

if not "%~1"=="" set "MDBBIN=%~1"
if not "%~2"=="" set "OUTDIR=%~2"
if not "%~3"=="" set "HOST=%~3"
if not "%~4"=="" set "PORT=%~4"
if not "%~5"=="" set "USER=%~5"
if not "%~6"=="" set "PASS=%~6"
REM ----------------------------------------------------------------

if not exist "%MDBBIN%\mariadb.exe" (
  echo ERROR: mariadb.exe not found at "%MDBBIN%".
  goto :end
)

REM Ask for password only if PASS is empty after overrides
if "%PASS%"=="" (
  echo Enter password for %USER%@%HOST% ^(input will be visible^)
  set /p "PASS=> "
  echo.
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

set "LOG=%OUTDIR%\_users_errors.log"
set "USERLIST=%OUTDIR%\_userlist.txt"
set "USERDUMP=%OUTDIR%\users_and_grants.sql"
del "%LOG%" 2>nul
del "%USERLIST%" 2>nul
del "%USERDUMP%" 2>nul

echo === Exporting users and grants to "%USERDUMP%" ===

REM Get list of users@hosts; adjust WHERE if you want to skip system accounts
"%MDBBIN%\mariadb.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% -N -B ^
  -e "SELECT CONCAT('''',User,'''@''',Host,'''') FROM mysql.user WHERE User<>''" > "%USERLIST%"

if errorlevel 1 (
  echo ERROR: Could not retrieve user list. See "%LOG%" for details.
  goto :end
)

REM Optional header
echo -- Users and grants exported from %HOST%:%PORT% on %DATE% %TIME%> "%USERDUMP%"
echo SET sql_log_bin=0;>> "%USERDUMP%"
echo.>> "%USERDUMP%"

for /f "usebackq delims=" %%U in ("%USERLIST%") do (
  echo -- Grants for %%U>>"%USERDUMP%"
  "%MDBBIN%\mariadb.exe" -h %HOST% -P %PORT% -u %USER% -p%PASS% -N -B ^
    -e "SHOW GRANTS FOR %%U" >> "%USERDUMP%" 2>>"%LOG%"
  echo.>>"%USERDUMP%"
)

echo SET sql_log_bin=1;>> "%USERDUMP%"
echo.
echo === Users and grants saved to: "%USERDUMP%"

if exist "%LOG%" (
  echo Some errors were recorded in: %LOG%
)

:end
endlocal

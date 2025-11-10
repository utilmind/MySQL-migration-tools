@echo off
REM ============ DEFAULT CONFIG (used if no args are passed) ============
REM Path to bin folder (MariaDB or MySQL)
set "SQLBIN=C:\Program Files\MariaDB 10.5\bin"
REM Client executable name: mysql.exe or mariadb.exe / mysqldump.exe or mariadb-dump.exe.
set "SQLCLI=mysql.exe"
set "SQLDUMP=mysqldump.exe"
REM Output folder for users_and_grants.sql
set "OUTDIR=D:\_db-dumps"
REM Connection params
set "HOST=localhost"
set "PORT=3306"
set "USER=root"
REM Password: put real password here, or leave empty to be prompted
set "PASS="
REM =====================================================================
REM (Don't use exclamation sign in file names, to avoid !VAR! issues.)
set "LOG=%OUTDIR%\^users_errors.log"
set "USERLIST=%OUTDIR%\^user-list.txt"
set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
set "TMPGRANTS=%OUTDIR%\_grants_tmp.txt"

REM --------- Override config from arguments if provided ----------
REM Arg1: SQLBIN, Arg2: OUTDIR, Arg3: HOST, Arg4: PORT, Arg5: USER, Arg6: PASS

if not "%~1"=="" set "SQLBIN=%~1"
if not "%~2"=="" set "OUTDIR=%~2"
if not "%~3"=="" set "HOST=%~3"
if not "%~4"=="" set "PORT=%~4"
if not "%~5"=="" set "USER=%~5"
if not "%~6"=="" set "PASS=%~6"
REM ----------------------------------------------------------------

if not exist "%SQLBIN%\%SQLCLI%" (
  echo ERROR: %SQLCLI% not found at "%SQLBIN%".
  goto :end
)

REM Ask for password only if PASS is empty after overrides
if "%PASS%"=="" (
  echo Enter password for %USER%@%HOST% ^(INPUT WILL BE VISIBLE^)
  set /p "PASS=> "
  echo.
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

del "%LOG%" 2>nul
del "%USERLIST%" 2>nul
del "%USERDUMP%" 2>nul


REM After variables are set, so we can use ^! to escape !. Before export.
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul

echo === Exporting users and grants to "%USERDUMP%" ===

REM Get list of users@hosts; skip system accounts like root, mariadb.sys, mysql.sys, mysql.session
"%SQLBIN%\%SQLCLI%" -h %HOST% -P %PORT% -u %USER% -p%PASS% -N -B ^
  -e "SELECT CONCAT('''',User,'''@''',Host,'''') FROM mysql.user WHERE User<>'' AND User NOT IN ('root','mariadb.sys','mysql.sys','mysql.session')" > "%USERLIST%"

if errorlevel 1 (
  echo ERROR: Could not retrieve user list. See "%LOG%" for details.
  goto :end
)

REM Optional header
echo -- Users and grants exported from %HOST%:%PORT% on %DATE% %TIME%> "%USERDUMP%"
echo SET sql_log_bin=0;>> "%USERDUMP%"
echo.>> "%USERDUMP%"

for /f "usebackq delims=" %%U in ("%USERLIST%") do (
  echo -- User and grants for %%U>>"%USERDUMP%"
  echo CREATE USER IF NOT EXISTS %%U;>>"%USERDUMP%"

  REM Write SHOW GRANTS output to a temporary file. (AK: we could output them, but should add ';' after GRANT string...)
  "%SQLBIN%\%SQLCLI%" -h "%HOST%" -P %PORT% -u "%USER%" -p%PASS% -N -B -e "SHOW GRANTS FOR %%U" >"%TMPGRANTS%" 2>>"%LOG%"

  REM Read each GRANT line and append a semicolon
  for /f "usebackq delims=" %%G in ("%TMPGRANTS%") do (
    echo %%G;>>"%USERDUMP%"
  )

  echo.>>"%USERDUMP%"
)

echo SET sql_log_bin=1;>> "%USERDUMP%"
echo.
echo === Users and grants saved to: "%USERDUMP%"

REM If log file exists but is empty (0 bytes), delete it
if exist "%LOG%" (
  for %%F in ("%LOG%") do if %%~zF EQU 0 del "%%F"
)

if exist "%LOG%" (
  echo Some errors were recorded in: %LOG%
)

:end
endlocal

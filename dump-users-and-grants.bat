@echo off
REM ======================================================================
REM  dump-users-and-grants.bat
REM
REM  Copyright (c) 2025 utilmind
REM  All rights reserved.
REM  https://github.com/utilmind/MySQL-Migration-from-Windows-PC/
REM
REM  Description:
REM    Helper script for exporting MySQL / MariaDB users and privileges
REM    into a standalone SQL file.
REM
REM    Features:
REM      - Connects to the server using the configured client binary
REM        (mysql.exe or mariadb.exe).
REM      - Queries mysql.user (or compatible view) to obtain the list
REM        of non-system accounts.
REM      - Skips internal / system users (e.g. root, mariadb.sys, etc.),
REM        depending on the configured filters.
REM      - For each user, generates SQL statements that:
REM          * create the user on the target server (if needed),
REM          * re-apply all privileges using SHOW GRANTS output.
REM      - Writes everything into users_and_grants.sql so that it can be
REM        imported before or together with database dumps.
REM
REM  Usage:
REM      Called directly:
REM        dump-users-and-grants.bat
REM          - Uses default configuration defined in this script.
REM
REM      Called from db-dump.bat:
REM        call dump-users-and-grants.bat [SQLBIN] [HOST] [PORT] [USER] [PASS] [OUTDIR] [OUTFILE]
REM          - Inherits connection and output settings from db-dump.bat.
REM
REM ======================================================================

REM ============ DEFAULT CONFIG (used if no args are passed) ============
REM Path to bin folder (MariaDB or MySQL). (Optionally. Something like "SQLBIN=C:\Program Files\MariaDB 10.5\bin".)
REM ATTN! If you have MULTIPLE VERSIONS of MySQL/MariaDB installed on your computer, please specify the exact path to the working version you are dumping from!
set "SQLBIN="
REM Run "mysql --version" to figure out the version of your default mysql.exe
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
set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
REM Log and temporary files
set "LOG=%OUTDIR%\_users_errors.log"
set "USERLIST=%OUTDIR%\__user-list.txt"
set "TMPGRANTS=%OUTDIR%\__grants_tmp.txt"

REM --------- Override config from arguments if provided ----------
REM Arg1: SQLBIN, Arg2: HOST, Arg3: PORT, Arg4: USER, Arg5: PASS, Arg6: OUTDIR, Arg7: USERDUMP

if not "%~1"=="" set "SQLBIN=%~1"
if not "%~2"=="" set "HOST=%~2"
if not "%~3"=="" set "PORT=%~3"
if not "%~4"=="" set "USER=%~4"
if not "%~5"=="" set "PASS=%~5"
if not "%~6"=="" set "OUTDIR=%~6"
if not "%~7"=="" set "USERDUMP=%~7"
REM ----------------------------------------------------------------

REM Add trailing slash (\) to the end of %SQLBIN%, if it's not empty.
if defined SQLBIN (
  if not "%SQLBIN:~-1%"=="\" (
    set "SQLBIN=%SQLBIN%\"
  )

  if not exist "%SQLBIN%%SQLCLI%" (
    echo ERROR: %SQLCLI% not found at "%SQLBIN%".
    echo Please open the '%~nx0', and edit the configuration, particularly the path in SQLBIN variable.
    goto :end
  )
)

REM Ask for password only if PASS is empty after overrides
if "%PASS%"=="" (
  echo Enter password for %USER%@%HOST% ^(INPUT WILL BE VISIBLE^)
  set /p "PASS=> "
  echo.
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

REM Delete previous files
del "%LOG%" 2>nul
del "%USERDUMP%" 2>nul
REM Unlikely temporary files are still there, but just in case.
del "%USERLIST%" 2>nul
del "%TMPGRANTS%" 2>nul


REM After variables are set, so we can use ^! to escape !. Before export.
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul

echo === Exporting users and grants to "%USERDUMP%" ===

REM Get list of users@hosts; skip system accounts like root, mariadb.sys, mysql.sys, mysql.session
"%SQLBIN%%SQLCLI%" -h %HOST% -P %PORT% -u %USER% -p%PASS% -N -B ^
  -e "SELECT CONCAT('''',User,'''@''',Host,'''') FROM mysql.user WHERE User<>'' AND User NOT IN ('root','mariadb.sys','mysql.sys','mysql.session','rdsadmin')" > "%USERLIST%"

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
  "%SQLBIN%%SQLCLI%" -h "%HOST%" -P %PORT% -u "%USER%" -p%PASS% -N -B -e "SHOW GRANTS FOR %%U" >"%TMPGRANTS%" 2>>"%LOG%"

  REM Read each GRANT line and append a semicolon
  for /f "usebackq delims=" %%G in ("%TMPGRANTS%") do (
    echo %%G;>>"%USERDUMP%"
  )

  echo.>>"%USERDUMP%"
)

REM Delete temporary files.
del "%USERLIST%" 2>nul
del "%TMPGRANTS%" 2>nul

echo SET sql_log_bin=1;>> "%USERDUMP%"
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

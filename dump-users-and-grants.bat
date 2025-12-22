@echo off
REM ======================================================================
REM  dump-users-and-grants.bat
REM
REM  Copyright (c) 2025 utilmind
REM  All rights reserved.
REM  https://github.com/utilmind/MySQL-migration-tools
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
REM Output folder for users_and_grants.sql
set "OUTDIR=.\_db-dumps"
REM Connection params
set "DB_HOST=localhost"
set "DB_PORT=3306"
set "DB_USER=root"
REM Password: put real password here, or leave empty to be prompted
set "DB_PASS="

REM If 1, add --skip-ssl to mysql invocations (ONLY when SSL_CA is empty).
set "SKIP_SSL=0"

REM Optional: path to a trusted CA bundle (PEM). If set, it overrides SKIP_SSL.
REM Example (AWS RDS): https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html
set "SSL_CA="


REM --------- Override config from arguments if provided ----------
REM Arg1: SQLBIN, Arg2: DB_HOST, Arg3: DB_PORT, Arg4: DB_USER, Arg5: DB_PASS, Arg6: OUTDIR, Arg7: USERDUMP, Arg8: SKIP_SSL, Arg9: SSL_CA
REM Notes:
REM   - DB_PASS can be passed as "*" to indicate "no password here; prefer local ini".
REM   - When a local ini is found, it is used via --defaults-extra-file and DB_PASS is ignored.

if not "%~1"=="" set "SQLBIN=%~1"
if not "%~2"=="" set "DB_HOST=%~2"
if not "%~3"=="" set "DB_PORT=%~3"
if not "%~4"=="" set "DB_USER=%~4"
if not "%~5"=="" set "DB_PASS=%~5"
if not "%~6"=="" set "OUTDIR=%~6"
if not "%~7"=="" set "USERDUMP=%~7"
if not "%~8"=="" set "SKIP_SSL=%~8"
if not "%~9"=="" set "SSL_CA=%~9"

REM Local option file (.mysql-client.ini) handling.
REM We intentionally DO NOT rely on %~10, because positional parameters >=10 are error-prone in cmd.exe.
REM Instead, we probe the ini next to this script.
set "LOCAL_DEFAULTS_FILE=%~dp0.mysql-client.ini"
set "DEFAULTS_OPT="
if exist "%LOCAL_DEFAULTS_FILE%" (
  set "DEFAULTS_OPT=%LOCAL_DEFAULTS_FILE%"
)


REM Set target file names, after %OUTDIR% is defined.
REM (Don't use exclamation sign in file names, to avoid !VAR! issues.)
REM Default output file if not provided via args.
if not defined USERDUMP set "USERDUMP=%OUTDIR%\_users_and_grants.sql"
REM Log and temporary files
set "LOG=%OUTDIR%\__users_errors.log"
set "USERLIST=%TEMP%\__user-list.txt"
set "TMPGRANTS=%TEMP%\__grants-tmp.txt"


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

REM Ask for password only if DB_PASS is empty after overrides (and no defaults-extra-file is used)
if not defined DEFAULTS_OPT (
  REM If the caller passed "*" as password, treat it as "no password provided".
  if "%DB_PASS%"=="*" set "DB_PASS="
  REM Ask for password only if DB_PASS is empty after overrides
  if "%DB_PASS%"=="" (
    echo Enter password for %DB_USER%@%DB_HOST% ^(INPUT WILL BE VISIBLE^)
    set /p "DB_PASS=> "
    echo.
  )
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

REM === BUILD AUTH/CONNECTION ARGUMENTS ===
REM NOTE: --defaults-extra-file MUST go first.
set "MYSQL_AUTH_OPTS="
if defined DEFAULTS_OPT (
  REM Prefer the canonical form without wrapping the whole option token in quotes.
  REM (This keeps cmd.exe parsing predictable and still supports spaces in the ini path.)
  REM Quote only the value part, not the whole token.
  set "MYSQL_AUTH_OPTS=--defaults-extra-file=""%DEFAULTS_OPT%"""
) else (
  REM Build SSL-related options. SSL_CA has priority over SKIP_SSL (mutually exclusive).
  REM Note: --ssl-verify-server-cert is not supported by every client build, so we enable it only if available.
  set "CONN_SSL_OPTS="
  set "CONN_VERIFY_CERT_OPTS="
  if not "%SSL_CA%"=="" (
    set "CONN_SSL_OPTS=--ssl --ssl-ca=""%SSL_CA%"""
    set "MYSQL_HELP_FILE=%TEMP%\mysql_help_%RANDOM%.tmp"
    "%SQLBIN%%SQLCLI%" --help >"%MYSQL_HELP_FILE%" 2>&1
    findstr /C:"--ssl-verify-server-cert" "%MYSQL_HELP_FILE%" >nul 2>&1
    if not errorlevel 1 (
      set "CONN_VERIFY_CERT_OPTS=--ssl-verify-server-cert"
    )
    del "%MYSQL_HELP_FILE%" >nul 2>&1
  ) else (
    if "%SKIP_SSL%"=="1" (
      set "CONN_SSL_OPTS=--skip-ssl"
    )
  )
  set "MYSQL_AUTH_OPTS=-h ""%DB_HOST%"" -P %DB_PORT% -u ""%DB_USER%"" -p%DB_PASS% %CONN_SSL_OPTS% %CONN_VERIFY_CERT_OPTS%"
)


"%SQLBIN%%SQLCLI%" %MYSQL_AUTH_OPTS% -N -B ^
    -e "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.user WHERE User NOT IN ('', 'root','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','mariadb.session','debian-sys-maint','healthchecker','rdsadmin')" >"%USERLIST%" 2>>"%LOG%"
if errorlevel 1 (
  echo ERROR: Could not retrieve user list. See "%LOG%" for details.
  goto :end
)

REM Optional header
echo -- Users and grants exported from %DB_HOST%:%DB_PORT% on %DATE% %TIME%> "%USERDUMP%"
echo SET sql_log_bin=0;>> "%USERDUMP%"
echo.>> "%USERDUMP%"

for /f "usebackq delims=" %%U in ("%USERLIST%") do (
  echo -- User and grants for %%U>>"%USERDUMP%"
  echo CREATE USER IF NOT EXISTS %%U;>>"%USERDUMP%"

  REM Write SHOW GRANTS output to a temporary file. (AK: we could output them, but should add ';' after GRANT string...)
  "%SQLBIN%%SQLCLI%" %MYSQL_AUTH_OPTS% %CONN_SSL_OPTS% -N -B -e "SHOW GRANTS FOR %%U" >"%TMPGRANTS%" 2>>"%LOG%"

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

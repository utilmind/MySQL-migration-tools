@echo off
REM ======================================================================
REM  db-import.bat
REM
REM  Copyright (c) 2025 utilmind
REM  All rights reserved.
REM  https://github.com/utilmind/MySQL-migration-tools
REM
REM  Description:
REM    Helper script to import MySQL / MariaDB database dump,
REM    displaying the progress in console and logging all errors.
REM
REM  Usage:
REM      db-import.bat source-dump.sql
REM
REM ======================================================================


REM ================== CONFIG ==================
REM Log file name
set "LOGFILE=_errors-import.log"
REM ============== END OF CONFIG ==================
REM Use UTF-8 encoding for output, if needed
chcp 65001 >nul


REM Check if first argument is provided
if "%~1"=="" (
    echo Error: no path to the MySQL dump provided.
    echo Usage: %~nx0 "C:\path\to\mysql-dump.sql"
    exit /b 1
)

REM Save first argument as file path
set "FILE=%~1"

REM Check if file exists
if not exist "%FILE%" (
    echo Error: file not found: "%FILE%"
    exit /b 1
)


REM Remove old log if exists. (To Recycle Bin.)
if exist "%LOGFILE%" del "%LOGFILE%"

echo Importing "%FILE%" into MySQL...

REM Run MySQL client:
REM   -u root -p        -> ask for password
REM   --verbose         -> show what is being executed (some progress). It puts good output to 'stdout' (console) and bad into 'stderr' (log).
REM   --force           -> continue import even if SQL errors occur. You can review all errors together in the log.
REM   < "%FILE%"        -> read SQL commands from dump file
REM   2> "%LOGFILE%"    -> send ONLY errors (stderr) to _errors.log
mysql -u root -p --verbose --force -e "source %FILE%" 2> "%LOGFILE%"

REM Save MySQL process exit code (connection / fatal errors)
set "MYSQL_ERRORLEVEL=%ERRORLEVEL%"

REM Check if log file has any content
set "HAS_ERRORS=0"
if exist "%LOGFILE%" (
    for %%A in ("%LOGFILE%") do (
        if not "%%~zA"=="0" set "HAS_ERRORS=1"
    )
)

REM If there are errors in log file
if "%HAS_ERRORS%"=="1" goto :hasErrors

REM If MySQL itself failed (e.g. auth, connection, etc.) but log is empty
if not "%MYSQL_ERRORLEVEL%"=="0" (
    echo Import FAILED ^(mysql returned errorlevel %MYSQL_ERRORLEVEL%^), but no SQL errors were logged.
    exit /b %MYSQL_ERRORLEVEL%
)

REM No need to keep empty log file
if exist "%LOGFILE%" del "%LOGFILE%"
REM No log errors and MySQL exited normally
echo Import completed successfully. No errors detected.
exit /b 0


:hasErrors
REM Count number of lines in log file
for /f %%C in ('type "%LOGFILE%" ^| find /v /c ""') do set ERRLINES=%%C
echo Import completed with ERRORS.
echo %ERRLINES% line(s) in "%LOGFILE%".
echo Please review the log file for details.
exit /b 1

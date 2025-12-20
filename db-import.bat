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
REM    Supports plain .sql files as well as .sql.gz, .zip and .rar archives.
REM
REM  Usage:
REM      db-import.bat source-dump.sql[.gz]|source-dump.zip|source-dump.rar
REM
REM ======================================================================


REM ================== CONFIG ==================
REM Log file name
set "LOGFILE=_errors-import.log"
set "DB_USER=root"
REM Password: put real password here, or leave EMPTY to be prompted. Do not expose your password in public!!
set "DB_PASS="
REM ============== END OF CONFIG ==================
REM Use UTF-8 encoding for output, if needed
chcp 65001 >nul

REM ==================== READ mysql HELP ====================
REM Make sure that mysql exists in PATH
mysql --version >nul 2>&1
if errorlevel 1 (
    echo [FAIL] mysql client not found in PATH or not executable.
    exit /b 1
)

REM Store mysql --help output in a temporary file for option detection
set "MYSQL_HELP_FILE=%TEMP%\mysql_help_%RANDOM%.tmp"
mysql --help >"%MYSQL_HELP_FILE%" 2>&1
if errorlevel 1 (
    echo [FAIL] Failed to execute "mysql --help".
    del "%MYSQL_HELP_FILE%" >nul 2>&1
    exit /b 1
)

REM Extra mysql client options for import (built only if supported by this mysql.exe)
set "IMPORT_OPTS="

REM Optional: increase client max_allowed_packet for large rows/BLOBs
if defined MAX_ALLOWED_PACKET (
    if not "%MAX_ALLOWED_PACKET%"=="" (
        findstr /C:"--max_allowed_packet" "%MYSQL_HELP_FILE%" >nul 2>&1
        if not errorlevel 1 (
            set "IMPORT_OPTS=%IMPORT_OPTS% --max_allowed_packet=%MAX_ALLOWED_PACKET%"
        ) else (
            echo [WARN] mysql client does not support --max_allowed_packet; skipping it.
        )
    )
)

REM Optional: set the network buffer size (bytes)
if defined NET_BUFFER_LENGTH (
    if not "%NET_BUFFER_LENGTH%"=="" (
        findstr /C:"--net_buffer_length" "%MYSQL_HELP_FILE%" >nul 2>&1
        if not errorlevel 1 (
            set "IMPORT_OPTS=%IMPORT_OPTS% --net_buffer_length=%NET_BUFFER_LENGTH%"
        ) else (
            echo [WARN] mysql client does not support --net_buffer_length; skipping it.
        )
    )
)

REM Cleanup temporary mysql --help file
if exist "%MYSQL_HELP_FILE%" del "%MYSQL_HELP_FILE%" >nul 2>&1
set "MYSQL_HELP_FILE="



REM Check if first argument is provided
if "%~1"=="" (
    echo Error: no path to the MySQL dump provided.
    echo Usage: %~nx0 "C:\path\to\mysql-dump.sql[.gz]" ^| "dump.zip" ^| "dump.rar"
    exit /b 1
)

REM Resolve absolute path to source file
set "SRC_FILE=%~f1"

REM Check if file exists
if not exist "%SRC_FILE%" (
    echo Error: file not found: "%SRC_FILE%"
    exit /b 1
)

REM Determine extension of the source file
for %%I in ("%SRC_FILE%") do set "SRC_EXT=%%~xI"

REM By default we will import the original file
set "WORK_SQL=%SRC_FILE%"
set "TEMP_SQL_DIR="

REM Handle archives: .rar via WinRAR/UnRAR, .zip/.gz via 7-Zip (7z.exe/7za.exe)
if /I "%SRC_EXT%"==".rar"  call :ExtractFromRar || goto :hasErrors
if /I "%SRC_EXT%"==".zip"  call :ExtractWith7z  || goto :hasErrors
if /I "%SRC_EXT%"==".gz"   call :ExtractWith7z  || goto :hasErrors

REM At this point, WORK_SQL points to the .sql file to import
REM Remove old log if exists.
if exist "%LOGFILE%" del "%LOGFILE%"

echo Importing "%WORK_SQL%" as '%DB_USER%'...

REM Run MySQL client:
REM   -u root -p        -> ask for password
REM   --verbose         -> show what is being executed (sometimes noisy, commented out below)
REM   --force           -> continue import even if SQL errors occur. You can review all errors together in the log.
REM   source file       -> read SQL commands from dump file
REM   2> "%LOGFILE%"    -> send ONLY errors (stderr) to _errors-import.log
mysql -u "%DB_USER%" -p%DB_PASS% %IMPORT_OPTS% --force -e "source %WORK_SQL%" 2> "%LOGFILE%"
REM mysql -u "%DB_USER%" -p%DB_PASS% %IMPORT_OPTS% --verbose --force -e "source %WORK_SQL%" 2> "%LOGFILE%"
REM mysql -u "%DB_USER%" -p%DB_PASS% %IMPORT_OPTS% --force -e "source %WORK_SQL%"

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
    REM Clean up temp directory if it was created
    if defined TEMP_SQL_DIR (
        rd /s /q "%TEMP_SQL_DIR%" 2>nul
    )
    exit /b %MYSQL_ERRORLEVEL%
)

REM Successful import:
REM Clean up temp directory if it was created
if defined TEMP_SQL_DIR (
    rd /s /q "%TEMP_SQL_DIR%" 2>nul
)

REM No need to keep empty log file
if exist "%LOGFILE%" del "%LOGFILE%"
REM No log errors and MySQL exited normally
echo Import completed successfully. No errors detected.
exit /b 0


REM ======================================================================
REM  ExtractFromRar
REM  Uses rar.exe or unrar.exe from PATH to extract %SRC_FILE%
REM  into a temporary directory. Picks first *.sql file as WORK_SQL.
REM  On success:  WORK_SQL and TEMP_SQL_DIR are set, exit /b 0
REM  On failure:  message printed, exit /b 1
REM ======================================================================
:ExtractFromRar
setlocal
set "RAR_SRC=%SRC_FILE%"

REM Detect RAR / UNRAR in PATH
set "RAR_EXE="
where rar >nul 2>&1 && set "RAR_EXE=rar"
if not defined RAR_EXE (
    where unrar >nul 2>&1 && set "RAR_EXE=unrar"
)

if not defined RAR_EXE (
    echo [FAIL] Neither rar.exe nor unrar.exe found in PATH. Cannot extract "%RAR_SRC%".
    endlocal & exit /b 1
)

REM Create temp directory
set "TMPDIR=%TEMP%\db-import-%RANDOM%%RANDOM%"
md "%TMPDIR%" 2>nul
if errorlevel 1 (
    echo [FAIL] Cannot create temp directory "%TMPDIR%".
    endlocal & exit /b 1
)

echo Extracting "%RAR_SRC%" to "%TMPDIR%\" using %RAR_EXE%...

REM -y = yes to all overwrite prompts
"%RAR_EXE%" x -y "%RAR_SRC%" "%TMPDIR%\" >nul
if errorlevel 1 (
    echo [FAIL] Failed to extract archive "%RAR_SRC%".
    rd /s /q "%TMPDIR%" 2>nul
    endlocal & exit /b 1
)

REM Find first .sql file in extracted directory
set "EXTRACTED_SQL="
for /R "%TMPDIR%" %%S in (*.sql) do (
    if not defined EXTRACTED_SQL set "EXTRACTED_SQL=%%~fS"
)

if not defined EXTRACTED_SQL (
    echo [FAIL] Archive "%RAR_SRC%" does not contain any .sql file.
    rd /s /q "%TMPDIR%" 2>nul
    endlocal & exit /b 1
)

endlocal & (
    set "WORK_SQL=%EXTRACTED_SQL%"
    set "TEMP_SQL_DIR=%TMPDIR%"
)
exit /b 0


REM ======================================================================
REM  ExtractWith7z
REM  Uses 7z.exe or 7za.exe from PATH to extract %SRC_FILE%
REM  into a temporary directory. Handles .zip and .gz archives.
REM  Picks first *.sql file as WORK_SQL.
REM  On success:  WORK_SQL and TEMP_SQL_DIR are set, exit /b 0
REM  On failure:  message printed, exit /b 1
REM ======================================================================
:ExtractWith7z
setlocal
set "ARCH_SRC=%SRC_FILE%"

REM Detect 7-Zip in PATH
set "SEVEN_EXE="
where 7z >nul 2>&1 && set "SEVEN_EXE=7z"
if not defined SEVEN_EXE (
    where 7za >nul 2>&1 && set "SEVEN_EXE=7za"
)

if not defined SEVEN_EXE (
    echo [FAIL] 7-Zip ^(7z.exe or 7za.exe^) not found in PATH. Cannot extract "%ARCH_SRC%".
    endlocal & exit /b 1
)

REM Create temp directory
set "TMPDIR=%TEMP%\db-import-%RANDOM%%RANDOM%"
md "%TMPDIR%" 2>nul
if errorlevel 1 (
    echo [FAIL] Cannot create temp directory "%TMPDIR%".
    endlocal & exit /b 1
)

echo Extracting "%ARCH_SRC%" to "%TMPDIR%\" using %SEVEN_EXE%...

REM -y = yes to all overwrite prompts
"%SEVEN_EXE%" x -y "-o%TMPDIR%" "%ARCH_SRC%" >nul
if errorlevel 1 (
    echo [FAIL] Failed to extract archive "%ARCH_SRC%".
    rd /s /q "%TMPDIR%" 2>nul
    endlocal & exit /b 1
)

REM Find first .sql file in extracted directory
set "EXTRACTED_SQL="
for /R "%TMPDIR%" %%S in (*.sql) do (
    if not defined EXTRACTED_SQL set "EXTRACTED_SQL=%%~fS"
)

if not defined EXTRACTED_SQL (
    echo [FAIL] Archive "%ARCH_SRC%" does not contain any .sql file.
    rd /s /q "%TMPDIR%" 2>nul
    endlocal & exit /b 1
)

endlocal & (
    set "WORK_SQL=%EXTRACTED_SQL%"
    set "TEMP_SQL_DIR=%TMPDIR%"
)
exit /b 0


:hasErrors
REM Clean up temp directory if it was created
if defined TEMP_SQL_DIR (
    rd /s /q "%TEMP_SQL_DIR%" 2>nul
)

REM Count number of lines in log file
for /f %%C in ('type "%LOGFILE%" ^| find /v /c ""') do set ERRLINES=%%C
echo Import completed with ERRORS.
echo %ERRLINES% line(s) in "%LOGFILE%".
echo Please review the log file for details.
exit /b 1

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
REM Connection params (leave DB_HOST/DB_PORT default if local)
set "DB_HOST=localhost"
set "DB_PORT=3306"
set "DB_USER=root"
REM Password: put real password here, or leave EMPTY to be prompted. NEVER EXPOSE YOUR PASSWORD to public or in any kind of Git repos!!
set "DB_PASS="
REM Optional: increase client max_allowed_packet for large rows/BLOBs.
REM Example values: 64M, 256M, 1G
REM
REM IMPORTANT! This option increase value for the client application, mysql.exe.
REM Please make sure that MySQL/MariaDB SERVER is ALSO supports huge data packets.
REM Add something like the following into your my.ini:
REM     [mysqld]
REM     max_allowed_packet=1G
REM     net_read_timeout=600
REM     net_write_timeout=600
REM
set "MAX_ALLOWED_PACKET=1024M"

REM Optional: set the network buffer size for mysqldump in bytes.
REM This can help when dumping tables with large rows / BLOBs over slow or flaky connections.
REM Example values: 1048576 (1 MiB), 4194304 (4 MiB)
set "NET_BUFFER_LENGTH=4194304"

REM Enable/disable dump pre-processing before import (0 = off, 1 = on)
set "USE_PREIMPORT=1"
REM Replace 'python' to 'python3' or 'py', depending under which name the Python interpreter is registered in your system.
set "PRE_PROCESSOR=python ./bash/pre-import.py"
REM Collation map file. Pairs of legacy collations -> new collations.
set "COLLATION_MAP=collation-map.json"

REM set "SQLCLI=mariadb.exe"
set "SQLCLI=mysql.exe"
REM ============== END OF CONFIG ==================
REM ================== OPTIONAL LOCAL INI ==================
REM If a local ini file exists near this script, use it for connection options.
REM This keeps passwords out of the .bat and allows per-repo local settings.
REM
REM File name (relative to script directory): .mysql-client.ini
set "SCRIPT_DIR=%~dp0"
set "LOCAL_INI=%SCRIPT_DIR%.mysql-client.ini"
set "DEFAULTS_OPT="
set "USE_LOCAL_INI=0"
if exist "%LOCAL_INI%" (
    set "DEFAULTS_OPT=--defaults-extra-file=""%LOCAL_INI%"""
    set "USE_LOCAL_INI=1"
)
REM If no local ini and DB_PASS is empty, ask once and reuse via MYSQL_PWD
if "%USE_LOCAL_INI%"=="0" (
    if "%DB_PASS%"=="" (
        set /p "DB_PASS=Enter password: "
    )
    REM mysql client will use MYSQL_PWD (avoid interactive prompt twice)
    set "MYSQL_PWD=%DB_PASS%"
)
REM If ini is present, do NOT pass -u/-p on CLI, because command-line options override
REM option-file values. Also avoid passing a bare "-p" (which would always trigger an interactive prompt).
REM ============== END OPTIONAL LOCAL INI ==================

REM Build auth options only when NOT using local ini.
set "AUTH_OPTS="
if "%USE_LOCAL_INI%"=="0" (
    set "AUTH_OPTS=-h%DB_HOST% -P%DB_PORT% -u ""%DB_USER%"""
)
REM Use UTF-8 encoding for output, if needed
chcp 65001 >nul

REM Make sure that mysql exists in PATH
%SQLCLI% --version >nul 2>&1
if errorlevel 1 (
    echo [FAIL] mysql client not found in PATH or not executable.
    exit /b 1
)

REM ==================== READ mysql HELP ====================
REM Detect whether the local mysql.exe supports certain client options (MariaDB/MySQL builds can differ).
REM Store mysql --help output in a temporary file for option detection
set "MYSQL_HELP_FILE=%TEMP%\mysql_help_%RANDOM%.tmp"
%SQLCLI% --help >"%MYSQL_HELP_FILE%" 2>&1
if errorlevel 1 (
    echo [FAIL] Failed to execute "mysql --help".
    del "%MYSQL_HELP_FILE%" >nul 2>&1
    exit /b 1
)

REM Extra mysql client options for import (built only if supported by this mysql.exe)
set "IMPORT_OPTS="

REM When using --defaults-extra-file, avoid passing packet/buffer sizing options on CLI,
REM because command-line options override option-file values.
if "%USE_LOCAL_INI%"=="1" (
    goto :after_import_opts
)

REM Optional: increase client max_allowed_packet for large rows/BLOBs
if defined MAX_ALLOWED_PACKET (
    if not "%MAX_ALLOWED_PACKET%"=="" (
        findstr /C:"--max-allowed-packet" "%MYSQL_HELP_FILE%" >nul 2>&1
        if not errorlevel 1 (
            set "IMPORT_OPTS=%IMPORT_OPTS% --max-allowed-packet=%MAX_ALLOWED_PACKET%"
        ) else (
            echo [WARN] mysql client does not support --max-allowed-packet; skipping it.
        )
    )
)

REM Optional: set the network buffer size (bytes)
if defined NET_BUFFER_LENGTH (
    if not "%NET_BUFFER_LENGTH%"=="" (
        findstr /C:"--net-buffer-length" "%MYSQL_HELP_FILE%" >nul 2>&1
        if not errorlevel 1 (
            set "IMPORT_OPTS=%IMPORT_OPTS% --net-buffer-length=%NET_BUFFER_LENGTH%"
        ) else (
            echo [WARN] mysql client does not support --net-buffer-length; skipping it.
        )
    )
)

:after_import_opts

REM Cleanup temporary mysqldump --help file (no longer needed after building COMMON_OPTS)
if defined MYSQL_HELP_FILE (
    if exist "%MYSQL_HELP_FILE%" del "%MYSQL_HELP_FILE%" >nul 2>&1
    set "MYSQL_HELP_FILE="
)


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

if "%USE_LOCAL_INI%"=="1" (
    echo Importing "%WORK_SQL%" using local ini credentials...
) else (
    echo Importing "%WORK_SQL%" as '%DB_USER%'...
)

REM Decide which SQL file to import
set "IMPORT_SQL=%WORK_SQL%"
set "PREIMPORT_SQL="

if "%USE_PREIMPORT%"=="1" (
    REM --- Preprocess dump (collation check + patch) BEFORE import ---
    set "DUMP_IN=%WORK_SQL%"
    set "PREIMPORT_SQL=%TEMP%\db-preimport-%RANDOM%%RANDOM%.sql"
    set "MYSQL_LIST_COLLATIONS_CMD=%SQLCLI% %DEFAULTS_OPT% %AUTH_OPTS% -N"

    %PRE_PROCESSOR% --mysql-command "%MYSQL_LIST_COLLATIONS_CMD%" --map "%COLLATION_MAP%" "%DUMP_IN%" "%PREIMPORT_SQL%"
    if errorlevel 1 (
        if exist "%PREIMPORT_SQL%" del "%PREIMPORT_SQL%" >nul 2>&1
        exit /b 1
    )

    set "IMPORT_SQL=%PREIMPORT_SQL%"
REM ) else (
REM    echo [INFO] Pre-import step is disabled. Importing the original dump as-is.
)

REM Run MySQL client:
REM   --verbose         -> show what is being executed (sometimes noisy, commented out below)
REM   --comments        -> don't strip comments
REM   --bvinary-mode    -> disable \0 interpretation and \r\n translation.
REM   --force           -> continue import even if SQL errors occur. You can review all errors together in the log.
REM   source file       -> read SQL commands from dump file
REM   2> "%LOGFILE%"    -> send ONLY errors (stderr) to _errors-import.log
%SQLCLI% %DEFAULTS_OPT% %AUTH_OPTS% %IMPORT_OPTS% --comments --binary-mode --force < "%IMPORT_SQL%" 2> "%LOGFILE%"
REM %SQLCLI% %DEFAULTS_OPT% %AUTH_OPTS% %IMPORT_OPTS% --verbose --comments --binary-mode --force -e "source %PREIMPORT_SQL%" 2> "%LOGFILE%"

REM Save MySQL process exit code (connection / fatal errors)
set "MYSQL_ERRORLEVEL=%ERRORLEVEL%"

REM Remove patched dump from TEMP
if defined PREIMPORT_SQL (
    if exist "%PREIMPORT_SQL%" del "%PREIMPORT_SQL%" >nul 2>&1
)

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
REM Remove patched dump from TEMP (if created)
if defined PREIMPORT_SQL (
    if exist "%PREIMPORT_SQL%" del "%PREIMPORT_SQL%" >nul 2>&1
)

REM Clean up temp directory if it was created
if defined TEMP_SQL_DIR (
    rd /s /q "%TEMP_SQL_DIR%" 2>nul
)

if not exist "%LOGFILE%" (
    echo Import completed with ERRORS.
    echo No log file was created: "%LOGFILE%"
    exit /b 1
)

REM Count number of lines in log file
for /f %%C in ('type "%LOGFILE%" ^| find /v /c ""') do set ERRLINES=%%C
echo Import completed with ERRORS.
echo %ERRLINES% line(s) in "%LOGFILE%".
echo Please review the log file for details.
exit /b 1

param(
    # Path to bin folder with mysql.exe / mariadb.exe
    [string]$SqlBin      = "C:\Program Files\MariaDB 10.5\bin",
    # Client executable name: mysql.exe or mariadb.exe
    [string]$SqlCli      = "mysql.exe",
    [string]$Host        = "localhost",
    [int]   $Port        = 3306,
    [string]$User        = "root",
    [string]$Password,
    [string]$OutDir      = "D:\_db-dumps",
    # Users to skip (system accounts)
    [string[]]$SkipUsers = @("root","mariadb.sys","mysql.sys","mysql.session")
)

# --- Resolve client path ---
$clientPath = Join-Path $SqlBin $SqlCli
if (-not (Test-Path $clientPath)) {
    Write-Error "Client not found: $clientPath"
    exit 1
}

# --- Ask password if not provided ---
if (-not $Password) {
    $secure = Read-Host -AsSecureString "Enter password for $User@$Host"
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringUni(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    )
}

# Use env var instead of putting password into command line
$env:MYSQL_PWD = $Password

# --- Prepare output directory and files ---
if (-not (Test-Path $OutDir)) {
    New-Item -Path $OutDir -ItemType Directory | Out-Null
}

$outFile  = Join-Path $OutDir "users_and_grants.sql"
$logFile  = Join-Path $OutDir "_users_errors.log"

Remove-Item $outFile,$logFile -ErrorAction SilentlyContinue

Write-Host "Exporting users and grants to $outFile"

# --- Helper: run mysql client and return lines ---
function Invoke-SqlCli {
    param(
        [string]$Query
    )
    & $clientPath -h $Host -P $Port -u $User -N -B -e $Query 2>> $logFile
}

# --- 1. Get list of users@hosts (excluding system accounts) ---
$skipSet = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$SkipUsers | ForEach-Object { [void]$skipSet.Add($_) }

$userQuery = @"
SELECT CONCAT(User,'@',Host)
FROM mysql.user
WHERE User <> ''
"@

# If you want to skip system users directly in SQL, you can add:
#   AND User NOT IN ('root','mariadb.sys','mysql.sys','mysql.session')

$rawUsers = Invoke-SqlCli -Query $userQuery

if (-not $rawUsers) {
    Write-Warning "No users found or query failed. See $logFile if exists."
}

# Normalize user@host list and skip system accounts
$userList = @()
foreach ($line in $rawUsers) {
    $parts = $line.Split('@',2)
    if ($parts.Count -ne 2) { continue }
    $u = $parts[0]
    $h = $parts[1]
    if ($skipSet.Contains($u)) { continue }
    $userList += ,@($u,$h)
}

# --- 2. Write header ---
"SET sql_log_bin=0;"            | Out-File -FilePath $outFile -Encoding UTF8
""                              | Out-File -FilePath $outFile -Encoding UTF8 -Append
"-- Users and grants exported from $Host`:$Port on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" `
                                | Out-File -FilePath $outFile -Encoding UTF8 -Append
""                              | Out-File -FilePath $outFile -Encoding UTF8 -Append

# --- 3. For each user: SHOW CREATE USER + SHOW GRANTS ---
foreach ($uh in $userList) {
    $u  = $uh[0]
    $h  = $uh[1]
    $uq = "'$u'@'$h'"

    Write-Host "Processing user $uq"

    # 3.1 SHOW CREATE USER: returns "user<TAB>CREATE USER ...;"
    $createLines = Invoke-SqlCli -Query "SHOW CREATE USER $uq"
    $createSql   = $null
    foreach ($line in $createLines) {
        # Expect 2 columns separated by tab: name and SQL
        $cols = $line -split "`t",2
        if ($cols.Count -eq 2) {
            $createSql = $cols[1]
            break
        }
    }

    if (-not $createSql) {
        # Fallback: minimal CREATE USER
        $createSql = "CREATE USER IF NOT EXISTS $uq;"
    }

    "-- User and grants for $uq" | Out-File -FilePath $outFile -Encoding UTF8 -Append
    $createSql                   | Out-File -FilePath $outFile -Encoding UTF8 -Append

    # 3.2 SHOW GRANTS FOR user
    $grantLines = Invoke-SqlCli -Query "SHOW GRANTS FOR $uq"
    foreach ($g in $grantLines) {
        $g | Out-File -FilePath $outFile -Encoding UTF8 -Append
    }

    ""                          | Out-File -FilePath $outFile -Encoding UTF8 -Append
}

"SET sql_log_bin=1;"            | Out-File -FilePath $outFile -Encoding UTF8 -Append

Write-Host "Done. Users and grants saved to $outFile"
if (Test-Path $logFile) {
    Write-Host "Some errors may be logged in $logFile"
}

# Clear password from environment
Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue

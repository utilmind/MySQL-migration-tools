#!/usr/bin/env bash
# ======================================================================
#  dump-users-and-grants.sh - Export MySQL / MariaDB users and grants
#
#  Part of: MySQL Migration Tools
#  Copyright (c) 2025 utilmind
#  https://github.com/utilmind/MySQL-migration-tools
#
#  Description:
#    Helper script for exporting MySQL / MariaDB users and privileges
#    into a standalone SQL file.
#
#    Connection settings are loaded from:
#      - hard-coded defaults in this script (have highest priority),
#      - .credentials.sh
#      - or .<config>.credentials.sh when --config <config> is used.
#
#    Expected variables in credentials file:
#      dbHost="localhost"
#      dbPort="3306"
#      dbUser="silkcards_dump"
#      dbPass="secret"
#
#    Rules:
#      - HOST / PORT from credentials are used only if empty in this script.
#      - USER from credentials is used only if USER in this script is empty.
#      - If USER == dbUser and PASS is empty, PASS is taken from dbPass.
#      - If USER != dbUser, dbPass is ignored; PASS from this script
#        (or prompt) is used.
#
#    The MySQL client is expected to be available as "mysql" in PATH.
#
#  Usage:
#    dump-users-and-grants.sh [options] /path/to/users-and-grants.sql
#
#    The first non-option argument is the output SQL file path.
#
#  License: MIT
###############################################################################

# --------------------------- CONSTANTS ---------------------------------
# Configuration profile name (used only for picking credentials file)
dbConfigName=""

# MySQL client executable name (from PATH)
SQLCLI="mysql"

# Connection params (defaults defined here have priority over `.credentials.sh`)
# Remember, that requesting user privileges/grants from the system table (`mysql.user`) often requires higher privileges, than usually applied for the data dumper.
# If USER is different than specified in dbUser of `.credentials.sh` and PASS is empty, then you will be prompted for a password.
HOST=""
PORT=""
USER="root"
PASS=""

# Output SQL file (REQUIRED; set via first positional argument)
USERDUMP=""

# Temporary files (will be derived from scriptDir + dbConfigName)
USERLIST=""
TMPGRANTS=""

# Skip system users by default
INCLUDE_SYSTEM_USERS=0

# Optional user name prefixes filter (User LIKE 'PREFIX%')
# Can hold multiple prefixes: ("mydata" "anotherdata" ...)
USER_PREFIXES=()

# System users list (SQL fragment inside NOT IN (...))
SYSTEM_USERS_LIST="'root','mysql.sys','mysql.session','mysql.infoschema',"\
"'mariadb.sys','mariadb.session','debian-sys-maint','healthchecker','rdsadmin'"

# ------------------------ SCRIPT / TEMP DIRS ---------------------------
# Temporary directory for helper files (user list, grants, etc.)
thisScript=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0") # fallback if readlink -f unavailable
scriptDir=$(cd -- "$(dirname -- "$thisScript")" && pwd)
tempDir="$scriptDir/_temp"
mkdir -p "$tempDir"

# --------------------------- HELP --------------------------------------
print_help() {
  cat <<EOF
dump-users-and-grants.sh - Export MySQL / MariaDB users and grants

Usage:
  dump-users-and-grants.sh [options] /path/to/users-and-grants.sql

Options:
  --config NAME        Use .NAME.credentials.sh instead of .credentials.sh
                       for connection settings (dbHost, dbPort, dbUser, dbPass).
  --user-prefix LIST   Export only users whose *name* starts with one of
                       the prefixes in LIST.
                       LIST can be:
                         - single prefix: "mydata"
                         - several prefixes: "mydata anotherdata"
                       (User LIKE 'mydata%' OR User LIKE 'anotherdata%'; host is not filtered).
  --include-system-users
                       Also export system / internal users
                       (root, mysql.sys, mariadb.sys, etc.).
  -h, --help           Show this help and exit.

Notes:
  - Connection settings come from:
      1) constants in this script (HOST/PORT/USER/PASS),
      2) .credentials.sh or .<config>.credentials.sh
         (HOST/PORT only if empty; USER only if empty;
          PASS only if USER == dbUser and PASS is empty).
  - The first non-option argument is the output SQL file path.
EOF
}

# ANSI colors (disabled if NO_COLOR is set or output is not a TTY)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_ERR=$'\033[1;31m'
  C_WARN=$'\033[1;33m'
  C_INFO=$'\033[1;36m'
  C_OK=$'\033[1;32m'
else
  C_RESET='' C_ERR='' C_WARN='' C_INFO='' C_OK=''
fi

log_info() { printf "%s[INFO]%s %s\n" "$C_INFO" "$C_RESET" "$*"; }
log_ok()   { printf "%s[ OK ]%s %s\n" "$C_OK"   "$C_RESET" "$*"; }
log_warn() { printf "%s[WARN]%s %s\n" "$C_WARN" "$C_RESET" "$*"; }
log_err()  { printf "%s[FAIL]%s %s\n" "$C_ERR"  "$C_RESET" "$*"; }

# ------------------------- ARG PARSING ---------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        dbConfigName="$2"; shift 2 ;;
      --user-prefix)
        # allow multiple prefixes in one argument: "--user-prefix 'silk posh'"
        if [[ -n "$2" ]]; then
          local raw="$2"
          shift 2
          # split by whitespace into array
          local parts=()
          # shellcheck disable=SC2206
          parts=($raw)
          for p in "${parts[@]}"; do
            USER_PREFIXES+=("$p")
          done
        else
          log_err "--user-prefix requires an argument"
          exit 1
        fi
        ;;
      --include-system-users)
        INCLUDE_SYSTEM_USERS=1; shift ;;
      -h|--help)
        print_help
        exit 0 ;;
      --)
        shift
        break ;;
      -*)
        log_err "Unknown option: $1"
        echo
        print_help
        exit 1 ;;
      *)
        # First non-option argument is the output file
        if [[ -z "$USERDUMP" ]]; then
          USERDUMP="$1"
          shift
        else
          log_err "Unexpected extra positional argument: $1"
          echo
          print_help
          exit 1
        fi
        ;;
    esac
  done

  # Handle any remaining args after "--"
  while [[ $# -gt 0 ]]; do
    if [[ -z "$USERDUMP" ]]; then
      USERDUMP="$1"
    else
      log_err "Unexpected extra positional argument: $1"
      echo
      print_help
      exit 1
    fi
    shift
  done
}

# -------------------- CREDENTIALS LOADING ------------------------------
load_credentials() {
  local cred_file
  if [[ -n "$dbConfigName" ]]; then
    cred_file="${scriptDir}/.${dbConfigName}.credentials.sh"
  else
    cred_file="${scriptDir}/.credentials.sh"
  fi

  if [[ -f "$cred_file" ]]; then
    log_info "Loading credentials from: ${cred_file}"
    # shellcheck disable=SC1090
    . "$cred_file"
  else
    if [[ -n "$dbConfigName" ]]; then
      log_warn "Credentials file not found: ${cred_file}"
    else
      log_warn "Credentials file not found: ${cred_file}; using built-in defaults."
    fi
  fi

  # Expected variables in credentials:
  #   dbHost, dbPort, dbUser, dbPass
  local credHost="${dbHost:-}"
  local credPort="${dbPort:-}"
  local credUser="${dbUser:-}"
  local credPass="${dbPass:-}"

  # HOST / PORT: use credentials only if still empty
  if [[ -z "$HOST" && -n "$credHost" ]]; then
    HOST="$credHost"
  fi
  if [[ -z "$PORT" && -n "$credPort" ]]; then
    PORT="$credPort"
  fi

  # USER: use credentials only if still empty
  if [[ -z "$USER" && -n "$credUser" ]]; then
    USER="$credUser"
  fi

  # PASS:
  # - If USER == credUser and PASS empty → take credPass.
  # - If USER != credUser → completely ignore credPass.
  if [[ "$USER" == "$credUser" ]]; then
    if [[ -z "$PASS" && -n "$credPass" ]]; then
      PASS="$credPass"
    fi
  fi

  # Fallbacks if some fields are still empty
  [[ -z "$HOST" ]] && HOST="localhost"
  [[ -z "$PORT" ]] && PORT="3306"
  [[ -z "$USER" ]] && USER="root"
}

# ------------------------- MYSQL WRAPPER -------------------------------
run_mysql() {
  "$SQLCLI" "$@"
}

# ------------------------- MAIN LOGIC ----------------------------------
main() {
  parse_args "$@"

  # Require output file
  if [[ -z "$USERDUMP" ]]; then
    log_err "Output SQL file is required. Pass it as the first positional argument."
    echo
    print_help
    exit 1
  fi

  load_credentials

  # Prepare temp filenames based on config name
  local config_tag
  if [[ -n "$dbConfigName" ]]; then
    config_tag="$dbConfigName"
  else
    config_tag="default"
  fi

  USERLIST="${tempDir}/_${config_tag}-user_list.txt"
  TMPGRANTS="${tempDir}/_${config_tag}-grants_tmp.txt"

  # Check that mysql client is available
  if ! command -v "$SQLCLI" >/dev/null 2>&1; then
    log_err "MySQL client '${SQLCLI}' not found in PATH."
    exit 1
  fi

  # Ask for password if still empty (only as a fallback)
  if [[ -z "$PASS" ]]; then
    printf "Enter password for %s@%s (input will be hidden): " "$USER" "$HOST"
    read -r -s PASS
    echo
  fi

  # Clean previous files
  rm -f "$USERLIST" "$TMPGRANTS" "$USERDUMP"

  # For logging: join prefixes into string
  local prefix_log="<none>"
  if [[ ${#USER_PREFIXES[@]} -gt 0 ]]; then
    prefix_log="${USER_PREFIXES[*]}"
  fi

  log_info "Exporting users and grants from ${HOST}:${PORT} using ${SQLCLI}..."
  log_info "Output file: ${USERDUMP}"
  log_info "User prefix filter(s): ${prefix_log}"
  log_info "Connecting as: ${USER}"

  # Build SQL to get user list
  local sql_userlist
  sql_userlist="SELECT CONCAT(\"'\",User,\"'@'\",Host,\"'\") FROM mysql.user WHERE User <> ''"

  # Exclude system users if flag is not set
  if [[ "$INCLUDE_SYSTEM_USERS" -ne 1 ]]; then
    sql_userlist+=" AND User NOT IN (${SYSTEM_USERS_LIST})"
  fi

  # Apply prefixes filter if provided: (User LIKE 'p1%' OR User LIKE 'p2%' ...)
  if [[ ${#USER_PREFIXES[@]} -gt 0 ]]; then
    sql_userlist+=" AND ("
    local first=1
    local p escaped_prefix
    for p in "${USER_PREFIXES[@]}"; do
      [[ -z "$p" ]] && continue
      escaped_prefix=$(printf "%s" "$p" | sed "s/'/''/g")
      if [[ $first -eq 1 ]]; then
        sql_userlist+="User LIKE '${escaped_prefix}%'"
        first=0
      else
        sql_userlist+=" OR User LIKE '${escaped_prefix}%'"
      fi
    done
    sql_userlist+=")"
  fi

  sql_userlist+=" ORDER BY User, Host;"

  # Retrieve user list
  if ! run_mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$PASS" -N -B \
       -e "$sql_userlist" >"$USERLIST"; then
    log_err "Could not retrieve user list (see MySQL error above)."
    exit 1
  fi

  if ! [[ -s "$USERLIST" ]]; then
    if [[ ${#USER_PREFIXES[@]} -gt 0 ]]; then
      log_warn "User list is empty (no users matching prefixes: ${prefix_log}). Nothing to export."
    else
      log_warn "User list is empty. Nothing to export."
    fi
    exit 0
  fi

  # Write header to USERDUMP
  {
    printf -- "-- Users and grants exported from %s:%s on %s\n" \
      "$HOST" "$PORT" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "SET sql_log_bin=0;"
    echo
  } >"$USERDUMP"

  # Loop through users and dump grants
  while IFS= read -r USER_IDENT; do
    [[ -z "$USER_IDENT" ]] && continue

    {
      printf -- "-- User and grants for %s\n" "$USER_IDENT"
      printf "CREATE USER IF NOT EXISTS %s;\n" "$USER_IDENT"
    } >>"$USERDUMP"

    # SHOW GRANTS for each user, then append ';'
    if ! run_mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$PASS" -N -B \
         -e "SHOW GRANTS FOR ${USER_IDENT}" >"$TMPGRANTS"; then
      log_warn "Failed to get grants for ${USER_IDENT} (see MySQL error above)."
      echo >>"$USERDUMP"
      continue
    fi

    while IFS= read -r GRANT_LINE; do
      [[ -z "$GRANT_LINE" ]] && continue
      printf "%s;\n" "$GRANT_LINE" >>"$USERDUMP"
    done <"$TMPGRANTS"

    echo >>"$USERDUMP"
  done <"$USERLIST"

  echo "SET sql_log_bin=1;" >>"$USERDUMP"

  # Cleanup temp files
  rm -f "$USERLIST" "$TMPGRANTS"

  log_ok "Users and grants saved to: ${USERDUMP}"
}

main "$@"

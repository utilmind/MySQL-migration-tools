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
#    Features:
#      - Connects to the server using the configured client binary
#        (mysql or mariadb).
#      - Queries mysql.user to obtain the list of non-system accounts.
#      - Skips internal / system users (root, mysql.sys, etc.) by default.
#      - Optional filter by user name prefix (User LIKE 'prefix%').
#      - For each user, generates SQL statements that:
#          * create the user on the target server (IF NOT EXISTS),
#          * re-apply all privileges using SHOW GRANTS output.
#      - Writes everything into _users_and_grants.sql so that it can be
#        imported before or together with database dumps.
#
#  Usage:
#    Modern (recommended) syntax:
#      dump-users-and-grants.sh [options]
#
#    Legacy positional syntax (for compatibility with Windows .bat style):
#      dump-users-and-grants.sh [SQLBIN] [HOST] [PORT] [USER] [PASSWORD] [OUTDIR] [OUTFILE]
#
#  License: MIT
###############################################################################

# --------------------------- DEFAULTS ----------------------------------
# Path to bin folder (MariaDB or MySQL).
SQLBIN=""

# Client binary name; can be overridden via environment (export SQLCLI=...)
SQLCLI="${SQLCLI:-mysql}"

# Output folder for _users_and_grants.sql
OUTDIR="./_db-dumps"

# Connection params
HOST="localhost"
PORT="3306"
USER="root"
PASS=""

# Output file (can be overridden; if empty, will be set after OUTDIR known)
USERDUMP=""

# Log and temporary files (will be derived from OUTDIR)
LOG=""
USERLIST=""
TMPGRANTS=""

# Skip system users by default
INCLUDE_SYSTEM_USERS=0

# Optional user name prefix filter (User LIKE 'PREFIX%')
USER_PREFIX=""

# System users list (SQL fragment inside NOT IN (...))
SYSTEM_USERS_LIST="'root','mysql.sys','mysql.session','mysql.infoschema',"\
"'mariadb.sys','mariadb.session','debian-sys-maint','healthchecker','rdsadmin'"

# --------------------------- HELP --------------------------------------
print_help() {
  cat <<EOF
dump-users-and-grants.sh - Export MySQL / MariaDB users and grants

Usage:
  dump-users-and-grants.sh [options]

Options:
  --sqlbin PATH        Path to directory with mysql/mariadb client binary.
  --host HOST          Database host (default: ${HOST})
  --port PORT          Database port (default: ${PORT})
  --user USER          Database user (default: ${USER})
  --password PASS      Database password (use with care; if omitted, you will be prompted).
  --outdir DIR         Output directory for generated files (default: ${OUTDIR})
  --outfile FILE       Output SQL file (default: OUTDIR/_users_and_grants.sql)
  --user-prefix PREFIX Export only users whose *name* starts with PREFIX
                       (User LIKE 'PREFIX%'; host is not filtered).
  --include-system-users
                       Also export system / internal users
                       (root, mysql.sys, mariadb.sys, etc.).
  -h, --help           Show this help and exit.

Legacy positional syntax (still supported, but deprecated):
  dump-users-and-grants.sh [SQLBIN] [HOST] [PORT] [USER] [PASSWORD] [OUTDIR] [OUTFILE]

Notes:
  - The script generates:
      * SET sql_log_bin=0; at the beginning,
      * CREATE USER IF NOT EXISTS statements,
      * GRANT statements based on SHOW GRANTS,
      * SET sql_log_bin=1; at the end.
  - Import this file before or together with your database dumps.
EOF
}


# ANSI colors (disabled if NO_COLOR is set or output is not a TTY)
# ------------
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
  local positional=()

  while [[ $# > 0 ]]; do
    case "$1" in
      --sqlbin)
        SQLBIN="$2"; shift 2 ;;
      --host)
        HOST="$2"; shift 2 ;;
      --port)
        PORT="$2"; shift 2 ;;
      --user)
        USER="$2"; shift 2 ;;
      --password)
        PASS="$2"; shift 2 ;;
      --outdir)
        OUTDIR="$2"; shift 2 ;;
      --outfile)
        USERDUMP="$2"; shift 2 ;;
      --user-prefix)
        USER_PREFIX="$2"; shift 2 ;;
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
        positional+=("$1"); shift ;;
    esac
  done

  # Append any remaining parameters as positional
  while [[ $# -gt 0 ]]; do
    positional+=("$1"); shift
  done

  # Legacy positional mapping:
  # [0]=SQLBIN [1]=HOST [2]=PORT [3]=USER [4]=PASS [5]=OUTDIR [6]=OUTFILE
  if [[ ${#positional[@]} -gt 0 ]]; then
    [[ -n "${positional[0]:-}" ]] && SQLBIN="${positional[0]}"
    [[ -n "${positional[1]:-}" ]] && HOST="${positional[1]}"
    [[ -n "${positional[2]:-}" ]] && PORT="${positional[2]}"
    [[ -n "${positional[3]:-}" ]] && USER="${positional[3]}"
    [[ -n "${positional[4]:-}" ]] && PASS="${positional[4]}"
    [[ -n "${positional[5]:-}" ]] && OUTDIR="${positional[5]}"
    [[ -n "${positional[6]:-}" ]] && USERDUMP="${positional[6]}"
  fi
}

# ------------------------- MYSQL WRAPPER -------------------------------
run_mysql() {
  # Usage: run_mysql [mysql options...] -- -e "SQL"
  "${SQLBIN}${SQLCLI}" "$@"
}

# ------------------------- MAIN LOGIC ----------------------------------
main() {
  parse_args "$@"

  # Normalize SQLBIN: add trailing slash if non-empty
  if [[ -n "$SQLBIN" ]]; then
    case "$SQLBIN" in
      */) : ;;
      *)  SQLBIN="${SQLBIN}/" ;;
    esac
    if [[ ! -x "${SQLBIN}${SQLCLI}" ]]; then
      log_err "Client '${SQLCLI}' not found at '${SQLBIN}${SQLCLI}'."
      printf 'Please edit %s and adjust the SQLBIN / SQLCLI variables.\n' "$(basename "$0")" >&2
      exit 1
    fi
  fi

  # Set derived paths
  mkdir -p "$OUTDIR" || {
    log_err "Failed to create output directory: ${OUTDIR}"
    exit 1
  }

  if [[ -z "$USERDUMP" ]]; then
    USERDUMP="${OUTDIR}/_users_and_grants.sql"
  fi
  LOG="${OUTDIR}/_users_errors.log"
  USERLIST="${OUTDIR}/__user-list.txt"
  TMPGRANTS="${OUTDIR}/__grants_tmp.txt"

  # Ask for password if still empty
  if [[ -z "$PASS" ]]; then
    printf "Enter password for %s@%s (input will be hidden): " "$USER" "$HOST"
    read -r -s PASS
    echo
  fi

  # Clean previous files
  rm -f "$LOG" "$USERLIST" "$TMPGRANTS" "$USERDUMP"

  log_info "Exporting users and grants from ${HOST}:${PORT} using ${SQLCLI}..."

  # Build SQL to get user list
  # Base WHERE: non-empty user
  local sql_userlist
  sql_userlist="SELECT CONCAT(\"'\",User,\"'@'\",Host,\"'\") FROM mysql.user WHERE User <> ''"

  # Exclude system users if flag is not set
  if [[ "$INCLUDE_SYSTEM_USERS" -ne 1 ]]; then
    sql_userlist+=" AND User NOT IN (${SYSTEM_USERS_LIST})"
  fi

  # Apply prefix filter if provided: User LIKE 'prefix%'
  if [[ -n "$USER_PREFIX" ]]; then
    # Escape single quotes in prefix, just in case
    local escaped_prefix
    escaped_prefix=$(printf "%s" "$USER_PREFIX" | sed "s/'/''/g")
    sql_userlist+=" AND User LIKE '${escaped_prefix}%'"
  fi

  sql_userlist+=" ORDER BY User, Host;"

  # Retrieve user list
  if ! run_mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$PASS" -N -B \
       -e "$sql_userlist" >"$USERLIST" 2>>"$LOG"; then
    log_err "Could not retrieve user list. See '${LOG}' for details."
    exit 1
  fi

  if ! [[ -s "$USERLIST" ]]; then
    if [[ -n "$USER_PREFIX" ]]; then
      log_warn "User list is empty (no users matching prefix '${USER_PREFIX}'). Nothing to export."
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
         -e "SHOW GRANTS FOR ${USER_IDENT}" >"$TMPGRANTS" 2>>"$LOG"; then
      log_warn "Failed to get grants for ${USER_IDENT}. See '${LOG}' for details."
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

  if [[ -f "$LOG" && ! -s "$LOG" ]]; then
    rm -f "$LOG"
  fi

  if [[ -f "$LOG" ]]; then
    log_warn "Some errors/warnings were recorded in: ${LOG}"
  fi
}

main "$@"

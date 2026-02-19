# MySQL / MariaDB Database Migration Tools

Windows batch (`.bat`) scripts and Linux Bash (`.sh`) utilities for creating SQL dumps of single or multiple databases — either into separate `.sql` files or one combined all-in-one dump (including users and their grants).

The goal is to create a dump that can be easily imported into **any** MySQL or MariaDB server while preserving:

- stored procedures
- functions
- triggers
- views
- DEFINER users
- privileges (grants)
- table options (charsets, collations, row formats)
- data in its *original* encoding, regardless of original server defaults

These tools let you safely move databases between MySQL/MariaDB servers of different versions, OSes, collation defaults, etc.
They also perfect for quick deployments of an empty database structure with all initial triggers and their definers (users).

However, the Windows and Linux versions of the `db-dump` script are not equal.
* the 🪟**Windows** version is designed for complete migration of all databases from one PC to another (make exact copy of all local databases recreating them from scratch), while the purpose of
* the 🐧**Linux** version is to create dumps of *one* specific database using the separate configs for each separate database and the task scheduler/crontab for automatic dumps. Dumps produced by the Linux script don't recreate the entire database; they only import the objects (updated tables, functions, triggers, etc.) contained in the dump.

---

## ✨ Key Features
✔  Transfers all users and their grants/privileges (excluding system users like *root*, *mariadb.sys*, etc).<br />
✔  Ignores system databases (*mysql*, *sys*, *information_schema*, *performance_schema*).<br />
✔  Dumps either separate databases into individual files, or all databases into a single dump (`--one` option in Windows).<br />
✔  Can remove legacy MySQL [compatibility comments](#-about-mysql-compatibility-comments) that interfere with developer comments inside triggers.<br />
✔  Enhances the dump with `CREATE TABLE` statements containing **full original table definitions**, including character sets, collations,
and row formats — ensuring data imports correctly even on servers with different defaults. This avoids issues such
as “duplicate entry” errors caused by differing collations.

---

# 📦 Installation

Installation is intentionally simple and does **not** require pip, dependencies, or root privileges.

```
MySQL-migration-tools/
│
├── db-dump.bat                         (Windows)
├── db-import.bat                       (Windows)
├── dump-users-and-grants.bat           (Windows)
│
└── _db-utils/                          (Linux)
     ├── db-auto-repair.sh
     ├── db-dump.sh
     ├── dump-users-and-grants.sh
     ├── optimize-tables.sh
     ├── strip-mysql-compatibility-comments.py  (this Python script used on Windows environment too)
     └── .sample.credentials.sh         (example of optional profiles)
```

### 🪟 Windows Installation

1. Download the repository or copy the `*.bat` files.
2. Edit `db-dump.bat` and set:
   - PATH to MySQL,
   - HOST, PORT,
   - user/password for dumping. (If password not specified in .bat file, you will be prompted for password.)
3. Run from CMD or PowerShell.

### 🐧 Linux Installation

1. Copy the directory `_db-utils/` with all scripts:

   ```bash
   cp -R MySQL-migration-tools/_db-utils /home/youruser/
   ```

2. Create `credentials`:

   ```bash
   cd /home/youruser/_db-utils
   cp .sample.credentials.sh .credentials.sh
   nano .credentials.sh
   ```

   Fill in:

   ```bash
   dbHost="your-host"
   dbPort="3306"
   dbUser="dumpuser"
   dbPass="yourpassword"
   ```

3. Make scripts executable:

   ```bash
   chmod +x *.sh
   ```

---

# ⚙️ Usage (how to run it)

The main difference between the Windows and Linux versions of `db-dump` script is that
* the 🪟**Windows** version is designed for complete migration of all databases from one PC to another (make exact copy of all local databases recreating them from scratch), while the purpose of
* the 🐧**Linux** version is to create dumps of *one* specific database using the separate configs for each separate database and the task scheduler/crontab for automatic dumps. Dumps produced by the Linux script don't recreate the entire database; they only import the objects (updated tables, functions, triggers, etc.) contained in the dump.

## 🪟 Windows

### Database Dumps with Users

Open `db-dump.bat` in a text editor and review the CONFIG block.

Usage:

```
db-dump.bat                      → dumps all DBs separately
db-dump.bat --one                → all DBs into a single file (_db.sql by default)
db-dump.bat --one=my-dump.sql    → all DBs into a single file with custom name, 'my-dump.sql'
db-dump.bat db1 db2 db3          → dump only selected databases (in separate dumps, since option --one not used)
db-dump.bat --one db1 db2 db3    → one combined SQL for selected DBs
db-dump.bat --one --no-users db1 db2 db3  → one combined SQL w/o information about users and grants, only specified databases.
db-dump.bat db_name --no-data    → dump specified database, DDL only (database structure only, no data). Target file has .ddl.sql extension.
db-dump.bat db_name --ddl        → --ddl option works like --no-data and --no-users combined. Dumps database structure only (DDL) into file with .ddl.sql extension.
```

#### 💡 Notes
* You can also dump remote hosts (not only database server on local PC), specifying
the hostname/IP and in the `%HOST%`/`%PORT%` variables.
* Users and grants are dumped automatically and usually prepended to the overall dump (if not skipped with `--no-users` option or configuration settings).
But you can also run stand-alone [`dump-users-and-grants.bat`](dump-users-and-grants.bat) separately to get the list of all non-system users and
their privileges/grants into SQL file, ready for import into another MySQL/MariaDB database.

### Import dumps

[`db-import.bat`](db-import.bat) supports **.gz**, **.zip** and **.rar** archives, so you don't need to manually extract dump from archive to import dump to the database. Although you should have `WinRar` or `7-Zip` installed and directory with their binaries should be listed in system `PATH`.

Usage:
```
db-import.bat source-dump.sql[.gz]|source-dump.zip|source-dump.rar
```
💡You can edit `db-import.bat` on your local PC and specify hardcoded password, to avoid having to enter a password every time you import dump into the database.

⚠️ If you are importing dumps with huge blobs, make sure that your MySQL/MariaDB **server** *(not mysql.exe, not client app)* is able to accept packets with size used in your dumps. Add something like the following into your `my.ini` (or `my.cnf`).

```ini
[mysqld]
; Allow importing of huge blobs
max_allowed_packet=1G
net_read_timeout=600
net_write_timeout=600
```

---

## 🔐 Secure credentials via `.ini` file (Windows)

On Windows, all `*.bat` scripts ([`db-dump.bat`](db-dump.bat), [`db-import.bat`](db-import.bat), [`dump-users-and-grants.bat`](dump-users-and-grants.bat))
support **optional MySQL client option files** (`.ini` / `.cnf`) to avoid hardcoding passwords
directly inside batch scripts.

### How it works

If a file named:

```
.mysql-client.ini
```

exists **in the same directory** as the `.bat` script, it will be automatically used for
connections via the MySQL option:

```
--defaults-extra-file=.mysql-client.ini
```

If the file **does not exist**, the scripts behave exactly as before and use the
hardcoded/default settings inside the `.bat` file.

> The `.ini` file is **optional**, but when present, its settings have **higher priority**
> than values hardcoded in the batch scripts.

### Recommended usage

- Store credentials and connection-related settings in [`.mysql-client.ini`](.mysql-client.ini)
- Add this file to `.gitignore`
- Restrict file permissions so only your user can read it

### Example [`.mysql-client.ini`](.mysql-client.ini)

```ini
[client]
host=127.0.0.1
port=3306
user=backup_user
password=SuperSecretPassword
default-character-set=utf8mb4

; Optional SSL settings:
# ssl-ca=C:/certs/rds-global-bundle.pem
; The following one is for MySQL only, not available in MariaDB.
# ssl-mode=REQUIRED

[mysqldump]
; Dump-specific options (optional)
max-allowed-packet=1024M
net-buffer-length=4194304
single-transaction
quick
compress
routines
events
triggers
hex-blob
no-tablespaces
;set-gtid-purged=OFF
;column-statistics=0

[mysql]
; Import-specific options (optional)
max-allowed-packet=1024M
net-buffer-length=4194304
```

### Notes

- Common connection settings (`host`, `user`, `password`, SSL, charset) should be placed
  in the `[client]` section.
- The `[mysqldump]` and `[mysql]` sections are **optional** and only needed if you want
  tool-specific overrides.
- You **do not need** to duplicate credentials between sections — MySQL clients inherit
  shared options automatically.
- Use `/` (slashes) or `\\` (double backslashes) in `ssl-ca` path in Windows,
  because `\` are misinterpreted as escape character.

---

## 🐧 Linux

### Database Dumps (single database only)

The Linux version of `db-dump.sh` creates a reliable dump of **one specific database**, using the connection settings stored in
`.credentials.sh` or `.NAME.credentials.sh` (when a configuration profile is provided).

It can dump:

- the **entire database** (structure + data),
- the database **structure only** (with `--no-data` option, e.g. to share/analyze structure w/o exposing data),
- a **selected set of tables** (with or w/o data, if `--no-data` or `--ddl` is used),
- if `--ddl` option is used it dumps only database structure (DDL) into file with `.ddl.sql` extension,
- optionally optimized/analyzed tables before dumping, if `--skip-optimize` is not used.


### **Dump full database (default)**

Using default credentials from [`.credentials.sh`](bash/.sample.credentials.sh) prepared in the same directory with [`db-dump.sh`](bash/db-dump.sh):

```bash
./db-dump.sh /backups/all-tables.sql
```

Using a named configuration profile (e.g. [`.production.credentials.sh`](bash/.sample.credentials.sh)), that allows to select specific database credentials, if you’re running multiple databases on single environment:

```bash
./db-dump.sh /backups/all-tables.sql production
```


### **Date-stamped filename**

If the filename contains an `@` symbol, it is replaced with the current date (**YYYYMMDD**):

```bash
./db-dump.sh "/backups/db-@.sql" production
```
💡 In this case dump is saved to /backups/db-***YYYYMMDD***.sql.<br />
♻️ BTW, use [Garbage Collector](https://github.com/utilmind/garbage-collector) tool to regularly remove outdated dumps (created by schedule/crontab) after a certain number of days.


### **Dump only specific tables**

You can dump only selected tables by listing them **after** the filename and configuration:

```bash
./db-dump.sh /backups/db-@.sql production users orders logs
```
...or tables as quoted list. Both forms are equivalent.
```bash
./db-dump.sh /backups/db-@.sql production "users orders logs"
```

### View help and the list of available options:

```bash
./db-dump.sh --help
```


### **Structure-only dump (`--no-data`)**

The `--no-data` option produces an SQL file containing **only the database schema**, without any table rows.

It additionally removes all:

- `DROP TABLE`
- `DROP VIEW`
- `DROP TRIGGER`
- `DROP FUNCTION` / `DROP PROCEDURE`
- versioned DROP-comments (`/*!50001 DROP ... */`)

This makes the output ideal for:

- schema analysis (including with AI tools),
- sharing database structure without data,
- preparing migration DDL,
- creating diffable schema snapshots.

Example:

```bash
./db-dump.sh --no-data /backups/mydb-@.sql production
```

Specific tables and `--no-data` can be combined:

```bash
./db-dump.sh --no-data /backups/schema-@.sql production users orders
```

### ✅ Schema DDL dump with auto-push to Git (`--ddl-push`)

If you want a **diffable schema snapshot** in Git, `db-dump.sh` can generate a **structure-only** dump and then **commit & push**
the resulting `*.ddl.sql` file into an **existing local clone**.

This is useful for:

- tracking schema evolution over time,
- reviewing DDL changes via PRs,
- keeping an always-up-to-date schema snapshot for deployments.

So you can have a repository that can automatically track ALL changes in your database structure:

<img width="678" height="369" alt="Tracked Differences" src="https://github.com/user-attachments/assets/49821137-b348-46be-9fdd-c5117866ccde" />

#### Command format

```bash
./db-dump.sh --ddl-push /path/to/your-local-repo/database.ddl.sql [configName]
```

- The output file **must be inside** `gitRepoPath` (unless you explicitly set `gitDdlPath` to copy it).
- When `--ddl-push` is used, the script commits and pushes **only if the file actually changed**.
- The script uses a lock file in `/tmp` to avoid concurrent cron runs racing each other.

#### Example: run with a named profile

```bash
./db-dump.sh --ddl-push /home/project-db-ddl/mydb.ddl.sql production
```

---

### 🧾 Example credentials profile (with Git settings)

Create a profile file next to `db-dump.sh`, for example:

- `.production.credentials.sh` (used when you pass `production` as the config name)

Example:

```bash
#!/bin/bash

# DB credentials
dbHost='localhost'
dbPort=3306
dbName=''
dbUser=''
dbPass=''

# Specify as bash array, even if only 1 prefix is used. Strings are not accepted. Only array is ok.
# dbTablePrefix=('table_prefix1_' 'table_prefix2_' 'bot_' 'email_' 'user_')

# ---------------- GIT SETTINGS (for --ddl-push option) ----------------
# Point to an existing local clone
gitRepoPath='/home/project-db-ddl'   # must contain `.git` directory!
# remote/branch names
gitRemoteName='origin'
gitBranchName='master'
#
# Where to store the ddl dump (relative path inside the repo).
# If not specified -- don't copy it to certain path, just commit as is.
# gitDdlPath='ddl/database_name.ddl.sql'
#
# Commit author (if server has no global git config)
gitCommitUsername='ddl-pusher'
gitCommitEmail='ddl-pusher@example.com'

# Optional, if host alias required (different SSH key, bot user, etc.)
#gitRemoteUrl='git@github.com-SSH-KEY-ALIAS:GIT-USERNAME/PROJECT_NAME-db-ddl.git'
```

**Notes**

- `gitRepoPath` must point to an already-cloned repository (no auto-clone).
- If you use multiple SSH keys on the same server, prefer an SSH host alias (e.g. `github.com-myrepo`) and set `gitRemoteUrl`
  accordingly, or set your repo's `origin` URL to the alias.
- `gitCommitUsername` / `gitCommitEmail` affect commit author only (not permissions).

---

### ⏰ Cron example (nightly DDL snapshot)

Example crontab entry that runs every night at **02:10** and logs output:

```cron
10 2 * * * /home/youruser/_db-utils/db-dump.sh --ddl-push /home/project-db-ddl/mydb.ddl.sql production >> /var/log/db-ddl-dump.log 2>&1
```

If you prefer **no logs**:

```cron
10 2 * * * /home/youruser/_db-utils/db-dump.sh --ddl-push /home/project-db-ddl/mydb.ddl.sql production >/dev/null 2>&1
```

Tip: ensure the cron user can `git push` non-interactively (SSH deploy key or PAT via Git credential helper), and that `origin` points
to the correct SSH host alias if you use multiple keys on the same machine.

### Notes & Warnings

⚠️ Ensure your disk has enough free space.
Post-processing requires **the same amount of space** as the dump itself.
You should have at least **2×** the dump size available.

ℹ️ MySQL may output:

```
mysqldump: [Warning] Using a password on the command line interface can be insecure.
```

This is normal and can be ignored — the script just passes the password to `mysqldump` as a command-line parameter.

⭐ Unless `--skip-optimize` is used, `db-dump.sh` automatically optimizes MyISAM tables and analyzes InnoDB tables before dumping.
You can also run optimization manually using stand-alone [`optimize-tables.sh`](optimize-tables.sh) tool.

---

### Exporting Users & Grants (Linux)

The script `dump-users-and-grants.sh` exports MySQL/MariaDB users and their grants into a standalone SQL file.

It loads connection settings from:

- `.credentials.sh`
- or `.NAME.credentials.sh` when using `--config NAME`.

### Examples

#### Export all non-system users:

```bash
./dump-users-and-grants.sh ./user-grants.sql
```

#### Use a specific configuration:

```bash
./dump-users-and-grants.sh --config production ./user-grants.sql
```

Uses `.production.credentials.sh`.

#### Filter by multiple prefixes:

```bash
./dump-users-and-grants.sh ./user-grants.sql --user-prefix "mydb anotherdb"
```

or:

```bash
./dump-users-and-grants.sh ./grants.sql \
    --user-prefix mydb \
    --user-prefix anotherdb
```

#### Include system users:

```bash
./dump-users-and-grants.sh ./grants.sql --include-system-users
```

---

## 🧹 Stand-alone Table Optimization (`optimize-tables.sh`)

The script [`optimize-tables.sh`](bash/optimize-tables.sh) can be used **independently**, without running a full dump.

It safely performs:

- `OPTIMIZE TABLE` on **MyISAM** tables
- `ANALYZE TABLE` on **InnoDB** tables
- Automatically skips unsupported engines
- Never modifies table data or structure
- Excludes backup tables matching `*_backup_*`.<br />
(Because developers often duplicate existing production table to the `tablename_backup_YYYY-MM-DD` when doing important structural
changes or data fixes, to quickly roll back everything if something goes wrong, but `*_backup_*` are really not needed in the dump.)

This tool is ideal for scheduled maintenance (cron) or manual performance checks. [`db-dump.sh`](bash/db-dump.sh) automatically executing
optimization before dump. Dumps are faster after table optimization. This is especially noticeable on MyISAM tables with many changes.

### ✔ How it selects tables

The script supports **three independent modes**:

#### 1) Explicit list of tables (manual mode)

If the **2nd parameter** contains a quoted list of tables:

```bash
./optimize-tables.sh production "table1 table2 log_2025 user_session"
```

Then:

- `dbTablePrefix` is ignored
- Only these tables are inspected
- Their engines are detected via `INFORMATION_SCHEMA`

#### 2) Prefix-based mode (automatic)

If the credentials file defines:

```bash
dbTablePrefix=('user_' 'order_' 'session_')
```

Then only tables starting with these prefixes are optimized/analyzed.

Backup tables are ALWAYS excluded:

```
*_backup_*
```

#### 3) Full-database mode (default)

If **`dbTablePrefix` is not defined** in the configuration (in script body or `.[config-name.]credentials.sh`),
or **defined but empty**,
and **no explicit table list is provided**,

then **all** tables from the database are processed (except `_backup_` tables).

### ✔ Usage (how to run it)

#### Using default credentials (`.credentials.sh`):

```bash
./optimize-tables.sh
```

#### Using a configuration profile (`.production.credentials.sh`):

```bash
./optimize-tables.sh production
```

#### With explicit table list:

```bash
./optimize-tables.sh production "session order user log"
```

### ✔ Cron usage example (Linux)

```bash
0 5 * * * /home/user/_db-utils/optimize-tables.sh production >/dev/null 2>&1
```

Runs daily at 05:00 and keeps the database healthy.

---

## 💬 About MySQL Compatibility Comments

MySQL and MariaDB dumps often include “versioned” compatibility comments such as:

```sql
/*!50003 CREATE*/ /*!50017 DEFINER=`user`@`host`*/ /*!50003 TRIGGER ... END */;
```

These `/*!xxxxx ... */` blocks are executed only on servers with a version number
equal or higher than the encoded one (e.g., `50003` → MySQL 5.0.3). On older versions,
they’re treated as normal comments and ignored.

This mechanism was meant for backward compatibility between MySQL versions, but on
modern MySQL/MariaDB setups, it’s usually unnecessary — and can even cause syntax errors.
For example, if a trigger body contains a developer comment `/* ... */` inside
a versioned block, it may conflict with the outer wrapper and break the SQL import.

The [`strip-mysql-compatibility-comments.py`](bash/strip-mysql-compatibility-comments.py)
**removes these compatibility wrappers** while preserving the real developers comments
in the function/trigger bodies.

Additionally, if a table metadata provided in TSV format, it will also
normalize `CREATE TABLE` statements to include ENGINE, ROW_FORMAT,
DEFAULT CHARSET and COLLATE according to the original server
metadata extracted from information_schema.TABLES.

---

## 🧩 Compatibility Notes

* Some commands in the dump may be incompatible with very old MySQL versions.
  For example, `CREATE USER IF NOT EXISTS` appeared only in MySQL 5.7+.
  If migrating to older versions, replace it with `CREATE USER` and remove the `IF NOT EXISTS` clause.
* If you encounter more incompatibilities, please open a discussion in the [Issues](../../issues) section or submit a pull request — feel free to update this `README` too.

---

## 🕰️ Time zone issues (possibly)

MySQL and MariaDB dumps sometimes contain statements like:

```sql
SET time_zone = 'UTC';
SET time_zone = 'Europe/Berlin';
```

Named time zones (e.g. `'UTC'`, `'America/Los_Angeles'`, `'Europe/Kiev'`) are only recognized if the server has its **time zone tables** populated.
If the tables are missing, the server will produce errors like:

```
ERROR 1298 (HY000): Unknown or incorrect time zone: 'Europe/Kiev'
```

Our post-processing script automatically normalizes the dump to use numeric offsets instead of `UTC`.
It automatically replaces all

```sql
SET time_zone = 'UTC';
to
SET time_zone = '+00:00';
```

Because numeric offsets always work and **do not require** time zone tables.
However, we cannot reliably automatically convert between named non-UTC zones due to daylight saving time changes and various local political decisions.
So, **if you want to keep using *named* time zones, you must load the system time zone database into MySQL or MariaDB**.

### 🪟 Windows users

MariaDB for Windows **does not include** time zone tables.
To enable named time zones, download a prebuilt SQL file from the official MariaDB tzdata repository and import it manually.

#### Official download location:

**https://downloads.mariadb.org/rest-api/mariadb/tzdata/**

Example (2024a release):

- POSIX version (recommended): **https://downloads.mariadb.org/rest-api/mariadb/tzdata/2024a/posix/timezone_posix.sql**
- Full version: **https://downloads.mariadb.org/rest-api/mariadb/tzdata/2024a/full/timezone_full.sql**

Import the file:

```bash
mysql -u root -p mysql < timezone_posix.sql
```

After importing, named time zones such as:

```sql
SET time_zone = 'UTC';
SET time_zone = 'America/New_York';
```

will work correctly on Windows.

### 🐧 Linux / Unix users

On Linux/Unix, time zone files are usually available at:

```
/usr/share/zoneinfo
```

MariaDB/MySQL provide utilities that convert *zoneinfo* into SQL:

```bash
# MySQL or older MariaDB:
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p mysql

# MariaDB specific (if available):
mariadb-tzinfo-to-sql /usr/share/zoneinfo | mysql -u root -p mysql
```

Once imported, the server will fully support all named time zones.

---

## 🧠 Important Things to Remember When Migrating MySQL Databases

1. **Never modify system tables or users**
   (`information_schema`, `performance_schema`, `mysql`, `sys`, and users like `root`, `mariadb.sys`, etc.).
   If system data gets corrupted, reinstall the database server instead of trying to fix it manually.

2. **Do not copy databases as binary files.**
   It might work for MyISAM tables but will fail for InnoDB and others.

3. **Be aware of charset and collation differences between servers.**
   Default character sets often differ between MySQL/MariaDB versions or server configurations.
   The standard `mysqldump` skips charset/collation options if they match the server defaults — which can lead to corrupted data or collation mismatches after import.

   Example:<br />
   A field defined as `UNIQUE index` may reject an insert if the new server’s collation treats certain characters as equivalent.
   For instance, in `utf8mb4_general_ci`, Ukrainian letters **г** and **ґ** are distinct, but in `utf8mb4_uca1400_ai_ci` they are treated as equal.
   So inserting differnt words like Ukrainian “ґрати” (“gate”) after “грати” (“to play”) would trigger a duplicate-key error.
   This script prevents such issues by ensuring each `CREATE TABLE` statement fully specifies its original charset, collation, and options.

4. *(Just a tip)* — Errors during import may flash by unnoticed in the terminal.
   Always redirect them to a log file, e.g.:
   ```bash
   mysql -u root -p < _db-dump.sql > errors.log
   ```
---

## 🛠️ How to repair InnoDB tables

**AK 2025-11-28: it's not related to the migration tools, I just want to keep these notes somewhere to not forget in case of emergency.**

Briefly... In November 2025, I had an incident where I ran out of disk space on a server with InnoDB tables. Unlike MyISAM tables, which are easily reindexed and repaired automatically, broken InnoDB tables are practically impossible to repair.
However, I managed to make a dump from a dead InnoDB tables, from a database where InnoDB engine failed to start.

What I did...
1. Stopped MariaDB/MySQL, e.g.
```bash
systemctl stop mariadb.service
```

2. Found `my.cnf` (MariaDB/MySQL configuration, in my case it was in `/etc/my.cnf.d/` directory) and inserted the following into `[mysqld]` section:
```
[mysqld]
innodb_force_recovery = 5
read_only = 1
skip-slave-start
```

3. Started MariaDB/MySQL, then made a dump.
```bash
systemctl start mariadb.service
./dump.sh ...
```


---

## 🧰 To-Do

- Check locked tables (at least in bash-version, although Windows is good too) and warn user about locks before dump. With prompt to continue or not, if not running by crontab.
- (Maybe) Prepare stand-alone script that will monitor database server for locks and will send email and/or telegram message (remember about limit of telegram message length) if some tables are locked too long.
- (If above will be implemented) Implement an option that will automatically kill processes that hold a locks.
- Detect unsupported COLLATION types in the post-processor script. Display warning (at least) if unsupported collations are detected. Auto-replace unsupported collations if special CLI-option is used.
- Selective user/grant extraction. (When dumping selected databases into separate files, include to dump only the relevant users/grants. We can detect users of only specific databases.)
- SQL dialect converter (MySQL → PostgreSQL, Oracle, etc.) Yes, this is can be complicated for automatic conversions in stored procedures and tiggers, but still possible. Maybe using AI.
- (Maybe) add simple garbage collector to remove outdated dumps in Linux version.

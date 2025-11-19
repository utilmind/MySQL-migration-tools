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
db-dump.bat --ONE                → all DBs into a single file
db-dump.bat db1 db2 db3          → dump only selected DBs
db-dump.bat --ONE db1 db2 db3    → one combined SQL for selected DBs
```

#### 💡 Notes
* You can also dump remote hosts (not only database server on local PC), specifying
the hostname/IP and in the `%HOST%`/`%PORT%` variables.
* Users and grants are dumped automatically and usually prepended to the overall dump (if not skipped).
But you can also run stand-alone [`dump-users-and-grants.bat`](dump-users-and-grants.bat) separately to get the list of all non-system users and
their privileges/grants into SQL file, ready for import into another MySQL/MariaDB database.

---

## 🐧 Linux

### Database Dumps (of single database)

**Single file (recommended).**<br />
Configuration taken from default [`.credentials.sh`](bash/.sample.credentials.sh):

```bash
./db-dump.sh /backups/all-tables.sql
```

**Using configuration profile.**<br />
This one takes credentials from [`.production.credentials.sh`](bash/.sample.credentials.sh):

```bash
./db-dump.sh /backups/all-tables.sql production
```

**Date-stamped filename.**<br />
Dumps all into a single SQL file. Current date in **YYYYMMDD** format substituted instead of **@** character in the file name.

```bash
./db-dump.sh "/backups/db-@.sql" production
```

💡 Use [Garbage Collector](https://github.com/utilmind/garbage-collector) tool to regularly remove outdated dumps (created by schedule/crontab) after a certain number of days.

View help and the list of available options:

```bash
./db-dump.sh --help
```

⚠️ Always make sure that device has enough space for dumps. Remember that post-processing of dump requires the same amount of disk space as the dump itself! Therefore, free up a size twice larger than needed for the dump.<br />
ℹ️ MySQL (not MariaDB) can display a warning like `mysqldump: [Warning] Using a password on the command line interface can be insecure.`
Yes, it's definitely is, but ignore this warning. This is simply the password entered or specified in the configuration,
which is substituted when calling mysqldump as a command-line parameter.<br />
⭐ If `--skip-optimize` option is not used [`db-dump.sh`](db-dump.sh) usually optimizing all MyISAM tables and analyzing InnoDB tables before each dump. But you can optimize/analyze your tables separately with [`optimize-tables.sh`](optimize-tables.sh) utility.

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

## Time zone issues

MySQL and MariaDB dumps sometimes contain statements like:

```sql
SET time_zone = 'UTC';
SET time_zone = 'Europe/Berlin';
```

Named time zones (e.g. `'UTC'`, `'Europe/Kiev'`) are only recognized if the server has its **time zone tables** populated.
If the tables are missing, the server will produce errors like:

```
ERROR 1298 (HY000): Unknown or incorrect time zone: 'America/Los_Angeles'
```

Our post-processing script automatically normalizes the dump to use numeric offsets instead of `UTC`.
It automatically replaces all

```sql
SET time_zone = 'UTC';
```

to

```sql
SET time_zone = '+00:00';
```

Because numeric offsets always work and **do not require** time zone tables.
However we can’t automatically fix other time zones due to summer and winter time shifts and various local political decisions.
So, **if you want to keep using named time zones, you must load the system time zone database into MySQL or MariaDB**.

---

## Windows users (MariaDB / MySQL)

MariaDB for Windows **does not include** time zone tables.
To enable named time zones, download a prebuilt SQL file from the official MariaDB tzdata repository and import it manually.

### Official download location:

**https://downloads.mariadb.org/rest-api/mariadb/tzdata/**

Example (2024a release):

- POSIX version (recommended):  
  **https://downloads.mariadb.org/rest-api/mariadb/tzdata/2024a/posix/timezone_posix.sql**
- Full version:  
  **https://downloads.mariadb.org/rest-api/mariadb/tzdata/2024a/full/timezone_full.sql**

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

---

## Linux / Unix users

On Linux/Unix, time zone files are usually available at:

```
/usr/share/zoneinfo
```

MariaDB/MySQL provide utilities that convert this directory into SQL:

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

## 🧰 To-Do

- Selective user/grant extraction. (When dumping selected databases, include to dump only the relevant users/grants.)
- SQL dialect converter (MySQL → PostgreSQL, Oracle, etc.) Yes, this is can be complicated for automatic conversions in stored procedures and tiggers, but still possible. Maybe using AI.
- (Maybe) add simple garbage collector to remove outdated dumps in Linux version.

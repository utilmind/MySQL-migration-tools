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

---

## ✨ Key Features
✔  Transfers all users and their grants/privileges (excluding system users like *root*, *mariadb.sys*, etc).<br />
✔  Ignores system databases (*mysql*, *sys*, *information_schema*, *performance_schema*).<br />
✔  Dumps either separate databases into individual files, or all databases into a single dump (`--one` option).<br />
✔  Can remove legacy MySQL compatibility comments that interfere with developer comments inside triggers.<br />
✔  Enhances the dump with `CREATE TABLE` statements containing **full original table definitions**, including character sets, collations, and row formats — ensuring data imports correctly even on servers with different defaults. This avoids issues such as “duplicate entry” errors caused by differing collations.

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

# ⚙️ Usage

## 🪟 Windows

### Database Dumps

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
But you can also run `dump-users-and-grants.bat` separately to get the list of all non-system users and
their privileges/grants into SQL file, ready for import into another MySQL/MariaDB database.

---

## 🐧 Linux

### Database Dumps

Single file (recommended).<br />
Configuration taken from default [`.credentials.sh`](bash/.sample.credentials.sh):

```bash
./db-dump.sh /backups/all-dbs.sql
```

Using configuration profile.<br />
This one takes credentials from [`.production.credentials.sh`](bash/.sample.credentials.sh):

```bash
./db-dump.sh /backups/all-dbs.sql production
```

Date-stamped filename.<br />
Dumps all into a single SQL file. Current date in **YYYYMMDD** format substituted instead of **@** character in the file name.

```bash
./db-dump.sh "/backups/db-@.sql" production
```

View help:

```bash
./db-dump.sh --help
```

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

# 💬 About MySQL Compatibility Comments

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

# 🧠 Migration Advice

1. Never modify system DBs manually (`mysql`, `sys`, …)  
2. Don’t copy raw InnoDB files  
3. Always dump with full charset/collation info  
4. Log imports during debugging:

```bash
mysql < dump.sql > errors.log 2>&1
```

---

# 🧰 To-Do

- Selective user/grant extraction. (When dumping selected databases, include to dump only the relevant users/grants.)  
- SQL dialect converter (MySQL → PostgreSQL, Oracle, etc.) Yes, this is complicated for stored functions and tiggers,
but still possible, maybe using AI.

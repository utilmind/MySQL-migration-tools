# MySQL / MariaDB Database Migration Tools

Windows batch (`.bat`) scripts for creating SQL dumps of single or multiple databases — either into separate `.sql` files or one combined all-in-one dump (including all users and their grants).

The goal is to create a dump that can be easily imported into any MySQL or MariaDB server, preserving **stored procedures, functions, triggers, views, user accounts (definers) with their privileges and the data in the original (not default!) encoding and collation**.

You can create the dump on a Windows machine but import it into any MySQL/MariaDB server, not necessarily running on Windows.

This tool is also perfect for quickly deploying an empty database structure with all initial triggers and definers (users).

---

## ✨ Key Features
✔ Transfers all users and their grants/privileges (excluding system users like *root*, *mariadb.sys*, etc).<br />
✔ Ignores system databases (*mysql*, *sys*, *information_schema*, *performance_schema*).<br />
✔ Dumps either separate databases into individual files, or all databases into a single dump (`--one` option).<br />
✔ Can remove legacy MySQL compatibility comments that interfere with developer comments inside triggers.<br />
✔ Enhances the dump with `CREATE TABLE` statements containing **full original table definitions**, including character sets, collations, and row formats — ensuring data imports correctly even on servers with different defaults. This avoids issues such as “duplicate entry” errors caused by differing collations.

---

## ⚙️ Usage

### 🪟 Windows

Before using, **open `db-dump.bat` in a text/code editor** and review the configuration (in CONFIG section inside).

* `db-dump.bat` — dumps all databases separately (+ `mysql.sql`)
* `db-dump.bat --ONE` — dumps all databases into a single file `_databases.sql` (case-insensitive).
  * *Excludes system databases:* `mysql`, `information_schema`, `performance_schema`, `sys`.
* `db-dump.bat db1 db2 db3` — dumps only the listed databases (separately).
* `db-dump.bat --ONE db1 db2 db3` — dumps only the listed databases into a single `_databases.sql`.

💡 You can also dump remote hosts, specifying the hostname/IP and in the `%HOST%`/`%PORT%` variables.

### 🐧 Linux

**Open `bash/db-dump.sh` in a text/code editor** and review the configuration (in CONFIG section inside).<br />
Then copy content of `bash` directory to your server instance.

* `db-dump.sh /path/dump-name.sql configuration-name` — dumps all databases into a single SQL file using connection settings from the configuration file named `.configuration-name.credentials.sh` in the same directory where `db-dump.sh` is located. If configuration-name not specified, all settings will be taken from `.credentials.sh`.
* `db-dump.sh /path/dump-name.sql` — dumps all databases into a single SQL file. Configuration (connection settings, and credentials, username/password) will be taken from `.credentials.sh` located in the same directory with `db-dump.sh`.
* `db-dump.sh --help` — displays help.

⚠️ MySQL (not MariaDB) can display a warning like
mysqldump: [Warning] Using a password on the command line interface can be insecure.
Yes, it's definitely is, but ignore this warning. This is simply the password entered or specified in the configuration,
which is substituted when calling mysqldump as a command-line parameter.

---

## 💬 About MySQL Compatibility Comments

MySQL and MariaDB dumps often include “versioned” compatibility comments such as:

```sql
/*!50003 CREATE*/ /*!50017 DEFINER=`user`@`host`*/ /*!50003 TRIGGER ... END */;
```

These `/*!xxxxx ... */` blocks are executed only on servers with a version number equal or higher than the encoded one (e.g., `50003` → MySQL 5.0.3). On older versions, they’re treated as normal comments and ignored.

This mechanism was meant for backward compatibility between MySQL versions, but on modern MySQL/MariaDB setups, it’s usually unnecessary — and can even cause syntax errors.
For example, if a trigger body contains a developer comment `/* ... */` inside a versioned block, it may conflict with the outer wrapper and break the SQL import.

The script [`strip-mysql-compatibility-comments.py`](strip-mysql-compatibility-comments.py) **removes these legacy wrappers** while preserving all regular comments and function/trigger bodies.
The result: a clean, readable, and portable dump that imports without issues on modern MySQL/MariaDB servers, while keeping all your developer comments intact.

---

## 🧩 Compatibility Notes

* Some commands in the dump may be incompatible with very old MySQL versions.
  For example, `CREATE USER IF NOT EXISTS` appeared only in MySQL 5.7+.
  If migrating to older versions, replace it with `CREATE USER` and remove the `IF NOT EXISTS` clause.
* If you encounter more incompatibilities, please open a discussion in the [Issues](../../issues) section or submit a pull request — feel free to update this `README` too.

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

* When dumping selected databases, include only the relevant users/grants.
* Maybe when I get inspired (or someone pays me :) Create a converter that translates MySQL syntax into SQL compatible with Postgres, Oracle, etc.

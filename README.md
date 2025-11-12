# MySQL / MariaDB Database Migration Tools

Windows batch (`.bat`) scripts for creating SQL dumps of single or multiple databases — either into separate `.sql` files or one combined all-in-one dump (including all users and their grants).

The goal is to create a dump that can be easily imported into any MySQL or MariaDB server, preserving **stored procedures, functions, triggers, views, and user accounts (definers) with their privileges**.

You can create the dump on a Windows machine and import it into any other MySQL or MariaDB server — not necessarily running on Windows.

This tool is also perfect for quickly deploying an empty database structure with all initial triggers and definers intact.

---

## ✨ Key Features
✔ Transfers all users and their grants/privileges (excluding system users like *root*, *mariadb.sys*, etc).  
✔ Ignores system databases (*mysql*, *sys*, *information_schema*, *performance_schema*).  
✔ Dumps either separate databases into individual files, or all databases into a single dump (`--one` option).  
✔ Can remove legacy MySQL compatibility comments that interfere with developer comments inside triggers.  
✔ Enhances the dump with `CREATE TABLE` statements containing **full original table definitions**, including character sets, collations, and row formats — ensuring data imports correctly even on servers with different defaults. This avoids issues such as “duplicate entry” errors caused by differing collations.

---

## ⚙️ Usage

Before using, **open `db-migration.bat` in a text/code editor** and configure the path to your MySQL/MariaDB executables (and optionally other parameters — see the CONFIG section inside).

* `db-migration.bat` — dumps all databases separately (+ `mysql.sql`)  
* `db-migration.bat --ONE` — dumps all databases into a single file `_databases.sql` (case-insensitive).  
  * *Excludes system databases:* `mysql`, `information_schema`, `performance_schema`, `sys`.  
* `db-migration.bat db1 db2 db3` — dumps only the listed databases (separately).  
* `db-migration.bat --ONE db1 db2 db3` — dumps only the listed databases into a single `_databases.sql`.

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

   Example:  
   A field defined as `UNIQUE` may reject an insert if the new server’s collation treats certain characters as equivalent.  
   For instance, in `utf8mb4_general_ci`, Ukrainian letters **г** and **ґ** are distinct, but in `utf8mb4_uca1400_ai_ci` they are treated as equal.  
   So inserting “ґрати” (“gate”) after “грати” (“to play”) would trigger a duplicate-key error.  
   This script prevents such issues by ensuring each `CREATE TABLE` statement fully specifies its original charset, collation, and options.

4. *(Just a tip)* — Errors during import may flash by unnoticed in the terminal.  
   Always redirect them to a log file, e.g.:  
   ```bash
   mysql -u root -p < _db-dump.sql > errors.log
   ```

---

## 🧰 To-Do

* When dumping selected databases, include only the relevant users/grants.  
* (Maybe someday 😄) Create a converter that translates MySQL syntax into SQL compatible with Postgres, Oracle, etc.  
* Possibly port these `.bat` scripts to Bash for Linux environments (in a separate repository).  
  The [`strip-mysql-compatibility-comments.py`](strip-mysql-compatibility-comments.py) script, however, is cross-platform and works everywhere.

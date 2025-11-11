Windows batch (.bat) scripts to make a dump for single or multiple databases into multiple separate .SQL-files OR ALL databases + ALL users and their grants into one single big SQL dump.

The goal is to make a dump that can be easily imported into MySQL/MariaDB, with all stored producedures, functions, triggers, views and of course users (definers) with their grants/privileges.

You make dump on Windows PC, which can be imported into any other MySQL or MariaDB server. Not necessarily hosted on Windows.

This also great for quick dump and deployment an empty database structure with all initial triggers and their definers.

# Usage
* `db-migration.bat`                   -> dump all databases separately (+ mysql.sql)
* `db-migration.bat --ONE`             -> dump all databases into ONE filem _databases.sql (just add `one`, case insensitive)<br />
&nbsp;&nbsp; &nbsp;&nbsp; <i>* EXCEPT system tables: `mysql`, `information_schema`, `performance_schema`, `sys`.</i>
* `db-migration.bat db1 db2 db3`       -> dump only listed databases separately.
* `db-migration.bat --ONE db1 db2 db3` -> dump only listed databases into single SQL, _databases.sql.

# Compatibility notes
* Some used commands are compatible with very old versions of MySQL. For example, `CREATE USER IF NOT EXISTS` appeared in syntax starting from MySQL 5.7.
So if you need to migrate very old data, replace it to just `CREATE USER` and remove `IF NOT EXISTS`.
* Google about more incompatibilities between MySQL and MariaDB. If there is something important, please pull your fix to this repo.

# ToDo
* When we dump selected databases, let's dump users/grants only for selected databases.
* Maybe when I get inspired (or someone pays me), I’ll make a tool that converts the MySQL syntax into SQLs compatible with Postgres, Oracle, etc. A simple tool for migrations between MySQL/MariaDB and PostgresSQL. I’m actually sure that something for migration between MySQL to PostgresSQL are already available, but still interested to build my own tool one day.

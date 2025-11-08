Windows batch (.bat) script to make a dump for single or multiple databases separately into different .SQL-files OR ALL databases including ALL users.

The goal is to make a dump that can be easily imported into MySQL/MariaDB database, with all stored producedures, functions, triggers and users (definers).

# Usage:
* `db-migration.bat`               -> dump all databases separately (+ mysql.sql)
* `db-migration.bat ALL`           -> dump all databases into one file all_databases.sql (just add `all`, case insensitive)
* `db-migration.bat db1 db2 db3`   -> dump only listed databases separately

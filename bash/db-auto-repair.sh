#!/bin/bash
. "$(dirname "$BASH_SOURCE")/.credentials.sh"
#
# (c) https://github.com/utilmind
#
# This script good for crontab, set on @reboot:
#     @reboot /var/www/_db_utils/mysql_auto_repair.sh
#
# However it's good only for local database only. Not needed for RDS instances of AWS, they are maintained separately.

# check & auto-repair mySQL tables
mysqlcheck --check --auto-repair --verbose --host=$dbHost --port=$dbPort --databases $dbName --user=$dbUser --password=$dbPass
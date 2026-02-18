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

# Optional, if hist alias required. If local repository points to different origin or cloned under different user/key.
#gitRemoteUrl='git@github.com-SSH-KEY-ALIAS:GIT-USERNAME/PROJECT_NAME-db-ddl.git'

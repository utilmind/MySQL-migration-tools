#!/bin/bash

# DB credentials
dbHost='localhost'
dbPort=3306
dbName=''
dbUser=''
dbPass=''

# Specify as bash array, even if only 1 prefix is used. Strings are not accepted. Only array is ok.
# dbTablePrefix=('table_prefix1_' 'table_prefix2_' 'bot_' 'email_' 'user_')

# ---------------- GIT SETTINGS (for db-dump.sh --ddl-push) ----------------
# Point to an existing local clone
# git_repo_path='/opt/db-ddl-repo'   # must contain `.git` directory!
#
# Optional: remote/branch names
# git_remote_name='origin'
# git_branch_name='main'
#
# Where inside the repo to store the ddl dump (relative path)
# git_ddl_path='ddl/your_database_name.ddl.sql'
#
# Optional: commit author (if server has no global git config)
# git_commit_username='db-dump-bot'
# git_commit_email='db-dump-bot@example.com'
#
# Optional: SSH private key path (if you want to force a specific key)
# git_ssh_key_path='/home/user/.ssh/id_ed25519'

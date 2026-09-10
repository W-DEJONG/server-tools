# Server tools

This package contains scripts for installing and maintaining Debian web servers.

Supported Debian releases: **12 (bookworm)** and **13 (trixie)**.

The entry command is `server-tool`.

Usage:
```shell
# Basic command
server-tool <command> [-y]

# Skip confirmation prompts
server-tool <command> -y

# Self maintenance
server-tool self-install
server-tool self-update

# Initial server configuration
server-tool init-server
server-tool init-server -y

# Install application packages
server-tool install <package> [<version> ...] [<package> ...] [-y]

# Available packages
server-tool install nginx
server-tool install php
server-tool install php -y 8.4 8.5
server-tool install npm
server-tool install npm -y 24
server-tool install cachetool
server-tool install composer
server-tool install composer --version 2.8.12
server-tool install composer -y
server-tool install mariadb-server
server-tool install mariadb-client
server-tool install mysql
server-tool install mysql-client
server-tool install postgresql
server-tool install postgresql -y 17 18
server-tool install memcached
server-tool install redis
server-tool install meilisearch
server-tool install aws
server-tool install aws my-backups
server-tool install aws my-backups -y
server-tool install postgresql redis php 8.4 -y

# Install web application users and folders
server-tool create-user <username> [-p <php-version>] [-y]
server-tool create-sudo-user <username> [-k <ssh-public-key-or-file>] [--no-password] [-y]
server-tool delete-user <username> [-y]
server-tool create-app <username> <application> [-u] [-d <db_name>] [-t pgsql|mysql] [--host <host>] [--port <port>] [--admin-user <user>] [--admin-password <password>] [--user-host <mysql-user-host>] [-p <php-version>] [-y]
server-tool create-app testdev demo -u -d mijnapp -p 8.4 -y
server-tool create-app testdev demo -u -d mijnapp -t mysql -y
server-tool create-app testdev demo -d mijnapp -t mysql --host db.internal --admin-user root -y
server-tool create-app testdev demo -d mijnapp -t pgsql --host db.internal --admin-user postgres -y
server-tool list-apps
server-tool delete-app <username> <application> [-y]
server-tool rename-app <username> <application> <new_name> [--keep-domain] [-y]
server-tool switch-php <username> <application> [-p <php-version>] [-y]
server-tool enable-ssl <username> <application> [-d <domain>] [-e <email>] [--self-signed] [--renew] [-y]
server-tool enable-basic-auth <username> <application> <auth_user> [-r <realm>] [-y]
server-tool disable-ssh-password [-y]
server-tool create-horizon <username> <application> [-p <php-version>] [-n <numprocs>] [-y]
server-tool create-queue <username> <application> [-p <php-version>] [-n <numprocs>] [-q <queue>] [-c <connection>] [--tries <n>] [--timeout <seconds>] [--sleep <seconds>] [-y]
server-tool apply-cron <username> <application> [-y]
server-tool enable-scheduler <username> <application> [-p <php-version>] [-y]
server-tool disable-scheduler <username> <application> [-y]
server-tool create-db <db_name> [-t pgsql|mysql] [--host <host>] [--port <port>] [--admin-user <user>] [--admin-password <password>] [--user-host <mysql-user-host>] [-y]
server-tool create-db mijnapp -t mysql --host db.internal --admin-user root
server-tool create-db mijnapp -t pgsql --host db.internal --admin-user postgres
# omit --admin-password to be prompted (like mysql -p)
server-tool dump-db <username> <application> [<target-folder>] [-y]
server-tool restore-db <username> <application> <file> [-y]
server-tool backup-app <username> <application> [-y]
server-tool backup-app testdev demo -y
server-tool backup-app <username> <application> --enable [-y]
server-tool backup-app <username> <application> --disable [-y]
server-tool test-backup [-y]
# /etc/server-tool/backup.conf is written by: server-tool install aws <bucket>
# S3_BUCKET=my-backups
# S3_REGION=eu-central-1
# SERVER_NAME=web-1
server-tool create-github-runner <url> <token> [-n <name>] [-l <labels>] [-u <username>] [-y]
server-tool create-github-runner https://github.com/my-org AAAA -n web-1 -l deploy -y
```

Install:
```shell

# Clone and install server tools repo
cd /usr/local/lib
git clone git@github.com/W-DEJONG/server-tools
ln -s /usr/local/lib/server-tools/server-tool /usr/local/bin/server-tool
```

Testing with Docker:
```shell
# Start Debian 12 and 13 test servers (systemd, repo mounted live)
docker compose up -d --build

# Interactive shell on Debian 12 or 13
docker compose exec bookworm bash
docker compose exec trixie bash

# Inside the container, server-tool is on PATH
server-tool init-server -y
server-tool install php -y 8.5

# Automated smoke test
docker compose exec bookworm /usr/local/lib/server-tools/docker/smoke-test.sh
docker compose exec trixie /usr/local/lib/server-tools/docker/smoke-test.sh

docker compose down
```

Nginx in the test containers is published on `localhost:8080` (bookworm) and `localhost:8081` (trixie).

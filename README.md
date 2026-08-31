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
server-tool install mariadb-server
server-tool install mariadb-client
server-tool install postgresql
server-tool install postgresql -y 17 18
server-tool install memcached
server-tool install redis
server-tool install aws
server-tool install postgresql redis php 8.4 -y

# Install web application users and folders
server-tool create-user <username> [-p <php-version>] [-y]
server-tool delete-user <username> [-y]
server-tool create-app <username> <application> [-u] [-d <db_name>] [-p <php-version>] [-y]
server-tool create-app testdev demo -u -d mijnapp -p 8.4 -y
server-tool delete-app <username> <application> [-y]
server-tool create-db <db_name> [-y]
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

# Automated smoke test (skips AWS; that package needs an EC2 IAM role)
docker compose exec bookworm /usr/local/lib/server-tools/docker/smoke-test.sh
docker compose exec trixie /usr/local/lib/server-tools/docker/smoke-test.sh

docker compose down
```

Nginx in the test containers is published on `localhost:8080` (bookworm) and `localhost:8081` (trixie).

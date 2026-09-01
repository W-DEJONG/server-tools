#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
php_version="$(tail -1 "$repo_dir/templates/php-versions")"
node_version="$(tail -1 "$repo_dir/templates/node-versions")"
postgres_version="$(tail -1 "$repo_dir/templates/postgresql-versions")"

if [ "${EUID}" -ne 0 ]; then
    echo "Run this smoke test as root inside the test container."
    exit 1
fi

echo "==> Debian $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "==> server-tool: $(command -v server-tool)"

echo "==> Unknown command is rejected"
if server-tool definitely-not-a-command; then
    echo "Expected unknown command to fail"
    exit 1
fi

echo "==> create-github-runner requires arguments"
if server-tool create-github-runner -y; then
    echo "Expected create-github-runner without arguments to fail"
    exit 1
fi

echo "==> init-server"
server-tool init-server -y

echo "==> install nginx"
server-tool install nginx -y

echo "==> install php ${php_version}"
server-tool install php -y "$php_version"

echo "==> install npm ${node_version}"
server-tool install npm -y "$node_version"

echo "==> install cachetool"
server-tool install cachetool -y

echo "==> install memcached"
server-tool install memcached -y

echo "==> install redis"
server-tool install redis -y

echo "==> install meilisearch"
server-tool install meilisearch -y
systemctl is-active --quiet meilisearch
curl -sf http://127.0.0.1:7700/health >/dev/null

echo "==> install postgresql ${postgres_version}"
server-tool install postgresql -y "$postgres_version"

echo "==> create-db smoke_testdb"
server-tool create-db smoke_testdb -y
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'smoke_testdb'" | grep -qx 1

echo "==> install mariadb-server"
server-tool install mariadb-server -y

echo "==> create-user testdev ${php_version}"
server-tool create-user testdev -y -p "$php_version"

echo "==> create-app testdev demo"
server-tool create-app testdev demo -y

echo "==> verify application layout"
test -d /home/testdev/demo/current/public
test -d /home/testdev/demo/nginx
test -f /home/testdev/demo/php-fpm/demo.conf
test -f /home/testdev/demo/nginx/demo.conf
grep -q "current/public" /home/testdev/demo/nginx/demo.conf
grep -q "php${php_version}-fpm-testdev-demo.sock" /home/testdev/demo/nginx/demo.conf
grep -q "php${php_version}-fpm-testdev-demo.sock" /home/testdev/demo/php-fpm/demo.conf
test -f /etc/php/${php_version}/fpm/pool.d/testdev_demo.conf
test -f /etc/nginx/conf.d/testdev_demo.conf

echo "==> delete-app testdev demo"
server-tool delete-app testdev demo -y
test ! -e /home/testdev/demo
test ! -e /etc/nginx/conf.d/testdev_demo.conf
test ! -e "/etc/php/${php_version}/fpm/pool.d/testdev_demo.conf"

echo "==> verify packages"
"php${php_version}" -v
node -v
npm -v
nginx -v
psql --version
redis-cli ping
test -x /usr/local/bin/cachetool

echo "==> smoke test passed"

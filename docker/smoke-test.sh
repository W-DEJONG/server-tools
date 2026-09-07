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

echo "==> create-sudo-user smokeadmin"
ssh-keygen -t ed25519 -N "" -f /tmp/smokeadmin -C smokeadmin@test -q
server-tool create-sudo-user smokeadmin -y -k /tmp/smokeadmin.pub
id smokeadmin
id -nG smokeadmin | grep -qw sudo
test -d /home/smokeadmin/.ssh
test -s /home/smokeadmin/.ssh/authorized_keys
grep -qxF "$(cat /tmp/smokeadmin.pub)" /home/smokeadmin/.ssh/authorized_keys
[ "$(getent shadow smokeadmin | cut -d: -f3)" = "0" ]
grep -qxF "export LS_OPTIONS='--color=auto'" /home/smokeadmin/.bashrc

echo "==> create-sudo-user smokenopass --no-password"
ssh-keygen -t ed25519 -N "" -f /tmp/smokenopass -C smokenopass@test -q
server-tool create-sudo-user smokenopass --no-password -y -k /tmp/smokenopass.pub
id smokenopass
id -nG smokenopass | grep -qw sudo
grep -qxF "$(cat /tmp/smokenopass.pub)" /home/smokenopass/.ssh/authorized_keys
[ -z "$(getent shadow smokenopass | cut -d: -f2)" ]
[ "$(getent shadow smokenopass | cut -d: -f3)" = "0" ]

echo "==> create-user testdev ${php_version}"
server-tool create-user testdev -y -p "$php_version"
id -nG testdev | grep -qw nginx

echo "==> disable-ssh-password"
server-tool disable-ssh-password -y
grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config.d/10-server-tool.conf
grep -q '^KbdInteractiveAuthentication no' /etc/ssh/sshd_config.d/10-server-tool.conf
grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config.d/10-server-tool.conf
sshd -t

echo "==> create-app testdev demo"
server-tool create-app testdev demo -y

echo "==> verify application layout"
test -d /home/testdev/demo/install/public
test -L /home/testdev/demo/current
test "$(readlink /home/testdev/demo/current)" = install
test -f /home/testdev/demo/current/public/index.php
grep -q "phpinfo();" /home/testdev/demo/install/public/index.php
test -d /home/testdev/demo/releases
getfacl /home/testdev/demo/install | grep -q "user:nginx:r-x"
test -d /home/testdev/demo/nginx
test -d /home/testdev/demo/nginx/ssl
getfacl /home/testdev | grep -q "user:nginx:--x"
getfacl /home/testdev/demo | grep -q "user:nginx:--x"
getfacl /home/testdev/demo/releases | grep -q "user:nginx:r-x"
getfacl /home/testdev/demo/releases | grep -q "default:user:nginx:r-x"
test -f /home/testdev/demo/php-fpm/demo.conf
test -f /home/testdev/demo/nginx/demo.conf
grep -q "current/public" /home/testdev/demo/nginx/demo.conf
grep -q "php${php_version}-fpm-testdev-demo.sock" /home/testdev/demo/nginx/demo.conf
grep -q "php${php_version}-fpm-testdev-demo.sock" /home/testdev/demo/php-fpm/demo.conf
grep -q "listen.owner = nginx" /home/testdev/demo/php-fpm/demo.conf
grep -q "listen.group = nginx" /home/testdev/demo/php-fpm/demo.conf
test -f /etc/php/${php_version}/fpm/pool.d/testdev_demo.conf
test -f /etc/nginx/conf.d/testdev_demo.conf
test -d /home/testdev/demo/supervisor
test -L /etc/supervisor/conf.d/testdev_demo.d
test -f /home/testdev/demo/nginx/auth.inc

echo "==> create-horizon testdev demo"
server-tool create-horizon testdev demo -y
test -f /home/testdev/demo/supervisor/horizon.conf
grep -q "php${php_version} artisan horizon" /home/testdev/demo/supervisor/horizon.conf
grep -q "directory=/home/testdev/demo/current/" /home/testdev/demo/supervisor/horizon.conf
test -L /etc/supervisor/conf.d/testdev_demo.d

echo "==> enable-basic-auth testdev demo tester"
server-tool enable-basic-auth testdev demo tester -r Staging -y
grep -q 'auth_basic "Staging"' /home/testdev/demo/nginx/auth.inc
test -s /home/testdev/demo/nginx/.htpasswd

echo "==> enable-ssl testdev demo --self-signed"
server-tool enable-ssl testdev demo -d demo.example.test --self-signed -y
grep -q "listen 443 ssl" /home/testdev/demo/nginx/demo.conf
test -f /home/testdev/demo/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo/nginx/ssl/demo.example.test.key
grep -q "return 301 https" /home/testdev/demo/nginx/demo.conf

echo "==> enable-ssl testdev demo --self-signed --renew"
server-tool enable-ssl testdev demo -d demo.example.test --self-signed --renew -y
openssl x509 -in /home/testdev/demo/nginx/ssl/demo.example.test.pem -noout -checkend $((86400 * 365 * 14))

echo "==> enable-scheduler testdev demo"
test -d /home/testdev/demo/cron
server-tool enable-scheduler testdev demo -y
grep -q "php${php_version} artisan schedule:run" /home/testdev/demo/cron/scheduler
crontab -u testdev -l | grep -qF '# BEGIN server-tool app: testdev/demo'
crontab -u testdev -l | grep -qF "cd /home/testdev/demo/current && php${php_version} artisan schedule:run"
crontab -u testdev -l | grep -qF '# END server-tool app: testdev/demo'

echo "==> apply-cron testdev demo"
cat > /home/testdev/demo/cron/extra <<EOF
0 3 * * * php /home/testdev/demo/current/artisan extra:job
EOF
chown testdev:testdev /home/testdev/demo/cron/extra
server-tool apply-cron testdev demo -y
crontab -u testdev -l | grep -qF "php${php_version} artisan schedule:run"
crontab -u testdev -l | grep -qF 'artisan extra:job'

echo "==> disable-scheduler testdev demo"
server-tool disable-scheduler testdev demo -y
test ! -f /home/testdev/demo/cron/scheduler
! crontab -u testdev -l | grep -qF 'artisan schedule:run'
crontab -u testdev -l | grep -qF 'artisan extra:job'

echo "==> delete-app testdev demo"
server-tool delete-app testdev demo -y
test ! -e /home/testdev/demo
test ! -e /etc/nginx/conf.d/testdev_demo.conf
test ! -e "/etc/php/${php_version}/fpm/pool.d/testdev_demo.conf"
test ! -e /etc/supervisor/conf.d/testdev_demo.d
! grep -qF '# BEGIN server-tool app: testdev/demo' <<< "$(crontab -u testdev -l 2>/dev/null || true)"

echo "==> verify packages"
"php${php_version}" -v
node -v
npm -v
nginx -v
psql --version
redis-cli ping
test -x /usr/local/bin/cachetool

echo "==> smoke test passed"

#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
php_version="$(tail -1 "$repo_dir/templates/php-versions")"
other_php_version="$(tail -2 "$repo_dir/templates/php-versions" | head -1)"
node_version="$(tail -1 "$repo_dir/templates/node-versions")"
other_node_version="$(tail -2 "$repo_dir/templates/node-versions" | head -1)"
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

echo "==> no arguments shows help"
server-tool | grep -q create-app

echo "==> help lists commands"
server-tool help | grep -q create-app
server-tool help | grep -q start-horizon
server-tool help | grep -q start-queue
server-tool help | grep -q stop-horizon
server-tool help | grep -q stop-queue

echo "==> help lists app-structure topic"
server-tool help | grep -q app-structure

echo "==> help create-app prints usage"
server-tool help create-app | grep -q 'Usage:'

echo "==> help start-queue documents --restart"
server-tool help start-queue | grep -q -- '--restart'

echo "==> help stop-queue documents --disable"
server-tool help stop-queue | grep -q -- '--disable'

echo "==> help app-structure describes the application layout"
server-tool help app-structure | grep -q '/home/<username>/<application>/'
server-tool help app-structure | grep -q 'current'

echo "==> help unknown command is rejected"
if server-tool help definitely-not-a-command; then
    echo "Expected help for unknown command to fail"
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

echo "==> check-certbot-renew"
server-tool check-certbot-renew -y
if systemctl cat certbot.timer >/dev/null 2>&1; then
    systemctl is-enabled --quiet certbot.timer
    systemctl is-active --quiet certbot.timer
else
    test -f /etc/cron.d/certbot
fi

echo "==> install php ${php_version}"
server-tool install php -y "$php_version"

echo "==> install npm ${other_node_version} ${node_version}"
server-tool install npm -y "$other_node_version" "$node_version"

echo "==> node wrappers follow .nvmrc"
node_default="$(cd /tmp && node -v)"
[[ "$node_default" == v${node_version}.* ]]
(cd /tmp && npm -v)

node_nvmrc_dir="$(mktemp -d)"
echo "$other_node_version" > "$node_nvmrc_dir/.nvmrc"
other_node_out="$(cd "$node_nvmrc_dir" && node -v)"
[[ "$other_node_out" == v${other_node_version}.* ]]
(cd "$node_nvmrc_dir" && npm -v)

echo "$node_version" > "$node_nvmrc_dir/.nvmrc"
default_node_out="$(cd "$node_nvmrc_dir" && node -v)"
[[ "$default_node_out" == v${node_version}.* ]]

mkdir -p "$node_nvmrc_dir/child/nested"
echo "$other_node_version" > "$node_nvmrc_dir/.nvmrc"
walkup_node_out="$(cd "$node_nvmrc_dir/child/nested" && node -v)"
[[ "$walkup_node_out" == v${other_node_version}.* ]]

echo "20" > "$node_nvmrc_dir/.nvmrc"
if (cd "$node_nvmrc_dir" && node -v); then
    echo "Expected node to fail for missing major 20"
    exit 1
fi
rm -rf "$node_nvmrc_dir"

echo "==> install cachetool"
server-tool install cachetool -y

echo "==> install composer --version 2.8.12"
server-tool install composer --version 2.8.12 -y
test -x /usr/local/bin/composer
composer --version --no-ansi | grep -q 2.8.12
echo "==> install composer (latest)"
server-tool install composer -y
test -x /usr/local/bin/composer
composer --version --no-ansi

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
grep -qxF "export LS_OPTIONS='--color=auto'" /home/testdev/.bashrc
grep -qxF "alias ls='ls \$LS_OPTIONS'" /home/testdev/.bashrc
grep -qxF "alias ll='ls \$LS_OPTIONS -l'" /home/testdev/.bashrc
grep -qxF "alias l='ls \$LS_OPTIONS -lA'" /home/testdev/.bashrc
grep -qxF "alias art='./artisan'" /home/testdev/.bashrc

echo "==> disable-ssh-password"
server-tool disable-ssh-password -y
grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config.d/10-server-tool.conf
grep -q '^KbdInteractiveAuthentication no' /etc/ssh/sshd_config.d/10-server-tool.conf
grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config.d/10-server-tool.conf
sshd -t

echo "==> create-db without type fails when both engines are installed"
if server-tool create-db should_fail -y; then
    echo "Expected create-db without -t to fail when PostgreSQL and MariaDB are both installed"
    exit 1
fi

echo "==> create-db --host without --admin-password fails when stdin is not a terminal"
if server-tool create-db remote_fail -t pgsql --host 127.0.0.1 -y; then
    echo "Expected create-db --host without --admin-password to fail without a TTY"
    exit 1
fi
if server-tool create-db remote_fail -t mysql --host 127.0.0.1 -y; then
    echo "Expected create-db --host without --admin-password to fail without a TTY"
    exit 1
fi

echo "==> create-app remote flags require -d"
if server-tool create-app testdev nohostapp --host 127.0.0.1 -y; then
    echo "Expected create-app --host without -d to fail"
    exit 1
fi

echo "==> create-app --host without --admin-password fails when stdin is not a terminal"
if server-tool create-app testdev remotefail -d remotefail -t pgsql --host 127.0.0.1 -y; then
    echo "Expected create-app --host without --admin-password to fail without a TTY"
    exit 1
fi
if server-tool create-app testdev remotefail -d remotefail -t mysql --host 127.0.0.1 -y; then
    echo "Expected create-app --host without --admin-password to fail without a TTY"
    exit 1
fi
test ! -e /home/testdev/remotefail

echo "==> create-app testdev demo -d dump_testdb -t pgsql"
server-tool create-app testdev demo -d dump_testdb -t pgsql -y

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
test -f /home/testdev/demo/.env.db
grep -q '^DB_CONNECTION=pgsql' /home/testdev/demo/.env.db
grep -q '^DB_HOST=127.0.0.1' /home/testdev/demo/.env.db
grep -q '^DB_DATABASE=dump_testdb' /home/testdev/demo/.env.db

echo "==> list-apps"
server-tool list-apps | grep -qxF 'testdev demo'

echo "==> dump-db and restore-db testdev demo"
db_pass="$(sed -n 's/^DB_PASSWORD=//p' /home/testdev/demo/.env.db | head -1)"
PGPASSWORD="$db_pass" psql -h 127.0.0.1 -U dump_testdb -d dump_testdb -v ON_ERROR_STOP=1 -c "CREATE TABLE smoke (id int); INSERT INTO smoke VALUES (1);"
server-tool dump-db testdev demo /tmp -y
dump_file="$(ls -1t /tmp/demo-*.dump | head -1)"
test -s "$dump_file"
PGPASSWORD="$db_pass" psql -h 127.0.0.1 -U dump_testdb -d dump_testdb -v ON_ERROR_STOP=1 -c "DROP TABLE smoke;"
server-tool restore-db testdev demo "$dump_file" -y
PGPASSWORD="$db_pass" psql -h 127.0.0.1 -U dump_testdb -d dump_testdb -tAc "SELECT id FROM smoke" | grep -qx 1

echo "==> create-db smoke_mysqldb -t mysql"
server-tool create-db smoke_mysqldb -t mysql -y
mysql -N -B -e "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'smoke_mysqldb'" | grep -qx 1

echo "==> create-app testdev mysqlapp -d smoke_mysqlapp -t mysql"
server-tool create-app testdev mysqlapp -d smoke_mysqlapp -t mysql -y
test -f /home/testdev/mysqlapp/.env.db
grep -q '^DB_CONNECTION=mysql' /home/testdev/mysqlapp/.env.db
grep -q '^DB_HOST=127.0.0.1' /home/testdev/mysqlapp/.env.db
grep -q '^DB_PORT=3306' /home/testdev/mysqlapp/.env.db
grep -q '^DB_DATABASE=smoke_mysqlapp' /home/testdev/mysqlapp/.env.db

echo "==> dump-db and restore-db testdev mysqlapp"
mysql_pass="$(sed -n 's/^DB_PASSWORD=//p' /home/testdev/mysqlapp/.env.db | head -1)"
MYSQL_PWD="$mysql_pass" mysql -h 127.0.0.1 -u smoke_mysqlapp smoke_mysqlapp -e "CREATE TABLE smoke (id int); INSERT INTO smoke VALUES (1);"
server-tool dump-db testdev mysqlapp /tmp -y
mysql_dump_file="$(ls -1t /tmp/mysqlapp-*.sql.gz | head -1)"
test -s "$mysql_dump_file"
gzip -t "$mysql_dump_file"
MYSQL_PWD="$mysql_pass" mysql -h 127.0.0.1 -u smoke_mysqlapp smoke_mysqlapp -e "DROP TABLE smoke;"
server-tool restore-db testdev mysqlapp "$mysql_dump_file" -y
MYSQL_PWD="$mysql_pass" mysql -h 127.0.0.1 -N -B -u smoke_mysqlapp smoke_mysqlapp -e "SELECT id FROM smoke" | grep -qx 1

echo "==> delete-app testdev mysqlapp"
server-tool delete-app testdev mysqlapp -y
test ! -e /home/testdev/mysqlapp

echo "==> start-horizon without config fails"
if server-tool start-horizon testdev demo -y; then
    echo "Expected start-horizon without config to fail"
    exit 1
fi

echo "==> stop-queue without config fails"
if server-tool stop-queue testdev demo -y; then
    echo "Expected stop-queue without config to fail"
    exit 1
fi

echo "==> create-horizon testdev demo"
server-tool create-horizon testdev demo -y
test -f /home/testdev/demo/supervisor/horizon.conf
grep -q "php${php_version} artisan horizon" /home/testdev/demo/supervisor/horizon.conf
grep -q "directory=/home/testdev/demo/current/" /home/testdev/demo/supervisor/horizon.conf
test -L /etc/supervisor/conf.d/testdev_demo.d

echo "==> create-queue testdev demo"
server-tool create-queue testdev demo -y
test -f /home/testdev/demo/supervisor/queue.conf
grep -q "php${php_version} artisan queue:work --sleep=3 --tries=3 --timeout=60 --max-time=3600" /home/testdev/demo/supervisor/queue.conf
grep -q "directory=/home/testdev/demo/current/" /home/testdev/demo/supervisor/queue.conf
grep -q "program:queue-testdev-demo" /home/testdev/demo/supervisor/queue.conf
grep -q "stopwaitsecs=3600" /home/testdev/demo/supervisor/queue.conf

echo "==> stop-horizon testdev demo"
server-tool stop-horizon testdev demo -y
grep -q '^autostart=true' /home/testdev/demo/supervisor/horizon.conf

echo "==> start-horizon testdev demo"
server-tool start-horizon testdev demo -y
grep -q '^autostart=true' /home/testdev/demo/supervisor/horizon.conf
grep -q '^autorestart=true' /home/testdev/demo/supervisor/horizon.conf

echo "==> start-horizon testdev demo again"
server-tool start-horizon testdev demo -y

echo "==> start-horizon testdev demo --restart"
server-tool start-horizon testdev demo --restart -y

echo "==> stop-queue testdev demo --disable"
server-tool stop-queue testdev demo --disable -y
grep -q '^autostart=false' /home/testdev/demo/supervisor/queue.conf

echo "==> start-queue testdev demo"
server-tool start-queue testdev demo -y
grep -q '^autostart=true' /home/testdev/demo/supervisor/queue.conf
grep -q '^autorestart=true' /home/testdev/demo/supervisor/queue.conf

echo "==> start-queue testdev demo --restart"
server-tool start-queue testdev demo --restart -y

echo "==> stop-horizon testdev demo --disable"
server-tool stop-horizon testdev demo --disable -y
grep -q '^autostart=false' /home/testdev/demo/supervisor/horizon.conf

echo "==> start-horizon testdev demo re-enables autostart"
server-tool start-horizon testdev demo -y
grep -q '^autostart=true' /home/testdev/demo/supervisor/horizon.conf
grep -q '^autorestart=true' /home/testdev/demo/supervisor/horizon.conf

echo "==> enable-basic-auth testdev demo tester"
server-tool enable-basic-auth testdev demo tester -r Staging -y
grep -q 'auth_basic "Staging"' /home/testdev/demo/nginx/auth.inc
test ! -e /home/testdev/demo/nginx/auth-map.conf
test -s /home/testdev/demo/nginx/.htpasswd

echo "==> enable-basic-auth testdev demo tester --except"
server-tool enable-basic-auth testdev demo tester -r Staging --except /webhooks --except /up -y
grep -q 'auth_basic $auth_basic_testdev_demo' /home/testdev/demo/nginx/auth.inc
grep -q 'default "Staging"' /home/testdev/demo/nginx/auth-map.conf
grep -qF '~^/webhooks(/|\?|$)' /home/testdev/demo/nginx/auth-map.conf
grep -qF '~^/up(/|\?|$)' /home/testdev/demo/nginx/auth-map.conf
grep -qxF '/webhooks' /home/testdev/demo/nginx/auth-except
grep -qxF '/up' /home/testdev/demo/nginx/auth-except

echo "==> enable-basic-auth keeps excepts without --except"
server-tool enable-basic-auth testdev demo tester -r Staging -y
grep -q 'auth_basic $auth_basic_testdev_demo' /home/testdev/demo/nginx/auth.inc
grep -qF '~^/webhooks(/|\?|$)' /home/testdev/demo/nginx/auth-map.conf
grep -qxF '/webhooks' /home/testdev/demo/nginx/auth-except
grep -qxF '/up' /home/testdev/demo/nginx/auth-except

echo "==> enable-ssl testdev demo --self-signed"
server-tool enable-ssl testdev demo -d demo.example.test --self-signed -y
grep -q "listen 443 ssl" /home/testdev/demo/nginx/demo.conf
test -f /home/testdev/demo/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo/nginx/ssl/demo.example.test.key
grep -q "return 301 https" /home/testdev/demo/nginx/demo.conf

echo "==> enable-ssl testdev demo --self-signed --renew"
server-tool enable-ssl testdev demo -d demo.example.test --self-signed --renew -y
openssl x509 -in /home/testdev/demo/nginx/ssl/demo.example.test.pem -noout -checkend $((86400 * 365 * 14))

echo "==> list-domains testdev demo"
server-tool list-domains testdev demo | grep -qxF demo.example.test

echo "==> add-domain testdev demo extra.example.test"
server-tool add-domain testdev demo extra.example.test -y
grep -qE 'server_name[[:space:]]+.*extra\.example\.test' /home/testdev/demo/nginx/demo.conf
grep -q "listen 443 ssl" /home/testdev/demo/nginx/demo.conf
grep -q "php${php_version}-fpm-testdev-demo.sock" /home/testdev/demo/nginx/demo.conf
test -f /home/testdev/demo/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo/nginx/ssl/demo.example.test.key
server-tool list-domains testdev demo | grep -qxF extra.example.test
if server-tool add-domain testdev demo extra.example.test -y; then
    echo "Expected duplicate add-domain to fail"
    exit 1
fi

echo "==> remove-domain testdev demo extra.example.test"
server-tool remove-domain testdev demo extra.example.test -y
! grep -qE 'server_name[[:space:]]+.*extra\.example\.test' /home/testdev/demo/nginx/demo.conf
grep -q "listen 443 ssl" /home/testdev/demo/nginx/demo.conf
grep -q "php${php_version}-fpm-testdev-demo.sock" /home/testdev/demo/nginx/demo.conf
if server-tool remove-domain testdev demo extra.example.test -y; then
    echo "Expected remove-domain for unknown domain to fail"
    exit 1
fi
if server-tool list-domains testdev demo | grep -qxF demo; then
    server-tool remove-domain testdev demo demo -y
fi
if server-tool remove-domain testdev demo demo.example.test -y; then
    echo "Expected remove-domain for the last domain to fail"
    exit 1
fi
server-tool list-domains testdev demo | grep -qxF demo.example.test

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

echo "==> rename-app testdev demo demo2 --keep-domain"
server-tool rename-app testdev demo demo2 --keep-domain -y
test ! -e /home/testdev/demo
test ! -e /etc/nginx/conf.d/testdev_demo.conf
test ! -e "/etc/php/${php_version}/fpm/pool.d/testdev_demo.conf"
test ! -e /etc/supervisor/conf.d/testdev_demo.d
! grep -qF '# BEGIN server-tool app: testdev/demo' <<< "$(crontab -u testdev -l 2>/dev/null || true)"
test -d /home/testdev/demo2
test -f /home/testdev/demo2/nginx/demo2.conf
test -f /home/testdev/demo2/php-fpm/demo2.conf
grep -q "php${php_version}-fpm-testdev-demo2.sock" /home/testdev/demo2/nginx/demo2.conf
grep -q "php${php_version}-fpm-testdev-demo2.sock" /home/testdev/demo2/php-fpm/demo2.conf
test -f "/etc/php/${php_version}/fpm/pool.d/testdev_demo2.conf"
test -f /etc/nginx/conf.d/testdev_demo2.conf
test -L /etc/supervisor/conf.d/testdev_demo2.d
grep -q "program:horizon-testdev-demo2" /home/testdev/demo2/supervisor/horizon.conf
grep -q "directory=/home/testdev/demo2/current/" /home/testdev/demo2/supervisor/horizon.conf
grep -q "program:queue-testdev-demo2" /home/testdev/demo2/supervisor/queue.conf
grep -q "directory=/home/testdev/demo2/current/" /home/testdev/demo2/supervisor/queue.conf
grep -q "stdout_logfile=/home/testdev/demo2/log/queue.log" /home/testdev/demo2/supervisor/queue.conf
grep -q "cd /home/testdev/demo2/current && php${php_version} artisan schedule:run" /home/testdev/demo2/cron/scheduler
grep -qF "php /home/testdev/demo2/current/artisan extra:job" /home/testdev/demo2/cron/extra
crontab -u testdev -l | grep -qF '# BEGIN server-tool app: testdev/demo2'
crontab -u testdev -l | grep -qF "cd /home/testdev/demo2/current && php${php_version} artisan schedule:run"
crontab -u testdev -l | grep -qF 'artisan extra:job'
grep -qE 'server_name[[:space:]]+.*demo\.example\.test' /home/testdev/demo2/nginx/demo2.conf
grep -qE 'server_name[[:space:]]+.*demo2' /home/testdev/demo2/nginx/demo2.conf
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.key
test -f /home/testdev/demo2/.env.db
grep -q '^DB_DATABASE=dump_testdb' /home/testdev/demo2/.env.db
grep -q 'auth_basic $auth_basic_testdev_demo2' /home/testdev/demo2/nginx/auth.inc
grep -q '/home/testdev/demo2/nginx/.htpasswd' /home/testdev/demo2/nginx/auth.inc
grep -q 'default "Staging"' /home/testdev/demo2/nginx/auth-map.conf
grep -qF '~^/webhooks(/|\?|$)' /home/testdev/demo2/nginx/auth-map.conf
grep -qF '~^/up(/|\?|$)' /home/testdev/demo2/nginx/auth-map.conf

echo "==> switch-php testdev demo2 ${other_php_version}"
if server-tool switch-php testdev demo2 -p "$php_version" -y; then
    echo "Expected switch-php to the current version to fail"
    exit 1
fi
server-tool switch-php testdev demo2 -p "$other_php_version" -y
grep -q "php${other_php_version}-fpm-testdev-demo2.sock" /home/testdev/demo2/nginx/demo2.conf
grep -q "php${other_php_version}-fpm-testdev-demo2.sock" /home/testdev/demo2/php-fpm/demo2.conf
test ! -e "/etc/php/${php_version}/fpm/pool.d/testdev_demo2.conf"
test -f "/etc/php/${other_php_version}/fpm/pool.d/testdev_demo2.conf"
grep -q "include=/home/testdev/demo2/php-fpm/demo2.conf" "/etc/php/${other_php_version}/fpm/pool.d/testdev_demo2.conf"
grep -q "php${other_php_version} artisan horizon" /home/testdev/demo2/supervisor/horizon.conf
grep -q "php${other_php_version} artisan queue:work --sleep=3 --tries=3 --timeout=60 --max-time=3600" /home/testdev/demo2/supervisor/queue.conf
grep -q "cd /home/testdev/demo2/current && php${other_php_version} artisan schedule:run" /home/testdev/demo2/cron/scheduler
grep -qF "php /home/testdev/demo2/current/artisan extra:job" /home/testdev/demo2/cron/extra
crontab -u testdev -l | grep -qF "cd /home/testdev/demo2/current && php${other_php_version} artisan schedule:run"
crontab -u testdev -l | grep -qF 'artisan extra:job'
grep -qE 'server_name[[:space:]]+.*demo\.example\.test' /home/testdev/demo2/nginx/demo2.conf
grep -qE 'server_name[[:space:]]+.*demo2' /home/testdev/demo2/nginx/demo2.conf
grep -q "listen 443 ssl" /home/testdev/demo2/nginx/demo2.conf
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.key
grep -q 'auth_basic $auth_basic_testdev_demo2' /home/testdev/demo2/nginx/auth.inc
grep -q '/home/testdev/demo2/nginx/.htpasswd' /home/testdev/demo2/nginx/auth.inc
grep -q 'default "Staging"' /home/testdev/demo2/nginx/auth-map.conf
grep -qF '~^/webhooks(/|\?|$)' /home/testdev/demo2/nginx/auth-map.conf
grep -qF '~^/up(/|\?|$)' /home/testdev/demo2/nginx/auth-map.conf

echo "==> disable-scheduler testdev demo2"
server-tool disable-scheduler testdev demo2 -y
test ! -f /home/testdev/demo2/cron/scheduler
! crontab -u testdev -l | grep -qF 'artisan schedule:run'
crontab -u testdev -l | grep -qF 'artisan extra:job'

echo "==> delete-app testdev demo2"
server-tool delete-app testdev demo2 -y
test ! -e /home/testdev/demo2
test ! -e /etc/nginx/conf.d/testdev_demo2.conf
test ! -e "/etc/php/${php_version}/fpm/pool.d/testdev_demo2.conf"
test ! -e "/etc/php/${other_php_version}/fpm/pool.d/testdev_demo2.conf"
test ! -e /etc/supervisor/conf.d/testdev_demo2.d
! grep -qF '# BEGIN server-tool app: testdev/demo2' <<< "$(crontab -u testdev -l 2>/dev/null || true)"

echo "==> backup-app without config fails"
if server-tool backup-app testdev demo -y; then
    echo "Expected backup-app without config to fail"
    exit 1
fi

echo "==> test-backup without config fails"
if server-tool test-backup -y; then
    echo "Expected test-backup without config to fail"
    exit 1
fi

echo "==> cron.d backup filenames are sanitized"
# shellcheck disable=SC1091
. "$repo_dir/lib/common"
[[ "$(app_backup_cron_file testdev demo)" == "/etc/cron.d/server-tool-backup-testdev-demo" ]]
[[ "$(app_backup_cron_file test_dev my.app)" == "/etc/cron.d/server-tool-backup-test-dev-my-app" ]]
[[ "$(app_backup_cron_file 'test__dev' '.my.app.')" == "/etc/cron.d/server-tool-backup-test-dev-my-app" ]]

echo "==> backup-app testdev demo --enable"
server-tool backup-app testdev demo --enable -y
test -f /etc/cron.d/server-tool-backup-testdev-demo
grep -q 'PATH=' /etc/cron.d/server-tool-backup-testdev-demo
grep -qF 'backup-app testdev demo -y' /etc/cron.d/server-tool-backup-testdev-demo

echo "==> backup-app testdev demo --disable"
server-tool backup-app testdev demo --disable -y
test ! -f /etc/cron.d/server-tool-backup-testdev-demo

echo "==> install aws smoke-bucket (stub CLI)"
cat > /usr/local/bin/aws <<'EOF'
#!/bin/bash
set -e
if [ "$1" != "s3" ] || [ "$2" != "cp" ]; then
    echo "aws stub: unexpected: $*" >&2
    exit 1
fi
shift 2
src=""
dest=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only-show-errors)
            shift
            ;;
        --region)
            shift 2
            ;;
        s3://*)
            dest="$1"
            shift
            ;;
        *)
            if [ -z "$src" ]; then
                src="$1"
            else
                dest="$1"
            fi
            shift
            ;;
    esac
done
if [ -z "$src" ] || [ -z "$dest" ]; then
    echo "aws stub: missing src or dest" >&2
    exit 1
fi
rel="${dest#s3://}"
mkdir -p "/tmp/s3-mock/$(dirname "$rel")"
cp "$src" "/tmp/s3-mock/$rel"
EOF
chmod +x /usr/local/bin/aws
server-tool install aws smoke-bucket -y
test -f /etc/server-tool/backup.conf
grep -qxF 'S3_BUCKET=smoke-bucket' /etc/server-tool/backup.conf

echo "==> test-backup"
server-tool test-backup -y
server_name="$(hostname -s)"
test -s "/tmp/s3-mock/smoke-bucket/${server_name}/.server-tool-check"

echo "==> backup-app testdev demo"
mkdir -p /home/testdev/demo/log /home/testdev/demo/releases/old
mkdir -p /home/testdev/demo/current/node_modules /home/testdev/demo/current/.git
mkdir -p /home/testdev/demo/nginx/certs /home/testdev/demo/current/storage/framework /home/testdev/demo/current/storage/logs
echo secret-log > /home/testdev/demo/log/access.log
echo old-release > /home/testdev/demo/releases/old/app.php
echo nm-pkg > /home/testdev/demo/current/node_modules/pkg.js
echo git-obj > /home/testdev/demo/current/.git/HEAD
echo 'APP_KEY=secret' > /home/testdev/demo/current/.env
echo 'cert' > /home/testdev/demo/nginx/certs/app.pem
echo 'cache' > /home/testdev/demo/current/storage/framework/cache
echo 'applog' > /home/testdev/demo/current/storage/logs/laravel.log
chown -R testdev:testdev /home/testdev/demo/log /home/testdev/demo/releases /home/testdev/demo/install /home/testdev/demo/nginx
server-tool backup-app testdev demo -y
weekday="$(LC_ALL=C date +%A | tr '[:upper:]' '[:lower:]')"
server_name="$(hostname -s)"
backup_zip="/tmp/s3-mock/smoke-bucket/${server_name}/testdev/demo/${weekday}.zip"
test -s "$backup_zip"
unzip -t "$backup_zip" >/dev/null
zip_list="$(unzip -Z1 "$backup_zip")"
grep -q 'current/public/index.php' <<< "$zip_list"
grep -q '^db/demo-.*\.dump$' <<< "$zip_list"
! grep -q '^\.env.db$' <<< "$zip_list"
! grep -q '\.env$' <<< "$zip_list"
! grep -q '^log/' <<< "$zip_list"
! grep -q '^releases/' <<< "$zip_list"
! grep -q 'node_modules' <<< "$zip_list"
! grep -q '/\.git/' <<< "$zip_list"
! grep -q '^install/' <<< "$zip_list"
! grep -q 'nginx/certs' <<< "$zip_list"
! grep -q 'nginx/ssl' <<< "$zip_list"
! grep -q 'storage/framework' <<< "$zip_list"
! grep -q 'storage/logs' <<< "$zip_list"

echo "==> verify packages"
"php${php_version}" -v
node -v
npm -v
nginx -v
psql --version
redis-cli ping
test -x /usr/local/bin/cachetool
test -x /usr/local/bin/composer
composer --version --no-ansi

echo "==> smoke test passed"

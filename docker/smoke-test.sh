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
grep -q 'auth_basic "Staging"' /home/testdev/demo2/nginx/auth.inc

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
test ! -e /etc/supervisor/conf.d/testdev_demo2.d
! grep -qF '# BEGIN server-tool app: testdev/demo2' <<< "$(crontab -u testdev -l 2>/dev/null || true)"

echo "==> backup-app without config fails"
if server-tool backup-app testdev demo -y; then
    echo "Expected backup-app without config to fail"
    exit 1
fi

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

echo "==> backup-app testdev demo"
mkdir -p /home/testdev/demo/log /home/testdev/demo/releases/old
mkdir -p /home/testdev/demo/current/node_modules /home/testdev/demo/current/.git
echo secret-log > /home/testdev/demo/log/access.log
echo old-release > /home/testdev/demo/releases/old/app.php
echo nm-pkg > /home/testdev/demo/current/node_modules/pkg.js
echo git-obj > /home/testdev/demo/current/.git/HEAD
chown -R testdev:testdev /home/testdev/demo/log /home/testdev/demo/releases /home/testdev/demo/install
server-tool backup-app testdev demo -y
weekday="$(LC_ALL=C date +%A | tr '[:upper:]' '[:lower:]')"
server_name="$(hostname -s)"
backup_zip="/tmp/s3-mock/smoke-bucket/${server_name}/testdev/demo/${weekday}.zip"
test -s "$backup_zip"
unzip -t "$backup_zip" >/dev/null
zip_list="$(unzip -Z1 "$backup_zip")"
grep -q 'current/public/index.php' <<< "$zip_list"
grep -q '^\.env.db$' <<< "$zip_list"
grep -q '^db/demo-.*\.dump$' <<< "$zip_list"
! grep -q '^log/' <<< "$zip_list"
! grep -q '^releases/' <<< "$zip_list"
! grep -q 'node_modules' <<< "$zip_list"
! grep -q '/\.git/' <<< "$zip_list"
! grep -q '^install/' <<< "$zip_list"

echo "==> verify packages"
"php${php_version}" -v
node -v
npm -v
nginx -v
psql --version
redis-cli ping
test -x /usr/local/bin/cachetool

echo "==> smoke test passed"

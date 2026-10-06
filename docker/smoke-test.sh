#!/bin/bash
set -euo pipefail

# grep -q exits at the first match and closes the pipe. The producer then
# dies with SIGPIPE, and pipefail turns a successful search into a failure.
grep() {
  local quiet=0 arg
  for arg in "$@"; do
    case "$arg" in
      --) break ;;
      -*[q]*) quiet=1 ;;
    esac
  done
  if [ "$quiet" -eq 1 ] && [ ! -t 0 ]; then
    local input
    input="$(cat)"
    command grep "$@" <<<"$input"
    return
  fi
  command grep "$@"
}

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
server-tool help | grep -q show-ssh-key
server-tool help | grep -q start-horizon
server-tool help | grep -q start-queue
server-tool help | grep -q stop-horizon
server-tool help | grep -q stop-queue
server-tool help | grep -q list-horizons
server-tool help | grep -q list-queues
server-tool help | grep -q list-jobs
server-tool help | grep -q list-github-runners

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

echo "==> help install alloy and monitoring"
server-tool help install alloy | grep -q -- '--api-key-file'
server-tool help install monitoring | grep -q -- '-d <domain>'
server-tool help update-grafana | grep -q 'Usage:'
server-tool help update-probes | grep -q 'Usage:'
if server-tool update-grafana -y; then
    echo "Expected update-grafana to fail before monitoring is installed"
    exit 1
fi
if server-tool update-probes -y; then
    echo "Expected update-probes to fail before Alloy is installed"
    exit 1
fi

echo "==> install alloy and monitoring require arguments"
if server-tool install alloy -y; then
    echo "Expected install alloy without arguments to fail"
    exit 1
fi
if server-tool install monitoring -y; then
    echo "Expected install monitoring without arguments to fail"
    exit 1
fi

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

echo "==> create-github-runner documents multiple instances"
server-tool help create-github-runner | grep -q '~/actions-runners/<name>'
server-tool help create-github-runner | grep -q 'unique runner name'

echo "==> create-github-runner rejects unsafe runner names"
if server-tool create-github-runner https://github.com/my-org test-token -n '../other' -y; then
    echo "Expected create-github-runner to reject a path-like runner name"
    exit 1
fi
if server-tool create-github-runner https://github.com/my-org test-token -n 'runner two' -y; then
    echo "Expected create-github-runner to reject a runner name with spaces"
    exit 1
fi

echo "==> delete-github-runner documents one-instance removal"
server-tool help | grep -q delete-github-runner
server-tool help delete-github-runner | grep -q -- '-t <removal-token>'
server-tool help delete-github-runner | grep -q '~/actions-runners/<name>'

echo "==> delete-github-runner rejects unsafe arguments"
if server-tool delete-github-runner -y; then
    echo "Expected delete-github-runner without a name to fail"
    exit 1
fi
if server-tool delete-github-runner -n '../other' -y; then
    echo "Expected delete-github-runner to reject a path-like runner name"
    exit 1
fi
if server-tool delete-github-runner -n web-1 -u root -y; then
    echo "Expected delete-github-runner to reject root"
    exit 1
fi

echo "==> delete-github-runner removes one instance and keeps the user"
if id ghrunner >/dev/null 2>&1; then
    userdel -r ghrunner
fi
useradd -m -s /bin/bash ghrunner
install -d -o ghrunner -g ghrunner /home/ghrunner/actions-runner /home/ghrunner/actions-runners/web-2 /home/ghrunner/actions-runners/web-3
cat > /home/ghrunner/actions-runner/.runner <<'EOF'
{
  "agentName": "web-1",
  "gitHubUrl": "https://github.com/my-org"
}
EOF
cat > /home/ghrunner/actions-runners/web-2/.runner <<'EOF'
{
  "agentName": "web-2",
  "gitHubUrl": "https://github.com/my-org"
}
EOF
cat > /home/ghrunner/actions-runners/web-3/.runner <<'EOF'
{
  "agentName": "web-3",
  "gitHubUrl": "https://github.com/my-org"
}
EOF
call_log="$(mktemp -d)"
chmod 777 "$call_log"
for runner_spec in "web-1 /home/ghrunner/actions-runner 0" "web-2 /home/ghrunner/actions-runners/web-2 0" "web-3 /home/ghrunner/actions-runners/web-3 1"; do
    runner_label="${runner_spec%% *}"
    runner_rest="${runner_spec#* }"
    runner_dir="${runner_rest% *}"
    runner_status="${runner_rest##* }"
    printf '%s\n' 'actions.runner.test.service' > "$runner_dir/.service"
    cat > "$runner_dir/svc.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$call_log/${runner_label}.svc"
EOF
    cat > "$runner_dir/config.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$call_log/${runner_label}.config"
exit ${runner_status}
EOF
    chmod 755 "$runner_dir/svc.sh" "$runner_dir/config.sh"
done
chown -R ghrunner:ghrunner /home/ghrunner/actions-runner /home/ghrunner/actions-runners

echo "==> list-github-runners ghrunner"
server-tool help list-github-runners | grep -q 'username name url token directory'
printf '%s\n' 'token-web-1' > /home/ghrunner/actions-runner/.registration-token
printf '%s\n' 'token-web-2' > /home/ghrunner/actions-runners/web-2/.registration-token
chown ghrunner:ghrunner /home/ghrunner/actions-runner/.registration-token /home/ghrunner/actions-runners/web-2/.registration-token
chmod 600 /home/ghrunner/actions-runner/.registration-token /home/ghrunner/actions-runners/web-2/.registration-token
[ "$(server-tool list-github-runners ghrunner | grep -c .)" -eq 3 ]
server-tool list-github-runners ghrunner | grep -qxF 'ghrunner web-1 https://github.com/my-org token-web-1 /home/ghrunner/actions-runner'
server-tool list-github-runners ghrunner | grep -qxF 'ghrunner web-2 https://github.com/my-org token-web-2 /home/ghrunner/actions-runners/web-2'
server-tool list-github-runners ghrunner | grep -qxF 'ghrunner web-3 https://github.com/my-org - /home/ghrunner/actions-runners/web-3'
server-tool list-github-runners | grep -qxF 'ghrunner web-1 https://github.com/my-org token-web-1 /home/ghrunner/actions-runner'
if server-tool list-github-runners ghrunner extra; then
    echo "Expected list-github-runners to reject extra arguments"
    exit 1
fi

if server-tool delete-github-runner -n missing -u ghrunner -y; then
    echo "Expected delete-github-runner to reject an unknown runner"
    exit 1
fi
test -d /home/ghrunner/actions-runner
test -d /home/ghrunner/actions-runners/web-2

server-tool delete-github-runner -n web-2 -u ghrunner -y
test ! -e /home/ghrunner/actions-runners/web-2
[ "$(server-tool list-github-runners ghrunner | grep -c .)" -eq 2 ]
if server-tool list-github-runners ghrunner | grep -qxF 'ghrunner web-2 https://github.com/my-org token-web-2 /home/ghrunner/actions-runners/web-2'; then
    echo "Expected list-github-runners to omit the removed runner"
    exit 1
fi
test -d /home/ghrunner/actions-runner
test -d /home/ghrunner/actions-runners/web-3
test ! -e "$call_log/web-2.config"
grep -qx stop "$call_log/web-2.svc"
grep -qx uninstall "$call_log/web-2.svc"
test ! -e "$call_log/web-1.svc"
id ghrunner >/dev/null

if server-tool delete-github-runner -n web-3 -u ghrunner -t bad-token -y; then
    echo "Expected delete-github-runner to keep the directory when unregister fails"
    exit 1
fi
test -d /home/ghrunner/actions-runners/web-3
grep -qx stop "$call_log/web-3.svc"
grep -qx 'remove --unattended --token bad-token' "$call_log/web-3.config"
if grep -qx uninstall "$call_log/web-3.svc"; then
    echo "Expected service uninstall to wait until unregister succeeds"
    exit 1
fi
test -d /home/ghrunner/actions-runner

server-tool delete-github-runner -n web-1 -u ghrunner -t remove-token -y
test ! -e /home/ghrunner/actions-runner
grep -qx stop "$call_log/web-1.svc"
grep -qx uninstall "$call_log/web-1.svc"
grep -qx 'remove --unattended --token remove-token' "$call_log/web-1.config"
test -d /home/ghrunner/actions-runners/web-3
id ghrunner >/dev/null
userdel -r ghrunner
rm -rf "$call_log"

echo "==> init-server"
server-tool init-server -y

echo "==> install nginx"
server-tool install nginx -y
large_files_nginx_conf=/etc/nginx/conf.d/10-server-tool-large-files.conf
test -f "$large_files_nginx_conf"
grep -qxF 'client_max_body_size 150M;' "$large_files_nginx_conf"
grep -qxF 'fastcgi_read_timeout 180;' "$large_files_nginx_conf"
nginx_config="$(nginx -T 2>&1)"
grep -qF 'client_max_body_size 150M;' <<< "$nginx_config"
grep -qF 'fastcgi_read_timeout 180;' <<< "$nginx_config"

echo "==> check-certbot-renew"
server-tool check-certbot-renew -y
if systemctl cat certbot.timer >/dev/null 2>&1; then
    systemctl is-enabled --quiet certbot.timer
    systemctl is-active --quiet certbot.timer
else
    test -f /etc/cron.d/certbot
fi

echo "==> install monitoring"
cat > /usr/local/bin/certbot <<'EOF'
#!/bin/bash
set -euo pipefail
domain=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)
            domain="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [ -z "$domain" ]; then
    echo "certbot stub: missing domain" >&2
    exit 1
fi
live="/etc/letsencrypt/live/${domain}"
mkdir -p "$live"
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${live}/privkey.pem" \
    -out "${live}/fullchain.pem" \
    -subj "/CN=${domain}" \
    -days 30 >/dev/null 2>&1
python3 - "$domain" <<'PY'
import pathlib, sys
domain = sys.argv[1]
path = pathlib.Path("/etc/nginx/sites-available/monitoring")
text = path.read_text()
text = text.replace("    listen 80;\n", "", 1)
text = text.replace("    listen [::]:80;\n", "", 1)
ssl = (
    "    listen 443 ssl;\n"
    "    listen [::]:443 ssl;\n"
    f"    ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;\n"
    f"    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;\n"
)
if "listen 443 ssl;" not in text:
    text = text.replace("    server_name ", ssl + "    server_name ", 1)
if "return 301 https://" not in text:
    text += f"""
server {{
    listen 80;
    listen [::]:80;
    server_name {domain};
    return 301 https://$host$request_uri;
}}
"""
path.write_text(text)
PY
EOF
chmod 755 /usr/local/bin/certbot
server-tool install monitoring -d monitor.example.test -e admin@example.test -y
monitoring_key="$(cat /etc/server-tool/monitoring-api.key)"
monitoring_password="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /etc/server-tool/monitoring.conf)"
server-tool install monitoring -d monitor.example.test -e admin@example.test -y
[ "$(cat /etc/server-tool/monitoring-api.key)" = "$monitoring_key" ]
[ "$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /etc/server-tool/monitoring.conf)" = "$monitoring_password" ]
rm -f /usr/local/bin/certbot
[ "$(stat -c %a /etc/server-tool/monitoring.conf)" = "600" ]
[ "$(stat -c %a /etc/server-tool/monitoring-api.key)" = "600" ]
[ "$(stat -c %a /etc/server-tool/nginx-monitoring-map.conf)" = "600" ]
grep -F "$monitoring_key" /etc/server-tool/nginx-monitoring-map.conf >/dev/null
if grep -F "$monitoring_key" /etc/nginx/sites-available/monitoring; then
    echo "Expected the nginx site to omit the API key"
    exit 1
fi
grep -q 'location /api/v1/write' /etc/nginx/sites-available/monitoring
grep -q 'location /loki/api/v1/push' /etc/nginx/sites-available/monitoring
grep -q 'proxy_pass http://127.0.0.1:3000;' /etc/nginx/sites-available/monitoring
grep -q 'client_max_body_size 32m;' /etc/nginx/sites-available/monitoring
grep -q 'listen 443 ssl;' /etc/nginx/sites-available/monitoring
grep -q 'return 301 https://' /etc/nginx/sites-available/monitoring
grep -q 'http://127.0.0.1:9090' /etc/grafana/provisioning/datasources/server-tool.yaml
grep -q 'http://127.0.0.1:3100' /etc/grafana/provisioning/datasources/server-tool.yaml
grep -q 'server-tools-server' /var/lib/grafana/dashboards/server-tools/server.json
grep -q 'probe_success' /var/lib/grafana/dashboards/server-tools/http.json
printf '{}\n' > /var/lib/grafana/dashboards/server-tools/http.json
server-tool update-grafana -y
grep -q '"legendFormat": "{{domain}}"' /var/lib/grafana/dashboards/server-tools/http.json
grep -q 'label_values(username)' /var/lib/grafana/dashboards/server-tools/logs.json
grep -q 'GF_AUTH_ANONYMOUS_ENABLED=false' /etc/systemd/system/grafana-server.service.d/server-tool.conf
grep -q 'GF_SERVER_ROOT_URL=https://monitor.example.test/' /etc/systemd/system/grafana-server.service.d/server-tool.conf
systemctl is-active --quiet prometheus
systemctl is-active --quiet loki
systemctl is-active --quiet grafana-server
for monitoring_port in 9090 3100 3000; do
    monitoring_ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        if ss -ltn | awk '{print $4}' | grep -qx "127.0.0.1:${monitoring_port}"; then
            monitoring_ok=1
            break
        fi
        sleep 1
    done
    if [ "$monitoring_ok" -ne 1 ]; then
        echo "Timed out waiting for 127.0.0.1:${monitoring_port}"
        exit 1
    fi
done
if ss -ltn | awk '{print $4}' | grep -Eq '^(0\.0\.0\.0|\*|\[::\]):(9090|3100|3000)$'; then
    echo "Expected Prometheus, Loki and Grafana to listen on localhost only"
    exit 1
fi
for monitoring_url in http://127.0.0.1:9090/-/ready http://127.0.0.1:3100/ready http://127.0.0.1:3000/api/health; do
    monitoring_ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        if curl -sf "$monitoring_url" >/dev/null; then
            monitoring_ok=1
            break
        fi
        sleep 1
    done
    if [ "$monitoring_ok" -ne 1 ]; then
        echo "Timed out waiting for $monitoring_url"
        exit 1
    fi
done

echo "==> install alloy"
server-tool install alloy --url https://monitor.example.test --api-key-file /etc/server-tool/monitoring-api.key -y
systemctl is-active --quiet alloy
[ "$(stat -c %a /etc/alloy/config.alloy)" = "640" ]
[ "$(stat -c %G /etc/alloy/config.alloy)" = "alloy" ]
grep -F "$monitoring_key" /etc/alloy/config.alloy >/dev/null
grep -F 'https://monitor.example.test/api/v1/write' /etc/alloy/config.alloy >/dev/null
grep -F 'https://monitor.example.test/loki/api/v1/push' /etc/alloy/config.alloy >/dev/null
grep -F '/home/*/*/current/storage/logs/*.log' /etc/alloy/config.alloy >/dev/null
grep -F '/home/*/*/log/*.log' /etc/alloy/config.alloy >/dev/null
if grep -F 'releases/' /etc/alloy/config.alloy; then
    echo "Expected Alloy to follow current/storage/logs instead of release directories"
    exit 1
fi
test -f /var/lib/server-tool/monitoring/blackbox-targets.json

echo "==> deployer storage symlink keeps the same log file"
deploy_sim="$(mktemp -d)"
mkdir -p "$deploy_sim/shared/storage/logs" "$deploy_sim/releases/release1" "$deploy_sim/releases/release2"
echo 'laravel log' > "$deploy_sim/shared/storage/logs/laravel.log"
ln -s ../../shared/storage "$deploy_sim/releases/release1/storage"
ln -s ../../shared/storage "$deploy_sim/releases/release2/storage"
ln -s releases/release1 "$deploy_sim/current"
deploy_inode="$(stat -c %i "$deploy_sim/current/storage/logs/laravel.log")"
ln -sfn releases/release2 "$deploy_sim/current"
[ "$(stat -c %i "$deploy_sim/current/storage/logs/laravel.log")" = "$deploy_inode" ]
test -f "$deploy_sim/current/storage/logs/laravel.log"
rm -rf "$deploy_sim"

echo "==> install php ${php_version}"
server-tool install php -y "$php_version"
large_files_php_conf="/etc/php/${php_version}/fpm/conf.d/99-server-tool-large-files.ini"
test -f "$large_files_php_conf"
grep -qxF 'upload_max_filesize = 150M' "$large_files_php_conf"
grep -qxF 'post_max_size = 151M' "$large_files_php_conf"
grep -qxF 'max_execution_time = 0' "$large_files_php_conf"
grep -qxF 'max_input_time = -1' "$large_files_php_conf"
php_fpm_info="$(php-fpm${php_version} -i)"
grep -qE 'upload_max_filesize.*150M' <<< "$php_fpm_info"
grep -qE 'post_max_size.*151M' <<< "$php_fpm_info"

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
meili_ok=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if curl -sf http://127.0.0.1:7700/health >/dev/null; then
        meili_ok=1
        break
    fi
    sleep 1
done
if [ "$meili_ok" -ne 1 ]; then
    echo "Timed out waiting for Meilisearch"
    exit 1
fi

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
test -s /home/testdev/.ssh/testdev

echo "==> show-ssh-key testdev"
server-tool help show-ssh-key | grep -q 'Usage:'
decoded="$(mktemp)"
server-tool show-ssh-key testdev | base64 -d > "$decoded"
cmp -s "$decoded" /home/testdev/.ssh/testdev
rm -f "$decoded"
if server-tool show-ssh-key; then
    echo "Expected show-ssh-key without a username to fail"
    exit 1
fi
if server-tool show-ssh-key root; then
    echo "Expected show-ssh-key root to fail"
    exit 1
fi
if server-tool show-ssh-key smokeadmin; then
    echo "Expected show-ssh-key smokeadmin to fail without a named private key"
    exit 1
fi
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
server-tool create-app testdev demo -d dump_testdb -t pgsql -p "$php_version" -y

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
getfacl /home/testdev/demo/log | grep -q 'user:alloy:r-x'
if grep -q 'demo.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json; then
    echo "Expected no HTTP probe before a dotted domain exists"
    exit 1
fi

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
server-tool create-app testdev mysqlapp -d smoke_mysqlapp -t mysql -p "$php_version" -y
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

echo "==> list-horizons testdev demo"
server-tool list-horizons | grep -qx 'testdev demo horizon-testdev-demo'
server-tool list-horizons testdev | grep -qx 'testdev demo horizon-testdev-demo'
server-tool list-horizons testdev demo | grep -qx 'testdev demo horizon-testdev-demo'

echo "==> list-queues testdev demo"
server-tool list-queues | grep -qx 'testdev demo queue-testdev-demo'
server-tool list-queues testdev | grep -qx 'testdev demo queue-testdev-demo'
server-tool list-queues testdev demo | grep -qx 'testdev demo queue-testdev-demo'

echo "==> list-jobs testdev demo"
server-tool list-jobs | grep -qx 'testdev demo horizon-testdev-demo'
server-tool list-jobs | grep -qx 'testdev demo queue-testdev-demo'
server-tool list-jobs testdev | grep -qx 'testdev demo horizon-testdev-demo'
server-tool list-jobs testdev demo | grep -qx 'testdev demo queue-testdev-demo'

echo "==> list-horizons unknown user fails"
if server-tool list-horizons definitely-not-a-user; then
    echo "Expected list-horizons for unknown user to fail"
    exit 1
fi

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

grep -q 'https://demo.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q '"domain": "demo.example.test"' /var/lib/server-tool/monitoring/blackbox-targets.json

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
grep -q 'https://extra.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json
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
grep -q 'https://demo.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json
if grep -q 'extra.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json; then
    echo "Expected the removed domain to leave the HTTP probes"
    exit 1
fi

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
grep -q '"application": "demo2"' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q 'https://demo.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json
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
server-tool list-horizons testdev demo2 | grep -qx 'testdev demo2 horizon-testdev-demo2'
server-tool list-queues testdev demo2 | grep -qx 'testdev demo2 queue-testdev-demo2'
server-tool list-jobs testdev | grep -qx 'testdev demo2 horizon-testdev-demo2'
server-tool list-jobs testdev | grep -qx 'testdev demo2 queue-testdev-demo2'
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
if grep -q 'demo.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json; then
    echo "Expected HTTP probes to drop the deleted application"
    exit 1
fi

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

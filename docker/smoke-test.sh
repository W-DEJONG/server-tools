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

verbose_app_field() {
  local user="$1"
  local app="$2"
  local field="$3"
  server-tool list-apps -v | awk -v u="$user" -v a="$app" -v f="$field" '
    NR == 1 {
      for (i = 1; i <= NF; i++) if ($i == f) col = i
    }
    $1 == u && $2 == a { print $col }
  '
}

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
server-tool help | grep -q switch-nginx
server-tool help | grep -q status

echo "==> help lists app-structure topic"
server-tool help | grep -q app-structure

echo "==> help create-app prints usage"
server-tool help create-app | grep -q 'Usage:'
server-tool help create-app | grep -q -- '--http-port'
server-tool help switch-nginx | grep -q 'Usage:'
server-tool help switch-nginx | grep -q 'HTTP listen port'
server-tool help list-apps | grep -q -- '-v'
server-tool help status | grep -q 'Usage:'

echo "==> help start-queue documents --restart"
server-tool help start-queue | grep -q -- '--restart'

echo "==> help stop-queue documents --disable"
server-tool help stop-queue | grep -q -- '--disable'

echo "==> help app-structure describes the application layout"
server-tool help app-structure | grep -q '/home/<username>/<application>/'
server-tool help app-structure | grep -q 'current'

echo "==> help install alloy and monitoring"
server-tool help install alloy | grep -q -- '--api-key-file'
server-tool help install alloy | grep -q -- '--forge'
server-tool help install alloy | grep -q -- '--monitoring'
server-tool help install alloy | grep -q 'Ubuntu 22.04'
server-tool help install monitoring | grep -q -- '-d <domain>'
server-tool help update-grafana | grep -q 'Usage:'
server-tool help update-monitoring | grep -q 'Usage:'
server-tool help update-php | grep -q 'Usage:'
server-tool help check-php-upload-progress | grep -q 'Usage:'
server-tool help check-php-upload-progress | grep -q -- '--check'
server-tool help check-default-host | grep -q 'Usage:'
server-tool help check-default-host | grep -q -- '--check'
server-tool help status | grep -q 'default host'
server-tool help install nginx | grep -q 'default host'
server-tool help update-probes | grep -q 'Usage:'
if server-tool update-grafana -y; then
    echo "Expected update-grafana to fail before monitoring is installed"
    exit 1
fi
if server-tool update-monitoring -y; then
    echo "Expected update-monitoring to fail before monitoring is installed"
    exit 1
fi
if server-tool update-php -y; then
    echo "Expected update-php to fail before PHP is installed"
    exit 1
fi
if server-tool check-php-upload-progress -y; then
    echo "Expected check-php-upload-progress to fail before PHP is installed"
    exit 1
fi
if server-tool check-default-host --check; then
    echo "Expected check-default-host to fail before nginx is installed"
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
if server-tool install alloy --forge -y; then
    echo "Expected install alloy --forge without a URL to fail"
    exit 1
fi
if server-tool install alloy --monitoring -y; then
    echo "Expected install alloy --monitoring to fail before monitoring is installed"
    exit 1
fi
if server-tool install alloy --forge --monitoring -y; then
    echo "Expected install alloy with both --forge and --monitoring to fail"
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
command -v logrotate >/dev/null
test -f /etc/logrotate.d/server-tool
grep -qF '/var/log/server-tool/backup.log' /etc/logrotate.d/server-tool
grep -qF '/home/*/*/log/*.log' /etc/logrotate.d/server-tool
grep -qF 'copytruncate' /etc/logrotate.d/server-tool
grep -qF 'su root root' /etc/logrotate.d/server-tool
grep -qF 'create 644 root root' /etc/logrotate.d/server-tool
logrotate -d /etc/logrotate.d/server-tool >/dev/null

echo "==> install nginx"
server-tool install nginx -y
large_files_nginx_conf=/etc/nginx/conf.d/10-server-tool-large-files.conf
test -f "$large_files_nginx_conf"
grep -qxF 'client_max_body_size 150M;' "$large_files_nginx_conf"
grep -qxF 'fastcgi_read_timeout 180;' "$large_files_nginx_conf"
request_log_format=/etc/nginx/conf.d/00-server-tool-log-format.conf
test -f "$request_log_format"
grep -qF 'log_format server_tool' "$request_log_format"
grep -qF 'host=$host' "$request_log_format"
nginx_config="$(nginx -T 2>&1)"
grep -qF 'client_max_body_size 150M;' <<< "$nginx_config"
grep -qF 'fastcgi_read_timeout 180;' <<< "$nginx_config"
grep -qF 'log_format server_tool' <<< "$nginx_config"
grep -qF 'host=$host' <<< "$nginx_config"
default_host_conf=/etc/nginx/conf.d/00-server-tool-default-host.conf
default_host_page=/var/www/server-tool/no-host.html
test -f "$default_host_conf"
test -f "$default_host_page"
grep -q 'default_server' "$default_host_conf"
grep -qF 'No active host found' "$default_host_page"
server-tool check-default-host --check
default_host_check="$(server-tool check-default-host --check)"
grep -qF 'Default host *:80: explicit' <<<"$default_host_check"
grep -qF '00-server-tool-default-host.conf' <<<"$default_host_check"
if grep -qF ': missing' <<<"$default_host_check"; then
    echo "Expected install nginx to set an explicit default host"
    exit 1
fi
default_host_body="$(mktemp)"
default_host_code="$(curl -sS -o "$default_host_body" -w '%{http_code}' -H 'Host: unknown.example' http://127.0.0.1/)"
[[ "$default_host_code" == "500" ]]
grep -qF 'No active host found' "$default_host_body"
localhost_code="$(curl -sS -o "$default_host_body" -w '%{http_code}' -H 'Host: localhost' http://127.0.0.1/)"
[[ "$localhost_code" == "200" ]]
if grep -qF 'No active host found' "$default_host_body"; then
    echo "Expected localhost to keep the named nginx server"
    exit 1
fi
rm -f "$default_host_body"

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

echo "==> default host rejects unknown https"
if server-tool check-default-host --check; then
    echo "Expected check-default-host to fail when 443 has no default_server"
    exit 1
fi
default_host_check="$(mktemp)"
server-tool check-default-host --check >"$default_host_check" || true
grep -qF 'Default host *:443 ssl: missing' "$default_host_check"
rm -f "$default_host_check"
server-tool check-default-host -y
grep -q 'ssl_reject_handshake on;' /etc/nginx/conf.d/00-server-tool-default-host.conf
if grep -q 'listen 443 ssl default_server' /etc/nginx/sites-available/monitoring; then
    echo "Expected monitoring to keep its own listen 443 ssl"
    exit 1
fi
server-tool check-default-host -y
[[ "$(grep -c 'listen 443 ssl default_server;' /etc/nginx/conf.d/00-server-tool-default-host.conf)" -eq 1 ]]
server-tool check-default-host --check
timeout 5 openssl s_client -connect 127.0.0.1:443 -servername unknown.example </dev/null >/tmp/unknown-sni 2>&1 || true
if grep -q 'BEGIN CERTIFICATE' /tmp/unknown-sni; then
    echo "Expected unknown HTTPS host to reject the handshake"
    exit 1
fi
timeout 5 openssl s_client -connect 127.0.0.1:443 -servername monitor.example.test </dev/null >/tmp/known-sni 2>&1 || true
grep -q 'monitor.example.test' /tmp/known-sni
rm -f /tmp/unknown-sni /tmp/known-sni
grep -q 'http://127.0.0.1:9090' /etc/grafana/provisioning/datasources/server-tool.yaml
grep -q 'http://127.0.0.1:3100' /etc/grafana/provisioning/datasources/server-tool.yaml
grep -q 'server-tools-server' /var/lib/grafana/dashboards/server-tools/server.json
grep -q 'probe_success' /var/lib/grafana/dashboards/server-tools/http.json
printf '{}\n' > /var/lib/grafana/dashboards/server-tools/http.json
server-tool update-grafana -y
grep -q '"legendFormat": "{{domain}}"' /var/lib/grafana/dashboards/server-tools/http.json
grep -q '"title": "HTTP status"' /var/lib/grafana/dashboards/server-tools/http.json
grep -q 'Requests per domain' /var/lib/grafana/dashboards/server-tools/http.json
grep -q 'loki_process_custom_nginx_requests_total' /var/lib/grafana/dashboards/server-tools/http.json
grep -q 'increase(' /var/lib/grafana/dashboards/server-tools/http.json
grep -qF '$__range' /var/lib/grafana/dashboards/server-tools/http.json
grep -q 'label_values(username)' /var/lib/grafana/dashboards/server-tools/logs.json
grep -q 'label_values(logfile)' /var/lib/grafana/dashboards/server-tools/logs.json
grep -q 'label_values(level)' /var/lib/grafana/dashboards/server-tools/logs.json
grep -q 'server-tools-backups' /var/lib/grafana/dashboards/server-tools/backups.json
grep -q 'Failures in 24h' /var/lib/grafana/dashboards/server-tools/backups.json
grep -q '\[24h\]' /var/lib/grafana/dashboards/server-tools/backups.json
grep -q 'noDataState: OK' /etc/grafana/provisioning/alerting/backup-failed.yaml
grep -q 'result="failed"' /etc/grafana/provisioning/alerting/backup-failed.yaml
grep -q 'uid: backup_failed' /etc/grafana/provisioning/alerting/backup-failed.yaml
grep -q 'sum by (server, username, application)' /etc/grafana/provisioning/alerting/backup-failed.yaml
grep -q '{{ $labels.username }}' /etc/grafana/provisioning/alerting/backup-failed.yaml
grep -q '{{ $labels.application }}' /etc/grafana/provisioning/alerting/backup-failed.yaml
grep -q 'uid: disk_space_low' /etc/grafana/provisioning/alerting/disk-space.yaml
grep -q 'node_filesystem_avail_bytes' /etc/grafana/provisioning/alerting/disk-space.yaml
grep -q '15 \* 1024 \* 1024 \* 1024' /etc/grafana/provisioning/alerting/disk-space.yaml
grep -q '> 80' /etc/grafana/provisioning/alerting/disk-space.yaml
grep -q 'for: 5m' /etc/grafana/provisioning/alerting/disk-space.yaml
grep -q '{{ $labels.mountpoint }}' /etc/grafana/provisioning/alerting/disk-space.yaml
grep -q 'uid: cpu_high' /etc/grafana/provisioning/alerting/cpu-high.yaml
grep -q 'node_cpu_seconds_total{mode="idle"}' /etc/grafana/provisioning/alerting/cpu-high.yaml
grep -q '> 80' /etc/grafana/provisioning/alerting/cpu-high.yaml
grep -q 'for: 5m' /etc/grafana/provisioning/alerting/cpu-high.yaml
grep -q '{{ $labels.server }}' /etc/grafana/provisioning/alerting/cpu-high.yaml
grep -q 'uid: memory_high' /etc/grafana/provisioning/alerting/memory-high.yaml
grep -q 'node_memory_MemAvailable_bytes' /etc/grafana/provisioning/alerting/memory-high.yaml
grep -q '> 80' /etc/grafana/provisioning/alerting/memory-high.yaml
grep -q 'for: 5m' /etc/grafana/provisioning/alerting/memory-high.yaml
grep -q '{{ $labels.server }}' /etc/grafana/provisioning/alerting/memory-high.yaml
grep -q 'GF_AUTH_ANONYMOUS_ENABLED=false' /etc/systemd/system/grafana-server.service.d/server-tool.conf
grep -q 'GF_SERVER_ROOT_URL=https://monitor.example.test/' /etc/systemd/system/grafana-server.service.d/server-tool.conf
grep -q -- '--storage.tsdb.retention.time=30d' /etc/systemd/system/prometheus.service.d/server-tool.conf
sed -i 's/--storage.tsdb.retention.time=30d/--storage.tsdb.retention.time=15d/' /etc/systemd/system/prometheus.service.d/server-tool.conf
grep -q -- '--storage.tsdb.retention.time=15d' /etc/systemd/system/prometheus.service.d/server-tool.conf
server-tool update-monitoring -y
grep -q -- '--storage.tsdb.retention.time=30d' /etc/systemd/system/prometheus.service.d/server-tool.conf
[ "$(cat /etc/server-tool/monitoring-api.key)" = "$monitoring_key" ]
[ "$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /etc/server-tool/monitoring.conf)" = "$monitoring_password" ]
grep -q 'retention_period: 744h' /etc/loki/server-tool.yaml
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
grep -F 'stage.multiline' /etc/alloy/config.alloy >/dev/null
grep -F 'logfile' /etc/alloy/config.alloy >/dev/null
grep -F '(?P<level>DEBUG|INFO|NOTICE|WARNING|ERROR|CRITICAL|ALERT|EMERGENCY)' /etc/alloy/config.alloy >/dev/null
grep -F '/home/*/*/log/*.log' /etc/alloy/config.alloy >/dev/null
grep -F '/home/*/*/log/access.log' /etc/alloy/config.alloy >/dev/null
grep -F '/var/log/server-tool/backup.log' /etc/alloy/config.alloy >/dev/null
grep -F 'logtype = "backup"' /etc/alloy/config.alloy >/dev/null
grep -F '(?P<result>ok|failed)' /etc/alloy/config.alloy >/dev/null
test -f /var/log/server-tool/backup.log
grep -F 'loki_process_custom_nginx_requests_total' /etc/alloy/config.alloy >/dev/null
grep -F 'host=(?P<domain>' /etc/alloy/config.alloy >/dev/null
if grep -F 'releases/' /etc/alloy/config.alloy; then
    echo "Expected Alloy to follow current/storage/logs instead of release directories"
    exit 1
fi
test -f /var/lib/server-tool/monitoring/blackbox-targets.json
grep -qxF server-tool /etc/server-tool/alloy-layout
test ! -f /etc/cron.d/server-tool-forge-monitoring

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
upload_progress_php_conf="/etc/php/${php_version}/fpm/conf.d/99-server-tool-upload-progress.ini"
test -f "$upload_progress_php_conf"
grep -qxF '; CVE-2026-115560: disable session upload progress until the next PHP bugfix release.' "$upload_progress_php_conf"
grep -qxF 'session.upload_progress.enabled = 0' "$upload_progress_php_conf"
grep -qE 'session\.upload_progress\.enabled.*Off' <<< "$php_fpm_info"

echo "==> check-php-upload-progress --check does not write"
rm -f "$upload_progress_php_conf"
if check_out="$(server-tool check-php-upload-progress --check)"; then
    echo "Expected check-php-upload-progress --check to fail when upload progress is enabled"
    exit 1
fi
grep -q 'session.upload_progress.enabled = On' <<<"$check_out"
test ! -e "$upload_progress_php_conf"

echo "==> check-php-upload-progress restores the drop-in"
check_out="$(server-tool check-php-upload-progress -y)"
grep -q 'session.upload_progress.enabled = Off' <<<"$check_out"
test -f "$upload_progress_php_conf"
grep -qxF 'session.upload_progress.enabled = 0' "$upload_progress_php_conf"
php_fpm_info="$(php-fpm${php_version} -i)"
grep -qE 'session\.upload_progress\.enabled.*Off' <<< "$php_fpm_info"

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
grep -qF 'access_log /home/testdev/demo/log/access.log server_tool;' /home/testdev/demo/nginx/demo.conf
grep -qF '/home/testdev/demo/current/storage/logs/*.log' /etc/logrotate.d/server-tool
grep -qF 'su testdev testdev' /etc/logrotate.d/server-tool
grep -qF '/home/*/*/log/*.log' /etc/logrotate.d/server-tool
logrotate -d /etc/logrotate.d/server-tool >/dev/null
grep -q "php${php_version}-fpm-testdev-demo.sock" /home/testdev/demo/nginx/demo.conf
grep -qxF '# nginx-php-mode: strict' /home/testdev/demo/nginx/demo.conf
grep -qxF '# nginx-http-port: 80' /home/testdev/demo/nginx/demo.conf
grep -qxF '    listen 80;' /home/testdev/demo/nginx/demo.conf
grep -qxF '    listen [::]:80;' /home/testdev/demo/nginx/demo.conf
grep -qF 'location ~ ^/index\.php(/|$) {' /home/testdev/demo/nginx/demo.conf
demo_body="$(mktemp)"
demo_code="$(curl -sS -o "$demo_body" -w '%{http_code}' -H 'Host: demo' http://127.0.0.1/)"
[[ "$demo_code" == "200" ]]
grep -q 'phpinfo' "$demo_body"
unknown_code="$(curl -sS -o "$demo_body" -w '%{http_code}' -H 'Host: unknown.example' http://127.0.0.1/)"
[[ "$unknown_code" == "500" ]]
grep -qF 'No active host found' "$demo_body"
rm -f "$demo_body"
if grep -q 'fastcgi_split_path_info' /home/testdev/demo/nginx/demo.conf; then
    echo "Expected the default nginx config to omit fastcgi_split_path_info"
    exit 1
fi
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
server-tool list-apps -v | awk 'NR==1 {print $1,$2,$3,$4,$5,$6,$7,$8}' | grep -qxF 'USER APP NGINX AUTH SSL BACKUP SCHEDULER WORKERS'
test "$(verbose_app_field testdev demo NGINX)" = strict
test "$(verbose_app_field testdev demo AUTH)" = off
test "$(verbose_app_field testdev demo SSL)" = off
test "$(verbose_app_field testdev demo BACKUP)" = off
test "$(verbose_app_field testdev demo SCHEDULER)" = off
test "$(verbose_app_field testdev demo WORKERS)" = off
[[ "$(server-tool status | awk 'NR==1')" == "SSH password login: disabled" ]]
server-tool status | grep -qF "PHP ${php_version} FPM: session.upload_progress.enabled = Off"
server-tool status | grep -qF "Default host *:80: explicit"
[[ "$(server-tool status | awk '$1=="testdev" && $2=="demo" {print $3}')" == "strict" ]]
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
server-tool create-app testdev mysqlapp -d smoke_mysqlapp -t mysql -p "$php_version" --nginx legacy -y
test -f /home/testdev/mysqlapp/.env.db
grep -qxF '# nginx-php-mode: legacy' /home/testdev/mysqlapp/nginx/mysqlapp.conf
grep -qxF '# nginx-http-port: 80' /home/testdev/mysqlapp/nginx/mysqlapp.conf
grep -qxF '    listen 80;' /home/testdev/mysqlapp/nginx/mysqlapp.conf
grep -q 'fastcgi_split_path_info' /home/testdev/mysqlapp/nginx/mysqlapp.conf
test "$(verbose_app_field testdev mysqlapp NGINX)" = legacy
test "$(verbose_app_field testdev mysqlapp AUTH)" = off
test "$(verbose_app_field testdev mysqlapp SSL)" = off
test "$(verbose_app_field testdev mysqlapp BACKUP)" = off
test "$(verbose_app_field testdev mysqlapp SCHEDULER)" = off
test "$(verbose_app_field testdev mysqlapp WORKERS)" = off
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
if grep -qF '/home/testdev/mysqlapp/current/storage/logs/*.log' /etc/logrotate.d/server-tool; then
    echo "Expected logrotate config to drop the deleted application"
    exit 1
fi
grep -qF '/home/testdev/demo/current/storage/logs/*.log' /etc/logrotate.d/server-tool

echo "==> create-app testdev portapp --http-port 8080"
if server-tool create-app testdev portapp --http-port 70000 -y; then
    echo "Expected an HTTP port above 65535 to fail"
    exit 1
fi
server-tool create-app testdev portapp -p "$php_version" --http-port 8080 -y
grep -qxF '# nginx-http-port: 8080' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '    listen 8080;' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '    listen [::]:8080;' /home/testdev/portapp/nginx/portapp.conf
if grep -qxF '    listen 80;' /home/testdev/portapp/nginx/portapp.conf || grep -qxF '    listen [::]:80;' /home/testdev/portapp/nginx/portapp.conf; then
    echo "Expected portapp to listen on 8080"
    exit 1
fi
server-tool switch-nginx testdev portapp -m legacy -y
grep -qxF '# nginx-php-mode: legacy' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '# nginx-http-port: 8080' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '    listen 8080;' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '    listen [::]:8080;' /home/testdev/portapp/nginx/portapp.conf
server-tool switch-nginx testdev portapp -m strict -y
grep -qxF '# nginx-php-mode: strict' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '# nginx-http-port: 8080' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '    listen 8080;' /home/testdev/portapp/nginx/portapp.conf
grep -qxF '    listen [::]:8080;' /home/testdev/portapp/nginx/portapp.conf
server-tool delete-app testdev portapp -y
test ! -e /home/testdev/portapp

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
grep -q '^stdout_logfile_maxbytes=0$' /home/testdev/demo/supervisor/horizon.conf
grep -q '^stdout_logfile_backups=0$' /home/testdev/demo/supervisor/horizon.conf
test -L /etc/supervisor/conf.d/testdev_demo.d

echo "==> create-queue testdev demo"
server-tool create-queue testdev demo -y
test -f /home/testdev/demo/supervisor/queue.conf
grep -q "php${php_version} artisan queue:work --sleep=3 --tries=3 --timeout=60 --max-time=3600" /home/testdev/demo/supervisor/queue.conf
grep -q "directory=/home/testdev/demo/current/" /home/testdev/demo/supervisor/queue.conf
grep -q "program:queue-testdev-demo" /home/testdev/demo/supervisor/queue.conf
grep -q "stopwaitsecs=3600" /home/testdev/demo/supervisor/queue.conf
grep -q '^stdout_logfile_maxbytes=0$' /home/testdev/demo/supervisor/queue.conf
grep -q '^stdout_logfile_backups=0$' /home/testdev/demo/supervisor/queue.conf

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
expected_workers=off
supervisor_status="$(supervisorctl status 2>/dev/null || true)"
horizon_running=0
queue_running=0
if printf '%s\n' "$supervisor_status" | awk '$2=="RUNNING" && ($1=="horizon-testdev-demo" || index($1,"horizon-testdev-demo:")==1) {found=1} END {exit !found}'; then
    horizon_running=1
fi
if printf '%s\n' "$supervisor_status" | awk '$2=="RUNNING" && ($1=="queue-testdev-demo" || index($1,"queue-testdev-demo:")==1) {found=1} END {exit !found}'; then
    queue_running=1
fi
if [ "$horizon_running" -eq 1 ] && [ "$queue_running" -eq 1 ]; then
    expected_workers=horizon,default
elif [ "$horizon_running" -eq 1 ]; then
    expected_workers=horizon
elif [ "$queue_running" -eq 1 ]; then
    expected_workers=default
fi
test "$(verbose_app_field testdev demo WORKERS)" = "$expected_workers"

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
test "$(verbose_app_field testdev demo AUTH)" = on

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
if grep -q 'listen 443 ssl default_server' /home/testdev/demo/nginx/demo.conf; then
    echo "Expected the application not to become the default https server"
    exit 1
fi
grep -q 'ssl_reject_handshake on;' /etc/nginx/conf.d/00-server-tool-default-host.conf
test -f /home/testdev/demo/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo/nginx/ssl/demo.example.test.key
grep -q "return 301 https" /home/testdev/demo/nginx/demo.conf
grep -qF 'access_log /home/testdev/demo/log/access.log server_tool;' /home/testdev/demo/nginx/demo.conf
grep -qxF '# nginx-php-mode: strict' /home/testdev/demo/nginx/demo.conf
grep -qxF '# nginx-http-port: 80' /home/testdev/demo/nginx/demo.conf
grep -qxF '    listen 80;' /home/testdev/demo/nginx/demo.conf
grep -qxF '    listen [::]:80;' /home/testdev/demo/nginx/demo.conf
grep -qF 'location ~ ^/index\.php(/|$) {' /home/testdev/demo/nginx/demo.conf
test "$(verbose_app_field testdev demo SSL)" = self-signed

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

echo "==> enable-ssl testdev demo replaces self-signed with Let's Encrypt"
cat > /usr/local/bin/certbot <<'EOF'
#!/bin/bash
set -euo pipefail
domain=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cert-name)
            domain="$2"
            shift 2
            ;;
        -d|--domain)
            if [ -z "$domain" ]; then
                domain="$2"
            fi
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
    -subj "/CN=${domain}/O=Lets Encrypt Stub" \
    -days 30 >/dev/null 2>&1
EOF
chmod 755 /usr/local/bin/certbot
server-tool enable-ssl testdev demo -d demo.example.test -e admin@example.test -y
cmp /etc/letsencrypt/live/demo.example.test/fullchain.pem /home/testdev/demo/nginx/ssl/demo.example.test.pem
cmp /etc/letsencrypt/live/demo.example.test/privkey.pem /home/testdev/demo/nginx/ssl/demo.example.test.key
openssl x509 -in /home/testdev/demo/nginx/ssl/demo.example.test.pem -noout -subject | grep -q 'Lets Encrypt Stub'
test -f /etc/letsencrypt/renewal-hooks/deploy/testdev_demo.sh
grep -q '/home/testdev/demo/nginx/ssl/demo.example.test.pem' /etc/letsencrypt/renewal-hooks/deploy/testdev_demo.sh
test "$(verbose_app_field testdev demo SSL)" = letsencrypt
grep -q "listen 443 ssl" /home/testdev/demo/nginx/demo.conf

echo "==> enable-ssl again leaves the Let's Encrypt certificate in place"
ssl_checksum="$(sha256sum /home/testdev/demo/nginx/ssl/demo.example.test.pem | awk '{print $1}')"
enable_ssl_again="$(server-tool enable-ssl testdev demo -d demo.example.test -y)"
grep -q 'leaving the nginx config unchanged' <<< "$enable_ssl_again"
grep -q 'HTTPS is already enabled.' <<< "$enable_ssl_again"
test "$(sha256sum /home/testdev/demo/nginx/ssl/demo.example.test.pem | awk '{print $1}')" = "$ssl_checksum"
test "$(verbose_app_field testdev demo SSL)" = letsencrypt

echo "==> enable-ssl --renew reissues Let's Encrypt"
server-tool enable-ssl testdev demo -d demo.example.test --renew -y
test "$(sha256sum /home/testdev/demo/nginx/ssl/demo.example.test.pem | awk '{print $1}')" != "$ssl_checksum"
openssl x509 -in /home/testdev/demo/nginx/ssl/demo.example.test.pem -noout -subject | grep -q 'Lets Encrypt Stub'
test "$(verbose_app_field testdev demo SSL)" = letsencrypt
rm -f /usr/local/bin/certbot

echo "==> enable-scheduler testdev demo"
test -d /home/testdev/demo/cron
server-tool enable-scheduler testdev demo -y
grep -q "php${php_version} artisan schedule:run" /home/testdev/demo/cron/scheduler
crontab -u testdev -l | grep -qF '# BEGIN server-tool app: testdev/demo'
crontab -u testdev -l | grep -qF "cd /home/testdev/demo/current && php${php_version} artisan schedule:run"
crontab -u testdev -l | grep -qF '# END server-tool app: testdev/demo'
test "$(verbose_app_field testdev demo SCHEDULER)" = on

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
grep -q '^stdout_logfile_maxbytes=0$' /home/testdev/demo2/supervisor/queue.conf
grep -qF '/home/testdev/demo2/current/storage/logs/*.log' /etc/logrotate.d/server-tool
if grep -qF '/home/testdev/demo/current/storage/logs/*.log' /etc/logrotate.d/server-tool; then
    echo "Expected logrotate config to follow the renamed application"
    exit 1
fi
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
grep -qxF '# nginx-php-mode: strict' /home/testdev/demo2/nginx/demo2.conf

echo "==> switch-nginx testdev demo2"
if server-tool switch-nginx testdev demo2 -m strict -y; then
    echo "Expected switch-nginx to the current mode to fail"
    exit 1
fi
if server-tool switch-nginx testdev demo2 -y; then
    echo "Expected switch-nginx -y without -m to fail"
    exit 1
fi
sed -i \
    -e 's/listen 80;/listen 8080;/' \
    -e 's/listen \[::\]:80;/listen [::]:8080;/' \
    /home/testdev/demo2/nginx/demo2.conf
server-tool switch-nginx testdev demo2 -m legacy -y
grep -qxF '# nginx-php-mode: legacy' /home/testdev/demo2/nginx/demo2.conf
grep -qxF '# nginx-http-port: 8080' /home/testdev/demo2/nginx/demo2.conf
grep -qxF '    listen 8080;' /home/testdev/demo2/nginx/demo2.conf
grep -qxF '    listen [::]:8080;' /home/testdev/demo2/nginx/demo2.conf
if grep -qxF '    listen 80;' /home/testdev/demo2/nginx/demo2.conf || grep -qxF '    listen [::]:80;' /home/testdev/demo2/nginx/demo2.conf; then
    echo "Expected switch-nginx to keep HTTP port 8080"
    exit 1
fi
grep -q 'fastcgi_split_path_info' /home/testdev/demo2/nginx/demo2.conf
grep -qE 'server_name[[:space:]]+.*demo\.example\.test' /home/testdev/demo2/nginx/demo2.conf
grep -qE 'server_name[[:space:]]+.*demo2' /home/testdev/demo2/nginx/demo2.conf
grep -q "listen 443 ssl" /home/testdev/demo2/nginx/demo2.conf
grep -q "php${php_version}-fpm-testdev-demo2.sock" /home/testdev/demo2/nginx/demo2.conf
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.key
server-tool switch-nginx testdev demo2 -m strict -y
grep -qxF '# nginx-php-mode: strict' /home/testdev/demo2/nginx/demo2.conf
grep -qxF '# nginx-http-port: 8080' /home/testdev/demo2/nginx/demo2.conf
grep -qxF '    listen 8080;' /home/testdev/demo2/nginx/demo2.conf
grep -qxF '    listen [::]:8080;' /home/testdev/demo2/nginx/demo2.conf
if grep -qxF '    listen 80;' /home/testdev/demo2/nginx/demo2.conf || grep -qxF '    listen [::]:80;' /home/testdev/demo2/nginx/demo2.conf; then
    echo "Expected switch-nginx to keep HTTP port 8080"
    exit 1
fi
grep -qF 'location ~ ^/index\.php(/|$) {' /home/testdev/demo2/nginx/demo2.conf
if grep -q 'fastcgi_split_path_info' /home/testdev/demo2/nginx/demo2.conf; then
    echo "Expected strict nginx config to omit fastcgi_split_path_info"
    exit 1
fi
grep -qE 'server_name[[:space:]]+.*demo\.example\.test' /home/testdev/demo2/nginx/demo2.conf
grep -qE 'server_name[[:space:]]+.*demo2' /home/testdev/demo2/nginx/demo2.conf
grep -q "listen 443 ssl" /home/testdev/demo2/nginx/demo2.conf
grep -q "php${php_version}-fpm-testdev-demo2.sock" /home/testdev/demo2/nginx/demo2.conf
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.pem
test -f /home/testdev/demo2/nginx/ssl/demo.example.test.key

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

echo "==> update-php upgrades every installed version"
update_php_out="$(server-tool update-php -y)"
grep -qF "  ${php_version}:" <<<"$update_php_out"
grep -qF "  ${other_php_version}:" <<<"$update_php_out"
systemctl is-active --quiet "php${php_version}-fpm"
systemctl is-active --quiet "php${other_php_version}-fpm"
php_fpm_info="$(php-fpm${php_version} -i)"
grep -qE 'upload_max_filesize.*150M' <<<"$php_fpm_info"

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
if grep -qF '/home/testdev/demo2/current/storage/logs/*.log' /etc/logrotate.d/server-tool; then
    echo "Expected logrotate config to drop the deleted application"
    exit 1
fi
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

echo "==> verbose workers column follows supervisor status"
workers_root="$(mktemp -d)"
mkdir -p "$workers_root/supervisor"
APP_VERBOSE_SUPERVISOR_KNOWN=1
APP_VERBOSE_SUPERVISOR_STATUS=$'horizon-testdev-demo:horizon-testdev-demo_00 RUNNING pid 1, uptime 0:01:00\nqueue-testdev-demo:queue-testdev-demo_00 RUNNING pid 2, uptime 0:01:00'
printf '%s\n' 'command=php8.4 artisan queue:work --queue=emails,reports --sleep=3' > "$workers_root/supervisor/queue.conf"
[[ "$(app_workers_column testdev demo "$workers_root")" == "horizon,emails,reports" ]]
printf '%s\n' 'command=php8.4 artisan queue:work --sleep=3' > "$workers_root/supervisor/queue.conf"
[[ "$(app_workers_column testdev demo "$workers_root")" == "horizon,default" ]]
APP_VERBOSE_SUPERVISOR_STATUS=$'queue-testdev-demo:queue-testdev-demo_00 RUNNING pid 2, uptime 0:01:00'
[[ "$(app_workers_column testdev demo "$workers_root")" == "default" ]]
APP_VERBOSE_SUPERVISOR_STATUS=$'horizon-testdev-demo2:horizon-testdev-demo2_00 RUNNING pid 3, uptime 0:01:00'
[[ "$(app_workers_column testdev demo "$workers_root")" == "off" ]]
[[ "$(app_workers_column testdev demo2 "$workers_root")" == "horizon" ]]
APP_VERBOSE_SUPERVISOR_STATUS=$'horizon-testdev-demo:horizon-testdev-demo_00 FATAL Exited too quickly'
[[ "$(app_workers_column testdev demo "$workers_root")" == "off" ]]
APP_VERBOSE_SUPERVISOR_KNOWN=0
[[ "$(app_workers_column testdev demo "$workers_root")" == "unknown" ]]
rm -rf "$workers_root"

echo "==> backup-app testdev demo --enable"
server-tool backup-app testdev demo --enable -y
test -f /etc/cron.d/server-tool-backup-testdev-demo
grep -q 'PATH=' /etc/cron.d/server-tool-backup-testdev-demo
grep -qF 'backup-app testdev demo -y' /etc/cron.d/server-tool-backup-testdev-demo
test "$(verbose_app_field testdev demo BACKUP)" = on

echo "==> backup-app testdev demo --disable"
server-tool backup-app testdev demo --disable -y
test ! -f /etc/cron.d/server-tool-backup-testdev-demo
test "$(verbose_app_field testdev demo BACKUP)" = off

echo "==> install aws smoke-bucket (stub CLI)"
cat > /usr/local/bin/aws <<'EOF'
#!/bin/bash
set -euo pipefail

if [ "${AWS_REQUEST_CHECKSUM_CALCULATION:-}" != "when_required" ]; then
    echo "aws stub: expected AWS_REQUEST_CHECKSUM_CALCULATION=when_required" >&2
    exit 1
fi
if [ "${AWS_RESPONSE_CHECKSUM_VALIDATION:-}" != "when_required" ]; then
    echo "aws stub: expected AWS_RESPONSE_CHECKSUM_VALIDATION=when_required" >&2
    exit 1
fi
if [ "${1:-}" != "s3api" ] || [ -z "${2:-}" ]; then
    echo "aws stub: unexpected: $*" >&2
    exit 1
fi

op="$2"
shift 2
bucket=""
key=""
body=""
content_md5=""
upload_id=""
part_number=""
multipart_upload=""
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket) bucket="$2"; shift 2 ;;
        --key) key="$2"; shift 2 ;;
        --body) body="$2"; shift 2 ;;
        --content-md5) content_md5="$2"; shift 2 ;;
        --region) shift 2 ;;
        --upload-id) upload_id="$2"; shift 2 ;;
        --part-number) part_number="$2"; shift 2 ;;
        --multipart-upload) multipart_upload="$2"; shift 2 ;;
        --query) shift 2 ;;
        --output) shift 2 ;;
        *)
            echo "aws stub: unexpected arg: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$bucket" ] || [ -z "$key" ]; then
    echo "aws stub: missing bucket or key" >&2
    exit 1
fi

mkdir -p /tmp/s3-mock
log_op() {
    printf '%s\n' "$1" >> /tmp/s3-mock/ops.log
}

require_content_md5() {
    local expected
    if [ -z "$body" ] || [ ! -f "$body" ]; then
        echo "aws stub: missing body" >&2
        exit 1
    fi
    if [ -z "$content_md5" ]; then
        echo "aws stub: Content-MD5 is required" >&2
        exit 1
    fi
    expected="$(openssl dgst -md5 -binary "$body" | openssl base64 | tr -d '\n')"
    if [ "$content_md5" != "$expected" ]; then
        echo "aws stub: content-md5 mismatch for $key" >&2
        echo "  got:      $content_md5" >&2
        echo "  expected: $expected" >&2
        exit 1
    fi
}

case "$op" in
    put-object)
        require_content_md5
        mkdir -p "/tmp/s3-mock/$bucket/$(dirname "$key")"
        cp "$body" "/tmp/s3-mock/$bucket/$key"
        log_op "put-object $bucket $key"
        ;;
    create-multipart-upload)
        upload_id="upid-${bucket}-${key//\//_}-$$"
        mkdir -p "/tmp/s3-mock-uploads/$upload_id"
        printf '%s\n' "$bucket" > "/tmp/s3-mock-uploads/$upload_id/bucket"
        printf '%s\n' "$key" > "/tmp/s3-mock-uploads/$upload_id/key"
        log_op "create $bucket $key"
        printf '%s\n' "$upload_id"
        ;;
    upload-part)
        require_content_md5
        if [ -z "$upload_id" ] || [ -z "$part_number" ]; then
            echo "aws stub: missing upload id or part number" >&2
            exit 1
        fi
        if [ ! -d "/tmp/s3-mock-uploads/$upload_id" ]; then
            echo "aws stub: unknown upload id $upload_id" >&2
            exit 1
        fi
        cp "$body" "/tmp/s3-mock-uploads/$upload_id/$part_number"
        log_op "upload-part $bucket $key $part_number"
        printf '"%s"\n' "$(openssl dgst -md5 "$body" | awk '{print $NF}')"
        ;;
    complete-multipart-upload)
        if [ -z "$upload_id" ] || [ -z "$multipart_upload" ]; then
            echo "aws stub: missing upload id or part list" >&2
            exit 1
        fi
        python3 - "$multipart_upload" "/tmp/s3-mock-uploads/$upload_id" "/tmp/s3-mock/$bucket/$key" <<'PY'
import hashlib, json, os, sys

spec_path, upload_dir, dest = sys.argv[1:]
if spec_path.startswith("file://"):
    spec_path = spec_path[len("file://"):]
with open(spec_path, encoding="utf-8") as handle:
    spec = json.load(handle)
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest, "wb") as out:
    for part in spec["Parts"]:
        number = part["PartNumber"]
        etag = str(part["ETag"]).strip('"')
        path = os.path.join(upload_dir, str(number))
        with open(path, "rb") as handle:
            data = handle.read()
        digest = hashlib.md5(data).hexdigest()
        if digest != etag:
            sys.stderr.write(f"aws stub: etag mismatch for part {number}: {etag} != {digest}\n")
            sys.exit(1)
        out.write(data)
PY
        log_op "complete $bucket $key"
        rm -rf "/tmp/s3-mock-uploads/$upload_id"
        ;;
    abort-multipart-upload)
        if [ -z "$upload_id" ]; then
            echo "aws stub: missing upload id" >&2
            exit 1
        fi
        log_op "abort $bucket $key $upload_id"
        rm -rf "/tmp/s3-mock-uploads/$upload_id"
        ;;
    *)
        echo "aws stub: unexpected operation: $op" >&2
        exit 1
        ;;
esac
EOF
chmod +x /usr/local/bin/aws
server-tool install aws smoke-bucket -y
test -f /etc/server-tool/backup.conf
grep -qxF 'S3_BUCKET=smoke-bucket' /etc/server-tool/backup.conf

echo "==> test-backup"
server-tool test-backup -y
server_name="$(hostname -s)"
test -s "/tmp/s3-mock/smoke-bucket/${server_name}/.server-tool-check"
grep -qxF "put-object smoke-bucket ${server_name}/.server-tool-check" /tmp/s3-mock/ops.log

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
mkdir -p /home/testdev/demo/shared/storage/app /home/testdev/demo/current/public
echo keep > /home/testdev/demo/shared/storage/app/keep.txt
ln -s ../../shared/storage /home/testdev/demo/current/public/storage
chown -R testdev:testdev /home/testdev/demo/log /home/testdev/demo/releases /home/testdev/demo/install /home/testdev/demo/nginx
server-tool backup-app testdev demo -y
weekday="$(LC_ALL=C date +%A | tr '[:upper:]' '[:lower:]')"
server_name="$(hostname -s)"
backup_zip="/tmp/s3-mock/smoke-bucket/${server_name}/testdev/demo/${weekday}.zip"
test -s "$backup_zip"
unzip -t "$backup_zip" >/dev/null
zip_list="$(unzip -Z1 "$backup_zip")"
grep -q 'current/public/index.php' <<< "$zip_list"
grep -qxF 'shared/storage/app/keep.txt' <<< "$zip_list"
grep -qxF 'current/public/storage' <<< "$zip_list"
! grep -q 'current/public/storage/' <<< "$zip_list"
test "$(unzip -p "$backup_zip" current/public/storage)" = "../../shared/storage"
unzip -Z "$backup_zip" current/public/storage | grep -q '^l'
grep -q 'username=testdev application=demo result=ok ' /var/log/server-tool/backup.log
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
grep -qxF "put-object smoke-bucket ${server_name}/testdev/demo/${weekday}.zip" /tmp/s3-mock/ops.log

echo "==> s3 multipart upload sends Content-MD5 per part"
# shellcheck disable=SC1091
source "$repo_dir/lib/common"
multipart_src="$(mktemp)"
dd if=/dev/zero of="$multipart_src" bs=1048576 count=65 status=none
aws_s3_upload "$multipart_src" "s3://smoke-bucket/multipart-check.bin"
test "$(grep -c '^upload-part smoke-bucket multipart-check.bin ' /tmp/s3-mock/ops.log)" = 2
grep -qxF "complete smoke-bucket multipart-check.bin" /tmp/s3-mock/ops.log
cmp "$multipart_src" /tmp/s3-mock/smoke-bucket/multipart-check.bin
rm -f "$multipart_src"

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

echo "==> forge alloy layout"
export SERVER_TOOL_ROOT="$repo_dir"
# shellcheck disable=SC1091
. "$repo_dir/lib/common"

if ! host_is_supported debian bookworm install nginx; then
    echo "Expected Debian 12 to allow every command"
    exit 1
fi
if host_is_supported debian bullseye install nginx; then
    echo "Expected Debian 11 to be rejected"
    exit 1
fi
if ! host_is_supported ubuntu jammy install alloy --url https://grafana.example.com --api-key-file /root/monitoring-api.key --forge; then
    echo "Expected Ubuntu 22.04 to allow install alloy --forge"
    exit 1
fi
if ! host_is_supported ubuntu noble install alloy --url https://grafana.example.com --api-key-file /root/monitoring-api.key --forge; then
    echo "Expected Ubuntu 24.04 to allow install alloy --forge"
    exit 1
fi
if ! host_is_supported ubuntu jammy self-update; then
    echo "Expected Ubuntu 22.04 to allow self-update"
    exit 1
fi
if ! host_is_supported ubuntu noble self-update; then
    echo "Expected Ubuntu 24.04 to allow self-update"
    exit 1
fi
if host_is_supported ubuntu focal self-update; then
    echo "Expected Ubuntu 20.04 to reject self-update"
    exit 1
fi
if host_is_supported ubuntu jammy install alloy --url https://grafana.example.com --api-key-file /root/monitoring-api.key; then
    echo "Expected Ubuntu to reject install alloy without --forge"
    exit 1
fi
if host_is_supported ubuntu jammy install nginx; then
    echo "Expected Ubuntu to reject install nginx"
    exit 1
fi
if host_is_supported ubuntu jammy install nginx alloy --forge; then
    echo "Expected Ubuntu to reject install alloy --forge combined with another package"
    exit 1
fi
if host_is_supported ubuntu focal install alloy --url https://grafana.example.com --api-key-file /root/monitoring-api.key --forge; then
    echo "Expected Ubuntu 20.04 to be rejected"
    exit 1
fi
if host_is_supported ubuntu noble update-probes; then
    echo "Expected update-probes on Ubuntu to require a Forge install"
    exit 1
fi
write_alloy_layout forge
forge_update_ok=0
if host_is_supported ubuntu noble update-probes; then
    forge_update_ok=1
fi
write_alloy_layout server-tool
if [ "$forge_update_ok" -ne 1 ]; then
    echo "Expected update-probes on Ubuntu after a Forge install"
    exit 1
fi
grep -qxF server-tool /etc/server-tool/alloy-layout

forge_cfg="$(mktemp)"
render_alloy_config "https://monitor.example.test" "test-key" "forge-host" forge "$forge_cfg"
grep -F '/home/*/*/storage/logs/*.log' "$forge_cfg" >/dev/null
grep -F '/var/log/nginx/*-error.log' "$forge_cfg" >/dev/null
grep -F '/var/log/nginx/*-access.log' "$forge_cfg" >/dev/null
grep -F 'else }}forge{{ end }}' "$forge_cfg" >/dev/null
grep -F 'loki_process_custom_nginx_requests_total' "$forge_cfg" >/dev/null
grep -F 'https://monitor.example.test/loki/api/v1/push' "$forge_cfg" >/dev/null
grep -F 'stage.multiline' "$forge_cfg" >/dev/null
if grep -F 'backup.log' "$forge_cfg"; then
    echo "Expected the Forge Alloy config to omit backup logs"
    exit 1
fi
if grep -F 'host=(?P<domain>' "$forge_cfg"; then
    echo "Expected the Forge Alloy config to take the domain from the nginx file name"
    exit 1
fi
if grep -F 'releases/' "$forge_cfg"; then
    echo "Expected the Forge Alloy config to skip release directories"
    exit 1
fi
if grep -F '/home/*/*/current/storage/logs/*.log' "$forge_cfg"; then
    echo "Expected the Forge Alloy config to read site storage/logs, not current/"
    exit 1
fi
if grep -F '/home/*/*/log/*.log' "$forge_cfg"; then
    echo "Expected the Forge Alloy config to skip server-tool nginx log directories"
    exit 1
fi
rm -f "$forge_cfg"

forge_site="/home/forge/demo.example.test"
mkdir -p "$forge_site/storage/logs"
echo '[2026-10-06 08:00:59] staging.ERROR: forge' > "$forge_site/storage/logs/laravel.log"
chmod 750 /home/forge "$forge_site" "$forge_site/storage" "$forge_site/storage/logs"
chmod 640 "$forge_site/storage/logs/laravel.log"
grant_forge_log_access
getfacl "$forge_site/storage/logs" | grep -q 'user:alloy:r-x'
getfacl /home/forge | grep -q 'default:user:alloy:r-x'
getfacl /home/testdev | grep -q 'user:alloy:r-x'
if getfacl /home/testdev | grep -q 'default:user:alloy:'; then
    echo "Expected Forge log access to leave server-tool homes unchanged"
    exit 1
fi

forge_nginx_conf="/etc/nginx/sites-available/zz-forge-smoke"
forge_nginx_link="/etc/nginx/sites-enabled/zz-forge-smoke"
cat > "$forge_nginx_conf" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name forge.example.test;
    return 301 https://forge.example.test$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name forge.example.test;
    root /home/forge/demo.example.test/current/public;
}
EOF
ln -s "$forge_nginx_conf" "$forge_nginx_link"
write_forge_blackbox_targets
grep -q 'https://forge.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q '"username": "forge"' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q '"application": "demo.example.test"' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q '"domain": "forge.example.test"' /var/lib/server-tool/monitoring/blackbox-targets.json
rm -f "$forge_nginx_link" "$forge_nginx_conf"
write_monitoring_blackbox_targets
if grep -q 'forge.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json; then
    echo "Expected the Forge probe to be removed when Debian probes are restored"
    exit 1
fi
rm -rf /home/forge

install_forge_monitoring_cron
grep -q 'update-probes -y' /etc/cron.d/server-tool-forge-monitoring
grep -q 'PATH=' /etc/cron.d/server-tool-forge-monitoring
remove_forge_monitoring_cron
test ! -f /etc/cron.d/server-tool-forge-monitoring

echo "==> monitoring host alloy layout"
monitoring_cfg="$(mktemp)"
render_alloy_config "https://monitor.example.test" "test-key" "monitor-host" monitoring "$monitoring_cfg"
grep -F 'logtype = "journal"' "$monitoring_cfg" >/dev/null
grep -F '/var/log/nginx/access.log' "$monitoring_cfg" >/dev/null
grep -F '/var/log/nginx/error.log' "$monitoring_cfg" >/dev/null
grep -F 'domain        = "monitor.example.test"' "$monitoring_cfg" >/dev/null
grep -F 'username      = "monitoring"' "$monitoring_cfg" >/dev/null
grep -F 'application   = "grafana"' "$monitoring_cfg" >/dev/null
grep -F 'loki_process_custom_nginx_requests_total' "$monitoring_cfg" >/dev/null
grep -F 'https://monitor.example.test/loki/api/v1/push' "$monitoring_cfg" >/dev/null
if grep -F 'backup.log' "$monitoring_cfg"; then
    echo "Expected the monitoring Alloy config to omit backup logs"
    exit 1
fi
if grep -F '/home/*/*/' "$monitoring_cfg"; then
    echo "Expected the monitoring Alloy config to omit application home globs"
    exit 1
fi
if grep -F 'host=(?P<domain>' "$monitoring_cfg"; then
    echo "Expected the monitoring Alloy config to use a fixed domain label"
    exit 1
fi
if grep -F '__MONITORING_DOMAIN__' "$monitoring_cfg"; then
    echo "Expected __MONITORING_DOMAIN__ to be replaced"
    exit 1
fi
rm -f "$monitoring_cfg"

saved_probes="$(mktemp)"
cp /var/lib/server-tool/monitoring/blackbox-targets.json "$saved_probes"
write_monitoring_host_blackbox_targets
grep -q 'https://monitor.example.test' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q '"username": "monitoring"' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q '"application": "grafana"' /var/lib/server-tool/monitoring/blackbox-targets.json
grep -q '"domain": "monitor.example.test"' /var/lib/server-tool/monitoring/blackbox-targets.json
cp "$saved_probes" /var/lib/server-tool/monitoring/blackbox-targets.json
rm -f "$saved_probes"
grep -qxF server-tool /etc/server-tool/alloy-layout
grep -F '/home/*/*/current/storage/logs/*.log' /etc/alloy/config.alloy >/dev/null

echo "==> smoke test passed"

#!/bin/bash
# Railway entrypoint for ERPNext v16. A Railway volume attaches to one service and
# every Frappe process needs sites/, so they all run here: nginx on $PORT, gunicorn,
# the socket.io server, background workers, the scheduler, and Redis for the cache
# and the job queue. The site is created on first boot with a generated
# Administrator password, migrated on the first boot of a new image version, and
# backed up nightly to the Railway bucket.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITE=erp  # a site may not share its name with an app
cd "$BENCH"
# An array, not a function: a backgrounded function runs in a subshell that
# swallows SIGTERM instead of passing it on.
AS_FRAPPE=(setpriv --reuid=frappe --regid="$(id -g frappe)" --init-groups env HOME=/home/frappe)
: "${DB_HOST:?DB_HOST is not set}" "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is not set}"

# Worker counts follow the memory Railway gives this service (the cgroup limit is the
# plan's per-service cap), never the host's 48 cores.
mem=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
small=$([ "$mem" != max ] && [ "$mem" -lt 2000000000 ] && echo 1 || echo 0)
WEB_WORKERS=${ERPNEXT_WEB_WORKERS:-$([ "$small" = 1 ] && echo 1 || echo 2)}
BG_WORKERS=${ERPNEXT_BG_WORKERS:-$([ "$small" = 1 ] && echo 1 || echo 2)}

# Railway volumes mount root-owned.
chown frappe: sites
# The volume hides what the image keeps in sites/: the app list, and the built
# assets, linked from the image so a new version serves its own.
cp /home/frappe/apps.txt /home/frappe/apps.json sites/
rm -rf sites/assets
ln -s "$BENCH/assets" sites/assets
mkdir -p sites/.redis
chown frappe: sites/apps.txt sites/apps.json sites/.redis

# Merged rather than rewritten, so settings made with `bench set-config -g` survive.
conf=sites/common_site_config.json
[ -s "$conf" ] || echo '{}' > "$conf"
jq --arg host "$DB_HOST" --argjson port "${DB_PORT:-3306}" '. + {
      db_host: $host, db_port: $port, default_site: "erp", socketio_port: 9000,
      redis_cache: "redis://127.0.0.1:13000", redis_queue: "redis://127.0.0.1:11000",
      redis_socketio: "redis://127.0.0.1:11000"}' "$conf" > "$conf.new"
mv "$conf.new" "$conf"
chown frappe: "$conf"

trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM INT

# The cache lives in memory only. The job queue is saved to the volume on shutdown,
# so jobs still waiting at a redeploy run after it.
"${AS_FRAPPE[@]}" redis-server --bind 127.0.0.1 --port 13000 --save '' --appendonly no \
  --maxmemory 256mb --maxmemory-policy allkeys-lru --loglevel warning 2>&1 &
"${AS_FRAPPE[@]}" redis-server --bind 127.0.0.1 --port 11000 --dir "$BENCH/sites/.redis" \
  --dbfilename queue.rdb --save 3600 1 --stop-writes-on-bgsave-error no --appendonly no \
  --loglevel warning 2>&1 &

# On a fresh deploy MariaDB may still be starting.
echo "railway: waiting for MariaDB at $DB_HOST"
for _ in $(seq 150); do
  MYSQL_PWD=$DB_ROOT_PASSWORD mariadb-admin ping -h "$DB_HOST" -P "${DB_PORT:-3306}" \
    -u root --silent >/dev/null 2>&1 && break
  sleep 2
done

# Frappe redraws its progress bars with \r, which Railway would log as one huge line;
# keep only each bar's final state.
bars() { sed -u 's/.*\r//'; }
# Every app in the image beyond frappe, unless FRAPPE_INSTALL_APPS narrows it.
read -ra APPS <<< "${FRAPPE_INSTALL_APPS:-$(grep -vx frappe sites/apps.txt | tr '\n' ' ')}"
installed() { "${AS_FRAPPE[@]}" bench --site "$SITE" list-apps 2>/dev/null | grep -q "^$1"; }
if [ ! -f "sites/$SITE/.railway-installed" ]; then
  # A site folder without the marker is a first boot that died part-way (the site
  # never served a request), unless the first app is fully installed and only the
  # marker is missing. Only the first case is rebuilt.
  if ! { [ -d "sites/$SITE" ] && installed "${APPS[0]}"; }; then
    : "${ERPNEXT_ADMIN_PASSWORD:?ERPNEXT_ADMIN_PASSWORD is not set}"
    echo "railway: first boot, creating the site with ${APPS[*]} (a few minutes)"
    "${AS_FRAPPE[@]}" bench new-site "$SITE" --force --mariadb-user-host-login-scope=% \
      --db-root-username root --db-root-password "$DB_ROOT_PASSWORD" \
      --admin-password "$ERPNEXT_ADMIN_PASSWORD" --install-app "${APPS[0]}" --set-default 2>&1 | bars
    installed "${APPS[0]}" || { echo "railway: site creation failed, retrying on restart"; exit 1; }
  fi
  "${AS_FRAPPE[@]}" touch "sites/$SITE/.railway-installed"
  fresh=1
fi
# The rest of the apps, on first boot and whenever an image adds one.
for app in "${APPS[@]:1}"; do
  installed "$app" && continue
  echo "railway: installing $app"
  "${AS_FRAPPE[@]}" bench --site "$SITE" install-app "$app" 2>&1 | bars
  installed "$app" || { echo "railway: installing $app failed, retrying on restart"; exit 1; }
done

# A new image version needs `bench migrate` before it serves the site: patches,
# schema changes and fixtures. A database backup is taken first.
version=$(for app in $(cat sites/apps.txt); do
  printf '%s %s, ' "$app" "$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "apps/$app/$app/__init__.py")"; done)
if [ "$(cat "sites/$SITE/.railway-version" 2>/dev/null)" != "$version" ]; then
  if [ -z "${fresh:-}" ]; then
    echo "railway: new version ($version), backing up the database and migrating"
    "${AS_FRAPPE[@]}" bench --site "$SITE" backup 2>&1
    "${AS_FRAPPE[@]}" bench --site "$SITE" migrate 2>&1 | bars
  fi
  echo "$version" | "${AS_FRAPPE[@]}" tee "sites/$SITE/.railway-version" >/dev/null
fi

# The public URL for links in emails and PDFs, which background jobs build without a
# request to take the host from.
url=${ERPNEXT_URL:-${RAILWAY_PUBLIC_DOMAIN:+https://$RAILWAY_PUBLIC_DOMAIN}}
site_conf=sites/$SITE/site_config.json
jq --arg url "$url" 'if $url == "" then del(.host_name) else .host_name = $url end' \
  "$site_conf" > /tmp/site_config.json
cat /tmp/site_config.json > "$site_conf" && rm /tmp/site_config.json

# --preload shares the loaded app between workers; with one worker it only keeps a
# second copy in the master, about 75 MB of a small plan.
preload=$([ "$WEB_WORKERS" -gt 1 ] && echo --preload || true)
"${AS_FRAPPE[@]}" env/bin/gunicorn --chdir=sites --bind=127.0.0.1:8000 \
  --workers="$WEB_WORKERS" --threads=4 --worker-class=gthread --worker-tmp-dir=/dev/shm \
  --timeout=120 --max-requests=5000 --max-requests-jitter=500 $preload \
  frappe.app:application 2>&1 &
"${AS_FRAPPE[@]}" node apps/frappe/socketio.js 2>&1 &
"${AS_FRAPPE[@]}" bench schedule 2>&1 &
# --quiet drops the four lines logged for every job; failed jobs are still logged.
if [ "$BG_WORKERS" = 1 ]; then
  "${AS_FRAPPE[@]}" bench worker --quiet --queue short,default,long 2>&1 &
else
  "${AS_FRAPPE[@]}" bench worker --quiet --queue short,default 2>&1 &
  "${AS_FRAPPE[@]}" bench worker --quiet --queue long,default,short 2>&1 &
fi
PORT=${PORT:-8080} SITE=$SITE envsubst '${PORT} ${SITE}' \
  < /templates/nginx/railway.conf.template > /etc/nginx/conf.d/frappe.conf
# Railway's health check probes from the start; until gunicorn listens, nginx would
# log each probe as an upstream error.
for _ in $(seq 60); do (: </dev/tcp/127.0.0.1/8000) 2>/dev/null && break; sleep 1; done
"${AS_FRAPPE[@]}" nginx -e stderr -g 'daemon off;' 2>&1 &
echo "railway: serving ERPNext ($version) with $WEB_WORKERS web and $BG_WORKERS background workers"

if [ -n "${S3_BUCKET:-}" ]; then
  # 03:00 UTC daily; a failed backup is logged, it never takes ERPNext down.
  while sleep $(( (97200 - $(date +%s) % 86400) % 86400 )); do erpnext-backup || true; done &
fi

# Any process exiting means the service is broken: exit so Railway restarts it.
wait -n
exit 1

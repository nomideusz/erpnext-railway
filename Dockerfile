# Pinned: frappe/erpnext:v16 moves with every weekly release, and a silent rebase can
# break every deploy of this template at once. Bump deliberately; the entrypoint
# backs up and migrates the site on the first boot of a new version.
FROM frappe/erpnext:v16.52.1

# More Frappe apps, built into the image the way frappe_docker does it. FRAPPE_APPS
# is a service variable (Railway passes it as a build arg): the Frappe HR template
# sets "hrms"; the ERPNext template leaves it empty.
ARG FRAPPE_APPS=""
# upgrade: github frappe/hrms
ARG HRMS_VERSION=v16.52.0
# upgrade: github frappe/helpdesk
ARG HELPDESK_VERSION=v1.31.0
# The image keeps the built assets in assets/, outside sites/; linked back during the
# build, the new app's bundles merge into them instead of replacing the manifest.
# Helpdesk's Vite build outgrows Node's default heap.
# telephony (Helpdesk's required app) has no releases, only its develop branch.
RUN [ -z "$FRAPPE_APPS" ] || { ln -s ../assets sites/assets \
    && for app in $FRAPPE_APPS; do \
      case $app in hrms) v=$HRMS_VERSION ;; helpdesk) v=$HELPDESK_VERSION ;; \
        telephony) v=develop ;; *) echo "unknown app $app"; exit 1 ;; esac; \
      NODE_OPTIONS=--max-old-space-size=4096 bench get-app --branch "$v" "https://github.com/frappe/$app" || exit 1; \
    done && rm sites/assets; }

USER root

# Frappe keeps its cache and job queue in Redis. Running both here, as `bench setup
# production` does on a server, saves two services and their private-network wiring.
RUN apt-get update \
    && apt-get install -y --no-install-recommends redis-server \
    && rm -rf /var/lib/apt/lists/*

# nginx sizes `worker_processes auto` from the host's cores (48 on Railway), and that
# many workers alone can run a small plan out of memory. Its log files are symlinks
# to /dev/stdout and /dev/stderr, which the frappe user may not reopen once they are
# pipes from a root process: errors go to the inherited stderr instead, and access
# logs are off (Railway's HTTP logs already have every request).
RUN sed -i -e 's/^worker_processes .*/worker_processes 2;/' \
      -e 's|^error_log .*|error_log stderr;|' \
      -e 's|access_log /var/log/nginx/access.log;|access_log off;|' /etc/nginx/nginx.conf

# The Railway volume mounts over sites/ and hides these; the entrypoint puts them back.
RUN cp sites/apps.txt sites/apps.json /home/frappe/

# The image has no bytecode for whoosh, and Python 3.14 compiling it prints invalid
# escape SyntaxWarnings to stderr on every boot, where Railway shows them as errors.
RUN env/bin/python -W ignore -m compileall -q env/lib/python3.*/site-packages/whoosh

COPY nginx.conf /templates/nginx/railway.conf.template
COPY --chmod=0755 railway-entrypoint.sh /railway-entrypoint.sh
COPY --chmod=0755 erpnext-backup erpnext-restore /usr/local/bin/

# Starts as root only to chown the Railway volume; every process runs as frappe.
ENTRYPOINT ["/railway-entrypoint.sh"]
CMD []

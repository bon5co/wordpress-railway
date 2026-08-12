#!/usr/bin/env bash
# Railway entrypoint for WordPress.
#
# Order matters: WordPress is installed and the administrator seeded BEFORE
# Apache binds a port. A stock deploy serves /wp-admin/install.php to whoever
# arrives first, and that visitor becomes an administrator -- measured on the
# stock image as an anonymous POST to install.php returning "Success!" with the
# attacker's username. On Railway the public URL exists before the deployer
# opens it, so the window is not theoretical.
set -euo pipefail

log() { echo "[railway] $*"; }

: "${WORDPRESS_ADMIN_USER:=admin}"
: "${WORDPRESS_ADMIN_EMAIL:=admin@example.com}"
: "${WORDPRESS_SITE_TITLE:=My WordPress Site}"
: "${WORDPRESS_ENABLE_XMLRPC:=0}"

if [ -z "${WORDPRESS_ADMIN_PASSWORD:-}" ]; then
    echo "[railway] FATAL: WORDPRESS_ADMIN_PASSWORD is empty." >&2
    echo "[railway] Refusing to boot: an instance with no seeded administrator" >&2
    echo "[railway] hands the WordPress install screen to the first stranger." >&2
    exit 1
fi

# ---------------------------------------------------------------- listen port
# Railway injects PORT into every service and its HTTP healthcheck dials that
# injected port, not the port the domain targets, so a public service has to
# honour it. Apache is baked to :80.
PORT="${PORT:-80}"
sed -ri "s/^Listen .*/Listen ${PORT}/" /etc/apache2/ports.conf
sed -ri "s!<VirtualHost \*:[0-9]+>!<VirtualHost *:${PORT}>!" /etc/apache2/sites-available/000-default.conf
grep -q '^ServerName' /etc/apache2/apache2.conf || echo 'ServerName localhost' >> /etc/apache2/apache2.conf
log "apache listening on ${PORT}"

# Apache refuses to start with "More than one MPM loaded", and on Railway the
# container came up with more than one enabled where the same image on a plain
# Docker host had only mpm_prefork. Rather than trust the image's state, settle
# it here: everything off, prefork on (the MPM the official image is built
# against, and the only one safe with mod_php).
log "mpm before: $(ls /etc/apache2/mods-enabled/ | grep -c mpm) module files"
a2dismod -f mpm_event mpm_worker mpm_prefork >/dev/null 2>&1 || true
a2enmod mpm_prefork >/dev/null 2>&1 || true
log "mpm after: $(ls /etc/apache2/mods-enabled/ | grep mpm | tr '\n' ' ')"

# ------------------------------------------------------------------ php sizing
# The stock php.ini-production leaves memory_limit at 128M and uploads at 2M,
# which is below what the media library and most page builders need. Size the
# limit from the container's own cgroup rather than a fixed number, so a bigger
# Railway plan is actually used.
mem_bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
if [ "$mem_bytes" = "max" ] || [ -z "$mem_bytes" ]; then
    mem_mb=512
else
    mem_mb=$(( mem_bytes / 1024 / 1024 / 4 ))
fi
[ "$mem_mb" -lt 256 ] && mem_mb=256
[ "$mem_mb" -gt 2048 ] && mem_mb=2048
upload_mb="${WORDPRESS_UPLOAD_MAX_MB:-64}"
cat > /usr/local/etc/php/conf.d/railway.ini <<EOF
memory_limit = ${mem_mb}M
upload_max_filesize = ${upload_mb}M
post_max_size = $(( upload_mb + 8 ))M
max_execution_time = 300
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 2
EOF
log "php memory_limit=${mem_mb}M upload_max_filesize=${upload_mb}M"

if [ "$WORDPRESS_ENABLE_XMLRPC" = "1" ]; then
    a2disconf railway-xmlrpc >/dev/null 2>&1 || true
    log "xmlrpc.php ENABLED by WORDPRESS_ENABLE_XMLRPC=1"
else
    a2enconf railway-xmlrpc >/dev/null 2>&1 || true
fi

# ------------------------------------------------- upstream setup, no listener
# The stock entrypoint only copies WordPress onto the volume and writes
# wp-config.php when its command starts with "apache2" or is "php-fpm", so it
# is invoked here with a command that does that work and then exits. Skipping
# this is exactly how the category's leading listing serves 403 on a fresh
# deploy: its start command runs `docker-entrypoint.sh a2dismod mpm_event`
# (setup skipped, wrong command) and then a bare `apache2-foreground` with no
# entrypoint at all, leaving /var/www/html empty.
log "running upstream setup"
docker-entrypoint.sh apache2 -v >/dev/null

install -d -m 0755 /var/www/html/wp-content/mu-plugins
cp -f /usr/src/railway-mu-plugins/*.php /var/www/html/wp-content/mu-plugins/
chown -R www-data:www-data /var/www/html/wp-content/mu-plugins

wp_cli() { wp --allow-root --path=/var/www/html "$@"; }

# Off by default. Set RAILWAY_IP_PROBE=1 to publish /railway-ip.php, which
# prints REMOTE_ADDR and X-Forwarded-For -- the only way to see what the edge
# actually hands the container on a given deploy.
if [ "${RAILWAY_IP_PROBE:-0}" = "1" ]; then
    printf '<?php header("Content-Type: text/plain"); echo "remote_addr=", $_SERVER["REMOTE_ADDR"], "\nxff=", $_SERVER["HTTP_X_FORWARDED_FOR"] ?? "", "\n";' \
        > /var/www/html/railway-ip.php
else
    rm -f /var/www/html/railway-ip.php
fi

# ------------------------------------------------------------------ wait on db
# Probed with mysqli, not `wp db check`: the WP-CLI command shells out to
# mysqlcheck and the image ships no MySQL client, so it fails for a reason that
# has nothing to do with the database being up.
for i in $(seq 1 60); do
    # Connects WITHOUT a database name and creates it if missing, so the
    # template needs no MARIADB_DATABASE variable on the database service. A
    # literal default there would be dropped by templateGenerate and republish
    # as a blank required field on the deploy form.
    if php -r '
        $h = getenv("WORDPRESS_DB_HOST") ?: "localhost";
        $p = 3306;
        if (strpos($h, ":") !== false) { list($h, $p) = explode(":", $h, 2); }
        mysqli_report(MYSQLI_REPORT_OFF);
        $c = @mysqli_connect($h, getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), "", (int) $p);
        if (! $c) { exit(1); }
        $db = getenv("WORDPRESS_DB_NAME") ?: "wordpress";
        if (! preg_match("/^[A-Za-z0-9_]+$/", $db)) { exit(1); }
        exit(mysqli_query($c, "CREATE DATABASE IF NOT EXISTS `" . $db . "` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci") ? 0 : 1);
    ' >/dev/null 2>&1; then
        break
    fi
    [ "$i" = 60 ] && { echo "[railway] FATAL: database unreachable after 60 tries" >&2; exit 1; }
    sleep 2
done
log "database reachable"

# --------------------------------------------------------------- seed the site
SITE_URL="${WORDPRESS_SITE_URL:-http://localhost}"
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ] && [ -z "${WORDPRESS_SITE_URL:-}" ]; then
    SITE_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi

if wp_cli core is-installed >/dev/null 2>&1; then
    log "WordPress already installed; re-applying administrator password"
    if wp_cli user get "$WORDPRESS_ADMIN_USER" --field=ID >/dev/null 2>&1; then
        wp_cli user update "$WORDPRESS_ADMIN_USER" \
            --user_pass="$WORDPRESS_ADMIN_PASSWORD" --skip-email >/dev/null
    else
        wp_cli user create "$WORDPRESS_ADMIN_USER" "$WORDPRESS_ADMIN_EMAIL" \
            --role=administrator --user_pass="$WORDPRESS_ADMIN_PASSWORD" >/dev/null
    fi
else
    log "installing WordPress at ${SITE_URL}"
    wp_cli core install \
        --url="$SITE_URL" \
        --title="$WORDPRESS_SITE_TITLE" \
        --admin_user="$WORDPRESS_ADMIN_USER" \
        --admin_password="$WORDPRESS_ADMIN_PASSWORD" \
        --admin_email="$WORDPRESS_ADMIN_EMAIL" \
        --skip-email >/dev/null
    # Anyone-can-register is off by default; make sure a later import cannot
    # quietly turn the instance into an open sign-up.
    wp_cli option update users_can_register 0 >/dev/null
    wp_cli option update blog_public 1 >/dev/null
fi

# Keep the site URL in step with the Railway domain unless the deployer has
# pointed a custom domain at it via WORDPRESS_SITE_URL.
if [ -n "${WORDPRESS_SITE_URL:-}" ] || [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    current="$(wp_cli option get siteurl 2>/dev/null || echo '')"
    if [ -n "$current" ] && [ "$current" != "$SITE_URL" ] && [ "${WORDPRESS_PIN_SITE_URL:-1}" = "1" ]; then
        log "site url ${current} -> ${SITE_URL}"
        wp_cli option update siteurl "$SITE_URL" >/dev/null
        wp_cli option update home "$SITE_URL" >/dev/null
    fi
fi

log "admin '${WORDPRESS_ADMIN_USER}' seeded; starting apache"
exec docker-entrypoint.sh "$@"

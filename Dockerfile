# Railway-tuned WordPress (PHP 8.3 + Apache).
#
# Pinned to 6.9.1-php8.3-apache rather than tracking `wordpress`/`latest`.
# WordPress keeps its own copy of core on the volume and updates itself from
# the admin UI, so an unpinned image tag does not keep an instance current --
# it only means a Railway redeploy can hand a live site a different PHP minor
# than the one its plugins were installed against.
FROM wordpress:6.9.1-php8.3-apache

# WP-CLI, used by the entrypoint to install WordPress and seed the
# administrator before Apache ever binds a port.
ADD https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar /usr/local/bin/wp
RUN chmod +x /usr/local/bin/wp

# The real client address is restored in PHP, not in Apache -- see
# mu-plugins/railway-client-ip.php. mod_remoteip needs a list of proxy
# addresses to trust, and Railway's edge reaches the container from a public
# address that rotates per request (measured: 152.233.33.163 then .161 for two
# consecutive requests from one client), so there is nothing stable to trust.

# Blocks xmlrpc.php at the web server as well as inside WordPress. XML-RPC
# accepts credential guesses in batches through system.multicall, so it is the
# cheapest brute-force surface on any public WordPress; set
# WORDPRESS_ENABLE_XMLRPC=1 to restore it for Jetpack or the mobile apps.
COPY railway-xmlrpc.conf /etc/apache2/conf-available/railway-xmlrpc.conf

COPY mu-plugins/ /usr/src/railway-mu-plugins/
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Baked, NOT published as template variables: templateGenerate keeps a
# variable's default only when the live value is a Railway expression, so a
# literal default is dropped and the variable republishes as a blank REQUIRED
# field on the deploy form.
ENV WORDPRESS_DB_NAME=wordpress \
    WORDPRESS_DB_USER=root \
    WORDPRESS_ADMIN_USER=admin \
    WORDPRESS_ADMIN_EMAIL=admin@example.com \
    WORDPRESS_SITE_TITLE="My WordPress Site" \
    WORDPRESS_LOGIN_MAX_ATTEMPTS=10 \
    WORDPRESS_LOGIN_WINDOW=900 \
    WORDPRESS_ENABLE_XMLRPC=0

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["apache2-foreground"]

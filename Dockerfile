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

# Recover the real client address.
#
# The stock image enables mod_remoteip with RemoteIPHeader X-Forwarded-For and
# RemoteIPInternalProxy limited to RFC1918 + loopback
# (/etc/apache2/conf-available/remoteip.conf). Railway's edge speaks to the
# container from 100.64.0.0/10, which matches none of those, so Apache stops
# walking the header at the edge hop and hands PHP the proxy's address as
# REMOTE_ADDR. Measured on this image with the stock config, a request with
# `X-Forwarded-For: 203.0.113.7, 100.64.5.5` produced REMOTE_ADDR 100.64.5.5.
#
# Everything in WordPress that is keyed on the client address then keys on
# Railway's edge instead: comment author IPs, the address stored with every
# failed-login record, and any security plugin's blocklist. Worse, that edge
# hop rotates per request, so a plugin that blocks "the attacker" blocks a
# shared address that the next request no longer comes from.
#
# Trusting 100.64.0.0/10 makes Apache continue to the previous hop, which
# Railway's edge writes itself -- it REPLACES any inbound X-Forwarded-For, so
# the first address cannot be spoofed by the client.
COPY railway-remoteip.conf /etc/apache2/conf-available/railway-remoteip.conf
RUN a2enconf railway-remoteip >/dev/null

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

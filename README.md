# wordpress-railway

Railway-tuned wrapper around the official `wordpress:6.9.1-php8.3-apache` image,
published as `ghcr.io/bon5co/wordpress-railway`.

What it changes, and why each change exists on Railway specifically:

- **Installs WordPress and seeds the administrator before Apache binds a port.**
  A stock deploy serves `/wp-admin/install.php` to whoever arrives first and that
  visitor becomes an administrator. The container refuses to boot when
  `WORDPRESS_ADMIN_PASSWORD` is empty, and re-applies the password on every boot,
  so a redeploy rotates it rather than locking the deployer out.
- **Restores the real visitor address in PHP.** Railway's edge is what reaches the container, from a public address that rotates per request, so `REMOTE_ADDR` is a proxy hop and everything keyed on it (comment IPs, security plugins, rate limits) is recording the wrong client.
  Measured live: two consecutive requests from one client arrived as
  `remote_addr=152.233.33.163` and `remote_addr=152.233.33.161`, both with
  `X-Forwarded-For: 106.73.62.0`.
- **Throttles failed logins** (10 per 15 minutes per client address, configurable)
  through a must-use plugin. WordPress core ships no throttle at all.
- **Blocks `xmlrpc.php`** at Apache and inside WordPress unless
  `WORDPRESS_ENABLE_XMLRPC=1`; `system.multicall` accepts credential guesses in
  batches.
- **Honours the injected `$PORT`.** Railway's HTTP healthcheck dials the injected
  port rather than the port the domain targets, so a public service has to listen
  there.
- **Sizes PHP from the container's cgroup** (memory limit, opcache, upload size)
  instead of the stock 128M / 2M defaults.
- **Creates the database if it does not exist**, so the template needs no
  literal-valued database variables on the deploy form.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `WORDPRESS_ADMIN_PASSWORD` | — (required) | Seeded administrator password; empty is a hard boot failure |
| `WORDPRESS_ADMIN_USER` | `admin` | Seeded administrator login |
| `WORDPRESS_ADMIN_EMAIL` | `admin@example.com` | Seeded administrator email |
| `WORDPRESS_SITE_TITLE` | `My WordPress Site` | Site title used at install time |
| `WORDPRESS_SITE_URL` | derived from `RAILWAY_PUBLIC_DOMAIN` | Set this when pointing a custom domain at the service |
| `WORDPRESS_PIN_SITE_URL` | `1` | Set to `0` to stop the entrypoint re-applying the site URL each boot |
| `WORDPRESS_LOGIN_MAX_ATTEMPTS` | `10` | Failed logins allowed per window, per client address |
| `WORDPRESS_LOGIN_WINDOW` | `900` | Throttle window in seconds |
| `WORDPRESS_ENABLE_XMLRPC` | `0` | Set to `1` to restore XML-RPC for Jetpack / the mobile apps |
| `WORDPRESS_UPLOAD_MAX_MB` | `64` | Upload size limit |

Standard `WORDPRESS_DB_*` variables are passed through to the upstream entrypoint.

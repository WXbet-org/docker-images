# dreamos-buildsystem-feed image
#
# Stock Caddy 2 with the feed's Caddyfile + startup script baked in
# so orchestrators can deploy the stack straight from Git without
# needing to also fetch sibling config files. Runtime behaviour is
# controlled purely by the compose file's env vars (FEED_DOMAIN,
# FEED_ACME_EMAIL, FEED_HTTP_PORT, FEED_HTTPS_PORT, RESCAN_INTERVAL)
# and the mounted build-tree volume.
FROM caddy:2

COPY Caddyfile   /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0555 /entrypoint.sh

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]

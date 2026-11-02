# Track the stable branch so the weekly scheduled rebuild picks up base-image security patches
FROM nginx:stable-alpine

RUN rm -f /etc/nginx/conf.d/default.conf \
 && mkdir -p /var/www/certbot

# Sites: 80 (ACME + redirect), 443 (accounts.opelikaschools.org -> IIS), 9000 (test page)
COPY conf.d/ /etc/nginx/conf.d/
COPY html/test/ /usr/share/nginx/test/

# Enables 443 once the Let's Encrypt cert exists and reloads nginx on renewal
COPY --chmod=755 docker-entrypoint.d/05-cert-watch.sh /docker-entrypoint.d/05-cert-watch.sh

# Mounted at runtime (shared with the certbot container):
#   /etc/letsencrypt   certificates (read-only here)
#   /var/www/certbot   ACME challenge files
EXPOSE 80 443 9000

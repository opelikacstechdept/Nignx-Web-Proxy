# Track the stable branch so the weekly scheduled rebuild picks up base-image security patches
FROM nginx:stable-alpine

RUN rm -f /etc/nginx/conf.d/default.conf

# Sites: see conf.d (https by name, http fallbacks, status page on 80 by IP and 9000)
COPY conf.d/ /etc/nginx/conf.d/
COPY snippets/ /etc/nginx/snippets/
COPY html/test/ /usr/share/nginx/test/

# Enables 443 once a certificate is present and reloads nginx when it changes
COPY --chmod=755 docker-entrypoint.d/05-cert-watch.sh /docker-entrypoint.d/05-cert-watch.sh

# Mounted at runtime:
#   /certs   fullchain.pem + privkey.pem
EXPOSE 80 443 9000 8081

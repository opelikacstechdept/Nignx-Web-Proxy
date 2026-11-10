# Track the stable branch so the weekly scheduled rebuild picks up base-image security patches
FROM nginx:stable-alpine

RUN rm -f /etc/nginx/conf.d/default.conf

# One file per site, plus 00-common.conf for shared settings
COPY conf.d/ /etc/nginx/conf.d/
COPY html/test/ /usr/share/nginx/test/

# Reloads nginx when the certificate is replaced; writes the status page's status.json
COPY --chmod=755 docker-entrypoint.d/05-cert-watch.sh /docker-entrypoint.d/05-cert-watch.sh

# Mounted at runtime: /certs (fullchain.pem + privkey.pem), /auth (gat.htpasswd)
EXPOSE 80 443 8081 9000

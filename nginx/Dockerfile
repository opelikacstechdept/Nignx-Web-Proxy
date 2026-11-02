# Track the stable branch so the weekly scheduled rebuild picks up base-image security patches
FROM nginx:stable-alpine

# openssl is used at startup to create the self-signed cert for the port-9000 test server
RUN apk add --no-cache openssl \
 && rm -f /etc/nginx/conf.d/default.conf

# Proxy config: shared backend, production site (80/443), test site (9000)
COPY conf.d/ /etc/nginx/conf.d/

# Startup script: creates the test cert; disables the production site if its cert is missing
COPY --chmod=755 docker-entrypoint.d/05-certs.sh /docker-entrypoint.d/05-certs.sh

# Let's Encrypt certs are mounted at runtime, not baked in:
#   -v /etc/letsencrypt:/etc/letsencrypt:ro
EXPOSE 80 443 9000

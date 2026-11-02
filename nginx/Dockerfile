# Track the stable branch so the weekly scheduled rebuild picks up base-image security patches
FROM nginx:stable-alpine

# Replace the stock default site with the intranet reverse-proxy config
RUN rm -f /etc/nginx/conf.d/default.conf
COPY conf.d/ /etc/nginx/conf.d/

# TLS certs are mounted at runtime (not baked into the image):
#   -v /etc/letsencrypt:/etc/letsencrypt:ro
EXPOSE 80 443

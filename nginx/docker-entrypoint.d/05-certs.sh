#!/bin/sh
# Runs on container start, before nginx launches.
set -eu

DOMAIN=accounts.opelikaschools.org
TEST_DIR=/etc/nginx/certs
LE_DIR=/etc/letsencrypt/live/$DOMAIN

# 1) Self-signed cert for the port-9000 test server (created once per container)
if [ ! -s "$TEST_DIR/test.crt" ] || [ ! -s "$TEST_DIR/test.key" ]; then
    echo "05-certs: generating self-signed test certificate for $DOMAIN"
    mkdir -p "$TEST_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
        -keyout "$TEST_DIR/test.key" -out "$TEST_DIR/test.crt" 2>/dev/null
    chmod 600 "$TEST_DIR/test.key"
fi

# 2) Without the Let's Encrypt cert, nginx would refuse to start at all.
#    In that case turn off the production 80/443 site so the test server still runs.
if [ -s "$LE_DIR/fullchain.pem" ] && [ -s "$LE_DIR/privkey.pem" ]; then
    [ -f /etc/nginx/conf.d/intranet.conf.disabled ] && \
        mv /etc/nginx/conf.d/intranet.conf.disabled /etc/nginx/conf.d/intranet.conf
    echo "05-certs: Let's Encrypt cert found - production site on 80/443 enabled"
else
    [ -f /etc/nginx/conf.d/intranet.conf ] && \
        mv /etc/nginx/conf.d/intranet.conf /etc/nginx/conf.d/intranet.conf.disabled
    echo "05-certs: WARNING no cert at $LE_DIR - production site on 80/443 DISABLED, test server on 9000 only"
fi

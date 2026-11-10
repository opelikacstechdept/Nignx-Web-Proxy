#!/bin/sh
# Runs on container start (before nginx), then keeps watching in the background.
# - Production (443) is only enabled when a certificate exists; otherwise
#   nginx would refuse to start at all.
# - When a cert is added or replaced later, nginx is reloaded automatically -
#   no restart needed.
# - The password-protected GAT site (8081) is only enabled when its password
#   file exists, for the same reason.
set -eu

# Folder(s) to look in for fullchain.pem + privkey.pem, in order of preference.
# /certs is ./certs next to docker-compose.yml on the server.
CERT_DIRS=${CERT_DIRS:-"/certs"}
SSL_DIR=/etc/nginx/ssl        # nginx reads the cert via links in here
CONF=/etc/nginx/conf.d/20-accounts-443.conf
STATUS=/usr/share/nginx/test/status.json
INTERVAL=${CERT_CHECK_INTERVAL:-300}   # seconds
GAT_CONF=/etc/nginx/conf.d/41-gat-8081.conf
UPS_CONF=/etc/nginx/conf.d/42-ups-monitor.conf
GAT_AUTH=/auth/gat.htpasswd

CERT_DIR=""
find_cert() {   # sets CERT_DIR to the first cert folder that has both files
    CERT_DIR=""
    for d in $CERT_DIRS; do
        if [ -s "$d/fullchain.pem" ] && [ -s "$d/privkey.pem" ]; then CERT_DIR=$d; return 0; fi
    done
    return 1
}

have_cert() {
    find_cert || return 1
    mkdir -p "$SSL_DIR"
    ln -sfn "$CERT_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
    ln -sfn "$CERT_DIR/privkey.pem"   "$SSL_DIR/privkey.pem"
}

apply() {   # prints "yes" if the production site was switched on/off
    changed=no
    if have_cert; then
        if [ -f "$CONF.disabled" ]; then mv "$CONF.disabled" "$CONF"; changed=yes; fi
        state=enabled; cert="found ($CERT_DIR)"
    else
        if [ -f "$CONF" ]; then mv "$CONF" "$CONF.disabled"; changed=yes; fi
        state=disabled; cert="missing (looked in: $CERT_DIRS)"
    fi
    if [ -s "$GAT_AUTH" ]; then
        if [ -f "$GAT_CONF.disabled" ]; then mv "$GAT_CONF.disabled" "$GAT_CONF"; changed=yes; fi
    else
        if [ -f "$GAT_CONF" ]; then mv "$GAT_CONF" "$GAT_CONF.disabled"; changed=yes; fi
    fi
    printf '{"production":"%s","certificate":"%s","checked":"%s"}\n' \
        "$state" "$cert" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" > "$STATUS"
    echo "$changed"
}

# UPS Monitor is reached via host.docker.internal (extra_hosts in docker-compose.yml).
# Without that entry nginx would refuse to start at all, so switch off just that site.
if getent hosts host.docker.internal >/dev/null 2>&1; then
    [ -f "$UPS_CONF.disabled" ] && mv "$UPS_CONF.disabled" "$UPS_CONF"
    echo "05-cert-watch: host.docker.internal found - UPS Monitor site enabled"
else
    [ -f "$UPS_CONF" ] && mv "$UPS_CONF" "$UPS_CONF.disabled"
    echo "05-cert-watch: WARNING host.docker.internal missing (add extra_hosts to docker-compose.yml) - UPS Monitor site DISABLED"
fi

fingerprint() { cat "$SSL_DIR/fullchain.pem" 2>/dev/null | md5sum | cut -d' ' -f1; }

apply >/dev/null
if have_cert; then
    echo "05-cert-watch: certificate found at $CERT_DIR - production site on 443 enabled"
else
    echo "05-cert-watch: WARNING no certificate in any of: $CERT_DIRS - production site on 443 DISABLED until it appears (port 80 and test page on 9000 still run)"
fi
if [ -s "$GAT_AUTH" ]; then
    echo "05-cert-watch: GAT password file found - GAT on 8081 enabled"
else
    echo "05-cert-watch: no GAT password file ($GAT_AUTH) - GAT on 8081 DISABLED"
fi

# Background watcher: enable 443 when the cert appears; reload to pick up renewals.
(
    set +e
    last=$(fingerprint)
    while sleep "$INTERVAL"; do
        changed=$(apply)
        fp=$(fingerprint)
        if [ "$changed" = yes ] || [ "$fp" != "$last" ]; then
            if nginx -t >/dev/null 2>&1; then
                nginx -s reload && echo "05-cert-watch: reloaded nginx (certificate or GAT password file changed)"
            else
                echo "05-cert-watch: config test failed, not reloading"
            fi
        fi
        last=$fp
    done
) &

#!/bin/sh
# Runs on container start (before nginx), then keeps watching in the background.
# - Production (443) is only enabled when the Let's Encrypt cert exists; otherwise
#   nginx would refuse to start at all.
# - When a cert appears later (first certbot run) or is renewed, nginx is reloaded
#   automatically - no restart needed.
set -eu

# Certificates to use, in order of preference (certbot "cert names", i.e. folders
# under /etc/letsencrypt/live). The wildcard cert for opelikaschools.org +
# *.opelikaschools.org comes first; a single-name cert is the fallback.
CERT_NAMES=${CERT_NAMES:-"opelikaschools.org accounts.opelikaschools.org"}
SSL_DIR=/etc/nginx/ssl        # nginx reads the cert via links in here
CONF=/etc/nginx/conf.d/20-accounts-443.conf
STATUS=/usr/share/nginx/test/status.json
INTERVAL=${CERT_CHECK_INTERVAL:-300}   # seconds

LE_DIR=""
find_cert() {   # sets LE_DIR to the first cert folder that has both files
    LE_DIR=""
    for name in $CERT_NAMES; do
        d=/etc/letsencrypt/live/$name
        if [ -s "$d/fullchain.pem" ] && [ -s "$d/privkey.pem" ]; then LE_DIR=$d; return 0; fi
    done
    return 1
}

have_cert() {
    find_cert || return 1
    mkdir -p "$SSL_DIR"
    ln -sfn "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
    ln -sfn "$LE_DIR/privkey.pem"   "$SSL_DIR/privkey.pem"
}

apply() {   # prints "yes" if the production site was switched on/off
    changed=no
    if have_cert; then
        if [ -f "$CONF.disabled" ]; then mv "$CONF.disabled" "$CONF"; changed=yes; fi
        state=enabled; cert="found ($LE_DIR)"
    else
        if [ -f "$CONF" ]; then mv "$CONF" "$CONF.disabled"; changed=yes; fi
        state=disabled; cert="missing (looked for: $CERT_NAMES)"
    fi
    printf '{"production":"%s","certificate":"%s","checked":"%s"}\n' \
        "$state" "$cert" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" > "$STATUS"
    echo "$changed"
}

fingerprint() { cat "$SSL_DIR/fullchain.pem" 2>/dev/null | md5sum | cut -d' ' -f1; }

apply >/dev/null
if have_cert; then
    echo "05-cert-watch: certificate found at $LE_DIR - production site on 443 enabled"
else
    echo "05-cert-watch: WARNING no certificate in /etc/letsencrypt/live/{$CERT_NAMES} - production site on 443 DISABLED until it appears (port 80 and test page on 9000 still run)"
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
                nginx -s reload && echo "05-cert-watch: reloaded nginx (certificate added, renewed or removed)"
            else
                echo "05-cert-watch: config test failed, not reloading"
            fi
        fi
        last=$fp
    done
) &

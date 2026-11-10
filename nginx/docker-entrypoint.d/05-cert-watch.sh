#!/bin/sh
# Runs on container start (before nginx), then keeps watching in the background.
#
# Switches sites on/off by file name in /etc/nginx/conf.d (a disabled file has
# ".disabled" appended):
#   *.https.conf  on when the certificate exists   (https sites)
#   *.http.conf   on when it does NOT exist        (plain-http fallbacks)
# plus per-site requirements, so one missing piece can't stop nginx as a whole:
#   *gat*                      needs /auth/gat.htpasswd (GAT's password file)
#   *upsmonitor*, *iiqresponder*  need host.docker.internal (extra_hosts in compose)
#
# When the certificate or password file is added/replaced/removed later, nginx is
# switched over and reloaded automatically - no restart needed.
set -eu

CERT_DIRS=${CERT_DIRS:-"/certs"}   # where fullchain.pem + privkey.pem are looked for
SSL_DIR=/etc/nginx/ssl             # nginx reads the cert via links in here
CONF_D=/etc/nginx/conf.d
STATUS=/usr/share/nginx/test/status.json
INTERVAL=${CERT_CHECK_INTERVAL:-300}   # seconds
GAT_AUTH=/auth/gat.htpasswd

CERT_DIR=""
find_cert() {   # sets CERT_DIR to the first folder that has both files
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

host_ok=no
getent hosts host.docker.internal >/dev/null 2>&1 && host_ok=yes

wanted() {   # wanted <base file name> <cert yes/no> -> exit 0 if the file should be on
    f=$1; cert=$2
    case "$f" in
        *.https.conf) [ "$cert" = yes ] || return 1 ;;
        *.http.conf)  [ "$cert" = no ]  || return 1 ;;
    esac
    case "$f" in
        *gat*) [ -s "$GAT_AUTH" ] || return 1 ;;
    esac
    case "$f" in
        *upsmonitor*|*iiqresponder*) [ "$host_ok" = yes ] || return 1 ;;
    esac
    return 0
}

apply() {   # switch files on/off; prints "yes" if anything changed
    changed=no
    if have_cert; then cert=yes; else cert=no; fi
    for path in "$CONF_D"/*.http.conf "$CONF_D"/*.https.conf "$CONF_D"/*.http.conf.disabled "$CONF_D"/*.https.conf.disabled; do
        [ -e "$path" ] || continue
        base=${path%.disabled}
        if wanted "$(basename "$base")" "$cert"; then
            if [ "$path" != "$base" ]; then mv "$path" "$base"; changed=yes; fi
        else
            if [ "$path" = "$base" ]; then mv "$path" "$path.disabled"; changed=yes; fi
        fi
    done
    if [ "$cert" = yes ]; then state=enabled; c="found ($CERT_DIR)"; else state=disabled; c="missing (looked in: $CERT_DIRS)"; fi
    printf '{"production":"%s","certificate":"%s","checked":"%s"}\n' \
        "$state" "$c" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" > "$STATUS"
    echo "$changed"
}

summary() {
    on=$(cd "$CONF_D" && ls *.http.conf *.https.conf 2>/dev/null | tr '\n' ' ')
    off=$(cd "$CONF_D" && ls *.disabled 2>/dev/null | sed 's/\.disabled$//' | tr '\n' ' ')
    echo "05-cert-watch: sites on:  ${on:-none}"
    echo "05-cert-watch: sites off: ${off:-none}"
}

apply >/dev/null
if find_cert; then
    echo "05-cert-watch: certificate found at $CERT_DIR - https sites on"
else
    echo "05-cert-watch: WARNING no certificate in any of: $CERT_DIRS - https sites OFF, plain-http fallbacks on"
fi
[ -s "$GAT_AUTH" ] || echo "05-cert-watch: WARNING no GAT password file ($GAT_AUTH) - GAT sites off"
[ "$host_ok" = yes ] || echo "05-cert-watch: WARNING host.docker.internal missing (add extra_hosts to docker-compose.yml) - UPS Monitor and IIQ Responder sites off"
summary

fingerprint() { { cat "$SSL_DIR/fullchain.pem" 2>/dev/null; cat "$GAT_AUTH" 2>/dev/null; } | md5sum | cut -d' ' -f1; }

# Background watcher: switch over when the cert/password file appears or goes;
# reload to pick up renewals.
(
    set +e
    last=$(fingerprint)
    while sleep "$INTERVAL"; do
        changed=$(apply)
        fp=$(fingerprint)
        if [ "$changed" = yes ] || [ "$fp" != "$last" ]; then
            if nginx -t >/dev/null 2>&1; then
                nginx -s reload && echo "05-cert-watch: reloaded nginx (certificate or GAT password file changed)" && summary
            else
                echo "05-cert-watch: config test failed, not reloading"
            fi
        fi
        last=$fp
    done
) &

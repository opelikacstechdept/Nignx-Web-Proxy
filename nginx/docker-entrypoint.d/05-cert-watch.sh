#!/bin/sh
# Runs on container start, then every 5 minutes in the background:
# reloads nginx when the certificate in /certs is replaced (renewal),
# and writes status.json for the status page.
set -eu

CERT=/certs/fullchain.pem
STATUS=/usr/share/nginx/test/status.json
INTERVAL=${CERT_CHECK_INTERVAL:-300}   # seconds

status() {
    if [ -s "$CERT" ]; then s=enabled; c="found ($CERT)"; else s=disabled; c="missing ($CERT)"; fi
    printf '{"production":"%s","certificate":"%s","checked":"%s"}\n' "$s" "$c" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" > "$STATUS"
}
fingerprint() { md5sum "$CERT" 2>/dev/null | cut -d' ' -f1; }

status
if [ -s "$CERT" ] && [ -s /certs/privkey.pem ]; then
    echo "05-cert-watch: certificate found in /certs"
else
    echo "05-cert-watch: ERROR no certificate in /certs (fullchain.pem + privkey.pem) - nginx can't start without it"
fi

(
    set +e
    last=$(fingerprint)
    while sleep "$INTERVAL"; do
        status
        fp=$(fingerprint)
        if [ "$fp" != "$last" ]; then
            if nginx -t >/dev/null 2>&1; then
                nginx -s reload && echo "05-cert-watch: certificate changed - nginx reloaded"
            else
                echo "05-cert-watch: certificate changed but config test failed - not reloading"
            fi
        fi
        last=$fp
    done
) &

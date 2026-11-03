#!/usr/bin/env bash
# Creates an internal certificate authority (once) and issues the proxy's
# HTTPS certificate from it. Run on the proxy server:
#
#   sudo ./make-internal-cert.sh                                   # accounts.opelikaschools.org
#   sudo ./make-internal-cert.sh accounts.opelikaschools.org iiq.opelikaschools.org 10.1.0.145
#
# Output:
#   /opt/nginx-proxy/certs/fullchain.pem + privkey.pem   -> picked up by the proxy within 5 min
#   /opt/nginx-proxy/ca/OpelikaSchools-Internal-CA.cer  -> install on the machines that must trust it
#   /opt/nginx-proxy/ca/ca.key                          -> CA private key: keep secret, back it up
#
# Re-running it issues a new server certificate from the SAME CA (renewal, or
# adding names) - machines that already trust the CA need nothing new.
set -euo pipefail

BASE=${BASE:-/opt/nginx-proxy}
CA_DIR=$BASE/ca
CERT_DIR=$BASE/certs
CA_SUBJECT="/O=Opelika City Schools/CN=Opelika City Schools Internal CA"
CA_DAYS=3650        # CA valid 10 years
CERT_DAYS=825       # server cert: Apple devices reject longer than 825 days

if [ "$#" -eq 0 ]; then set -- accounts.opelikaschools.org; fi

command -v openssl >/dev/null || { echo "openssl is required (apt install openssl)"; exit 1; }
mkdir -p "$CA_DIR" "$CERT_DIR"
chmod 700 "$CA_DIR"
umask 077

# --- 1. Certificate authority (only created the first time) ------------------
if [ ! -s "$CA_DIR/ca.key" ]; then
    echo "Creating internal CA in $CA_DIR ..."
    # nameConstraints: this CA can only vouch for opelikaschools.org names and
    # 10.x addresses, so even a leaked CA key can't impersonate other sites.
    if ! out=$(openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days "$CA_DAYS" \
        -subj "$CA_SUBJECT" \
        -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" \
        -addext "nameConstraints=critical,permitted;DNS:opelikaschools.org,permitted;DNS:.opelikaschools.org,permitted;IP:10.0.0.0/255.0.0.0" 2>&1); then
        echo "$out"; echo "ERROR: could not create the CA"; exit 1
    fi
    # DER copy with a friendly name for Windows / Group Policy / Google Admin
    openssl x509 -in "$CA_DIR/ca.crt" -outform der -out "$CA_DIR/OpelikaSchools-Internal-CA.cer"
    chmod 644 "$CA_DIR/ca.crt" "$CA_DIR/OpelikaSchools-Internal-CA.cer"
else
    echo "Using existing CA in $CA_DIR"
fi

# --- 2. Server certificate --------------------------------------------------
san=""
for n in "$@"; do
    if [[ "$n" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then san+="IP:$n,"; else san+="DNS:$n,"; fi
done
san=${san%,}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/ext.cnf" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName=$san
EXT

echo "Issuing server certificate for: $san"
openssl req -new -nodes -newkey rsa:2048 -sha256 -subj "/O=Opelika City Schools/CN=$1" \
    -keyout "$work/privkey.pem" -out "$work/server.csr" 2>/dev/null
openssl x509 -req -in "$work/server.csr" -sha256 -days "$CERT_DAYS" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial -CAserial "$CA_DIR/ca.srl" \
    -extfile "$work/ext.cnf" -out "$work/fullchain.pem" 2>/dev/null

if ! openssl verify -CAfile "$CA_DIR/ca.crt" "$work/fullchain.pem" >/dev/null 2>&1; then
    echo "ERROR: the CA refused this certificate. It can only cover *.opelikaschools.org"
    echo "       names and 10.x.x.x addresses. Nothing was changed."
    exit 1
fi

# Swap both files in together so the proxy never sees a mismatched pair
chmod 644 "$work/fullchain.pem"; chmod 600 "$work/privkey.pem"
mv -f "$work/privkey.pem"   "$CERT_DIR/privkey.pem.new"
mv -f "$work/fullchain.pem" "$CERT_DIR/fullchain.pem.new"
mv -f "$CERT_DIR/privkey.pem.new"   "$CERT_DIR/privkey.pem"
mv -f "$CERT_DIR/fullchain.pem.new" "$CERT_DIR/fullchain.pem"

echo
echo "Done."
echo "  Server cert : $CERT_DIR/fullchain.pem (valid $CERT_DAYS days, until $(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate | cut -d= -f2))"
echo "  CA to deploy: $CA_DIR/OpelikaSchools-Internal-CA.cer"
echo "  CA thumbprint (SHA-1, as Windows shows it):"
echo "      $(openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
echo "The proxy switches 443 on / reloads within 5 minutes."

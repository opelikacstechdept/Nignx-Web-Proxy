# Nginx Web Proxy

The front end for the web apps on the Docker host **10.1.0.145**. nginx answers on ports 80/443 and sends each site name to the right app, using one wildcard certificate (`*.opelikaschools.org`) for HTTPS.

| Site | Goes to | Login |
| --- | --- | --- |
| `https://accounts.opelikaschools.org` | IIS server `10.11.1.69:443` | Microsoft sign-in (the site's own) |
| `https://gat.opelikaschools.org` | GAT, `gat:8080` | GAT's own Google sign-in |
| `https://upsmonitor.opelikaschools.org` | UPS Monitor, `ups-monitor:8080` | UPS Monitor's own (`APP_USERNAME`/`APP_PASSWORD`) |
| `https://iiqresponder.opelikaschools.org` | IIQ Responder, `iiq-responder:8080` | IIQ Responder's own (`App__Username`/`App__Password`) |
| `http://10.1.0.145` or `:9000` | Status/test page served by nginx | none |

- `http://` on any of these names redirects to `https://`. The old GAT address `http://10.1.0.145:8081` redirects to `https://gat.opelikaschools.org`.
- Each name needs an **internal DNS A record** pointing at `10.1.0.145`.
- Names that aren't listed are refused on 443 rather than showing another site.

## The certificate

One **GoDaddy wildcard certificate** (`*.opelikaschools.org`) covers every site. GoDaddy is a public CA, so every PC, Chromebook and phone trusts it with nothing to deploy.

On the proxy server it lives in **`/opt/nginx-proxy/certs/`** as two files:

| File | Contents |
| --- | --- |
| `fullchain.pem` | The certificate, followed by GoDaddy's intermediate bundle |
| `privkey.pem` | The private key (unencrypted, `chmod 600`) |

nginx needs both files to start. When they're replaced (renewal), the proxy notices within 5 minutes and reloads by itself — no restart.

### Installing / renewing (GoDaddy)

GoDaddy's download (server type **Apache** / **Other**) contains the certificate (e.g. `<serial>.pem` or `<serial>.crt`) and the intermediate bundle (`gd_bundle-*.crt`). **GoDaddy never has the private key** — it was created with the certificate request and is kept in a `.pfx` backup (see below).

Copy the files to the server's home folder, then:

```bash
sudo sh -c 'cat ~localadmin/CERT.pem ~localadmin/gd_bundle*.pem > /opt/nginx-proxy/certs/fullchain.pem'
```

```bash
openssl pkcs12 -in ~/KEY-BACKUP.pfx -nocerts -nodes | sudo tee /opt/nginx-proxy/certs/privkey.pem >/dev/null && sudo chmod 600 /opt/nginx-proxy/certs/privkey.pem
```

(Older Windows-made `.pfx` files may need `-legacy` after `pkcs12`.) For a renewal with the same key, only the first command is needed.

Check the certificate and key belong together — must print `YES`:

```bash
[ "$(sudo openssl x509 -in /opt/nginx-proxy/certs/fullchain.pem -noout -pubkey | sha256sum)" = "$(sudo openssl pkey -in /opt/nginx-proxy/certs/privkey.pem -pubout | sha256sum)" ] && echo YES || echo "NO - wrong key"
```

Check what's installed and what the proxy did:

```bash
openssl x509 -in /opt/nginx-proxy/certs/fullchain.pem -noout -subject -issuer -enddate -ext subjectAltName
```

```bash
docker logs intranet-proxy 2>&1 | grep 05-cert
```

Afterwards remove the copies in the home folder (`rm ~/*.pfx ~/*.pem`) — the server only needs the two files in `certs/`.

### The private key backup

Keep **one** copy of the `.pfx` (certificate + private key) somewhere safe and locked down (password manager or restricted admin share). It's the only backup of the key: without it, a rebuilt or second server means re-keying with GoDaddy. Don't keep stray copies in Downloads or home folders.

**Lost the key?** Re-key the certificate on GoDaddy (free): make a new key and request on the proxy server, paste the request into GoDaddy → SSL Certificates → Re-key & Manage, then install the reissued certificate as above. Re-keying revokes the old certificate, so anything else still using it must be updated too.

```bash
sudo mkdir -p /opt/nginx-proxy/certs/pending && cd /opt/nginx-proxy/certs/pending && sudo openssl req -new -newkey rsa:2048 -nodes -subj "/CN=*.opelikaschools.org" -keyout wildcard.key -out wildcard.csr && sudo chmod 600 wildcard.key && cat wildcard.csr
```

### Renewal

GoDaddy certificates last about a year. Check the end date with the `openssl x509 ... -enddate` command above, renew on GoDaddy before it, and install the new certificate as above.

## Layout — one file per site

| Path | Purpose |
| --- | --- |
| `nginx/conf.d/00-common.conf` | Shared: certificate/TLS, proxy headers, http→https redirect for every name, refuse unknown names on 443 |
| `nginx/conf.d/accounts.conf` | accounts.opelikaschools.org → IIS `10.11.1.69` |
| `nginx/conf.d/gat.conf` | gat.opelikaschools.org → GAT, old `:8081` → https |
| `nginx/conf.d/upsmonitor.conf` | upsmonitor.opelikaschools.org → `ups-monitor:8080` |
| `nginx/conf.d/iiqresponder.conf` | iiqresponder.opelikaschools.org → `iiq-responder:8080` |
| `nginx/conf.d/status.conf` | Status/test page on 80 by IP and on 9000 |
| `nginx/html/test/index.html` | The status/test page |
| `nginx/docker-entrypoint.d/05-cert-watch.sh` | Reloads nginx when the certificate is replaced |
| `nginx/Dockerfile` | Image based on `nginx:stable-alpine` |
| `docker-compose.yml` | Runs the proxy on the server |
| `.github/workflows/build-proxy.yml` | Builds, tests (`nginx -t`) and pushes the image to GHCR |

**Adding a site:** give the app its own network with an alias (below), copy `upsmonitor.conf` to `newsite.conf`, change `server_name` and the `set $app` line, add a DNS record, push. The wildcard certificate and the http→https redirect already cover any `*.opelikaschools.org` name.

**Requirements on the server:** the certificate in `certs/` and the three app networks (below). If an app is down, only that site shows an error; the others keep working.

## Test page (port 9000)

`http://10.1.0.145:9000` (or `http://10.1.0.145`) shows that nginx is up, whether the certificate was found, and has a **Test connection to IIS** button.

## GAT

GAT signs people in with Google itself (it needs `https://`, which nginx provides). nginx adds no login of its own.

## The apps' networks

Each app has its **own standalone Docker network**, named after the app. nginx joins all of them; each app is only on its own, so the apps **can't reach each other** — only nginx can. nginx reaches each app by its network name on port 8080.

```
                ┌── gat ────────────> http://gat:8080
nginx ──────────┼── ups-monitor ────> http://ups-monitor:8080
                └── iiq-responder ──> http://iiq-responder:8080
```

Each app's own repository already sets this up in its `docker-compose.yml` (it joins its network with that alias, and publishes its web port on `127.0.0.1` only, so the server itself can still reach it but nothing else can):

| App | Repository | Network | Direct (server only) |
| --- | --- | --- | --- |
| GAT | [Google-Drive-Audit](https://github.com/opelikacstechdept/Google-Drive-Audit) | `gat` | `127.0.0.1:8080` |
| UPS Monitor | [UPS-Monitor](https://github.com/opelikacstechdept/UPS-Monitor) | `ups-monitor` | `127.0.0.1:8084` |
| IIQ Responder | [IIQ-Responder](https://github.com/opelikacstechdept/IIQ-Responder) | `iiq-responder` | `127.0.0.1:8082` |

Create the networks once on the server (UPS Monitor's `deploy/update.sh` also creates its own):

```bash
docker network create gat
docker network create ups-monitor
docker network create iiq-responder
```

- UPS Monitor keeps its **syslog** port (`514/udp`) open to the network — the UPS cards send to it directly, not through nginx.
- Each app's own login (GAT's Google sign-in, UPS Monitor's and IIQ Responder's passwords) passes straight through nginx, encrypted by https. GAT needs `GOOGLE_AUDIT_Web__BehindProxy=true` in its `.env` and `https://gat.opelikaschools.org/signin-google` as a redirect URI on its Google sign-in client.
- **Adding an app:** give it its own standalone network with an alias in its compose file, add the network to `docker-compose.yml` here, and add a site file.

## Microsoft sign-in through the proxy (accounts)

How the sign-in round trip is handled:

1. **Correct return address.** IIS receives the real hostname, HTTPS and port 443 (plus `X-Forwarded-*` headers), so the app builds `redirect_uri = https://accounts.opelikaschools.org/...`, which matches the app registration in Entra ID. No change to the app registration is needed if it already used this address.
2. **Redirects untouched.** `proxy_redirect off` — the redirect to `login.microsoftonline.com` and its parameters pass through exactly as IIS sent them.
3. **Cookies untouched.** Nonce/correlation and auth cookies (`SameSite=None; Secure`) pass through unmodified.
4. **Large auth headers.** Header buffers are raised (64k) so big sign-in cookies don't cause `502 upstream sent too big header` after login.
5. **No tokens in logs.** Access logs omit query strings, so authorization codes or tokens in callback URLs are never written to disk. Microsoft's response normally comes as a POST body, which nginx doesn't log.
6. **Encrypted both hops.** Browser → proxy uses your certificate; proxy → IIS is also HTTPS. The proxy does not verify IIS's certificate. To harden this, put IIS's CA cert in the image and add `proxy_ssl_verify on; proxy_ssl_trusted_certificate ...;`.

Sign-in passes **through** the proxy; nginx never reads or stores credentials. Users type their password on Microsoft's own site, not on this server.

## Configuration

- **IIS address:** the `upstream` block in `nginx/conf.d/accounts.conf` (currently `10.11.1.69:443`).
- **Names:** `server_name` in each site's file.

## Automatic builds

Every push to GitHub (any branch) builds the image, checks the config (`nginx -t` with a throwaway certificate), and pushes it to GHCR. It also rebuilds every Monday at 06:00 UTC for nginx security patches, and can be run by hand from the Actions tab.

| Tag | When |
| --- | --- |
| `latest` | pushes to `main` |
| `<branch-name>` | pushes to that branch (`/` becomes `-`) |
| `sha-<short>` | every build |

Update the server:

```bash
docker compose pull && docker compose up -d
```

If the package is private, log in once on the server with a GitHub token that has `read:packages`:

```bash
docker login ghcr.io -u <github-username>
```

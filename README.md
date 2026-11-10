# Nginx Web Proxy

The front end for the web apps on the Docker host **10.1.0.145**. nginx answers on ports 80/443 and sends each site name to the right app, using one wildcard certificate (`*.opelikaschools.org`) for HTTPS.

| Site | Goes to | Login |
| --- | --- | --- |
| `https://accounts.opelikaschools.org` | IIS server `10.11.1.69:443` | Microsoft sign-in (the site's own) |
| `https://gat.opelikaschools.org` | GAT container `gat-web-1` (over the `proxy-net` network) | nginx username/password (`auth/gat.htpasswd`) |
| `https://upsmonitor.opelikaschools.org` | UPS Monitor, host port 8084 | UPS Monitor's own (`APP_USERNAME`/`APP_PASSWORD`) |
| `https://iiqresponder.opelikaschools.org` | IIQ Responder, host port 8082 | IIQ Responder's own (`App__Username`/`App__Password`) |
| `http://10.1.0.145` or `:9000` | Status/test page served by nginx | none |

- `http://` on any of these names redirects to `https://`. The old GAT address `http://10.1.0.145:8081` redirects to `https://gat.opelikaschools.org`.
- Each name needs an **internal DNS A record** pointing at `10.1.0.145`.
- Names that aren't listed (or a site that is switched off) are refused on 443 rather than showing another site.

## The certificate

One wildcard certificate covers every site. On the proxy server it lives in **`/opt/nginx-proxy/certs/`** as two files:

| File | Contents |
| --- | --- |
| `fullchain.pem` | The certificate, followed by the issuing CA's intermediate certificate(s) |
| `privkey.pem` | The private key (unencrypted) |

Within 5 minutes of the files appearing (or being replaced, e.g. renewal) the proxy switches every site to HTTPS and reloads by itself — no restart. Until they exist, the app sites run on plain http by name and `accounts` stays off.

Converting what your CA or vendor gave you (run in `/opt/nginx-proxy/certs/`):

- **`.pfx` / `.p12`** (e.g. exported from Windows with the private key):
  ```bash
  sudo openssl pkcs12 -in /path/to/wildcard.pfx -nokeys -out fullchain.pem && sudo openssl pkcs12 -in /path/to/wildcard.pfx -nocerts -nodes -out privkey.pem && sudo chmod 600 privkey.pem
  ```
- **Separate files** (`wildcard.crt` + CA chain `.crt` + `.key`):
  ```bash
  sudo sh -c 'cat wildcard.crt ca-chain.crt > fullchain.pem && cp wildcard.key privkey.pem && chmod 600 privkey.pem'
  ```
  If a `.cer`/`.crt` is binary (DER), convert it first: `openssl x509 -inform der -in file.cer -out file.pem`.

Check what's installed:

```bash
openssl x509 -in /opt/nginx-proxy/certs/fullchain.pem -noout -subject -issuer -enddate -ext subjectAltName
```

```bash
docker logs intranet-proxy 2>&1 | grep 05-cert
```

## How sites switch on and off

`nginx/docker-entrypoint.d/05-cert-watch.sh` runs at startup and every 5 minutes, and switches config files on/off by name, so one missing piece never stops nginx as a whole:

| Files | On when |
| --- | --- |
| `*.https.conf` | the certificate is present |
| `*.http.conf` | the certificate is **not** present (plain-http fallback) |
| `41-gat.*` | … and `auth/gat.htpasswd` exists |
| `42-upsmonitor.*`, `43-iiqresponder.*` | … and `host.docker.internal` resolves (`extra_hosts` in `docker-compose.yml`) |

The startup log lists which sites are on and off.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Runs the proxy on the server |
| `nginx/Dockerfile` | Image based on `nginx:stable-alpine` |
| `nginx/snippets/ssl.conf` | Shared HTTPS settings (certificate, TLS, HSTS) |
| `nginx/snippets/proxy-app.conf` | Shared proxy settings for the app sites |
| `nginx/conf.d/00-backend.conf` | IIS backend address, shared settings, token-safe log format |
| `nginx/conf.d/10-http.conf` | Port 80: accounts → https |
| `nginx/conf.d/15-default.https.conf` | Port 443 catch-all: refuse unknown names |
| `nginx/conf.d/20-accounts.https.conf` | accounts.opelikaschools.org → IIS |
| `nginx/conf.d/30-test-9000.conf` | Status/test page on 9000, and on 80 by IP |
| `nginx/conf.d/41-gat.https.conf` / `.http.conf` | GAT (password) |
| `nginx/conf.d/42-upsmonitor.https.conf` / `.http.conf` | UPS Monitor |
| `nginx/conf.d/43-iiqresponder.https.conf` / `.http.conf` | IIQ Responder |
| `nginx/html/test/index.html` | The test page |
| `nginx/docker-entrypoint.d/05-cert-watch.sh` | Switches sites on/off, reloads on certificate changes |
| `scripts/make-internal-cert.sh` | Optional: internal CA + certificate (not needed with the wildcard) |
| `.github/workflows/build-proxy.yml` | Builds, tests (`nginx -t`) and pushes the image to GHCR |

## Test page (port 9000)

`http://10.1.0.145:9000` (or `http://10.1.0.145`) shows that nginx is up, whether the certificate was found, and has a **Test connection to IIS** button.

## GAT (password)

GAT has no login of its own, so nginx asks for a username and password before passing anyone through. GAT publishes no port of its own; nginx reaches it as `gat-web-1:8080` over the shared Docker network `proxy-net`, so the password can't be bypassed.

One-time setup: `docker network create proxy-net`; in GAT's compose file remove `ports:` and add the `proxy-net` network (to the `web` service and as `external: true` at the bottom).

Users are in `/opt/nginx-proxy/auth/gat.htpasswd`:

- **Add a user** (asks for the password twice; stored hashed):
  ```bash
  printf 'USERNAME:%s\n' "$(openssl passwd -6)" | sudo tee -a /opt/nginx-proxy/auth/gat.htpasswd >/dev/null
  ```
- **Remove a user / change a password:** delete their line (`sudo nano /opt/nginx-proxy/auth/gat.htpasswd`), then add them again.

## UPS Monitor and IIQ Responder

Both run as their own containers and publish a port on the host (UPS Monitor 8084, IIQ Responder 8082). nginx reaches them through `host.docker.internal` (the `extra_hosts` entry in `docker-compose.yml`); nothing needs to change in those apps. Their own logins pass straight through nginx. Over https those passwords are now encrypted.

- They are still reachable directly on `http://10.1.0.145:8084` / `:8082` (plain http). Closing those so everyone goes through https needs a small change in each app's compose file (join `proxy-net` like GAT) — not done yet.
- UPS Monitor's syslog from the UPS cards (UDP 514) does not go through nginx.
- To change a site's name, edit `server_name` (and the redirect) in its `.https.conf` and `.http.conf`.

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

- **Backend:** `nginx/conf.d/00-backend.conf` (currently `10.11.1.69:443`).
- **Names:** each site's name is in `server_name` (and its redirect) in its `.https.conf` / `.http.conf`; accounts also in `10-http.conf`.

## Automatic builds

Every push to GitHub (any branch) builds the image, checks the config with and without a certificate, and pushes it to GHCR. It also rebuilds every Monday at 06:00 UTC for nginx security patches, and can be run by hand from the Actions tab.

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

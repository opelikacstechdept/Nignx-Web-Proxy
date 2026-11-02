# Nginx Web Proxy

An nginx reverse proxy that serves `https://accounts.opelikaschools.org` and forwards traffic to the internal IIS server at `https://10.11.1.69:443`. The site signs users in with Microsoft (Entra ID); the proxy is set up so that sign-in works through it (see below).

| Port | What | Certificate |
| --- | --- | --- |
| 80 | Let's Encrypt validation; everything else redirects to https | none |
| 443 | **accounts.opelikaschools.org** → IIS | Let's Encrypt (certbot container) |
| 9000 | **Test page** served by nginx itself (plain http) | none |

Port 443 switches on by itself as soon as the certificate exists, and nginx reloads by itself after each renewal — no restarts needed.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Proxy + certbot (renewal) for the server |
| `nginx/Dockerfile` | Image based on `nginx:stable-alpine` |
| `nginx/conf.d/00-backend.conf` | IIS backend address, shared settings, token-safe log format |
| `nginx/conf.d/10-http.conf` | Port 80: ACME challenge + redirect |
| `nginx/conf.d/20-accounts-443.conf` | Port 443: the real site |
| `nginx/conf.d/30-test-9000.conf` | Port 9000: test page |
| `nginx/html/test/index.html` | The test page |
| `nginx/docker-entrypoint.d/05-cert-watch.sh` | Turns 443 on when the cert exists; reloads on renewal |
| `.github/workflows/build-proxy.yml` | Builds, tests (`nginx -t`) and pushes the image to GHCR |

## Test page (port 9000)

`http://<proxy-server-ip>:9000` shows:

- that nginx is up and reachable, plus your IP, time, and the address you used
- whether the production site on 443 is enabled and whether the certificate was found
- a **Test connection to IIS** button that checks whether the proxy can reach `10.11.1.69:443`. A redirect result is normal: it's IIS sending you to Microsoft sign-in.

It deliberately does not proxy the site: Microsoft only sends users back to the registered `https://accounts.opelikaschools.org` address, so sign-in can only be tested on 443.

## Getting the certificate (first time)

Let's Encrypt must reach the proxy over the internet on port 80:

1. Public DNS `accounts.opelikaschools.org` → the school's public IP.
2. Firewall forwards ports **80 and 443** from that public IP to the proxy server (`10.1.0.145`).

Then, in the folder with `docker-compose.yml`:

```bash
docker compose up -d
```

```bash
docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot -d accounts.opelikaschools.org --email <admin-email> --agree-tos --no-eff-email
```

Within 5 minutes the proxy notices the cert and enables 443 (the test page on 9000 shows it). Renewal runs automatically in the `certbot` container.

If the site is internal-only (not reachable from the internet), port-80 validation can't work. Use a DNS challenge instead, or place an existing certificate (e.g. a wildcard) at `/etc/letsencrypt/live/accounts.opelikaschools.org/fullchain.pem` and `privkey.pem`.

## Microsoft sign-in through the proxy

How the sign-in round trip is handled:

1. **Correct return address.** IIS receives the real hostname, HTTPS and port 443 (plus `X-Forwarded-*` headers), so the app builds `redirect_uri = https://accounts.opelikaschools.org/...`, which matches the app registration in Entra ID. No change to the app registration is needed if it already used this address.
2. **Redirects untouched.** `proxy_redirect off` — the redirect to `login.microsoftonline.com` and its parameters pass through exactly as IIS sent them.
3. **Cookies untouched.** Nonce/correlation and auth cookies (`SameSite=None; Secure`) pass through unmodified.
4. **Large auth headers.** Header buffers are raised (64k) so big sign-in cookies don't cause `502 upstream sent too big header` after login.
5. **No tokens in logs.** Access logs omit query strings, so authorization codes or tokens in callback URLs are never written to disk. Microsoft's response normally comes as a POST body, which nginx doesn't log.
6. **Encrypted both hops.** Browser → proxy uses the Let's Encrypt cert; proxy → IIS is also HTTPS. The proxy does not verify IIS's certificate. To harden this, put IIS's CA cert in the image and add `proxy_ssl_verify on; proxy_ssl_trusted_certificate ...;`.

Sign-in passes **through** the proxy; nginx never reads or stores credentials. Users type their password on Microsoft's own site, not on this server.

## Configuration

- **Backend:** `nginx/conf.d/00-backend.conf` (currently `10.11.1.69:443`).
- **Domain:** if it changes, update `server_name`/cert paths in `10-http.conf`, `20-accounts-443.conf`, `DOMAIN` in `05-cert-watch.sh` and in the workflow.

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

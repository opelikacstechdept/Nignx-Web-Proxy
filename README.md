# Nginx Web Proxy

An nginx reverse proxy that serves `https://accounts.opelikaschools.org` and forwards traffic to the internal IIS server at `https://10.11.1.69:443`. The site signs users in with Microsoft (Entra ID); the proxy is set up so that sign-in works through it (see below).

| Port | What | Certificate |
| --- | --- | --- |
| 80 | Let's Encrypt validation; everything else redirects to https | none |
| 443 | **accounts.opelikaschools.org** → IIS | Let's Encrypt wildcard `*.opelikaschools.org` |
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
| `nginx/docker-entrypoint.d/05-cert-watch.sh` | Finds the cert, turns 443 on when it exists, reloads on renewal |
| `.github/workflows/build-proxy.yml` | Builds, tests (`nginx -t`) and pushes the image to GHCR |

## Test page (port 9000)

`http://<proxy-server-ip>:9000` shows:

- that nginx is up and reachable, plus your IP, time, and the address you used
- whether the production site on 443 is enabled and whether the certificate was found
- a **Test connection to IIS** button that checks whether the proxy can reach `10.11.1.69:443`. A redirect result is normal: it's IIS sending you to Microsoft sign-in.

It deliberately does not proxy the site: Microsoft only sends users back to the registered `https://accounts.opelikaschools.org` address, so sign-in can only be tested on 443.

## Getting the certificate (first time)

The proxy uses **one wildcard certificate** for `opelikaschools.org` and `*.opelikaschools.org`, so it covers `accounts.opelikaschools.org` and any other subdomain added later. Let's Encrypt only issues wildcards through a **DNS TXT-record check**, so the site does not need to be reachable from the internet and no ports need opening.

On the proxy server, in the folder with `docker-compose.yml`:

```bash
docker compose run --rm -it --entrypoint certbot certbot certonly --manual --preferred-challenges dns -d opelikaschools.org -d '*.opelikaschools.org' --email <admin-email> --agree-tos --no-eff-email
```

certbot then shows **two** TXT values, one at a time, both for the same name `_acme-challenge.opelikaschools.org`:

1. In the **public** DNS for `opelikaschools.org`, add a TXT record `_acme-challenge` with the first value. Press Enter in certbot.
2. Add a **second** TXT record with the same name and the second value (keep the first one). Wait a minute or two, then press Enter.

The certificate is saved to `/etc/letsencrypt/live/opelikaschools.org/`. Within 5 minutes the proxy notices it and enables 443 (the test page on 9000 shows it). The two TXT records can be deleted afterwards.

**Renewal:** certificates issued this way last 90 days and do **not** renew by themselves, because the TXT records were added by hand. Run the same command again before it expires (Let's Encrypt emails a reminder). To make renewal automatic, certbot can use your DNS host's API instead; the proxy needs no change for that.

The proxy looks for certificates in this order: `live/opelikaschools.org` (wildcard), then `live/accounts.opelikaschools.org`. Override with the `CERT_NAMES` environment variable.

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
- **Domain:** if it changes, update `server_name` in `10-http.conf` and `20-accounts-443.conf`, `CERT_NAMES` in `05-cert-watch.sh`, and `CERT_NAME` in the workflow.

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

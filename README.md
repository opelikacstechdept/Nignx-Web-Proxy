# Nginx Web Proxy

An nginx reverse proxy that serves `https://accounts.opelikaschools.org` and forwards traffic to the internal IIS server at `https://10.11.1.69:443`. The site signs users in with Microsoft (Entra ID); the proxy is set up so that sign-in works through it (see below).

| Port | What | Certificate |
| --- | --- | --- |
| 80 | `accounts.opelikaschools.org` → redirect to https; anything else (e.g. by IP) → status page | none |
| 443 | **accounts.opelikaschools.org** → IIS | Your certificate in `certs/` (443 is off until it's there) |
| 9000 | **Test page** served by nginx itself (plain http) | none |

Port 443 switches on by itself as soon as the certificate exists, and nginx reloads by itself after each renewal — no restarts needed.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Runs the proxy on the server |
| `nginx/Dockerfile` | Image based on `nginx:stable-alpine` |
| `nginx/conf.d/00-backend.conf` | IIS backend address, shared settings, token-safe log format |
| `nginx/conf.d/10-http.conf` | Port 80: redirect accounts.opelikaschools.org to https |
| `nginx/conf.d/20-accounts-443.conf` | Port 443: the real site |
| `nginx/conf.d/30-test-9000.conf` | Status/test page on 9000, and on 80 by IP |
| `nginx/conf.d/40-other-apps.conf` | Other apps on this host (8080/8081) by name — switched off for now |
| `nginx/html/test/index.html` | The test page |
| `nginx/docker-entrypoint.d/05-cert-watch.sh` | Finds the cert, turns 443 on when it exists, reloads on renewal |
| `.github/workflows/build-proxy.yml` | Builds, tests (`nginx -t`) and pushes the image to GHCR |

## Test page (port 9000)

`http://<proxy-server-ip>:9000` shows:

- that nginx is up and reachable, plus your IP, time, and the address you used
- whether the production site on 443 is enabled and whether the certificate was found
- a **Test connection to IIS** button that checks whether the proxy can reach `10.11.1.69:443`. A redirect result is normal: it's IIS sending you to Microsoft sign-in.

It deliberately does not proxy the site: Microsoft only sends users back to the registered `https://accounts.opelikaschools.org` address, so sign-in can only be tested on 443.

## Other apps on this server (8080 / 8081)

Two other containers run on the same Docker host. For now they are reached **directly**, without nginx:

- `http://10.1.0.145:8080`
- `http://10.1.0.145:8081`

To reach them **by name** later (e.g. `app1.opelikaschools.org`), follow the steps at the top of `nginx/conf.d/40-other-apps.conf`: add internal DNS records pointing at 10.1.0.145, uncomment the two blocks, set the real names, and push. `docker-compose.yml` already includes the `extra_hosts` entry nginx needs to reach those ports.

## Adding the certificate

Port 443 stays off until a certificate is in place. Once you have one (for example a purchased certificate for `accounts.opelikaschools.org` or `*.opelikaschools.org`), put two files in the `certs` folder next to `docker-compose.yml` on the proxy server:

| File | Contents |
| --- | --- |
| `certs/fullchain.pem` | Your certificate, followed by the CA's intermediate certificate(s) |
| `certs/privkey.pem` | The private key (unencrypted) |

Within 5 minutes the proxy notices them, turns 443 on and reloads; the test page on port 9000 shows the certificate as found. To replace the certificate later (renewal), overwrite both files — the proxy reloads by itself.

Certificate vendors deliver files in different formats. Typical conversions (run on the proxy server, inside the `certs` folder):

- **Separate files** (`your_domain.crt` + `intermediate.crt`/`ca-bundle.crt` + the `.key` you generated):
  ```bash
  cat your_domain.crt ca-bundle.crt > fullchain.pem && cp your_domain.key privkey.pem
  ```
- **A `.pfx` / `.p12` file** (e.g. exported from Windows/IIS):
  ```bash
  openssl pkcs12 -in cert.pfx -nokeys -out fullchain.pem && openssl pkcs12 -in cert.pfx -nocerts -nodes -out privkey.pem
  ```

Then lock down the key:

```bash
chmod 600 privkey.pem
```

## Microsoft sign-in through the proxy

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
- **Domain:** if it changes, update `server_name` in `10-http.conf` and `20-accounts-443.conf`, and the certificate in `certs/`.

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

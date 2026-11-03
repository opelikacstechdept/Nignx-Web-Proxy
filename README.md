# Nginx Web Proxy

An nginx reverse proxy that serves `https://accounts.opelikaschools.org` and forwards traffic to the internal IIS server at `https://10.11.1.69:443`. The site signs users in with Microsoft (Entra ID); the proxy is set up so that sign-in works through it (see below).

| Port | What | Certificate |
| --- | --- | --- |
| 80 | Let's Encrypt validation; everything else redirects to https | none |
| 443 | **accounts.opelikaschools.org** → IIS | Wildcard `*.opelikaschools.org` (from win-acme on the IIS server) |
| 9000 | **Test page** served by nginx itself (plain http) | none |

Port 443 switches on by itself as soon as the certificate exists, and nginx reloads by itself after each renewal — no restarts needed.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Proxy (+ optional certbot) for the server |
| `windows/copy-cert-to-proxy.ps1` | Run by win-acme on the IIS server: copies the cert to the proxy |
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

## Certificate: one wildcard cert for IIS and the proxy

One Let's Encrypt **wildcard certificate** (`opelikaschools.org` + `*.opelikaschools.org`) is used on **both** servers:

- **win-acme** on the IIS server (10.11.1.69) requests and renews it, and installs it in IIS.
- After every issue/renewal, win-acme runs `windows/copy-cert-to-proxy.ps1`, which copies it over SSH to the proxy (`/opt/nginx-proxy/certs/opelikaschools.org/`).
- The proxy notices the new files within 5 minutes and reloads itself (port 443 switches on the first time).

### 1. Proxy server (10.1.0.145), once

```bash
mkdir -p /opt/nginx-proxy/certs
```

Use the current `docker-compose.yml` from this repo (it mounts `./certs`), then:

```bash
cd /opt/nginx-proxy && docker compose pull && docker compose up -d
```

### 2. IIS server (10.11.1.69), once — PowerShell as Administrator

Folder for the script, key and PEM files, readable only by SYSTEM and Administrators:

```powershell
New-Item -ItemType Directory -Force C:\certs\pem | Out-Null
icacls C:\certs /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"
```

Copy `windows/copy-cert-to-proxy.ps1` from this repo to `C:\certs\`. Create an SSH key; press **Enter twice** when asked for a passphrase (win-acme runs unattended, so the key can't have one):

```powershell
ssh-keygen -t ed25519 -f C:\certs\proxy_ssh_key -C "win-acme copy to proxy"
```

Show the public key and copy the line:

```powershell
Get-Content C:\certs\proxy_ssh_key.pub
```

On the **proxy server**, append that line to `~localadmin/.ssh/authorized_keys`, prefixed with `from="10.11.1.69" ` so the key only works from the IIS server:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'from="10.11.1.69" <paste the ssh-ed25519 line here>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

### 3. Request the certificate with win-acme

Download win-acme (x64, pluggable) from <https://www.win-acme.com> to `C:\win-acme`, run `wacs.exe` as Administrator and choose:

| Prompt | Choice |
| --- | --- |
| Main menu | **Create certificate (full options)** |
| Source | **Manual input** — `opelikaschools.org,*.opelikaschools.org` |
| Split | one certificate |
| Validation | **DNS** — "Create verification records manually" (or your DNS host's plugin, see below) |
| Key type | RSA |
| Store | **Windows Certificate Store** *and* **PEM encoded files** → path `C:\certs\pem` |
| Installation | **Create or update bindings in IIS** (pick the accounts.opelikaschools.org site) *and* **Start external script** → `C:\certs\copy-cert-to-proxy.ps1`, no parameters |

For manual DNS validation win-acme shows TXT values for `_acme-challenge.opelikaschools.org`; add each one in the **public** DNS for `opelikaschools.org` and press Enter. They can be removed afterwards.

When it finishes, check `C:\certs\copy-cert-to-proxy.log` and the proxy test page (`http://10.1.0.145:9000`), which should show the certificate as found in `/certs/opelikaschools.org`.

### Renewal

win-acme adds a scheduled task that renews automatically **only if validation is automatic**. With manual TXT records it can't renew unattended, so either re-run it before the 90 days are up, or pick your DNS host's plugin in the validation step (Cloudflare, Azure DNS, Route 53, GoDaddy, Google and others are available) so renewals — and the copy to the proxy — happen on their own.

### Fallback: certbot on the proxy

The proxy also accepts a certbot certificate in `/etc/letsencrypt/live/opelikaschools.org/` (or `live/accounts.opelikaschools.org/`) if there is none in `certs/`. Search order can be changed with the `CERT_DIRS` environment variable.

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
- **Domain:** if it changes, update `server_name` in `10-http.conf` and `20-accounts-443.conf`, `CERT_DIRS` in `05-cert-watch.sh`, `RemoteDir` in `copy-cert-to-proxy.ps1`, and `CERT_NAME` in the workflow.

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

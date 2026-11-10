# Nginx Web Proxy

An nginx reverse proxy that serves `https://accounts.opelikaschools.org` and forwards traffic to the internal IIS server at `https://10.11.1.69:443`. The site signs users in with Microsoft (Entra ID); the proxy is set up so that sign-in works through it (see below).

| Port | What | Certificate |
| --- | --- | --- |
| 80 | `accounts.opelikaschools.org` → redirect to https; anything else (e.g. by IP) → status page | none |
| 443 | **accounts.opelikaschools.org** → IIS | Your certificate in `certs/` (443 is off until it's there) |
| 9000 | **Test page** served by nginx itself (plain http) | none |
| 8081 | **GAT**, password protected (plain http) | none |

Port 443 switches on by itself as soon as the certificate exists, and nginx reloads by itself after each renewal — no restarts needed.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Runs the proxy on the server |
| `scripts/make-internal-cert.sh` | Creates an internal CA and the proxy's certificate |
| `nginx/Dockerfile` | Image based on `nginx:stable-alpine` |
| `nginx/conf.d/00-backend.conf` | IIS backend address, shared settings, token-safe log format |
| `nginx/conf.d/10-http.conf` | Port 80: redirect accounts.opelikaschools.org to https |
| `nginx/conf.d/20-accounts-443.conf` | Port 443: the real site |
| `nginx/conf.d/30-test-9000.conf` | Status/test page on 9000, and on 80 by IP |
| `nginx/conf.d/41-gat-8081.conf` | GAT on 8081 behind a password |
| `nginx/conf.d/42-ups-monitor.conf` | UPS Monitor (8084) by name: `ups.opelikaschools.org` |
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

## GAT behind a password (port 8081)

GAT (`gat-web-1`) has no login of its own, so nginx asks for a username and password (the browser's sign-in box) before passing anyone through to it. GAT itself no longer publishes a port, so the password can't be bypassed.

One-time setup on the proxy server:

1. Shared network so nginx can reach GAT by name:
   ```bash
   docker network create proxy-net
   ```
2. In **GAT's** compose file: delete its `ports:` lines (`127.0.0.1:8081:8080`), and join the network — add under its service:
   ```yaml
       networks:
         - default
         - proxy-net
   ```
   and at the bottom of the file:
   ```yaml
   networks:
     proxy-net:
       external: true
   ```
   Then `docker compose up -d` in GAT's folder.
3. Create a login (asks for the password twice; it is stored hashed):
   ```bash
   sudo mkdir -p /opt/nginx-proxy/auth && printf 'gatadmin:%s\n' "$(openssl passwd -6)" | sudo tee -a /opt/nginx-proxy/auth/gat.htpasswd >/dev/null
   ```
4. Use the current `docker-compose.yml` from this repo (port 8081, `./auth`, `proxy-net`), then `docker compose pull && docker compose up -d` in `/opt/nginx-proxy`.

Browse to `http://10.1.0.145:8081`.

- **More users:** run step 3 again with another name in place of `gatadmin`. Takes effect immediately.
- **Change a password / remove a user:** edit `/opt/nginx-proxy/auth/gat.htpasswd` (one line per user), then re-add the user with step 3.
- **No password file → port 8081 stays closed**, so GAT is never exposed without a password.
- The password travels over plain http on the internal network. Once a certificate is in place this can move to https.

## UPS Monitor by name

[UPS Monitor](https://github.com/opelikacstechdept/UPS-Monitor) runs as its own container and publishes port 8084 on the host. nginx makes it available by name:

- `http://ups.opelikaschools.org` → UPS Monitor (through nginx)
- `http://10.1.0.145:8084` still works directly

Setup:

1. Internal DNS: an A record `ups.opelikaschools.org` → `10.1.0.145`.
2. Nothing to change in UPS Monitor. nginx reaches it via `host.docker.internal:8084` (the `extra_hosts` entry in `docker-compose.yml`), and UPS Monitor's own login (`APP_USERNAME`/`APP_PASSWORD`) is passed straight through.
3. On the proxy server: `docker compose pull && docker compose up -d` in `/opt/nginx-proxy`.

To use a different name, change `server_name` in `nginx/conf.d/42-ups-monitor.conf` and push. If UPS Monitor moves off port 8084, change the `server` line in the same file. Only the web dashboard goes through nginx; syslog from the UPS cards (UDP 514) still goes directly to UPS Monitor.

If the proxy's compose file is missing the `extra_hosts` entry, the UPS site is switched off at startup (logged) and every other site keeps working.

## Other apps on this server (8082 / 8081)

Two other containers run on the same Docker host. For now they are reached **directly**, without nginx:

- `http://10.1.0.145:8082` (IIQResponder — its own login)
- `http://10.1.0.145:8081` (GAT — now through nginx with a password, see above)

To reach them **by name** later (e.g. `app1.opelikaschools.org`), follow the steps at the top of `nginx/conf.d/40-other-apps.conf`: add internal DNS records pointing at 10.1.0.145, uncomment the two blocks, set the real names, and push. `docker-compose.yml` already includes the `extra_hosts` entry nginx needs to reach those ports.

## Internal certificate (until a purchased one is in place)

`scripts/make-internal-cert.sh` creates a small **internal certificate authority (CA)** once, and issues the proxy's HTTPS certificate from it. Machines that have the CA installed trust the site with no warnings; others see a certificate warning.

The CA is limited (name constraints) to `opelikaschools.org` names and `10.x.x.x` addresses, so even if its key leaked it could not be used to impersonate other websites.

### Create it (proxy server)

Copy `scripts/make-internal-cert.sh` to `/opt/nginx-proxy/`, then:

```bash
cd /opt/nginx-proxy && chmod +x make-internal-cert.sh && sudo ./make-internal-cert.sh accounts.opelikaschools.org 10.1.0.145
```

List every name (and IP) the certificate should cover. The script writes `certs/fullchain.pem` + `certs/privkey.pem` (the proxy turns 443 on within 5 minutes) and `ca/OpelikaSchools-Internal-CA.cer` (the file to deploy).

- **Renew / add names:** run it again with the full list of names. The same CA is reused, so machines need nothing new. The server certificate lasts 825 days.
- **`ca/ca.key` is the CA's private key.** Keep it secret and back it up somewhere safe; without it you can't renew, and anyone with it can issue certificates the machines trust (within the limits above).

### Install the CA on the machines that should trust it

Use `OpelikaSchools-Internal-CA.cer`. It must go in the **Trusted Root Certification Authorities** store (machine-wide), not the personal store.

| Machines | How |
| --- | --- |
| Domain-joined Windows (Group Policy) | Group Policy Management → edit a GPO linked to those computers → Computer Configuration → Policies → Windows Settings → Security Settings → Public Key Policies → **Trusted Root Certification Authorities** → right-click → Import → the `.cer`. Applies at next policy refresh (`gpupdate /force` to test). |
| Intune-managed Windows | Devices → Configuration → Create → Windows 10 and later → Templates → **Trusted certificate** → upload the `.cer`, destination store "Computer certificate store - Root" → assign. |
| One Windows PC (testing) | Admin Command Prompt: `certutil -addstore -f Root OpelikaSchools-Internal-CA.cer` |
| Chromebooks | Google Admin console → Devices → Networks → **Certificates** → pick the OU → Add certificate → upload → tick **Chromebook** under "Certificate authority" → Save. |
| Mac | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain OpelikaSchools-Internal-CA.cer` (or an MDM certificate profile) |

Edge and Chrome on Windows use the Windows store. Firefox uses its own unless enterprise roots are enabled (policy `Certificates → ImportEnterpriseRoots`, on by default in recent versions on Windows).

To check a machine: browse to `https://accounts.opelikaschools.org` — no warning, and the certificate is issued by *Opelika City Schools Internal CA*. The CA thumbprint the script prints should match the one shown on the machine.

When the purchased certificate arrives, put it in `certs/` (below); the internal CA can then be removed from the machines.

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

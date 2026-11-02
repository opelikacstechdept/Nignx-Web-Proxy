# Nginx Web Proxy

An nginx reverse proxy that terminates TLS for `accounts.opelikaschools.org` and forwards traffic to the internal IIS server at `https://10.11.1.69:443`.

The image contains two sites:

| Port | Site | Certificate |
| --- | --- | --- |
| 80 → 443 | **Production**: `accounts.opelikaschools.org` | Let's Encrypt, mounted from the host |
| 9000 | **Test**: same backend, for trying things out | Self-signed, created automatically when the container starts |

If no Let's Encrypt cert is mounted, the production site is switched off automatically and the test site on 9000 still runs, so you can test before the real cert exists.

## Layout

| Path | Purpose |
| --- | --- |
| `nginx/Dockerfile` | Image based on `nginx:stable-alpine` |
| `nginx/conf.d/00-backend.conf` | IIS backend address (shared by both sites) |
| `nginx/conf.d/intranet.conf` | Production site: HTTP→HTTPS redirect, TLS on 443 |
| `nginx/conf.d/test-9000.conf` | Test site on 9000 |
| `nginx/docker-entrypoint.d/05-certs.sh` | Startup: creates the test cert; disables production if its cert is missing |
| `.github/workflows/build-proxy.yml` | Builds, tests (`nginx -t`) and pushes the image to GHCR |

## Configuration

- **Backend:** edit `nginx/conf.d/00-backend.conf` (currently `10.11.1.69:443`).
- **Domain:** if you change `server_name` or the cert paths, also update `DOMAIN` in the workflow and in `05-certs.sh`.

## Automatic builds

Every push to GitHub (any branch) builds the image, checks the config with and without a cert, and pushes it to GHCR. It also rebuilds every Monday at 06:00 UTC to pick up nginx security patches, and can be run by hand from the Actions tab.

| Tag | When |
| --- | --- |
| `latest` | pushes to `main` |
| `<branch-name>` | pushes to that branch (`/` becomes `-`) |
| `sha-<short>` | every build |

Image: `ghcr.io/opelikacstechdept/nignx-web-proxy/intranet-proxy`

## Running (docker compose)

The same file is in the repo as `docker-compose.yml`.

```yaml
services:
  intranet-proxy:
    image: ghcr.io/opelikacstechdept/nignx-web-proxy/intranet-proxy:latest
    container_name: intranet-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "9000:9000"   # test site - remove this line to turn it off
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
```

```bash
docker compose pull && docker compose up -d
```

If the package is private, log in once on the server with a GitHub token that has `read:packages`:

```bash
docker login ghcr.io -u <github-username>
```

Reload after a cert renewal:

```bash
docker compose exec intranet-proxy nginx -s reload
```

## Testing on port 9000

Browse to `https://<proxy-server-ip>:9000` and accept the self-signed certificate warning.

For the most realistic test (cookies, sign-in), add a hosts-file entry on your test PC, `<proxy-server-ip>  accounts.opelikaschools.org`, and browse to `https://accounts.opelikaschools.org:9000`. Remove the entry afterwards.

Startup messages, including whether production is enabled:

```bash
docker logs intranet-proxy | grep 05-certs
```

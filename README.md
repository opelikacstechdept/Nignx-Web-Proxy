# Nginx Web Proxy

An nginx reverse proxy that terminates TLS for `accounts.opelikaschools.org` and forwards traffic to the internal IIS server.

## Layout

| Path | Purpose |
| --- | --- |
| `nginx/Dockerfile` | Image based on `nginx:stable-alpine` |
| `nginx/conf.d/intranet.conf` | Proxy config: HTTP→HTTPS redirect, TLS, upstream to IIS |
| `.github/workflows/build-proxy.yml` | Builds the image, runs `nginx -t` against a throwaway cert, then pushes to GHCR |

## Configuration

- **Backend:** edit the `upstream iis_backend` block in `nginx/conf.d/intranet.conf` (currently `https://10.11.1.69:443`).
- **Domain:** if you change `server_name` or the cert paths, also update `DOMAIN` in the workflow so the CI config test still matches.

## CI / image

On every push to `main` that touches `nginx/**` or the workflow, plus every Monday at 06:00 UTC and on manual dispatch, the workflow publishes:

- `ghcr.io/opelikacstechdept/nignx-web-proxy/intranet-proxy:latest`
- `ghcr.io/opelikacstechdept/nignx-web-proxy/intranet-proxy:sha-<short>`

## Running

Certificates are not baked into the image. Mount the host's Let's Encrypt directory read-only:

```bash
docker run -d --name intranet-proxy --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  ghcr.io/opelikacstechdept/nignx-web-proxy/intranet-proxy:latest
```

After renewing certificates, reload nginx without downtime:

```bash
docker exec intranet-proxy nginx -s reload
```

## Test proxy (port 9000)

`test/` holds a standalone test instance that listens on **https port 9000** and forwards to the same IIS backend. It runs in its own container, so it can sit next to production (80/443) without interfering, and it needs no image build or Let's Encrypt cert.

On the proxy server:

```bash
cd test
mkdir -p certs
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
  -subj "/CN=accounts.opelikaschools.org" \
  -addext "subjectAltName=DNS:accounts.opelikaschools.org" \
  -keyout certs/test.key -out certs/test.crt
docker compose up -d
```

Then browse to `https://<proxy-server-ip>:9000` and accept the self-signed certificate warning.

For the most realistic test (cookies, sign-in), add a hosts-file entry on your test PC, `<proxy-server-ip>  accounts.opelikaschools.org`, and browse to `https://accounts.opelikaschools.org:9000`. Remove the entry afterwards.

Logs: `docker logs -f intranet-proxy-test` · Stop: `docker compose down`

# Documenso behind the portal

Documenso ([documenso.com](https://documenso.com)) is an open-source DocuSign
alternative. This directory is a **template** for hosting it as a portal app,
following the proxied-app pattern documented in the root `CLAUDE.md`
("App backends (proxied apps)").

## Architecture

```
Client → Traefik :443 (TLS, Host match)
       → edge network → nginx (server_name sign.example.com)
       → proxy_pass http://documenso-backend:3000
              │
              ├─── joined to `edge`              (reachable from portal nginx)
              └─── joined to `documenso-internal` (reaches postgres privately)
                          │
                          └── documenso-postgres (internal-only, no host port)
```

- **One FQDN, fully proxied.** Documenso owns every path; this is *not* a
  path-split site. `--oauth` is deliberately NOT used — public per-recipient
  signing URLs (`/sign/<token>`) must reach the app without portal auth.
- **App stack lives outside the portal repo** at `/srv/portal-apps/documenso/`.
  This directory in the repo is the source for the operator copy.
- **Postgres is unreachable from other portal apps.** The `documenso-internal`
  bridge network is `internal: true` — the DB has no route off-host.
- **systemd starts both stacks at boot.** `portal-app-documenso.service` has
  `Requires=portal-nginx.service` so the routing edge is up before Documenso.

## What's in this directory

| File                          | Purpose                                                                |
| ----------------------------- | ---------------------------------------------------------------------- |
| `docker-compose.yml`          | The compose stack (postgres + documenso). Pinned image tags.           |
| `.env.example`                | Template env file. Copy to `.env`, fill in, mode 600.                  |
| `nginx-site.conf.example`     | Replacement nginx server block (hand-edit after `portal provision-site`). |
| (operator-populated) `.env`   | Real secrets. Gitignored.                                              |
| (operator-populated) `certs/` | PDF signing cert (`cert.p12`). Gitignored.                             |

The matching systemd unit lives at `../../systemd/portal-app-documenso.service`.

## Install runbook

Run as the `portal` service user (or via `sudo -iu portal`). Substitute
`sign.your-domain.com` with your actual FQDN throughout.

### 0. DNS prerequisite

Point an A record for the FQDN at this host's public IP and confirm it
resolves before proceeding. Without correct DNS, Let's Encrypt's HTTP-01
challenge fails on first request and you start eating into the
5-issuance-per-week-per-hostname quota on retries.

```bash
dig +short sign.your-domain.com   # must match `curl -4 ifconfig.me`
curl -4 ifconfig.me
```

### 1. Stage the app directory and substitute the FQDN

```bash
FQDN=sign.your-domain.com         # ← edit before running

sudo mkdir -p /srv/portal-apps/documenso
sudo cp -a /srv/portal/apps/documenso/. /srv/portal-apps/documenso/

# Substitute the placeholder FQDN in every file that contains one. Both
# docker-compose.yml (the `hostname:` directive — see Step 7's SMTP note)
# and nginx-site.conf.example need this.
sudo find /srv/portal-apps/documenso -type f \
    \( -name 'docker-compose.yml' -o -name 'nginx-site.conf.example' \) \
    -exec sed -i "s/sign\.example\.com/$FQDN/g" {} +

sudo chown -R portal:portal /srv/portal-apps/documenso
cd /srv/portal-apps/documenso
```

### 2. Generate the signing certificate

Self-signed is fine for in-house use; CA-issued may be required for
legally-recognized signatures in your jurisdiction.

```bash
mkdir -p certs && cd certs
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
    -keyout key.pem -out cert.pem \
    -subj "/CN=Documenso Self-Signed/O=Your Org"
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem \
    -passout pass:CHANGEME-cert-passphrase
chmod 644 cert.p12         # container's app user (non-root) reads this
rm cert.pem key.pem        # keep only the .p12
cd ..
```

### 3. Generate secrets and write `.env`

```bash
cp .env.example .env
chmod 600 .env

# Three independent crypto secrets — copy each into the matching slot in .env.
openssl rand -base64 32        # → NEXTAUTH_SECRET
openssl rand -base64 32        # → NEXT_PRIVATE_ENCRYPTION_KEY
openssl rand -base64 32        # → NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY
openssl rand -base64 24        # → POSTGRES_PASSWORD (also embedded in DATABASE_URL)
```

Set `NEXT_PUBLIC_WEBAPP_URL`, SMTP creds, and `NEXT_PRIVATE_SIGNING_PASSPHRASE`
to match the values you used above. Then **back the file up to your secret
store** — losing the encryption keys makes existing documents undecryptable.

### 4. Provision the portal-side routing

```bash
portal provision-site $FQDN

# Replace the generated static-only nginx config with the Documenso proxy
# version. Step 1 already substituted the FQDN in the source template.
sudo -u portal cp /srv/portal-apps/documenso/nginx-site.conf.example \
    /srv/portal/nginx/conf.d/$FQDN.conf
```

**Do NOT reload nginx yet.** nginx resolves upstream hostnames at
config-test time, not lazily at request time — and `documenso-backend`
doesn't exist on the `edge` network until Step 5 brings the stack up.
Reloading now would fail with `host not found in upstream`. The reload
happens at the end of Step 5.

The Traefik dynamic file generated by `provision-site` is correct as-is —
Traefik just routes by Host; the path-level proxy work happens at nginx.

### 5. Bring up the app stack and reload nginx

```bash
cd /srv/portal-apps/documenso
docker compose up -d
docker compose logs -f documenso       # watch Prisma migrations on first start

# Once Documenso shows healthy (compose ps), the nginx upstream resolves:
portal reload-nginx
```

First container start can take a couple of minutes (image pull + DB
migrations). Hit `https://$FQDN/` in a browser; Let's Encrypt issues the
cert on the first request via Traefik's HTTP-01 resolver.

### 6. Install the systemd unit

```bash
sudo cp /srv/portal/systemd/portal-app-documenso.service \
    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now portal-app-documenso.service
```

Use `systemctl restart` (not `start`) for any subsequent config/env changes —
the unit is `Type=oneshot` + `RemainAfterExit=yes`, same gotcha as the other
portal units.

### 7. SMTP relay setup (Google Workspace)

If you're using Google Workspace's IP-trusted SMTP relay
(`smtp-relay.gmail.com:587`), the relay rejects EHLO from un-resolvable
container hostnames with a generic `421 4.7.0 Try again later, closing
connection. (EHLO)` — easy to misdiagnose as an IP allowlist problem.

The compose template's `hostname: sign.example.com` directive (substituted
to your real FQDN in Step 1) fixes this by pinning the container's OS
hostname to the public FQDN. nodemailer reads `os.hostname()` for its EHLO
name, so the relay sees a hostname it can resolve.

Other Workspace SMTP relay gotchas worth knowing:

- The egress IP from `curl -4 ifconfig.me` must match exactly what's in
  Workspace Admin → Apps → Gmail → Routing → SMTP relay service. NAT and
  floating-IP setups frequently produce a different egress IP than what
  `ifconfig` shows on the host.
- "Allowed senders" must be set to **"Only addresses in my domains"** so
  `noreply@<your-domain>` works without a real Workspace mailbox. The
  alternative ("Only registered Apps users") would require `noreply` to
  be a real account.
- Routing rule changes can take 5-60 minutes to propagate.

## Backups

Three things are needed for a full restore. Losing any one of them costs data:

1. `pg_dump` of the documenso database (named volume `documenso-pg-data`).
2. The `uploads/` directory if `NEXT_PUBLIC_UPLOAD_TRANSPORT=s3` was switched
   to a local equivalent — by default uploads ride in Postgres, so #1 covers it.
3. `.env` and `certs/cert.p12` — these encrypt and sign documents respectively;
   without them, restored Postgres data is unreadable.

Sample dump command (from the host):

```bash
docker exec documenso-postgres pg_dump -U documenso documenso \
    | gzip > /var/backups/documenso-$(date +%F).sql.gz
```

## Upgrades

```bash
cd /srv/portal-apps/documenso
# Bump the tag in docker-compose.yml (Dependabot will open PRs against
# the in-repo template; the operator copy here is hand-bumped).
docker compose pull
docker compose up -d
docker compose logs -f documenso       # confirm migrations applied cleanly
```

Always `pg_dump` before bumping. Prisma migrations run on container start, so
a bad image leaves you with a half-migrated DB.

## Operational notes

- **Mail deliverability matters.** Sign links are emailed to external
  recipients; SPF, DKIM, and DMARC for the `MAIL_FROM` domain are non-optional.
- **OAuth in front would break signing.** Don't put portal-level OAuth in
  front of this site. Documenso has its own auth for the operator side, and
  recipients sign without any account.
- **Resource sizing.** PDF rendering is CPU-bursty; 2 vCPU / 2 GB is a
  reasonable floor.

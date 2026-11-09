# CLAUDE.md — traefik-nginx-portal

Provisioning scripts + config for a two-container hosting stack: **Traefik** (TLS + routing) in front of **nginx** (static sites). One Traefik fronts many nginx sites; each site is (de)provisioned by shell scripts that write three coordinated artifacts.

History before 2026-10-19: `.claude/archive/CLAUDE.20261019-233000.md` (local only).

- Repo root IS the portal root (`bin/`, `nginx/`, `traefik/`, `docker-compose.yml` at top level). Scripts resolve their own dir (`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`); compose mounts are relative (`./traefik/...`), so any checkout path works (`/srv/portal/`, `/srv/ai/`, `/opt/portal/`). `/srv/portal/` in examples is conventional; `$PORTAL_DIR` = `$REPO_ROOT` = wherever it's checked out.
- No build, no tests, no linter — pure shell + config.

## ⛔ Live host: `/srv/portal` on webproxy.ai
- After any root edit or `git pull`, `chown portal:portal` the tracked files, then test with `systemctl restart portal-traefik` (runs as `User=portal`) — never a manual `docker compose`. Root umask 027 caused the 2026-10-15 6.5 h all-sites outage. No test reboot done since.

## Architecture

Two independent compose stacks meeting on shared Docker networks `traefik` + `edge` (both `external: true`; must exist first):
- `docker-compose.yml` — Traefik `traefik:v3.7.17` (patch-pinned) on `traefik` + `edge`, ports 80/443, internal `:8082/ping` entrypoint for the healthcheck. Static config `traefik/traefik.yml`; watches `traefik/dynamic/`. LE HTTP-01; certs in `traefik/acme.json` (bind mount; writable even with `read_only: true`).
- `docker-compose.override.yml` (host-only, gitignored, auto-loaded by `docker compose`/systemd): per-host additions. On the production host it adds the `admitly` network to Traefik (admitly.io's app shares it with Traefik only) and, since 2026-11-09, the `family` network (family.jjocapps.com's `family-tree` and `family-auth`).
- `nginx/docker-compose.yml` — `nginx:1.27-alpine` (minor-pinned) on `edge` only, no host ports. Hardened: `read_only` root FS, `cap_drop ALL`, `no-new-privileges`, tmpfs `/var/cache/nginx`, `/var/run`, `/tmp`. Healthcheck `http://127.0.0.1/` (served by `00-default.conf` catchall).
- **nginx logging under `read_only`:** `access_log /var/log/nginx/access.log` / `error_log /var/log/nginx/error.log` work only because the image symlinks them to `/dev/stdout`/`/dev/stderr`. **Don't add any other log paths in `conf.d/*.conf`** — nginx fails to start creating them. For on-disk per-site logs: bind-mount `./logs:/var/log/nginx` *and* drop `read_only: true` (+ logrotate).
- `bin/bootstrap.sh` once per host (safe to re-run): `create-docker-networks.sh` → `acme.json` preflight (touch + chmod 600) → `ensure-default-tls.sh`. Verify with `bin/verify-networks.sh` (expects `traefik → edge,traefik`, `nginx → edge`).
- `acme.json` is not committed. Without the preflight, `docker compose up` auto-creates the bind path as a root-owned **directory**, permanently breaking Traefik.

### Lifecycle (systemd + Docker split)
- Prod: `systemd/portal-nginx.service` + `systemd/portal-traefik.service` (installed to `/etc/systemd/system/` by `install.sh`). Each `Type=oneshot` + `RemainAfterExit=yes`, `ExecStart=docker compose up -d` as the `portal` user, enabled on boot. `portal-traefik` has `Requires=portal-nginx.service`.
- **systemd owns start/stop/boot; `restart: unless-stopped` owns in-run crash recovery.** systemd doesn't monitor containers after `ExecStart` returns. `systemctl stop` runs `docker compose down`, which `unless-stopped` respects.
- **Use `systemctl restart`, never `start`.** Oneshot units stay `active (exited)`, so `start` on them is a **no-op**: `docker compose down && systemctl start portal-traefik` leaves no containers while systemd reports fine.
- To apply `.env` changes: `systemctl restart portal-traefik` (re-runs `up -d`, re-substitutes `.env`, recreates changed containers). Don't reach for `compose down`.
- Backend apps can mirror this with a `portal-app-<name>.service`.

### Permissions model (hardened hosts)
Hardened hosts set root/portal login umask 007 or 027 (`/etc/login.defs` `UMASK`). Two umask layers counter it:
- `install.sh`: `umask 022` at top + `chmod -R u=rwX,go=rX` on the install dir after the phase-4 chown.
- `bin/_lib.sh`: `umask 022`, sourced by every `bin/` script → 644 files / 755 dirs regardless of login umask. Edit the umask in `_lib.sh`, not individual scripts.

Without them, bind-mounted configs land 600/700 and site content 660/770:
- **Traefik** runs as root, but `cap_drop: ALL` strips `DAC_OVERRIDE`, so root obeys normal DAC. Compose `cap_add: DAC_OVERRIDE` restores it; without it Traefik crash-loops on `open /etc/traefik/traefik.yml: permission denied` before the healthcheck runs.
- **nginx** master is root (gets `DAC_OVERRIDE`), but workers `setuid` to `nginx` and **lose all caps** (no ambient/file caps). Workers do the I/O, so content must be world-readable (644/755); `cap_add: DAC_OVERRIDE` is a no-op here — the umask is what makes it work.
- Secrets are chmodded explicitly after creation (`acme.json` 600, `traefik/certs/default.key` 600, `traefik/certs/` 700), so `umask 022` doesn't weaken them. Traefik reads them via `DAC_OVERRIDE`; portal user as owner.

### The three-files-per-site invariant
`list-sites.sh` treats these as the sources of truth:
1. `nginx/conf.d/<fqdn>.conf` — server block (:80 on `edge`, `server_name <fqdn>`, root `/var/www/<fqdn>`). Logs go to global stdout/stderr; no per-site log files.
2. `nginx/sites/<fqdn>/` — content dir (placeholder `index.html`).
3. `traefik/dynamic/<fqdn>.yml` — router `Host(\`<fqdn>\`)` on `websecure` → `nginx-backend`, middlewares `security-headers@file` + `rate-limit@file`, TLS resolver `letsencrypt`. `--oauth` adds `oauth-google-forward-auth@file`; with `--oauth-public=<prefixes>` the file holds *two* routers (see OAuth).

- Any one missing → `list-sites.sh` reports **drift**. Provision/deprovision always act on all three.
- `provision-site.sh` has an `EXIT` trap that rolls back what it created if `nginx -t` or another step fails. The `rm -rf` of the site dir is safe *only because* the refuse-to-overwrite guard exists; if the guard is relaxed, tighten the rollback (`IDEMPOTENCY_AUDIT.md` L1).

### Shared script helpers (`bin/_lib.sh`)
- Sourced by every `bin/` script. No shebang (library); uses `# shellcheck shell=bash`. Exports `$PORTAL_DIR` — use it for non-script paths (`nginx/`, `traefik/`, compose files, `logs/`, lock file); use `$SCRIPT_DIR` for sibling scripts.
- Colors (TTY-aware, empty when piped): `GREEN`, `YELLOW`, `RED`, `BLUE`, `BOLD`, `DIM`, `RESET`.
- Logging: `log_info`, `log_ok`, `log_warn`, `log_error`, `log_skip`, `die`. Specialized tags are local (`log_step` in bootstrap, `log_dry` in deprovision).
- `validate_fqdn <fqdn>` — single FQDN regex: lowercase, ≥1 dot, DNS-legal; rejects wildcards, IDN/punycode, plus explicit `..`/`/` checks (FQDN feeds `rm -rf` paths). Edit here, not in callers.
- `acquire_portal_lock <dir>` — `flock` mutex for concurrent (de)provision; silent no-op without `flock` (macOS).
- `write_atomic <target>` — stdin → temp file on same FS → atomic rename; respects umask. Use for all generated files; never revert to `cat > $TARGET <<EOF`. For mode-sensitive outputs (keys) use explicit mktemp-chmod-mv like `ensure-default-tls.sh`.
- `nginx_reload [container]` — test + graceful reload; warns and skips if container not running; non-zero only on test/reload failure (callers add their own message). Used by `provision-site.sh`, `deprovision-site.sh`, `bin/reload-nginx.sh`.

### Shared Traefik dynamic files
`_`-prefixed files in `traefik/dynamic/` are shared config (skipped by `list-sites.sh`):
- `_shared-services.yml` — `nginx-backend` → `http://nginx:80` on `edge`. Missing → every site 503s.
- `_middlewares.yml` — `security-headers`, `rate-limit`.
- `_default-tls.yml` — `tls.stores.default` → self-signed cert in `traefik/certs/` (gitignored), from `ensure-default-tls.sh`, so unknown SNI gets our cert not Traefik's.
- `_oauth.yml` — `oauth-google-forward-auth` `forwardAuth` → `traefik-forward-auth-google` sidecar on the `traefik` network.

### OAuth protection
- Google Workspace sign-in (or any OIDC provider by reconfiguring the sidecar). **One stateless (JWT-cookie) sidecar protects N sites** — `traefik-forward-auth-google` in top-level `docker-compose.yml`.
- **Opt-in:** `provision-site.sh --oauth` (or menu prompt) attaches `oauth-google-forward-auth@file`. Re-provision without it → public.
- Sidecar is behind `profiles: [oauth]`; runs only when `.env` has `COMPOSE_PROFILES=oauth`. Enable later: edit `.env`, `systemctl restart portal-traefik`.
- `.env` vars: `OAUTH_PROVIDERS_GOOGLE_CLIENT_ID` + `OAUTH_PROVIDERS_GOOGLE_CLIENT_SECRET` (Google Cloud Console); `OAUTH_SECRET` (32-byte cookie key, `openssl rand -base64 32`, generated by `install.sh`); `OAUTH_DOMAIN` (comma-separated email domains, e.g. `jjocllc.com,partner.com`). One OAuth client serves all sites on the default sidecar; no per-site credentials.
- Register `https://<fqdn>/_oauth` per protected site in the OAuth client; `provision-site.sh --oauth` prints it.
- **Per-path opt-outs:** `--oauth-public=/healthz,/webhooks/` (comma-separated `PathPrefix`) → dual-router YAML: public router `priority: 100` (no OAuth) + catchall `priority: 10` (full chain). Explicit priorities so precedence doesn't rely on rule-length tiebreak. Validation rejects entries not starting with `/` or containing backticks.
- LE HTTP-01 (`/.well-known/acme-challenge/*` on `web` :80) is intercepted by Traefik before any router — auth never sees it.

**Adding a second OAuth client or provider** (same-provider different client — e.g. another Workspace with its own client/consent screen, which shared `OAUTH_DOMAIN` can't separate — or a different provider like Entra ID/Okta). Copy-paste-rename the sidecar; pick a short lowercase `<name>` (`acme`, `partner`, `microsoft`):
1. Compose: copy `traefik-forward-auth-google` as `container_name: traefik-forward-auth-<name>`, env refs suffixed `_<UPPER_NAME>` (e.g. `OAUTH_PROVIDERS_GOOGLE_CLIENT_ID_ACME`); same `profiles: [oauth]` + `traefik` network.
2. `/srv/portal/.env` (600): `OAUTH_PROVIDERS_GOOGLE_CLIENT_ID_<UPPER_NAME>`, `_SECRET_<UPPER_NAME>`, `OAUTH_SECRET_<UPPER_NAME>` (fresh `openssl rand -base64 32`, distinct), `OAUTH_DOMAIN_<UPPER_NAME>`.
3. `traefik/dynamic/_oauth-<name>.yml`: middleware `oauth-google-forward-auth-<name>` → `http://traefik-forward-auth-<name>:4181` (same shape as `_oauth.yml`).
4. `systemctl restart portal-traefik` — dynamic YAML hot-reloads, new compose service doesn't.
5. `provision-site.sh <fqdn> --oauth-provider=<name>` attaches `oauth-google-forward-auth-<name>@file`. Name: lowercase alnum + hyphens, no leading/trailing hyphen, ≤32 chars; prints redirect URI + `.env` var name.
6. Add `https://<fqdn>/_oauth` to *that* client (the `_<UPPER_NAME>` one, not the default).
- Different provider: same steps, but change `provider:` and env names to the upstream's (`PROVIDERS_OIDC_*`, `PROVIDERS_GENERIC_OAUTH_*`, …). Keep the `oauth-google-forward-auth-<name>` naming so callers needn't know the provider.
- **Address-level restriction** (same client, specific addresses): set `WHITELIST` (comma-separated exact addresses) instead of `DOMAIN` on the sibling sidecar; with `MATCH_WHITELIST_OR_DOMAIN` off only those pass. Client ID/secret may reuse the default's — access control lives in the sidecar config.

⚠️ **An unset allowlist fails OPEN.** `ValidateEmail` (`internal/auth.go`) returns `true` when `WHITELIST` **and** `DOMAIN` are both empty — a typo'd/missing env var admits every Google account, silently. After any sidecar config change, check what it received:
```bash
docker compose exec traefik-forward-auth-<name> env | grep -E 'WHITELIST|DOMAIN'
```
Apps behind an address-restricted sidecar should also re-check `X-Forwarded-User` against their own allowlist.

**Live sidecars:** `traefik-forward-auth-google` (DOMAIN-scoped) and `traefik-forward-auth-jjoc` (`OAUTH_WHITELIST_JJOC`, single address; first consumer `mail.jjocapps.com`, which fronts a tool that can trash a mailbox — hence address-level restriction + app-side re-check).

Not supported: provider chaining on one site ("Google OR Microsoft") — one provider per instance; use Authelia/Dex/Keycloak.

### Wildcard certs (per-tenant subdomains)
- `letsencrypt-dns` resolver (Route53 DNS-01) alongside default `letsencrypt` (HTTP-01) in `traefik.yml`. First user `admitly.io` (mints `<user>.admitly.io` on signup).
- Why: LE requires DNS-01 for wildcards; per-subdomain HTTP-01 would hit LE's 50 certs per registered domain per week.
- Per-site dynamic YAML — three things:
  1. Rule matches apex + one-label subdomains (escaped `\\.` for YAML + regex):
     ```yaml
     rule: "Host(`example.com`) || HostRegexp(`^[a-z0-9-]+\\.example\\.com$`)"
     ```
  2. `tls.certResolver: letsencrypt-dns` — else Traefik uses the first resolver (HTTP-01) and fails `acme: could not determine solvers`.
  3. **`tls.domains` MUST have apex as `main` AND wildcard as SAN.** `*.example.com` doesn't cover bare `example.com`; listing only the wildcard in `main` leaves the apex on a stale HTTP-01 cert or the self-signed default.
     ```yaml
     tls:
       certResolver: letsencrypt-dns
       domains:
         - main: example.com
           sans:
             - "*.example.com"
     ```
- nginx: `server_name example.com *.example.com;`; app dispatches on `Host` / `X-Forwarded-Host`.
- AWS: `bin/iam-route53-setup.sh --domain example.com [--user NAME] [--rotate-key]` — run from an operator workstation, NOT prod, NOT via `portal` wrapper (uses local admin AWS creds). Creates least-privilege IAM user + inline policy on the hosted zone + access key, emits a mode-600 `.env` snippet. Idempotent.
- **Static config = restart, dynamic = reload.** `traefik.yml` (resolvers) is read only at startup; a new resolver needs `systemctl restart portal-traefik`. `Router uses a nonexistent certificate resolver` = YAML reached prod but Traefik wasn't restarted.
- **Stale `acme.json` certs:** changing `tls.domains` after issuance may not re-issue. Back up `acme.json` (a typo loses all certs), `jq` out the entry from `letsencrypt-dns.Certificates`, restart, hit the site.
- Second DNS provider (Cloudflare, DO, …): add another resolver in `traefik.yml` (swap `dnsChallenge.provider` + compose env vars); sites choose per dynamic file. Route53 is the only one wired today.

### App backends (proxied apps)
Path-split sites: static at `/`, reverse-proxy a prefix (e.g. `/api/`) to a backend. First: `admitly.io` (MPA + FastAPI streaming vLLM SSE).
- **Backends live at `/srv/portal-apps/<name>/`** — sibling to the portal, never inside. Own `docker-compose.yml`, `container_name: <name>-backend`, joined to `external: true` `edge`. Portal owns routing; app owns its lifecycle (volumes, env, healthcheck, optional `portal-app-<name>.service`).
- **Hand-edit nginx after `portal provision-site`:** add `location ^~ /api/ { proxy_pass http://<name>-backend:PORT; ... }` **before** the static-asset regex. `^~` is critical — otherwise `/api/foo.js` is captured by the cache regex and 404s. (`--backend HOST:PORT` flag deliberately declined until 2–3 proxied apps show a real shape.)
- **SSE-critical nginx settings** for any streaming backend:
  - `proxy_buffering off` — else the client sees nothing until generation ends. #1 SSE footgun.
  - `proxy_read_timeout 1h` / `proxy_send_timeout 1h` — 60s defaults truncate long streams.
  - `proxy_http_version 1.1` + `proxy_set_header Connection ""` — upstream keepalive (with `upstream { ... keepalive 32; }`).
  - `proxy_ignore_client_abort on` — with a detached upstream pump (admitly's FastAPI tees vLLM deltas into an asyncio queue), persistence completes if the tab closes.
- Traefik and SSE: v3 auto-flushes `text/event-stream` (ignores `flushInterval`), and the generated dynamic file is fine unchanged. But `websecure` `respondingTimeouts.writeTimeout` caps the whole response: it was `30s` here (cut admitly.io chat streams during GPU cold starts) and was `660s` for a few hours on 2026-11-01 and is now `300s` (fits observed cold starts of 166-238 s; the app's client recovers from longer ones, and it halves how long a slow-reading client can hold a connection). `serversTransport.forwardingTimeouts.responseHeaderTimeout` defaults to `0`.
- `--oauth` covers the API too; if the backend does its own auth, add `--oauth-public=/api/`.
- `deprovision-site.sh` removes the three artifacts by filename only; `docker compose down` + `rm -rf` the backend stack separately.

### Request flow
Client → Traefik :443 (TLS, `Host()` from `dynamic/<fqdn>.yml`) → `edge` → `nginx-backend` → nginx `server_name` in `conf.d/<fqdn>.conf` → `/var/www/<fqdn>/` or proxied backend. nginx `set_real_ip_from` trusts `172.16.0.0/12`, `10.0.0.0/8`, `192.168.0.0/16`. :80 redirects to `websecure`. TLS 1.2+, explicit cipher list.

## Repository posture
Public **github.com/crxnit/traefik-nginx-portal**, ruleset on `main`:
- **Signed commits required.** Repo-local `.git/config`: `gpg.format = ssh`, `user.signingkey = ~/.ssh/id_rsa.pub`, `commit.gpgsign = true`. Key must be registered as an **SSH signing key** (not just auth) on the pusher's account, and author email verified there. Unsigned → rejected.
- Non-admins: PR only, linear history, signed, review, CODEOWNERS approval. Admin `@crxnit` bypasses: direct `git push origin main` or `gh pr merge <n> --admin --squash --delete-branch`. Trivial fixes → direct signed push; substantive → PR.
- CI (`.github/workflows/ci.yml`, every push + PR): `bash -n` on ubuntu-latest AND macos-latest (bash 3.2), `shellcheck --severity=warning`, `gitleaks git` over full history. Globs `bin/*.sh` + `install.sh`. Intentional `# shellcheck disable=SC2086` on `$spa_flag` and `$DC_CMD` in install phase 4 (word-splitting required).
- Pre-commit (`.pre-commit-config.yaml`): gitleaks, shellcheck, trailing-whitespace, EOF newline, YAML parse, shebang consistency. Per clone: `pip install pre-commit && pre-commit install`.
- Dependabot weekly: Actions (all bumps), Docker pins (minor/patch only; majors manual).
- Rejected: `:latest`/unpinned images, unsigned commits, bash-4-only constructs (`${var,,}`), new secrets.

## Common commands
`portal` wrapper (`/usr/local/bin/portal` → `$INSTALL_DIR/bin/portal`) runs `bin/<cmd>.sh` as the service user via `sudo -iu $PORTAL_USER`, so every write is owned by `portal` (clean audit; removing an admin from sudoers = offboarding). Use it in prod; `./bin/*.sh` direct is for local/dev.
```bash
portal                                     # interactive menu
portal menu --cheatsheet                   # CLI reference
portal provision-site <fqdn> [--spa]
portal deprovision-site <fqdn> [--yes]
portal list-sites [--probe] [--drift-only]
portal verify-networks
portal bootstrap
portal reload-nginx                        # test + graceful reload

systemctl status  portal-nginx portal-traefik
systemctl restart portal-traefik           # Requires= brings nginx up too
systemctl stop    portal-traefik portal-nginx
journalctl -u portal-traefik -f
tail -f /srv/portal/logs/traefik/access.log # file since 2026-10-14; 30 days, logrotate/traefik-access

./bin/list-sites.sh [--probe [--probe-host X]] [--drift-only] [--format json]
./bin/provision-site.sh <fqdn> [--spa] [--no-reload] [--traefik-dir DIR]
./bin/deprovision-site.sh <fqdn> [--dry-run] [--yes] [--keep-content]
# also: menu.sh [--cheatsheet], bootstrap.sh, verify-networks.sh, reload-nginx.sh

TRAEFIK_DYNAMIC_DIR=/opt/traefik/dynamic ./bin/provision-site.sh ...
NGINX_CONTAINER=staging-nginx TRAEFIK_CONTAINER=staging-traefik ./bin/verify-networks.sh
```

## Server installer
`install.sh` / `teardown.sh` headers document phases, steps and flags — read them. `install.sh` (fresh host; distinct from `bin/bootstrap.sh`, which re-runs host setup on an existing clone): preflight (existing-install guard + :80/:443 scan via `ss`→`netstat`→`lsof`) → deps → prompts → confirm → clone, patch ACME email, create user, chown, systemd units, wrapper, bootstrap as portal, `enable --now`, optional first site → verify → final log. Essentials:
- Fresh install (default, every prod install): `curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh | bash`. Self-elevates via `sudo -E`; interactive. Exits 0 with no changes if an existing install is found; exits 1 if anything listens on :80/:443. Log: `/var/log/portal-install-TIMESTAMP.log` (falls back to `$HOME/`), syslog tag `portal-install`. Service user `portal` (override `PORTAL_USER=`). No systemd → falls back to `docker compose up -d` with a warning.
- Flags don't forward through curl-pipe (`bash -s --`) → download first: `curl -fsSL .../install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh --restore-acme /var/backups/portal-acme-<ts>.json`.
- `teardown.sh` is the inverse (typed install-dir confirmation, idempotent, refuses system paths/`root`). One-liner by default; download first for `--backup-acme[=PATH]`.
- **LE limit: 5 duplicate certs per exact hostname set per week.** For teardown/install iteration use `teardown.sh --backup-acme` → `install.sh --restore-acme PATH` (restored between bootstrap and `enable --now`, so ACME isn't hit). It carries the LE account key — don't cross backups between ACME-email configs. Fresh prod installs: one-liner, clean issuance.
- **install.sh / teardown.sh don't source `_lib.sh`** (repo may not exist yet / anymore). Only `log_info`, `log_warn`, `log_error`, `log_step`. **No `log_ok`/`log_skip`** — they pass `bash -n` + shellcheck but fail at runtime `command not found`, which `set -e` turns into a mid-phase crash. Use `log_info "Wrote …"` instead.
- **Curl-pipeable interactive scripts must reopen stdin from `/dev/tty`** before the first `read` (piped stdin survives `sudo -E bash "$tmp"` broken, so prompts silently get empty input). Copy `ensure_tty_stdin` (`[ -t 0 ] && return 0; exec < /dev/tty`) from install.sh/teardown.sh; don't improvise.

## Conventions
- `list-sites.sh` skips `00-default.conf` / `default.conf`, `sites/default/`, and `_`-prefixed dynamic files.
- Router names = FQDN with `.` → `-` (`app.example.com` → `app-example-com`). Theoretical collision `a-b.com` vs `a.b-com`; never bitten.
- Container names default `nginx`/`traefik`; scripts honor `NGINX_CONTAINER` / `TRAEFIK_CONTAINER`.
- Provision is one-shot: refuses to overwrite any of the three artifacts. Deprovision requires typing the FQDN unless `--yes`. Deliberate — `IDEMPOTENCY_AUDIT.md` Q1.
- Generated files carry no timestamps/run metadata (byte-identical re-renders).
- Keep `00-default.conf` (`server_name _` catchall) — the nginx healthcheck depends on it.
- **`.env`** (install root, gitignored, 600, owned by portal) is the single source for `COMPOSE_PROFILES`, OAuth and Route53 creds. `install.sh` writes it; edit in place + `systemctl restart portal-traefik`. **No `.env.example`** — schema lives here and in `install.sh` `phase4_write_env_file`. Route53 vars `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, optional `AWS_HOSTED_ZONE_ID` stay blank unless a site uses `letsencrypt-dns`. IAM: `route53:GetChange` (all) + `route53:ChangeResourceRecordSets` / `route53:ListResourceRecordSets` on the zone (+ `route53:ListHostedZonesByName` if `AWS_HOSTED_ZONE_ID` unset).

## Known limitations
- HTTP-01 `letsencrypt` (needs :80 reachable) is the default; `letsencrypt-dns` only via explicit `tls.certResolver` + `tls.domains`.
- Per-site nginx logs not persisted (Docker logging driver only).
- Default TLS cert is self-signed → unknown hostnames get a browser warning before Traefik's 404. Intended; for a CA-signed default, dump an LE cert from `acme.json` via a sidecar and point `_default-tls.yml` at it.

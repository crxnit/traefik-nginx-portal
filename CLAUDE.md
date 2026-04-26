# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Provisioning scripts and configuration for a two-container web-hosting stack: **Traefik** (TLS termination + routing) in front of **nginx** (serving static sites). One Traefik instance fronts many nginx-hosted sites; each site is provisioned/deprovisioned via shell scripts that write three coordinated artifacts.

The repo root IS the portal root — `bin/`, `nginx/`, `traefik/`, and `docker-compose.yml` all sit at the top level. The scripts resolve their own directory at runtime (`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`), so the portal works at any checkout location: `/srv/portal/`, `/srv/ai/`, `/opt/portal/`, etc. Docker Compose volume mounts are relative (`./traefik/...`), so they follow the repo wherever it sits. Paths like `/srv/portal/` in examples throughout this doc are conventional — substitute your actual path. `$PORTAL_DIR` in prose means "wherever the portal is checked out" and equals `$REPO_ROOT`.

## Architecture

Two independent compose stacks that meet on shared Docker networks:

- `docker-compose.yml` — Traefik (`traefik:v3.3.4`, patch-pinned) on networks `traefik` + `edge`, ports 80/443, plus an internal `:8082/ping` entrypoint for the container healthcheck. Reads static config from `traefik/traefik.yml` and watches `traefik/dynamic/` for per-site router files. Let's Encrypt HTTP-01 challenge; certs persist in `traefik/acme.json` (bind mount; writable even with `read_only: true`).
- `nginx/docker-compose.yml` — `nginx:1.27-alpine` (minor-line pinned) on the `edge` network only (no host ports — Traefik reaches it over `edge`). Hardened: `read_only` root FS, `cap_drop ALL`, `no-new-privileges`, tmpfs for `/var/cache/nginx`, `/var/run`, `/tmp`. Healthcheck hits `http://127.0.0.1/` (handled by the `00-default.conf` catchall).

**nginx logging under `read_only`:** there is no writable path for `/var/log/nginx/` inside the container. `nginx.conf` writes `access_log /var/log/nginx/access.log` / `error_log /var/log/nginx/error.log`, which works because the `nginx:alpine` image ships those paths as symlinks to `/dev/stdout` / `/dev/stderr`. Do NOT introduce any other `access_log`/`error_log` paths in `conf.d/*.conf` — new filenames have no symlink, and nginx will fail to start trying to create them in a read-only dir. If per-site on-disk logs are ever wanted, add `./logs:/var/log/nginx` as a bind mount *and* drop `read_only: true`.

Both networks (`traefik`, `edge`) are declared `external: true` and must exist before either stack starts. Run `bin/bootstrap.sh` once per host — it chains `create-docker-networks.sh`, the `acme.json` preflight (touch + chmod 600), and `ensure-default-tls.sh` in the correct order, and is safe to re-run. Verify wiring with `bin/verify-networks.sh` (expects `traefik → edge,traefik` and `nginx → edge`).

**Lifecycle ownership (split).** On a production install, both compose stacks are managed by systemd via `systemd/portal-nginx.service` and `systemd/portal-traefik.service` (templates in the repo, installed to `/etc/systemd/system/` by `install.sh`). Each unit is `Type=oneshot` + `RemainAfterExit=yes`, runs `ExecStart=docker compose up -d` as the `portal` service user, and is `enable`d to come up on boot. `portal-traefik.service` has `Requires=portal-nginx.service` so the backend is up before the edge tries to route. **systemd owns start/stop/boot; Docker's `restart: unless-stopped` policy owns in-run crash recovery.** The two don't fight: `systemctl stop` invokes `docker compose down`, which is an explicit stop that `unless-stopped` respects, so Docker won't auto-resurrect a service the admin just stopped.

`acme.json` is not committed — `bootstrap.sh` creates it with mode 600 on demand. Without the preflight, `docker compose up` silently auto-creates the bind-mount path as a root-owned directory, which breaks Traefik permanently; `bootstrap.sh` is how you avoid that class of failure.

### Permissions model (hardened-host defenses)

Two umask layers keep the installer and provisioning scripts correct on hardened hosts where the root / portal login umask is 007 or 027 (common when `/etc/login.defs` sets `UMASK 007`):

- `install.sh` sets `umask 022` at the top, and runs `chmod -R u=rwX,go=rX` on the install dir after chowning to the portal user. Covers the git clone and anything created in phase 4 before bootstrap hands off to the portal user.
- `bin/_lib.sh` sets `umask 022` too — it's sourced by every `bin/` script, so `bootstrap.sh` / `ensure-default-tls.sh` / `provision-site.sh` all produce 644 files and 755 dirs regardless of the portal user's login-shell umask. Edit the umask in `_lib.sh`, not in individual scripts.

Without both layers, bind-mounted configs end up 600/700 on the host (unreadable from inside the containers), and per-site content ends up 660/770 (unreadable by nginx workers). The two container-side failure modes are subtly different:

- **Traefik**: runs as root inside the container, but `cap_drop: ALL` strips `DAC_OVERRIDE` from the cap bounding set — so root loses its usual "ignore file modes" superpower and becomes subject to normal DAC. The compose file therefore explicitly `cap_add: DAC_OVERRIDE` back, which *does* apply to root. Without it, Traefik crash-loops on `open /etc/traefik/traefik.yml: permission denied` before the healthcheck can even run.
- **nginx**: master runs as root (benefits from `cap_add: DAC_OVERRIDE`), but workers `setuid` to the `nginx` user and **lose all effective capabilities** in the process — caps don't survive setuid without ambient caps or file caps, and we don't set either. Workers do the actual file I/O, so per-site content must be world-readable (644/755) for them to serve it. `cap_add: DAC_OVERRIDE` on the nginx compose is effectively a no-op for this — the umask defense is what makes it work.

Secret files (`acme.json` mode 600, `traefik/certs/default.key` mode 600, `traefik/certs/` dir mode 700) chmod explicitly after creation, so `umask 022` doesn't weaken them. Traefik still reads them because it has `DAC_OVERRIDE` as root; the portal user can read them because it's the owner.

### The three-files-per-site invariant

A provisioned site has three coordinated artifacts that `list-sites.sh` treats as the sources of truth:

1. `nginx/conf.d/<fqdn>.conf` — nginx server block (listens on :80 inside the edge network, `server_name <fqdn>`, roots at `/var/www/<fqdn>`). Logs fall through to stdout/stderr via `nginx.conf`'s global `access_log`/`error_log` — no per-site log files.
2. `nginx/sites/<fqdn>/` — content directory (placeholder `index.html` created at provision time).
3. `traefik/dynamic/<fqdn>.yml` — Traefik dynamic router: `Host(\`<fqdn>\`)` on `websecure` → service `nginx-backend`, middlewares `security-headers@file` + `rate-limit@file`, TLS via `letsencrypt` resolver. When provisioned with `--oauth`, the middleware chain also includes `oauth-google-forward-auth@file`; when combined with `--oauth-public=<prefixes>`, this file contains *two* routers (public + protected) rather than one — see "OAuth protection" below.

If any one of these is missing, `list-sites.sh` reports **drift**. The provision and deprovision scripts always act on all three together. `provision-site.sh` has an `EXIT` trap that rolls back any artifacts it created if `nginx -t` or another step fails partway — the refuse-to-overwrite guard protects against re-provisioning but cleanup happens automatically on failure. Note: the rollback is safe to `rm -rf` the site dir *only because* the guard prevents re-running over a populated site; if the guard is ever relaxed, the rollback must also be tightened (see `IDEMPOTENCY_AUDIT.md` finding L1).

### Shared script helpers

`bin/_lib.sh` is sourced by every other script in `bin/`. It provides the shared vocabulary so scripts stay terse and consistent. Intentionally has no shebang — it's a library, sourced not invoked; uses a `# shellcheck shell=bash` directive instead so shellcheck still knows the dialect. Exports `$PORTAL_DIR` (the absolute path of the portal root, computed at source time); callers use `$PORTAL_DIR` for non-script paths (`nginx/`, `traefik/`, compose files, `logs/`, the lock file) and `$SCRIPT_DIR` for invoking sibling scripts.

**Colors (TTY-aware; empty strings when output is piped):** `GREEN`, `YELLOW`, `RED`, `BLUE`, `BOLD`, `DIM`, `RESET`.

**Log helpers** (prepend a bracketed tag, route to stdout or stderr):
- `log_info`, `log_ok`, `log_warn`, `log_error`, `log_skip`, `die` — used everywhere.
- Scripts that need specialized tags define them locally (e.g. `log_step` in bootstrap, `log_dry` in deprovision).

**Functions:**
- `validate_fqdn <fqdn>` — single source of truth for the FQDN regex. Also rejects `..` and `/` even though the regex already excludes them (defense-in-depth since the FQDN is later used in `rm -rf` paths). Edit here, not in callers.
- `acquire_portal_lock <dir>` — `flock`-based mutex so two concurrent provision/deprovision invocations don't race. Silent no-op if `flock` isn't installed (macOS dev hosts).
- `write_atomic <target>` — reads stdin, writes to a temp file on the same filesystem, renames atomically. Prevents half-written files if the process is SIGKILL'd or the host loses power. Respects umask. Use for any generated config/content file; for mode-sensitive outputs (keys, etc.) follow the explicit mktemp-chmod-mv pattern like `ensure-default-tls.sh` does for the openssl key/cert pair.
- `nginx_reload [container]` — test-and-graceful-reload the running nginx. Skips with a warning if the container isn't running. Returns non-zero only on config-test or reload failure. Used by `provision-site.sh`, `deprovision-site.sh`, and `bin/reload-nginx.sh` — three callers, one implementation. Callers supply their own contextual error messages after a non-zero return.

### Shared Traefik dynamic files

Underscore-prefixed YAML files in `traefik/dynamic/` are shared config, skipped by `list-sites.sh` FQDN discovery:

- `_shared-services.yml` — defines the `nginx-backend` service that every generated router references. Points at `http://nginx:80` on the `edge` network. Without this file, every per-site router returns 503.
- `_middlewares.yml` — defines the `security-headers` and `rate-limit` middlewares that generated routers attach by default.
- `_default-tls.yml` — points `tls.stores.default` at a self-signed cert so unknown-SNI requests get our own cert instead of Traefik's built-in one. Generated by `ensure-default-tls.sh`; the cert + key live in `traefik/certs/` (gitignored).
- `_oauth.yml` — defines the `oauth-google-forward-auth` `forwardAuth` middleware that per-site routers attach when they opt into OAuth. Points at the `traefik-forward-auth-google` sidecar over the `traefik` network.

### OAuth protection

Sites can be protected behind Google Workspace sign-in (or, by reconfiguring the same sidecar, any OIDC-compliant provider). **One shared sidecar protects N sites** — `traefik-forward-auth-google` in the top-level `docker-compose.yml` is stateless (JWT-cookie based) and decoupled from specific FQDNs.

**Opt-in, not opt-out.** Existing sites stay public. A site opts in via `provision-site.sh --oauth` (or the menu prompt), which attaches `oauth-google-forward-auth@file` to the site's middleware chain. Removing the flag and re-provisioning reverts to public.

**Sidecar lifecycle.** The sidecar is guarded by `profiles: [oauth]` in compose, so it only starts when `.env` sets `COMPOSE_PROFILES=oauth`. Operators who don't need OAuth get zero runtime overhead — the service is defined but inert. `install.sh` writes `.env` at mode 600 owned by portal, populated either with real OAuth values (if the operator opts in during install) or empty ones; enabling later is "edit `.env`, `systemctl restart portal-traefik`".

**Config layout in .env.** `OAUTH_PROVIDERS_GOOGLE_CLIENT_ID` + `OAUTH_PROVIDERS_GOOGLE_CLIENT_SECRET` come from the Google Cloud Console. `OAUTH_SECRET` is a 32-byte random cookie-signing key generated by `install.sh` (`openssl rand -base64 32`). `OAUTH_DOMAIN` is a comma-separated list of allowed email domains (e.g. `jjocllc.com,partner.com`). A single Google OAuth client serves all protected sites on this portal; per-site credentials are not supported (and not needed — the domain whitelist handles access control).

**Per-site redirect URI.** Each protected site needs `https://<fqdn>/_oauth` registered in the Google Cloud Console OAuth client. `provision-site.sh --oauth` prints the exact URI to add as part of its "next steps" output.

**Per-path opt-outs.** `--oauth-public=/healthz,/webhooks/` (comma-separated `PathPrefix` values) generates a **dual-router YAML**: a high-priority (`priority: 100`) public router matching the exempt prefixes with no OAuth middleware, and a low-priority (`priority: 10`) catchall with the full middleware chain. Priorities are explicit so precedence doesn't depend on Traefik's rule-length tiebreak. Path validation rejects non-`/`-prefixed entries and anything containing backticks (which would break out of the quoted Traefik rule).

**ACME challenge path is safe.** LE HTTP-01 hits `http://<fqdn>/.well-known/acme-challenge/*` on the `web` (:80) entrypoint, which Traefik intercepts internally *before* any router runs. Auth never sees it. No extra configuration needed.

**Adding a second provider later.** Naming is specific (`traefik-forward-auth-google`, `oauth-google-forward-auth@file`) rather than generic, so a second provider (e.g. Microsoft Entra ID, Okta) lands as a copy-paste-rename: new sidecar service, new `_oauth-<provider>.yml`, new middleware name. Sites pick which middleware to attach at provision time.

**What's NOT supported.** Provider chaining on a single site ("sign in with Google OR Microsoft") — traefik-forward-auth is one-provider-per-instance. Workflows that need that are Authelia/Dex/Keycloak territory.

### Wildcard certs (per-tenant subdomains)

Sites can opt into a wildcard cert (`*.example.com`) via the **`letsencrypt-dns` ACME resolver** — Route53 DNS-01, defined alongside the default `letsencrypt` HTTP-01 in `traefik.yml`. First case is `admitly.io`, which mints `<user>.admitly.io` on signup and needs a cert that already covers any subdomain a future signup might create.

**Why DNS-01 not HTTP-01.** HTTP-01 can't issue wildcard certs — Let's Encrypt requires DNS-01 for `*.example.com`. Per-subdomain on-demand HTTP-01 issuance is a non-starter for signup-driven products: LE caps duplicate-cert issuance at 50 per registered domain per week, which a popular launch would burn through in hours.

**Per-site opt-in** in the dynamic YAML — three things to get right:

1. **Router rule** matches both apex and any one-label subdomain (note the escaped `\\.` — YAML string + Traefik regex layers both need it):
   ```yaml
   rule: "Host(`example.com`) || HostRegexp(`^[a-z0-9-]+\\.example\\.com$`)"
   ```

2. **`tls.certResolver: letsencrypt-dns`** — opts this site into DNS-01. Without it, Traefik falls back to the first defined resolver (HTTP-01) and fails with `acme: could not determine solvers` on the wildcard.

3. **`tls.domains` MUST include apex as `main` AND wildcard as a SAN.** Wildcard certs in TLS don't cover the parent — `*.example.com` matches `foo.example.com` but not bare `example.com`. Common mistake: only listing `*.example.com` in `main` produces a cert that doesn't cover the apex (apex falls back to a stale HTTP-01 cert from a prior deployment, or to the self-signed default).
   ```yaml
   tls:
     certResolver: letsencrypt-dns
     domains:
       - main: example.com
         sans:
           - "*.example.com"
   ```

**nginx side** — `server_name example.com *.example.com;` in the conf.d block. The app backend reads the `Host` header (or `X-Forwarded-Host`) to dispatch by tenant.

**AWS provisioning.** `bin/iam-route53-setup.sh --domain example.com` (run from an operator workstation, NOT prod — it uses your local admin AWS creds to mint narrow-scope creds for prod) creates a least-privilege IAM user, attaches an inline policy scoped to the relevant Route53 hosted zone, mints an access key, and emits a mode-600 `.env` snippet for transport to prod. Idempotent; pass `--rotate-key` to replace an existing key.

**Static config = restart, dynamic = reload.** `traefik.yml` (where the resolvers are defined) is the **static** config — read only at process startup. The `dynamic/` directory is hot-reloaded, but adding a new resolver requires `systemctl restart portal-traefik`. A dynamic YAML referencing a resolver that isn't yet in the running static config errors with `Router uses a nonexistent certificate resolver` — that means the YAML pull made it to prod but Traefik wasn't restarted.

**Stale `acme.json` certs during iteration.** If you change `tls.domains` after a cert was already issued (e.g. forgot the apex SAN the first time), Traefik may not re-issue — it checks whether existing certs cover the requested domains and can keep serving the old one. Surgical fix: `jq` out the bad entry from `letsencrypt-dns.Certificates`, back up `acme.json` first (typo = lose all certs), restart Traefik, hit the site to trigger re-issuance.

**Adding a second DNS provider later.** Naming is specific (`letsencrypt-dns` rather than generic `wildcard`), so a second provider (Cloudflare, DigitalOcean, etc.) lands as a third resolver entry in `traefik.yml` — copy-paste-rename, swap `dnsChallenge.provider` + the env vars in `docker-compose.yml`. Sites pick which resolver to opt into per dynamic file.

### App backends (proxied apps)

The portal originally hosted static sites only. It also supports **path-split sites** that serve static content at `/` and reverse-proxy a path prefix (e.g. `/api/`) to a backend container — first example is `admitly.io` (MPA frontend + FastAPI backend that streams vLLM SSE deltas to the browser).

**Backend stacks live at `/srv/portal-apps/<name>/`** — sibling to the portal repo, *not* inside it. Each app is its own `docker-compose.yml` with `container_name: <name>-backend` (so nginx can resolve it by service name), joined to the `external: true` `edge` network, with whatever volumes/env/healthcheck the app needs. The portal owns the routing edge; the app stack owns its own lifecycle. Mirror the `portal-traefik.service` pattern with a `portal-app-<name>.service` if you want it to boot with the host.

**The nginx config is hand-edited after `portal provision-site`.** The provision script generates a static-only server block; for a proxied app you add a `location ^~ /api/ { proxy_pass http://<name>-backend:PORT; ... }` block before the static-asset regex. The `^~` prefix is critical — without it, a request to `/api/foo.js` (or any path ending in a static-asset extension) gets captured by the cache regex and 404s, because nginx normally lets regex matches override prefix matches. We considered adding `--backend HOST:PORT` flags to `provision-site.sh` and declined; the hand-edit pattern is fine until a second or third proxied app emerges and a real shape becomes obvious.

**SSE-critical nginx settings** for any backend that streams (LLM responses, log tails, progress events):

- `proxy_buffering off` — without it, clients see nothing until generation completes, then the whole response in one burst. #1 SSE footgun and the silent-breakage everyone hits first.
- `proxy_read_timeout 1h` / `proxy_send_timeout 1h` — defaults are 60s, which truncate any long generation mid-stream.
- `proxy_http_version 1.1` + `proxy_set_header Connection ""` — required for upstream keepalive (paired with an `upstream { ... keepalive 32; }` block).
- `proxy_ignore_client_abort on` — when paired with a backend that has a detached upstream pump (admitly.io's FastAPI tees vLLM deltas into an asyncio queue and persists regardless of client state), persistence completes even if the client tab closes mid-stream. Belt-and-suspenders with the app's own design.

**Traefik needs no changes for SSE.** Traefik 3 auto-detects `Content-Type: text/event-stream` and flushes writes to the client immediately, ignoring its `flushInterval` setting. Default `entryPoints.websecure.transport.respondingTimeouts.writeTimeout` of `0` means no write limit, and `serversTransport.forwardingTimeouts.responseHeaderTimeout` defaults to `0` too. The path-split happens entirely at the nginx layer; Traefik just routes by Host. The dynamic file `portal provision-site` generates is the right file unchanged.

**OAuth interaction.** `--oauth` covers the whole site, API included. If the backend wants to do its own auth (bearer tokens, signed webhooks, etc.), pair with `--oauth-public=/api/` so the API path bypasses the forward-auth middleware.

**Deprovision is unchanged.** `deprovision-site.sh` removes the three artifacts by filename — it doesn't parse contents and doesn't know the nginx config has a proxy block. The backend stack at `/srv/portal-apps/<name>/` is an operator concern: `docker compose down` and `rm -rf` separately if you want it fully gone.

### Request flow

Client → Traefik :443 (terminates TLS, matches `Host()` rule from a `dynamic/<fqdn>.yml`) → routes over the `edge` network to the `nginx-backend` service (defined in `_shared-services.yml`) → nginx matches `server_name` in `conf.d/<fqdn>.conf` → serves from `/var/www/<fqdn>/`, *or* (for proxied-app sites) reverse-proxies a path prefix to a backend container on the `edge` network — see "App backends (proxied apps)" above. nginx trusts `X-Forwarded-For` from `172.16.0.0/12`, `10.0.0.0/8`, and `192.168.0.0/16` (all RFC1918 Docker ranges) via `set_real_ip_from`.

Plain HTTP (:80) is configured to redirect everything to `websecure`. TLS options pin TLS 1.2+ and an explicit cipher suite list.

## Repository posture

Public repo at **github.com/crxnit/traefik-nginx-portal**, protected by a ruleset scoped to `main`:

- **Signed commits required.** SSH signing config lives in `.git/config` (repo-local: `gpg.format = ssh`, `user.signingkey = ~/.ssh/id_rsa.pub`, `commit.gpgsign = true`). Pushing requires the signing key registered as an **SSH signing key** (not just auth) on the pusher's GitHub account, **and** the commit's author email verified on that same account. Unsigned commits are rejected at the server.
- **Main branch is ruleset-protected.** Default flow for non-admins: PR only, with linear history, signed commits, PR review, and CODEOWNERS approval. Admin `@crxnit` is on the ruleset bypass list, so both direct `git push origin main` and `gh pr merge <n> --admin --squash --delete-branch` work for the maintainer. Trivial fixes that don't need review typically land via direct push on a signed commit; anything substantive still goes through a PR so there's a reviewable diff in the GitHub UI. CI runs on every push either way.
- **CI must be green.** `.github/workflows/ci.yml` runs on every push + PR: `bash -n` on ubuntu-latest AND macos-latest (bash 3.2 compat check), `shellcheck --severity=warning`, and `gitleaks git` over full history.
- **Pre-commit hooks fire on `git commit`.** `.pre-commit-config.yaml`: gitleaks, shellcheck, trailing-whitespace, EOF newline, YAML parse, shebang consistency. Install per clone: `pip install pre-commit && pre-commit install`.
- **Dependabot opens weekly PRs** for GitHub Actions versions and Docker image pins. Minor/patch only for images (major bumps left manual); all bumps welcomed for Actions.

Things that will be rejected: `:latest` or unpinned images, unsigned commits, bash-4-only constructs like `${var,,}` (caught by macOS bash-3.2 syntax CI), new secrets in commits (caught by gitleaks).

## Common commands

On an install.sh-provisioned host, admins use the `portal` wrapper — it runs each bin/ subcommand as the `portal` service user via `sudo -iu`, so every file written ends up owned by `portal` regardless of which admin triggered the action. Below, `portal <cmd>` and `./bin/<cmd>.sh` are equivalent modulo the identity. Use the wrapper form in prod; the direct form is for local/dev work where the calling user already owns the install dir.

```bash
# Wrapper — prod path, runs as service user. Installed at /usr/local/bin/portal
# by install.sh, symlinking into $INSTALL_DIR/bin/portal.
portal                                     # interactive menu (default)
portal menu --cheatsheet                   # non-interactive CLI reference
portal provision-site <fqdn> [--spa]       # add a site
portal deprovision-site <fqdn> [--yes]     # remove a site
portal list-sites [--probe] [--drift-only] # state / reachability
portal verify-networks                     # container/network wiring check
portal bootstrap                           # re-run one-shot host setup
portal reload-nginx                        # test + graceful reload

# Lifecycle (systemd is the authority on an install.sh-provisioned host)
systemctl status  portal-nginx portal-traefik
systemctl restart portal-traefik           # nginx has Requires= so starting traefik starts nginx
systemctl stop    portal-traefik portal-nginx
journalctl -u portal-traefik -f            # live logs (compose logs still work too)

# Direct-invocation forms — used locally or when developing bin/ scripts.
./bin/menu.sh
./bin/menu.sh --cheatsheet
./bin/bootstrap.sh
./bin/verify-networks.sh
./bin/list-sites.sh [--probe [--probe-host X]] [--drift-only] [--format json]
./bin/provision-site.sh <fqdn> [--spa] [--no-reload] [--traefik-dir DIR]
./bin/deprovision-site.sh <fqdn> [--dry-run] [--yes] [--keep-content]
./bin/reload-nginx.sh

# Workstation-only — sets up the AWS IAM user + Route53 policy + access
# key for the letsencrypt-dns resolver. Runs against your local AWS CLI
# credentials (admin-level), produces narrow-scope creds for prod's .env.
# Do NOT run via the `portal` wrapper — see script header.
./bin/iam-route53-setup.sh --domain <fqdn> [--user NAME] [--rotate-key]

# Override knobs
TRAEFIK_DYNAMIC_DIR=/opt/traefik/dynamic ./bin/provision-site.sh ...
NGINX_CONTAINER=staging-nginx TRAEFIK_CONTAINER=staging-traefik ./bin/verify-networks.sh
```

No build, no tests, no linter — this is purely shell + config.

## Server installer

`install.sh` at the repo root is a single downloadable script for initial host setup. Distinct from `bin/bootstrap.sh` (which re-runs one-shot host setup on an already-cloned repo), `install.sh` clones the repo, patches the ACME email, creates the service user, chowns the install dir, installs systemd units, runs `bootstrap.sh` as the service user, enables + starts both stacks via systemctl, and optionally provisions a first site — all from an interactive prompt flow. Intended use: `curl ... | bash` on a fresh Linux server.

```bash
# Fresh server — one-liner is the default path. No flags, interactive
# prompts drive the rest. Use this for every production install.
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh | bash

# Flag-case only (e.g. --restore-acme to preserve certs across a reinstall).
# `bash -s -- --flag VALUE` doesn't cleanly forward through curl-pipe, so
# download first when args are needed:
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh --restore-acme /var/backups/portal-acme-<ts>.json
```

Structure: 7 phases (preflight, dependency checks, prompts, confirm, install, verify, cleanup + final log). Writes a full session log to `/var/log/portal-install-TIMESTAMP.log` (falls back to `$HOME/` if unwritable) and emits syslog entries via `logger -t portal-install` at each phase. Exits 0 without changes if an existing installation is detected. When curl-piped, reopens stdin from `/dev/tty` so prompts still work.

**Phase 0 is two checks, not one.** (1) Existing-install guard: a narrow scan for prior copies of *this* portal (by container/network name and install-dir layout) — exits 0 (benign) if found, since re-running on an already-installed host is usually a mistake not a failure. (2) Port scan: any listener on :80 or :443 (via `ss` → `netstat` → `lsof` fallbacks) exits 1 (error) with a concrete stop-this-service hint. The second check catches webservers/proxies the first one misses — a host-level nginx/Caddy/Apache or a Traefik under a different name.

**Self-elevate + hardened-host defenses.** `install.sh` reads its own file (or re-downloads to `/tmp` when curl-piped) and re-execs under `sudo -E`, so `curl ... | bash` works for any sudo-capable operator. Sets `umask 022` at the top and runs `chmod -R u=rwX,go=rX` on `$INSTALL_DIR` after the chown in phase 4 — both exist because hardened hosts default root's `UMASK` to 007/027 in `/etc/login.defs`, which would otherwise leave `git clone`'d configs at mode 600 (unreadable by the in-container Traefik once `cap_drop: ALL` removes `DAC_OVERRIDE`). See the **Permissions model** section under Architecture for the full failure chain.

**Service-user + systemd model.** install.sh creates a system user (`portal` by default, override via `PORTAL_USER=...`), adds it to the `docker` group, and chowns `$INSTALL_DIR` to it. All subsequent operator actions run as that user — never as the invoking admin. Two systemd units (`portal-nginx.service`, `portal-traefik.service`, templated from `systemd/*.service` in the repo) handle start/stop/boot: enabled at install time so the portal comes back up on reboot. Docker's own `restart: unless-stopped` handles in-run crash recovery (container OOM, traefik panic, etc.) — that's a distinct concern from "service should start on boot" and systemd doesn't monitor containers after `ExecStart` returns. See the **Lifecycle ownership (split)** note in the Architecture section for the interaction details. If systemd isn't detected (edge case: Alpine containers, chroots), install.sh falls back to plain `docker compose up -d` with a warning.

**Operator wrapper.** A `bin/portal` script in the repo, symlinked to `/usr/local/bin/portal` at install time, runs any `bin/<cmd>.sh` as the service user via `sudo -iu $PORTAL_USER`. Admins type `portal menu`, `portal provision-site <fqdn>`, `portal verify-networks`, etc. — short commands map to the full script names. This keeps audit trails clean (every write is owned by `portal`, regardless of which admin triggered it) and means removing an admin from `sudoers` is sufficient offboarding.

**CI coverage.** `.github/workflows/ci.yml` globs `bin/*.sh` + `install.sh` for both `bash -n` and shellcheck. Keep new/edited scripts bash-3.2-compatible (macOS bash-3.2 runs the syntax check) and shellcheck-clean. The intentional `# shellcheck disable=SC2086` comments are on `$spa_flag` and `$DC_CMD` in phase 4 where word-splitting is required.

**Teardown.** `teardown.sh` at repo root is the paired inverse of `install.sh`. Same self-elevate + curl-pipe pattern, same safety rails (blacklists system paths, refuses to remove `root`), typed-confirmation guard (operator must type the install-dir path), idempotent across partial-install states. Removes: systemd units → containers → networks → wrapper symlink → install dir → service user → install logs. Default teardown is the one-liner `curl -fsSL .../teardown.sh | bash`; download-first (same pattern as `install.sh`) is only needed when passing flags like `--backup-acme=PATH`. `install.sh`'s partial-install-failure hint points at this script.

**Cert preservation across teardown/install cycles.** Let's Encrypt caps duplicate-cert issuance at **5 per exact hostname set per week** (rolling) — test cycles that re-provision the same FQDN burn through this fast. Workaround: `teardown.sh --backup-acme[=PATH]` copies `acme.json` (timestamped default under `/var/backups/`) before wiping; `install.sh --restore-acme PATH` drops that file back into the new install between the bootstrap step and systemctl's `enable --now`, so Traefik starts with pre-existing certs and doesn't hit ACME at all. Both flags force the download-first invocation (the one-liner curl-pipe can't forward args through `bash -s --`). The account key inside `acme.json` is preserved too, so the restored install stays tied to the same LE account — don't cross backups from different ACME-email configurations. Use this for iteration; fresh production installs stick with the one-liner and let ACME issue clean.

## Conventions

- FQDN validation lives in `_lib.sh::validate_fqdn`: lowercase, at least one dot, DNS-legal, and no path-escape characters. Wildcards and IDN/punycode labels are rejected. Edit the regex there, not in callers.
- Generated files are written via `_lib.sh::write_atomic` (temp file + rename). Don't revert to plain `cat > $TARGET <<EOF` — the atomic path survives SIGKILL / power loss, the direct redirect doesn't.
- `list-sites.sh` skips `00-default.conf` / `default.conf` in `conf.d/`, `sites/default/`, and any `_`-prefixed file in `traefik/dynamic/`.
- Traefik router names are derived from FQDN by replacing `.` with `-` (e.g. `app.example.com` → router `app-example-com`). Theoretical collision: `a-b.com` vs `a.b-com` both map to `a-b-com`. Has never bitten us.
- Container names (`nginx`, `traefik`) are the defaults throughout; every script that `docker exec`s into them honors `NGINX_CONTAINER` / `TRAEFIK_CONTAINER` env overrides for side-by-side deployments.
- Provision script is one-shot by design: it refuses to overwrite any of the three artifacts if they already exist. Deprovision requires typing the FQDN to confirm (unless `--yes`). This is deliberate — see `IDEMPOTENCY_AUDIT.md` Open Question Q1.
- Generated files (`conf.d/<fqdn>.conf`, `dynamic/<fqdn>.yml`) contain no timestamps or run-specific metadata — running the provision template twice produces byte-identical output (if the overwrite guard were removed).
- `00-default.conf` is the catchall `server_name _` that handles unknown Host headers; keep it present — the nginx healthcheck relies on it.
- `.env` at the install root is the single source of truth for `COMPOSE_PROFILES`, OAuth credentials, and Route53 DNS-01 credentials. Gitignored, mode 600, owned by portal. `install.sh` writes it; operators edit in place + `systemctl restart portal-traefik` to apply. Don't commit a `.env.example` either — the schema lives in CLAUDE.md (above) and `install.sh`'s `phase4_write_env_file` comment block, so there's no template to rot. Route53 vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, optional `AWS_HOSTED_ZONE_ID`) stay blank by default; populate only when a site opts into the `letsencrypt-dns` resolver. IAM policy is least-privilege: `route53:GetChange` cluster-wide + `route53:ChangeResourceRecordSets` / `route53:ListResourceRecordSets` scoped to the relevant hosted zone (+ `route53:ListHostedZonesByName` if `AWS_HOSTED_ZONE_ID` is unset).
- **install.sh and teardown.sh don't source `_lib.sh`** — they're standalone bootstrappers that can't assume the repo exists yet (install.sh) or still exists (teardown.sh). Their log vocabulary is narrower: `log_info`, `log_warn`, `log_error`, `log_step` only. **No `log_ok` or `log_skip`** — those live in `_lib.sh` and are only available to `bin/*.sh`. Reaching for them in install.sh/teardown.sh silently passes `bash -n` + `shellcheck` (they're valid function names, just undefined) and only fails at runtime with `command not found` — which `set -e` turns into a mid-phase crash. If you want a "success" tag in install.sh, use `log_info` with explicit phrasing ("Wrote …", "Installed …") and accept the color difference.
- **Interactive scripts that support `curl … | bash` must reopen stdin from `/dev/tty`** before the first `read`. When curl-piped, bash inherits stdin from the (closed) download pipe; the self-elevate via `sudo -E bash "$tmp"` preserves that broken stdin. A `read` there gets empty input and silently fails the prompt. Both `install.sh::ensure_tty_stdin` and `teardown.sh::ensure_tty_stdin` implement the `[ -t 0 ] && return 0; exec < /dev/tty` pattern — copy that into any new bootstrap-style script, don't improvise.
- **App backends live at `/srv/portal-apps/<name>/`** — sibling to the portal repo, never inside it. Each app is its own compose stack joined to the `external: true` `edge` network, with `container_name: <name>-backend` so nginx's upstream block can resolve it by name. The portal owns routing; the app stack owns its own lifecycle (volumes, env, healthcheck, optional `portal-app-<name>.service`). See "App backends (proxied apps)" under Architecture for the nginx hand-edit pattern and SSE-critical settings.
- **Use `systemctl restart`, not `start`, on the portal units.** `portal-nginx.service` and `portal-traefik.service` are both `Type=oneshot` + `RemainAfterExit=yes`, which means systemd reports them as `active (exited)` after `docker compose up -d` returns 0 — and `systemctl start` on an already-active unit is a **no-op**. So `docker compose down && systemctl start portal-traefik` leaves you with no containers running and systemd cheerfully claiming the unit is fine. Always `systemctl restart` (which forces stop+start, re-running ExecStart). Also: don't reach for `compose down` to apply `.env` changes — `systemctl restart portal-traefik` already invokes `docker compose up -d`, which re-substitutes `.env` and recreates containers when their env or config changed.

## Known limitations

- **Two ACME resolvers, HTTP-01 is the default.** `letsencrypt` (HTTP-01, requires :80 reachable from the internet) is what every site gets unless it explicitly opts into `letsencrypt-dns` (Route53 DNS-01) via `tls.certResolver` + `tls.domains` in its dynamic YAML. DNS-01 exists for sites that mint per-tenant subdomains and need wildcard certs (e.g. `*.admitly.io`); requires AWS credentials in `.env` (see schema). Other DNS providers would land as additional resolver entries — Route53 is the only one wired today.
- **Per-site nginx logs are not persisted** — they ride the container's stdout/stderr via Docker's logging driver. Add a `./logs:/var/log/nginx` volume + logrotate if you need on-disk per-site logs.
- **Default TLS cert is self-signed** (via `ensure-default-tls.sh`). Clients hitting unknown hostnames get a browser cert warning before seeing Traefik's 404. This is working-as-intended for a catchall; if you want a real CA-signed default, dump an existing Let's Encrypt cert from `acme.json` via a sidecar and point `_default-tls.yml` at it.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Provisioning scripts and configuration for a two-container web-hosting stack: **Traefik** (TLS termination + routing) in front of **nginx** (serving static sites). One Traefik instance fronts many nginx-hosted sites; each site is provisioned/deprovisioned via shell scripts that write three coordinated artifacts.

All runtime state lives under `srv/portal/` in the repo. The scripts resolve their own directory at runtime (`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`), so the repo works at any checkout location: `/srv/portal/`, `/srv/ai/portal/`, `/opt/portal/`, etc. Docker Compose volume mounts are relative (`./traefik/...`), so they follow automatically. Paths like `/srv/portal/` in examples throughout this doc are conventional — substitute your actual path. `$PORTAL_DIR` in prose means "wherever the portal is checked out".

## Architecture

Two independent compose stacks that meet on shared Docker networks:

- `srv/portal/docker-compose.yml` — Traefik (`traefik:v3.3.4`, patch-pinned) on networks `traefik` + `edge`, ports 80/443, plus an internal `:8082/ping` entrypoint for the container healthcheck. Reads static config from `traefik/traefik.yml` and watches `traefik/dynamic/` for per-site router files. Let's Encrypt HTTP-01 challenge; certs persist in `traefik/acme.json` (bind mount; writable even with `read_only: true`).
- `srv/portal/nginx/docker-compose.yml` — `nginx:1.27-alpine` (minor-line pinned) on the `edge` network only (no host ports — Traefik reaches it over `edge`). Hardened: `read_only` root FS, `cap_drop ALL`, `no-new-privileges`, tmpfs for `/var/cache/nginx`, `/var/run`, `/tmp`. Healthcheck hits `http://127.0.0.1/` (handled by the `00-default.conf` catchall).

**nginx logging under `read_only`:** there is no writable path for `/var/log/nginx/` inside the container. `nginx.conf` writes `access_log /var/log/nginx/access.log` / `error_log /var/log/nginx/error.log`, which works because the `nginx:alpine` image ships those paths as symlinks to `/dev/stdout` / `/dev/stderr`. Do NOT introduce any other `access_log`/`error_log` paths in `conf.d/*.conf` — new filenames have no symlink, and nginx will fail to start trying to create them in a read-only dir. If per-site on-disk logs are ever wanted, add `./logs:/var/log/nginx` as a bind mount *and* drop `read_only: true`.

Both networks (`traefik`, `edge`) are declared `external: true` and must exist before either stack starts. Run `srv/portal/bin/bootstrap.sh` once per host — it chains `create-docker-networks.sh`, the `acme.json` preflight (touch + chmod 600), and `ensure-default-tls.sh` in the correct order, and is safe to re-run. Verify wiring with `srv/portal/bin/verify-networks.sh` (expects `traefik → edge,traefik` and `nginx → edge`).

`acme.json` is not committed — `bootstrap.sh` creates it with mode 600 on demand. Without the preflight, `docker compose up` silently auto-creates the bind-mount path as a root-owned directory, which breaks Traefik permanently; `bootstrap.sh` is how you avoid that class of failure.

### The three-files-per-site invariant

A provisioned site has three coordinated artifacts that `list-sites.sh` treats as the sources of truth:

1. `srv/portal/nginx/conf.d/<fqdn>.conf` — nginx server block (listens on :80 inside the edge network, `server_name <fqdn>`, roots at `/var/www/<fqdn>`). Logs fall through to stdout/stderr via `nginx.conf`'s global `access_log`/`error_log` — no per-site log files.
2. `srv/portal/nginx/sites/<fqdn>/` — content directory (placeholder `index.html` created at provision time).
3. `srv/portal/traefik/dynamic/<fqdn>.yml` — Traefik dynamic router: `Host(\`<fqdn>\`)` on `websecure` → service `nginx-backend`, middlewares `security-headers@file` + `rate-limit@file`, TLS via `letsencrypt` resolver.

If any one of these is missing, `list-sites.sh` reports **drift**. The provision and deprovision scripts always act on all three together. `provision-site.sh` has an `EXIT` trap that rolls back any artifacts it created if `nginx -t` or another step fails partway — the refuse-to-overwrite guard protects against re-provisioning but cleanup happens automatically on failure. Note: the rollback is safe to `rm -rf` the site dir *only because* the guard prevents re-running over a populated site; if the guard is ever relaxed, the rollback must also be tightened (see `IDEMPOTENCY_AUDIT.md` finding L1).

### Shared script helpers

`srv/portal/bin/_lib.sh` is sourced by every script in the portal (all 8 of them). It provides the shared vocabulary so scripts stay terse and consistent:

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

### Request flow

Client → Traefik :443 (terminates TLS, matches `Host()` rule from a `dynamic/<fqdn>.yml`) → routes over the `edge` network to the `nginx-backend` service (defined in `_shared-services.yml`) → nginx matches `server_name` in `conf.d/<fqdn>.conf` → serves from `/var/www/<fqdn>/`. nginx trusts `X-Forwarded-For` from `172.16.0.0/12`, `10.0.0.0/8`, and `192.168.0.0/16` (all RFC1918 Docker ranges) via `set_real_ip_from`.

Plain HTTP (:80) is configured to redirect everything to `websecure`. TLS options pin TLS 1.2+ and an explicit cipher suite list.

## Common commands

All commands assume cwd = `srv/portal/`.

```bash
# Interactive menu covering every operator action (wraps the scripts below).
# Requires a TTY. For non-interactive use, invoke the scripts directly.
# Writes an audit log to srv/portal/logs/menu.log (gitignored).
./bin/menu.sh
./bin/menu.sh --cheatsheet     # non-interactive CLI reference

# Bootstrap (one time, per server) — idempotent; chains the three setup steps
# and enforces the right order (networks, acme.json preflight, default TLS).
./bin/bootstrap.sh

# Start stacks (nginx first so Traefik finds a ready backend on first request)
docker compose -f nginx/docker-compose.yml up -d   # nginx
docker compose up -d                     # Traefik

# Verify health
./bin/verify-networks.sh                     # confirms both containers on correct networks
./bin/list-sites.sh                          # table: nginx/content/traefik presence per site
./bin/list-sites.sh --probe                  # adds `nginx -T` check + HTTPS reachability
./bin/list-sites.sh --probe --probe-host X   # probe from off-host, resolving to Traefik IP X
./bin/list-sites.sh --drift-only             # show only inconsistent sites
./bin/list-sites.sh --format json            # machine-readable

# Site lifecycle
./bin/provision-site.sh <fqdn>               # static site
./bin/provision-site.sh <fqdn> --spa         # SPA fallback (try_files ... /index.html)
./bin/provision-site.sh <fqdn> --no-reload   # skip `nginx -t` + reload
./bin/deprovision-site.sh <fqdn> --dry-run   # preview
./bin/deprovision-site.sh <fqdn>             # prompts: type the FQDN to confirm
./bin/deprovision-site.sh <fqdn> --yes --keep-content   # remove configs, keep sites/<fqdn>/

# Manual nginx reload (used by provisioning scripts internally)
./bin/reload-nginx.sh

# Override Traefik dynamic dir (env var or flag)
TRAEFIK_DYNAMIC_DIR=/opt/traefik/dynamic ./bin/provision-site.sh ...
./bin/provision-site.sh <fqdn> --traefik-dir /opt/traefik/dynamic

# Override container names (e.g., running a second portal alongside this one)
NGINX_CONTAINER=staging-nginx TRAEFIK_CONTAINER=staging-traefik ./bin/verify-networks.sh
```

No build, no tests, no linter — this is purely shell + config.

## Conventions

- FQDN validation lives in `_lib.sh::validate_fqdn`: lowercase, at least one dot, DNS-legal, and no path-escape characters. Wildcards and IDN/punycode labels are rejected. Edit the regex there, not in callers.
- Generated files are written via `_lib.sh::write_atomic` (temp file + rename). Don't revert to plain `cat > $TARGET <<EOF` — the atomic path survives SIGKILL / power loss, the direct redirect doesn't.
- `list-sites.sh` skips `00-default.conf` / `default.conf` in `conf.d/`, `sites/default/`, and any `_`-prefixed file in `traefik/dynamic/`.
- Traefik router names are derived from FQDN by replacing `.` with `-` (e.g. `app.example.com` → router `app-example-com`). Theoretical collision: `a-b.com` vs `a.b-com` both map to `a-b-com`. Has never bitten us.
- Container names (`nginx`, `traefik`) are the defaults throughout; every script that `docker exec`s into them honors `NGINX_CONTAINER` / `TRAEFIK_CONTAINER` env overrides for side-by-side deployments.
- Provision script is one-shot by design: it refuses to overwrite any of the three artifacts if they already exist. Deprovision requires typing the FQDN to confirm (unless `--yes`). This is deliberate — see `IDEMPOTENCY_AUDIT.md` Open Question Q1.
- Generated files (`conf.d/<fqdn>.conf`, `dynamic/<fqdn>.yml`) contain no timestamps or run-specific metadata — running the provision template twice produces byte-identical output (if the overwrite guard were removed).
- `00-default.conf` is the catchall `server_name _` that handles unknown Host headers; keep it present — the nginx healthcheck relies on it.

## Known limitations

- **Only HTTP-01 ACME challenge** (`traefik.yml`). Requires :80 reachable from the internet. No DNS-01 fallback configured; wildcard certs unavailable.
- **Per-site nginx logs are not persisted** — they ride the container's stdout/stderr via Docker's logging driver. Add a `./logs:/var/log/nginx` volume + logrotate if you need on-disk per-site logs.
- **Default TLS cert is self-signed** (via `ensure-default-tls.sh`). Clients hitting unknown hostnames get a browser cert warning before seeing Traefik's 404. This is working-as-intended for a catchall; if you want a real CA-signed default, dump an existing Let's Encrypt cert from `acme.json` via a sidecar and point `_default-tls.yml` at it.

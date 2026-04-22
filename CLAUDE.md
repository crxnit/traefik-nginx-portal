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

### The three-files-per-site invariant

A provisioned site has three coordinated artifacts that `list-sites.sh` treats as the sources of truth:

1. `nginx/conf.d/<fqdn>.conf` — nginx server block (listens on :80 inside the edge network, `server_name <fqdn>`, roots at `/var/www/<fqdn>`). Logs fall through to stdout/stderr via `nginx.conf`'s global `access_log`/`error_log` — no per-site log files.
2. `nginx/sites/<fqdn>/` — content directory (placeholder `index.html` created at provision time).
3. `traefik/dynamic/<fqdn>.yml` — Traefik dynamic router: `Host(\`<fqdn>\`)` on `websecure` → service `nginx-backend`, middlewares `security-headers@file` + `rate-limit@file`, TLS via `letsencrypt` resolver.

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

### Request flow

Client → Traefik :443 (terminates TLS, matches `Host()` rule from a `dynamic/<fqdn>.yml`) → routes over the `edge` network to the `nginx-backend` service (defined in `_shared-services.yml`) → nginx matches `server_name` in `conf.d/<fqdn>.conf` → serves from `/var/www/<fqdn>/`. nginx trusts `X-Forwarded-For` from `172.16.0.0/12`, `10.0.0.0/8`, and `192.168.0.0/16` (all RFC1918 Docker ranges) via `set_real_ip_from`.

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

# Override knobs
TRAEFIK_DYNAMIC_DIR=/opt/traefik/dynamic ./bin/provision-site.sh ...
NGINX_CONTAINER=staging-nginx TRAEFIK_CONTAINER=staging-traefik ./bin/verify-networks.sh
```

No build, no tests, no linter — this is purely shell + config.

## Server installer

`install.sh` at the repo root is a single downloadable script for initial host setup. Distinct from `bin/bootstrap.sh` (which re-runs one-shot host setup on an already-cloned repo), `install.sh` clones the repo, patches the ACME email, creates the service user, chowns the install dir, installs systemd units, runs `bootstrap.sh` as the service user, enables + starts both stacks via systemctl, and optionally provisions a first site — all from an interactive prompt flow. Intended use: `curl ... | bash` on a fresh Linux server.

```bash
# On a fresh production server:
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh | bash
# or download first:
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh -o install.sh && bash install.sh
```

Structure: 7 phases (existing-config guard, dependency checks, prompts, confirm, install, verify, cleanup + final log). Writes a full session log to `/var/log/portal-install-TIMESTAMP.log` (falls back to `$HOME/` if unwritable) and emits syslog entries via `logger -t portal-install` at each phase. Exits 0 without changes if an existing installation is detected. When curl-piped, reopens stdin from `/dev/tty` so prompts still work.

**Service-user + systemd model.** install.sh creates a system user (`portal` by default, override via `PORTAL_USER=...`), adds it to the `docker` group, and chowns `$INSTALL_DIR` to it. All subsequent operator actions run as that user — never as the invoking admin. Two systemd units (`portal-nginx.service`, `portal-traefik.service`, templated from `systemd/*.service` in the repo) handle start/stop/boot: enabled at install time so the portal comes back up on reboot. Docker's own `restart: unless-stopped` handles in-run crash recovery (container OOM, traefik panic, etc.) — that's a distinct concern from "service should start on boot" and systemd doesn't monitor containers after `ExecStart` returns. See the **Lifecycle ownership (split)** note in the Architecture section for the interaction details. If systemd isn't detected (edge case: Alpine containers, chroots), install.sh falls back to plain `docker compose up -d` with a warning.

**Operator wrapper.** A `bin/portal` script in the repo, symlinked to `/usr/local/bin/portal` at install time, runs any `bin/<cmd>.sh` as the service user via `sudo -iu $PORTAL_USER`. Admins type `portal menu`, `portal provision-site <fqdn>`, `portal verify-networks`, etc. — short commands map to the full script names. This keeps audit trails clean (every write is owned by `portal`, regardless of which admin triggered it) and means removing an admin from `sudoers` is sufficient offboarding.

**CI coverage.** `.github/workflows/ci.yml` globs `bin/*.sh` + `install.sh` for both `bash -n` and shellcheck. Keep new/edited scripts bash-3.2-compatible (macOS bash-3.2 runs the syntax check) and shellcheck-clean. The intentional `# shellcheck disable=SC2086` comments are on `$spa_flag` and `$DC_CMD` in phase 4 where word-splitting is required.

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

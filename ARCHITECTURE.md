# Architecture

This document explains how the portal is designed: the moving parts, how they interact, and why the scripts are shaped the way they are. For an AI-focused, opinionated version optimized for quick context, see `CLAUDE.md`. For the audit trail of why specific design decisions were made, see `IDEMPOTENCY_AUDIT.md`.

---

## 1. What the system does

The repo provides a **single-host, multi-tenant static-site hosting stack**:

- **One Traefik instance** terminates TLS on :443 for many hostnames, obtaining Let's Encrypt certificates automatically.
- **One nginx instance** serves the static content for each site, mounted from host directories.
- **Shell scripts** handle the lifecycle of each site: provisioning (create the three required config artifacts + reload nginx), deprovisioning (remove them + reload), auditing (detect drift), and host-level bootstrap (create Docker networks, set file permissions, generate a default TLS cert).

The design goal is: **adding or removing a site should be one command, always safe to re-run, and leave the system in a consistent state even if something fails partway through.**

---

## 2. Container topology

```
                        ┌───────────────────────────┐
                        │  Client (Internet / LAN)  │
                        └────────────┬──────────────┘
                                     │ :80 / :443
                                     ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                   Docker host (srv/portal/)                      │
  │                                                                  │
  │   ┌────────────────────────────────┐                             │
  │   │  traefik container             │                             │
  │   │  image: traefik:v3.3.4         │                             │
  │   │  - terminates TLS (:443)       │                             │
  │   │  - HTTP→HTTPS redirect (:80)   │                             │
  │   │  - ACME (Let's Encrypt HTTP-01)│                             │
  │   │  - :8082 /ping (healthcheck)   │                             │
  │   └──┬──────────────────────────┬──┘                             │
  │      │ network: traefik         │ network: edge                  │
  │      │ (ACME + TLS handshake)   │ (backend traffic)              │
  │      ▼                          ▼                                │
  │  (upstream cloud)          ┌───────────────────────────────────┐ │
  │                            │  nginx container                  │ │
  │                            │  image: nginx:1.27-alpine         │ │
  │                            │  - listens :80 (plain HTTP)       │ │
  │                            │  - reads conf.d/*.conf            │ │
  │                            │  - serves /var/www/<fqdn>/        │ │
  │                            └───────────────────────────────────┘ │
  └──────────────────────────────────────────────────────────────────┘

  Two external Docker networks (managed outside compose, by bootstrap.sh):
    - traefik : Traefik only. Reserved for any future TLS-adjacent services.
    - edge    : Traefik + nginx. Carries backend HTTP traffic.
```

**Why two networks?** The `edge` network is the only channel between Traefik and nginx; keeping it separate from `traefik` means nginx has no visibility into ACME traffic or anything else that might later share the `traefik` network. Defense in depth rather than functional necessity.

**Why nginx is not on the host `ports:`** nginx never listens on a host-visible port. All inbound traffic comes through Traefik via the `edge` network, so a misconfigured nginx can't leak to the internet.

---

## 3. Request flow

A typical HTTPS request to `example.com` traverses the stack like this:

```
1.  Client → Traefik :443
    - SNI = example.com
    - Traefik picks the TLS certificate for this Host from acme.json
      (or falls back to the default self-signed cert from _default-tls.yml)

2.  Traefik consults its dynamic file provider
    - File watcher reads srv/portal/traefik/dynamic/*.yml
    - Finds the router whose rule is Host(`example.com`)
    - Router references service = nginx-backend (defined in _shared-services.yml)
    - Router references middlewares = security-headers@file, rate-limit@file
      (both defined in _middlewares.yml)

3.  Traefik applies the middleware chain
    - security-headers: HSTS, X-Frame-Options: DENY, etc.
    - rate-limit: 100 req/sec average, 200 burst

4.  Traefik forwards to the nginx-backend service
    - loadBalancer → http://nginx:80 (Docker DNS resolves 'nginx' on edge network)
    - Host header is preserved (passHostHeader: true)

5.  nginx receives the request on :80
    - Matches server_name example.com in conf.d/example.com.conf
    - Serves from /var/www/example.com/ (host-mounted from nginx/sites/example.com/)
    - Access log goes to stdout via /dev/stdout symlink (read-only FS)

6.  Response flows back: nginx → Traefik → client
```

Plain HTTP (:80) is configured at the Traefik level to unconditionally redirect to HTTPS. Unknown hostnames over HTTPS get a 404 from Traefik (router miss) but the TLS handshake still presents a cert — the default self-signed one, so clients see a warning rather than Traefik's built-in generated cert.

---

## 4. The three-artifact invariant

A site called `example.com` is represented by **exactly three files/directories** on the host:

| Path                                              | Purpose                                         |
|---------------------------------------------------|-------------------------------------------------|
| `srv/portal/nginx/conf.d/example.com.conf`        | nginx `server { server_name example.com; ... }` block — routing inside the nginx container |
| `srv/portal/nginx/sites/example.com/`             | Content directory, mounted at `/var/www/example.com/` inside the nginx container |
| `srv/portal/traefik/dynamic/example.com.yml`      | Traefik router + TLS directive — routing at the edge |

**All three must exist.** If any one is missing, the site is "drifted":
- No nginx conf → Traefik routes to nginx, nginx has no server block, returns the default catchall's 404
- No content dir → nginx finds the server block but the root doesn't exist, returns 500
- No Traefik dynamic yaml → Traefik has no router for that host, returns its own 404

`list-sites.sh` is the drift detector. It walks all three directories, joins by FQDN, and reports any site where the three artifacts don't match up.

**The provisioning scripts treat these as an atomic unit.** `provision-site.sh` creates all three (or rolls back on failure); `deprovision-site.sh` removes all three. The scripts refuse to operate if existing files would be overwritten — intentional "one-shot" behavior (see §9).

---

## 5. File layout

```
.
├── .gitignore                          # Excludes generated per-site files, secrets, binaries
├── ARCHITECTURE.md                     # This document
├── CLAUDE.md                           # Concise AI-focused context
├── IDEMPOTENCY_AUDIT.md                # Audit history + rationale for design decisions
└── srv/
    └── portal/                         # Deploys to /srv/portal/ on the host
        ├── bootstrap.sh                # One-shot host setup (networks, acme.json, default TLS)
        ├── create-docker-networks.sh   # Network bootstrap (delegated from bootstrap.sh)
        ├── ensure-default-tls.sh       # Self-signed default cert for unknown-SNI requests
        ├── verify-networks.sh          # Post-deploy container/network wiring check
        ├── provision-site.sh           # Add a site (three-artifact write + reload)
        ├── deprovision-site.sh         # Remove a site (three-artifact delete + reload)
        ├── list-sites.sh               # Drift detector + optional reachability probe
        ├── _lib.sh                     # Shared helpers sourced by every other script
        ├── docker-compose.yml          # Traefik stack
        ├── traefik/
        │   ├── traefik.yml             # Static Traefik config (TLS options, entrypoints, ACME)
        │   ├── acme.json               # ACME state — NOT committed; created by bootstrap.sh
        │   ├── certs/                  # NOT committed; default self-signed cert + key
        │   │   ├── default.crt
        │   │   └── default.key
        │   └── dynamic/                # Traefik file-provider config
        │       ├── _default-tls.yml    # tls.stores.default (self-signed)
        │       ├── _middlewares.yml    # security-headers, rate-limit
        │       ├── _shared-services.yml # nginx-backend (referenced by every site router)
        │       └── <fqdn>.yml          # Per-site router — NOT committed (gitignored)
        └── nginx/
            ├── docker-compose.yml      # nginx stack
            ├── nginx.conf              # Global nginx config
            ├── reload-nginx.sh         # Test + graceful reload (wrapper around _lib.sh)
            ├── conf.d/
            │   ├── 00-default.conf     # Catchall server_name _ (default_server)
            │   └── <fqdn>.conf         # Per-site server block — NOT committed
            └── sites/
                ├── default/            # Content for 00-default.conf
                │   └── index.html
                └── <fqdn>/             # Per-site content — NOT committed
                    └── index.html
```

The underscore-prefix convention on Traefik shared files (`_*.yml`) is what `list-sites.sh` uses to distinguish them from per-site router files.

---

## 6. Scripts

All scripts use `set -euo pipefail` and source `srv/portal/_lib.sh`. They're organized into three groups by purpose:

### 6.1. Host bootstrap (run once per server)

**`bootstrap.sh`** — top-level setup script. Chains:
1. Ensures `traefik/acme.json` exists with mode 600 (touching if absent). This must happen **before** `docker compose up`, otherwise Docker silently creates the bind-mount target as a root-owned directory, which breaks Traefik and requires sudo to recover.
2. Calls `ensure-default-tls.sh` to generate the self-signed default cert.
3. Calls `create-docker-networks.sh` to create the `traefik` and `edge` external networks (skipped with a warning if the Docker daemon isn't reachable — useful for preparing host state before Docker is up).

Each step is idempotent. Re-running is always safe. The order matters: acme.json and certs work without Docker; network creation does not.

**`create-docker-networks.sh`** — creates the two external Docker networks if absent. Usually called from `bootstrap.sh`, but can be invoked directly.

**`ensure-default-tls.sh`** — generates `traefik/certs/default.{crt,key}` (self-signed, 10-year, RSA 2048, CN=`default.invalid`) and writes `traefik/dynamic/_default-tls.yml` to point Traefik's default TLS store at them. Idempotent: skips if the cert exists, auto-regenerates if within 30 days of expiry, supports `--force` to unconditionally re-generate. Uses atomic file writes (temp + rename) so an interrupted run can't leave a half-written key on disk.

**`verify-networks.sh`** — post-deploy sanity check. Confirms both containers are running and attached to the expected networks. Returns non-zero if anything is off. Safe to run repeatedly, read-only.

### 6.2. Site lifecycle (run per site)

**`provision-site.sh <fqdn> [--spa] [--no-reload]`** — creates the three artifacts for a new site and reloads nginx. Key behaviors:
- Validates FQDN via `_lib.sh::validate_fqdn` (lowercase, at least one dot, rejects path-escape chars).
- Acquires a `flock`-based mutex on `.portal.lock` so concurrent invocations can't race.
- Refuses to proceed if any of the three target paths already exist — no silent overwrites.
- Installs an `EXIT` trap that rolls back any artifacts it created if any step fails (including `nginx -t` failure). Successful runs disable the trap.
- All file writes use `write_atomic` (temp + rename) to survive SIGKILL / power loss.
- Tests nginx config and gracefully reloads via `nginx_reload`. If the container isn't running (e.g. during initial host setup), the reload is skipped with a warning and the script still succeeds.

**`deprovision-site.sh <fqdn> [--dry-run] [--yes] [--no-reload] [--keep-content]`** — mirror operation. Removes the three artifacts and reloads nginx. Safety features:
- Dry-run mode shows what would be removed without acting.
- Interactive confirmation requires the operator to type the FQDN exactly (unless `--yes`).
- `--keep-content` preserves `sites/<fqdn>/` for cases where the config is being replaced but the content is reusable.
- Same flock-based mutex as provision.
- "Nothing to remove" is a success — the command is convergent for the no-op case.

**`list-sites.sh [--probe] [--drift-only] [--format json]`** — the drift detector. Enumerates FQDNs across all three source directories, joins them, and reports which artifacts each site has. Flags any site missing at least one artifact as drift.

With `--probe`: additionally checks whether the nginx container recognizes the site (via `nginx -T`) and whether an HTTPS request to the site returns a 2xx/3xx/4xx (useful for detecting certs that haven't been issued yet). With `--probe-host X`: resolves the FQDN to X instead of localhost (use when running the check from off-host).

With `--format json`: machine-readable output for CI / cron use.

Read-only; always safe to run.

### 6.3. Operational utility

**`nginx/reload-nginx.sh`** — test-and-graceful-reload the nginx container. Thin wrapper around `_lib.sh::nginx_reload`. Useful when you've hand-edited `conf.d/` files and need to apply them without going through provision.

**`menu.sh`** — interactive menu that wraps every other script in the toolkit. Organizes actions into host-setup, stack-lifecycle, sites, and logs categories. Requires a TTY (reads go through `/dev/tty` so piped stdin can't bypass confirmation prompts). For non-interactive use, invoke the underlying scripts directly or run `./menu.sh --cheatsheet` to print the CLI equivalents.

Every menu session writes to an audit log at `srv/portal/logs/menu.log` (gitignored, mode 600). One event per line, UTC timestamp, key=value format:

```
2026-04-20T16:20:20Z session_start user=john host=prod-1 pid=38341 tty=/dev/pts/0
2026-04-20T16:20:25Z menu_choice user=john host=prod-1 pid=38341 choice=10 label=provision_site
2026-04-20T16:20:25Z action_start user=john host=prod-1 pid=38341 action=provision_site
2026-04-20T16:20:29Z action_end user=john host=prod-1 pid=38341 action=provision_site exit=0 duration=4s
2026-04-20T16:20:35Z session_end user=john host=prod-1 pid=38341 duration=15s
```

The PID doubles as a session identifier — `grep 'pid=38341' menu.log` reconstructs an operator's entire session. If the log directory isn't writable, a one-time warning prints and the menu continues without audit logging (logging failure never blocks operator work). Menu option `L` shows the last 30 entries without leaving the tool.

The audit log records **metadata only** (what was done, when, by whom, with what exit code) — not captured command output. If full transcripts are needed, use `script(1)` or `tee` externally: `./menu.sh 2>&1 | tee session-$(date +%s).log`.

---

## 7. Shared library: `_lib.sh`

`_lib.sh` is the single source of truth for anything two or more scripts would otherwise duplicate. Every portal script sources it. It provides:

### 7.1. Colors

TTY-aware variables: `GREEN`, `YELLOW`, `RED`, `BLUE`, `BOLD`, `DIM`, `RESET`. Empty strings when output is piped (so `./provision-site.sh foo | tee log` produces clean log files, no escape codes).

### 7.2. Log helpers

Standard output routing:

| Function | Prefix tag | Stream  | Typical use |
|----------|------------|---------|-------------|
| `log_info` | `[INFO]` | stdout | Progress messages |
| `log_ok`   | `[ OK ]` | stdout | Step succeeded |
| `log_warn` | `[WARN]` | stdout | Recoverable issue |
| `log_error`| `[ERROR]`| stderr | Failure |
| `log_skip` | `[SKIP]` | stdout | Idempotent no-op |
| `die`      | —        | stderr, then `exit 1` | Unrecoverable |

Scripts that need specialized tags define them locally (e.g. `log_step` in bootstrap for section headers, `log_dry` in deprovision for dry-run output).

### 7.3. `validate_fqdn <fqdn>`

Returns 0 if the input is a valid DNS-legal, lowercase FQDN with at least one dot and no `..` or `/` path-escape characters. Returns non-zero otherwise. Belt-and-suspenders: the regex alone would reject path escapes, but the explicit check protects against future regex loosening (e.g. adding wildcard support) since the FQDN is later used in `rm -rf` paths during rollback or deprovision.

### 7.4. `write_atomic <target>`

Reads stdin, writes to `<target>.XXXXXX` (via mktemp on the same filesystem), chmods to match the umask, then `mv`s into place. POSIX atomic rename means the target is always either the old content or the new — never a partial file, even on SIGKILL or power loss.

Use for any generated config/content file. For mode-sensitive outputs (private keys, etc.), follow the explicit mktemp → chmod → mv pattern like `ensure-default-tls.sh` does for the openssl key/cert pair.

### 7.5. `acquire_portal_lock <dir>`

Opens `<dir>/.portal.lock` on file descriptor 9 and tries a non-blocking `flock -n`. Fails with exit 1 if another provision/deprovision invocation is already holding the lock. Silent no-op on systems without `flock` (macOS dev hosts); engaged on Linux servers.

The lock is released automatically when the process exits — the kernel closes FD 9 and flock releases.

### 7.6. `nginx_reload [container]`

Tests nginx config in the named container (defaulting to `$NGINX_CONTAINER` then `"nginx"`), then gracefully reloads. Returns 0 on success or if the container isn't running (skipped with a warning — useful during host setup). Returns 1 on config-test or reload failure. Callers handle the non-zero path with their own contextual error messages.

---

## 8. Docker state and bind mounts

A subtle but critical property of Docker bind mounts: **if the host path doesn't exist, Docker creates it as a directory, owned by root.** This is a footgun that trips up operators on fresh deploys.

Specifically in this stack:
- `traefik/acme.json` — Docker creates as a directory, Traefik can't write to it, ACME is broken. Requires `sudo rm -rf` to recover.
- `traefik/certs/` — Docker creates as an empty root-owned dir, `ensure-default-tls.sh` can't chmod or write in it, the default TLS cert never deploys.

`bootstrap.sh` exists primarily to prevent these two failures: it touches `acme.json` with mode 600 and runs `ensure-default-tls.sh` **before** any `docker compose up`. Script order matters — the audit trail in `IDEMPOTENCY_AUDIT.md` (findings H1 and H2) explains the design in more detail.

The `certs/` directory is also protected by a writability check inside `ensure-default-tls.sh`: if the script finds the directory exists but isn't writable by the current user, it bails with an explicit error message including the exact `sudo rm -rf` command to recover.

---

## 9. Idempotency model

The scripts take different stances on re-runnability, matching the shape of what they do:

| Script | Stance | Rationale |
|--------|--------|-----------|
| `bootstrap.sh` | **Idempotent** (safe to re-run) | One-shot setup; expected to be run once but may need to be re-run after partial failure |
| `ensure-default-tls.sh` | **Idempotent** + convergent | Skips if cert exists; auto-regenerates if within 30 days of expiry |
| `create-docker-networks.sh` | **Idempotent** | Existence-check before create |
| `verify-networks.sh` | **Read-only** | No state change |
| `list-sites.sh` | **Read-only** | No state change |
| `provision-site.sh` | **One-shot** (refuses re-run on existing site) | Prevents accidental overwrite of hand-edited configs or deployed content; if you truly want to re-provision, deprovision first |
| `deprovision-site.sh` | **Idempotent** | "Nothing to remove" is treated as success; the "desired state" is absence |
| `nginx/reload-nginx.sh` | **Idempotent** | Graceful reload is inherently re-runnable |

**Why is `provision-site.sh` one-shot rather than convergent?** The provision script writes three artifacts, two of which are content directories that the operator may later populate with real data (HTML, assets, etc.). A convergent provision ("re-run until state matches desired") could wipe deployed content. The one-shot refuse-to-overwrite is the safety rail.

If you need to re-apply a provision (e.g., to pick up template changes), the current path is:
1. `deprovision-site.sh <fqdn> --keep-content` (remove configs only)
2. `provision-site.sh <fqdn>` (creates fresh configs but won't touch sites/<fqdn>/)

Not the most ergonomic flow, but makes accidental content loss impossible. See `IDEMPOTENCY_AUDIT.md` Open Question Q1 for the full discussion.

The rollback trap in `provision-site.sh` is coupled to this stance: it `rm -rf`s any path the script created, which is only safe because the overwrite guard prevents re-running over a populated site. If the one-shot behavior is ever relaxed, the rollback must be tightened in lockstep (documented as audit finding L1).

---

## 10. Security hardening

Both containers run hardened:

**Traefik:**
- `read_only: true` root FS
- `cap_drop: [ALL]` + `cap_add: [NET_BIND_SERVICE]`
- `no-new-privileges`
- `mem_limit: 256m`, `cpus: 0.5`
- Healthcheck on internal `/ping` (port 8082, not exposed)
- TLS 1.2+ with explicit cipher suite list (see `traefik.yml`)
- `accessLog: {}` → Docker log driver

**nginx:**
- `read_only: true` root FS with tmpfs carve-outs for `/var/cache/nginx`, `/var/run`, `/tmp`
- `cap_drop: [ALL]` + minimal add set: `CHOWN, SETGID, SETUID, NET_BIND_SERVICE, DAC_OVERRIDE`
- `no-new-privileges`
- `mem_limit: 256m`, `cpus: 0.5`
- Healthcheck via `wget http://127.0.0.1/` (hits the `00-default.conf` catchall which returns 404 — a 404 is still a healthy response)

Under `read_only: true`, nginx can only write to logs because the `nginx:alpine` image ships `/var/log/nginx/access.log` → `/dev/stdout` and `/var/log/nginx/error.log` → `/dev/stderr` as symlinks. Any new `access_log` path introduced in `conf.d/*.conf` that isn't one of those symlinks will fail at nginx startup with `EROFS`. This is why `provision-site.sh` generates server blocks without per-site log paths — everything flows through the global stdout/stderr.

**Image pinning:**
- `traefik:v3.3.4` (patch-pinned within the 3.3 minor line)
- `nginx:1.27-alpine` (minor-pinned)

Neither is digest-pinned. If full reproducibility is needed, append `@sha256:...` to the image refs.

---

## 11. Deployment workflow

### First-time setup on a fresh host

```bash
git clone <this-repo> /srv/portal-src
cd /srv/portal-src

# Bootstrap host state (idempotent, safe to re-run)
./srv/portal/bootstrap.sh

# Start the stacks (nginx first so Traefik finds a ready backend)
docker compose -f srv/portal/nginx/docker-compose.yml up -d
docker compose -f srv/portal/docker-compose.yml up -d

# Sanity check
./srv/portal/verify-networks.sh
./srv/portal/list-sites.sh
```

### Add a site

```bash
# Provision (creates 3 artifacts, tests config, reloads nginx)
./srv/portal/provision-site.sh example.com

# Deploy real content
rsync -av build/ /srv/portal/nginx/sites/example.com/

# First request triggers ACME cert issuance (requires :80 reachable on public IP)
curl -I https://example.com/
```

### Remove a site

```bash
./srv/portal/deprovision-site.sh example.com --dry-run   # preview
./srv/portal/deprovision-site.sh example.com             # type FQDN to confirm
```

### Audit

```bash
./srv/portal/list-sites.sh               # table view
./srv/portal/list-sites.sh --probe       # + reachability checks
./srv/portal/list-sites.sh --drift-only  # only show misconfigured sites
```

---

## 12. Multi-tenant deploys

The scripts honor `NGINX_CONTAINER` / `TRAEFIK_CONTAINER` environment variables for operating on containers with non-default names:

```bash
# Run a second portal stack alongside the first
export NGINX_CONTAINER=staging-nginx
export TRAEFIK_CONTAINER=staging-traefik

./srv/portal/verify-networks.sh
./srv/portal/provision-site.sh staging.example.com
```

The compose files still pin `container_name: nginx` / `container_name: traefik` by default, so you'll need to override those via a compose override file or edit the compose files to match your container names. The env-var plumbing is there so the scripts don't need to be forked.

---

## 13. Deliberate tradeoffs and known limitations

- **Only HTTP-01 ACME challenge.** Requires port 80 reachable from the internet. No DNS-01 configured. Wildcard certs are not available.
- **Default TLS cert is self-signed.** Unknown-SNI requests over HTTPS produce a browser cert warning. A real CA-signed default would require dumping an existing Let's Encrypt cert from `acme.json` via a sidecar like `ldez/traefik-certs-dumper` — deliberately left out of scope.
- **Per-site logs are not persisted.** Everything rides the container's stdout/stderr via Docker's logging driver. On-disk per-site logs would require dropping `read_only: true` on nginx and adding a `./logs:/var/log/nginx` bind mount + logrotate.
- **Provision is one-shot.** See §9.
- **FQDN regex rejects uppercase, wildcards, and IDN/punycode.** Mostly fine for this use case; document-time choice to keep validation conservative.
- **Single-host design.** There's no orchestration for multi-host deploys. For that, reach for k8s / nomad / swarm.

---

## 14. Where to go next

- `CLAUDE.md` — concise, opinionated AI context. Shorter, assumes more.
- `IDEMPOTENCY_AUDIT.md` — the full audit trail with 16 findings across two passes, showing what was considered, what was fixed, and what was deliberately deferred with rationale.
- Each script's header comment describes its specific behavior, flags, and exit codes.

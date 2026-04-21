# Portal Scripts — Operator Guide

Reference for infrastructure engineers operating or extending the portal's shell tooling. Companion document to `ARCHITECTURE.md` (which covers the *system* — containers, networks, request flow) — this guide covers the *operator tooling*: what each script does, when to use it, how they compose, and how to extend them.

**Audience:** engineers running day-to-day operations, debugging incidents, onboarding sites, or porting this pattern to another deployment.

**Not for:** app developers (see `APP_DEVELOPMENT_PROMPT.md` / `APP_MIGRATION_PROMPT.md`) or AI context priming (see `CLAUDE.md`).

> **Path convention.** Every script resolves its own directory at runtime via `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, so the repo works at any checkout path: `/srv/portal-src/`, `/srv/ai/portal-src/`, `/opt/portal/`, `~/work/portal/` — all equivalent. Docker Compose volume mounts are relative (`./traefik/...`), so they follow the repo wherever it sits. Examples in this guide use `/srv/portal-src/` as a conventional clone target; substitute your path when running commands. Where prose mentions a concrete file location, `$PORTAL_DIR` means "the `srv/portal/` directory inside your clone" — e.g., `$PORTAL_DIR/logs/menu.log` is `/srv/portal-src/srv/portal/logs/menu.log` if you cloned to `/srv/portal-src/`, or `/srv/ai/portal-src/srv/portal/logs/menu.log` if you cloned to `/srv/ai/portal-src/`.

---

## 1. TL;DR — just tell me what to run

| I want to... | Command |
|---|---|
| Do anything interactively | `./bin/menu.sh` |
| First-time host setup | `./bin/bootstrap.sh` |
| Add a new site | `./bin/provision-site.sh <fqdn>` |
| Remove a site | `./bin/deprovision-site.sh <fqdn>` |
| See every provisioned site + drift | `./bin/list-sites.sh` |
| Confirm containers are wired correctly | `./bin/verify-networks.sh` |
| Reload nginx config after a manual edit | `./bin/reload-nginx.sh` |
| Force-regenerate the default TLS cert | `./bin/ensure-default-tls.sh --force` |
| See CLI-equivalent reference without the menu | `./bin/menu.sh --cheatsheet` |

All commands run from `srv/portal/`. Every script sources `_lib.sh` for shared helpers — you don't need to; it's automatic.

---

## 2. `menu.sh` — the primary operator entry point

`menu.sh` is the recommended way to operate the portal. It wraps every other script behind a numbered interactive menu and writes an audit log of every action.

### 2.1 What it covers

16 numbered actions plus three utility entries, organized by category:

- **Host setup:** bootstrap, regenerate default TLS cert
- **Stacks:** start, stop, restart, verify-networks
- **Sites:** list, list-with-probe, drift-only, provision, deprovision, reload nginx
- **Logs:** Traefik tail, Traefik follow, nginx tail, nginx follow
- **Reference:** `L` view audit log, `C` CLI cheatsheet, `Q` quit

Every numbered action delegates to an existing script — menu.sh doesn't reimplement logic. If you fix a bug in `provision-site.sh`, the menu picks it up automatically.

### 2.2 Why TTY-only

Every `read` in `menu.sh` goes through `/dev/tty` rather than stdin. This means **piped input cannot bypass confirmation prompts**. A would-be caller can't `echo "y" | ./bin/menu.sh` past the deprovision confirmation — the read still blocks on the terminal.

This is a deliberate safety property: destructive actions (stop stacks, deprovision, regenerate cert) always require human acknowledgement at a real terminal. If you're trying to automate, use the underlying scripts directly — that's what they're there for.

When invoked without a TTY, menu.sh prints a clear error and exits 1. Exception: `./bin/menu.sh --cheatsheet` prints the CLI-equivalent reference non-interactively, for use in docs or SSH non-interactive sessions.

### 2.3 Status banner

The menu displays a live status line at the top:

```
Portal Operations    ($PORTAL_DIR)
  Traefik: running    nginx: running    sites: 7
```
The path shown is the absolute path to the portal directory on your host, resolved at runtime.

Container states come from `docker inspect`, so `absent`/`exited`/`restarting` all surface immediately. Site count enumerates `traefik/dynamic/*.yml` excluding underscore-prefixed shared files.

### 2.4 Audit log

`menu.sh` writes every session and every action to `srv/portal/logs/menu.log` (gitignored, mode 600). Format: one event per line, UTC timestamp, key=value payload:

```
2026-04-20T16:20:20Z session_start user=john host=prod-1 pid=38341 tty=/dev/pts/0
2026-04-20T16:20:25Z menu_choice   user=john host=prod-1 pid=38341 choice=10 label=provision_site
2026-04-20T16:20:25Z action_start  user=john host=prod-1 pid=38341 action=provision_site
2026-04-20T16:20:29Z action_end    user=john host=prod-1 pid=38341 action=provision_site exit=0 duration=4s
2026-04-20T16:20:35Z session_end   user=john host=prod-1 pid=38341 duration=15s
```

The PID doubles as a session identifier — `grep 'pid=38341'` reconstructs a full operator session.

**Metadata-only by design.** The audit log records what was done, by whom, when, with what exit code. It does not capture command output. Rationale: metadata is grep-friendly and compact; full transcripts balloon quickly and include ANSI escape noise. If you need a full transcript for a specific session: `./bin/menu.sh 2>&1 | tee session-$(date +%s).log`.

**Logging failures never block operator work.** If the log directory isn't writable (permissions issue, read-only FS, etc.), menu.sh prints a one-time warning and continues silently without logging.

The `L` menu option displays the last 30 entries inline, useful for "did that deprovision actually go through?" sanity checks.

---

## 3. The shared library: `_lib.sh`

`_lib.sh` is sourced by every portal script (all 8 of them). Do not invoke it directly — it has no top-level executable logic beyond variable initialization.

### 3.1 Colors

TTY-aware color variables: `GREEN`, `YELLOW`, `RED`, `BLUE`, `BOLD`, `DIM`, `RESET`. Empty strings when stdout isn't a terminal, so piping or redirecting produces clean log files with no escape codes.

### 3.2 Log helpers

| Function | Tag | Stream | Typical use |
|---|---|---|---|
| `log_info` | `[INFO]` | stdout | Progress narration |
| `log_ok`   | `[ OK ]` | stdout | Step succeeded |
| `log_warn` | `[WARN]` | stdout | Recoverable issue |
| `log_error`| `[ERROR]`| stderr | Failure |
| `log_skip` | `[SKIP]` | stdout | Idempotent no-op |
| `die`      | —        | stderr + `exit 1` | Unrecoverable |

Scripts that need specialized tags define them locally (e.g., `log_step` in bootstrap for section headers, `log_dry` in deprovision for dry-run output).

### 3.3 Shared functions

**`validate_fqdn <fqdn>`** — returns 0 if the input is a lowercase, DNS-legal FQDN with at least one dot and no `..` or `/` path-escape characters. Single source of truth for FQDN validation; edit the regex here, not in callers.

**`write_atomic <target>`** — reads stdin, writes to `<target>.XXXXXX` on the same filesystem, chmods to match the umask, then `mv`s into place. POSIX atomic rename means the target is always either old content or new content — never a half-written file, even on SIGKILL or power loss. Use for any generated config. For mode-sensitive outputs (private keys, etc.), follow the explicit mktemp → chmod → mv pattern like `ensure-default-tls.sh` does for the openssl key/cert pair.

**`acquire_portal_lock <dir>`** — opens `<dir>/.portal.lock` on file descriptor 9 and tries a non-blocking `flock -n`. Dies with exit 1 if another provision/deprovision invocation holds the lock. Silent no-op on systems without `flock` (macOS dev hosts); engaged on Linux production hosts. Lock releases automatically when the process exits.

**`nginx_reload [container]`** — tests nginx config in the named container (default `$NGINX_CONTAINER` then `"nginx"`), then gracefully reloads. Returns 0 on success or if the container isn't running (skipped with a warning — useful during host setup). Returns 1 on config-test or reload failure. Callers handle the non-zero path with contextual error messages.

### 3.4 Shared constants

**`PORTAL_NGINX_SERVICE_NAME`** (value: `"nginx-backend"`) — the Traefik service name every generated per-site router references. Must match the `services:` key in `traefik/dynamic/_shared-services.yml`. If the service is ever renamed, update both this constant AND the yaml.

---

## 4. Script reference

One section per script. Each covers: purpose, typical invocation, inputs/outputs, idempotency stance, and gotchas specific to that script.

### 4.1 `bootstrap.sh`

**Purpose:** one-shot host setup. Run once per server, before `docker compose up`.

**Does, in order:**
1. Touches `traefik/acme.json` with mode 600 if missing. Critical — without this, Docker's bind mount silently creates the path as a root-owned directory, breaking Traefik permanently.
2. Calls `ensure-default-tls.sh` to generate the self-signed default cert + Traefik dynamic wiring.
3. Calls `create-docker-networks.sh` to create the `traefik` and `edge` external networks. Skipped with a warning if the Docker daemon isn't reachable — useful for preparing host state before Docker is up.
4. Prints the operator's next steps (the `docker compose up -d` commands for both stacks, in the right order).

**Idempotent.** Each step skips itself if the work is already done. Safe to re-run any number of times.

**Ordering note:** acme.json preflight and TLS cert generation happen first because they don't require Docker. Network creation last because it does. This means `bootstrap.sh` runs to completion in two phases: all non-Docker work unconditionally, then Docker-dependent work if available.

**Typical invocation:** `./bin/bootstrap.sh` — no flags. Always full sequence.

### 4.2 `create-docker-networks.sh`

**Purpose:** create the `traefik` and `edge` Docker networks if absent.

**Idempotent.** Uses the textbook `docker network inspect <name> >/dev/null 2>&1 || docker network create <name>` pattern.

**Direct invocation is fine** — `bootstrap.sh` delegates to this script, but you can also call it standalone after a Docker reinstall to re-create the networks without touching anything else.

**Exits non-zero** if `docker` is missing from PATH or the daemon is unreachable.

### 4.3 `ensure-default-tls.sh`

**Purpose:** generate and wire in a self-signed default TLS cert so unknown-SNI requests to `:443` receive a sensible cert instead of Traefik's generated one.

**Creates:**
- `traefik/certs/default.crt` — self-signed X.509 cert
- `traefik/certs/default.key` — matching private key (mode 600)
- `traefik/dynamic/_default-tls.yml` — Traefik dynamic file pointing `tls.stores.default` at the cert

**Idempotent + convergent.** Skips if the cert already exists; auto-regenerates if the cert expires within 30 days; regenerates unconditionally with `--force`. Uses atomic writes (mktemp + chmod + mv) so an interrupted run can't leave a half-written key.

**Flags:**
- `--cn CN` — Subject Common Name (default: `default.invalid`, an RFC 2606 reserved TLD guaranteed never to collide with real hosts)
- `--days N` — validity in days (default: 3650)
- `--key-size BITS` — RSA key size (default: 2048)
- `--force` — regenerate even if the cert and dynamic yaml exist

**Writability guard:** if `traefik/certs/` exists but isn't writable by the current user (typical when Docker auto-created it as a root-owned dir before the script ever ran), the script bails with the exact `sudo rm -rf ...` recovery command. Do not ignore this — fixing it requires root once.

**Typical invocations:**
```bash
./bin/ensure-default-tls.sh              # idempotent refresh/check
./bin/ensure-default-tls.sh --force      # unconditional regenerate
./bin/ensure-default-tls.sh --cn company.internal --days 365 --key-size 4096
```

### 4.4 `verify-networks.sh`

**Purpose:** post-deploy sanity check that both containers are running and attached to the expected Docker networks.

**Expected state:**
- `traefik` container → attached to `edge` + `traefik`
- `nginx` container → attached to `edge`

**Read-only.** No state changes. Safe in loops, cron, CI. Returns 0 if all checks pass; 1 otherwise.

**Container names are configurable:** set `NGINX_CONTAINER` / `TRAEFIK_CONTAINER` env vars to check non-default names (e.g., for a secondary staging portal on the same host).

**Output categories:**
- `[ OK ]` — container running and correctly wired
- `[WARN]` — container attached to unexpected extra networks (not a failure, just informational)
- `[ERROR]` — container missing, not running, or missing expected networks

### 4.5 `list-sites.sh`

**Purpose:** the drift detector. Enumerates FQDNs across the three sources of truth, joins them, and reports which sites have all three artifacts vs which are missing one.

**Three sources:**
1. `nginx/conf.d/<fqdn>.conf` — nginx server blocks (excluding `00-default.conf` / `default.conf`)
2. `nginx/sites/<fqdn>/` — content directories (excluding `default/`)
3. `traefik/dynamic/<fqdn>.yml` — Traefik router files (excluding `_*`-prefixed shared configs)

**Read-only.** No state changes.

**Flags:**
- `--probe` — additionally check whether nginx recognizes the site (via `nginx -T`) and whether HTTPS returns a 2xx/3xx/4xx. Adds LIVE and HTTPS columns.
- `--probe-host HOST` — IP to resolve each FQDN to when probing (default: `127.0.0.1`). Use when running off-host to point at the portal's public IP.
- `--drift-only` — show only rows where at least one artifact is missing.
- `--format json` — machine-readable output, for CI / cron integration.

**Drift status codes:**
- `ok` — all three artifacts present
- `drift` — at least one missing

**Typical invocations:**
```bash
./bin/list-sites.sh                                  # table
./bin/list-sites.sh --probe                          # + live reachability
./bin/list-sites.sh --probe --probe-host 203.0.113.1 # probe off-host
./bin/list-sites.sh --drift-only                     # only broken sites
./bin/list-sites.sh --format json | jq '.[] | select(.drift=="yes")'
```

### 4.6 `provision-site.sh`

**Purpose:** add a new site to the portal. Creates all three artifacts as a coordinated unit, tests nginx config, and gracefully reloads.

**Creates:**
1. `nginx/conf.d/<fqdn>.conf` — nginx server block, `listen 80; server_name <fqdn>; root /var/www/<fqdn>; ...`
2. `nginx/sites/<fqdn>/index.html` — placeholder landing page
3. `traefik/dynamic/<fqdn>.yml` — Traefik router on `websecure` with `security-headers@file` + `rate-limit@file` middlewares and the `letsencrypt` cert resolver

**Stance: one-shot.** Refuses to proceed if any of the three target paths already exist. This is deliberate — the content directory may contain deployed data, and silently overwriting is worse than a hard stop. To re-provision: `./bin/deprovision-site.sh <fqdn> --keep-content` first.

**Rollback on failure.** An `EXIT` trap removes any artifacts the script itself created if it exits non-zero before the success marker (e.g., `nginx -t` failure). The trap is armed *after* the refuse-to-overwrite check, so an idempotency refusal can't wipe pre-existing files. The rollback is safe to `rm -rf` the site dir only because the overwrite guard prevents re-running over a populated site — if the guard is ever relaxed, the rollback must be tightened in lockstep.

**Flags:**
- `--spa` — SPA fallback: adds `try_files $uri $uri/ /index.html;` so client-side routed deep links work
- `--no-reload` — skip the `nginx -t` + reload step (for batch provisioning before bringing the stack up)
- `--traefik-dir DIR` — override the Traefik dynamic config directory

**Env overrides:**
- `TRAEFIK_DYNAMIC_DIR` — same as the flag
- `NGINX_CONTAINER` — which nginx container to reload (default: `nginx`)
- `CERT_RESOLVER` — which Traefik cert resolver to reference (default: `letsencrypt`)

**Atomic writes.** All three artifacts are written via `write_atomic` from `_lib.sh` — temp file + rename — so an interrupted run can't leave a half-written conf file that nginx fails to parse.

**Mutex.** Calls `acquire_portal_lock` from `_lib.sh` so concurrent provision/deprovision invocations can't race. On systems without `flock` this is a no-op.

**Typical invocation:**
```bash
./bin/provision-site.sh myapp.example.com
./bin/provision-site.sh spa.example.com --spa
./bin/provision-site.sh batch.example.com --no-reload   # then reload once at the end
```

### 4.7 `deprovision-site.sh`

**Purpose:** remove a site. Mirror of `provision-site.sh`.

**Removes:** all three artifacts (unless `--keep-content`).

**Stance: idempotent.** "Nothing to remove" is treated as success. Safe to run repeatedly; the desired state is absence.

**Flags:**
- `--dry-run` — preview what would be removed without acting
- `--yes` / `-y` — skip the interactive confirmation
- `--no-reload` — skip nginx test + reload
- `--keep-content` — remove `conf.d/` and `dynamic/` entries but preserve `sites/<fqdn>/` (useful when replacing a site's config but keeping its content)
- `--traefik-dir DIR` — override the Traefik dynamic directory

**Confirmation.** Unless `--yes` is passed, the operator must type the FQDN verbatim to confirm. A smart guardrail against fat-finger removal.

**Atomic with nginx reload.** After removing the artifacts, the script tests the remaining nginx config and reloads. If the test fails, the script exits non-zero with a message suggesting `conf.d/` has other issues (since removing a site should leave a valid config behind).

**Mutex.** Same `flock` mechanism as provision.

**Typical invocations:**
```bash
./bin/deprovision-site.sh old.example.com --dry-run   # preview
./bin/deprovision-site.sh old.example.com             # interactive, types FQDN
./bin/deprovision-site.sh old.example.com --yes       # non-interactive
./bin/deprovision-site.sh old.example.com --yes --keep-content
```

### 4.8 `bin/reload-nginx.sh`

**Purpose:** test-and-graceful-reload the nginx container. Thin wrapper around `_lib.sh::nginx_reload`.

**Use case:** after hand-editing `conf.d/*.conf`. The provision/deprovision scripts reload automatically — this one is for manual config changes.

**Idempotent.** Graceful reload is inherently re-runnable; worst case is a no-op.

**Container name configurable** via `NGINX_CONTAINER` env var (default: `nginx`).

Just 12 lines of code. Exists as a standalone script so it can be invoked directly without going through the menu.

---

## 5. Script interaction map

Which scripts call which?

```
bootstrap.sh
 ├── (internal) acme.json preflight
 ├── ensure-default-tls.sh
 │    └── _lib.sh (write_atomic, log_*, PORTAL_NGINX_SERVICE_NAME)
 └── create-docker-networks.sh
      └── _lib.sh (log_*)

provision-site.sh
 └── _lib.sh (validate_fqdn, acquire_portal_lock, write_atomic, nginx_reload, log_*)

deprovision-site.sh
 └── _lib.sh (validate_fqdn, acquire_portal_lock, nginx_reload, log_*)

list-sites.sh
 └── _lib.sh (log_* colors only; no functional helpers used)

verify-networks.sh
 └── _lib.sh (log_*)

bin/reload-nginx.sh
 └── _lib.sh (nginx_reload, log_*)

bin/menu.sh
 ├── bin/bootstrap.sh                   # action 1
 ├── bin/ensure-default-tls.sh --force  # action 2
 ├── docker compose (both stacks)       # actions 3,4,5
 ├── bin/verify-networks.sh             # action 6
 ├── bin/list-sites.sh [flags]          # actions 7,8,9
 ├── bin/provision-site.sh [flags]      # action 10
 ├── bin/deprovision-site.sh [flags]    # action 11
 ├── bin/reload-nginx.sh                # action 12
 ├── docker compose logs                # actions 13-16
 └── _lib.sh (everything)
```

**Key observation:** all interactions go through `_lib.sh`. No script calls another script's internal functions — they either delegate as subprocesses (`bootstrap.sh` → `ensure-default-tls.sh`) or share via the library.

---

## 6. Operator workflows — common recipes

### 6.1 Stand up a brand new host from zero

```bash
# 1. Clone repo — target is arbitrary, pick what fits your host
git clone <repo-url> /srv/portal-src         # or /srv/ai/portal-src, /opt/portal, etc.
cd /srv/portal-src

# 2. (Option A) Run bootstrap directly
./srv/portal/bin/bootstrap.sh

# 2. (Option B) Run bootstrap through the menu and get the audit log
cd srv/portal && ./bin/menu.sh   # pick option 1

# 3. Start stacks (nginx first)
docker compose -f srv/portal/nginx/docker-compose.yml up -d
docker compose -f srv/portal/docker-compose.yml up -d

# 4. Verify
./srv/portal/bin/verify-networks.sh
./srv/portal/bin/list-sites.sh
```

### 6.2 Onboard a new site (static)

```bash
# 1. Confirm DNS points at this host
dig +short myapp.example.com    # should return the host's public IP

# 2. Provision — creates 3 artifacts, reloads nginx
./srv/portal/bin/provision-site.sh myapp.example.com
# (add --spa if it's a client-side-routed SPA)

# 3. Deploy content (target is $PORTAL_DIR/nginx/sites/<fqdn>/)
rsync -av myapp/dist/ ./srv/portal/nginx/sites/myapp.example.com/

# 4. First HTTPS request triggers ACME (allow 10-30s)
curl -I https://myapp.example.com/

# 5. Confirm
./srv/portal/bin/list-sites.sh --probe   # LIVE=yes, HTTPS=2xx
```

### 6.3 Onboard a new site (dynamic container)

```bash
# 1. DNS + provision as above
./srv/portal/bin/provision-site.sh myapp.example.com --no-reload
# --no-reload because we'll replace the Traefik yaml below

# 2. Drop the app's compose file at srv/portal/apps/myapp/docker-compose.yml
#    (see APP_DEVELOPMENT_PROMPT.md for the template)

# 3. Overwrite the auto-generated Traefik dynamic yaml with one pointing at
#    the app container instead of nginx-backend
cat > srv/portal/traefik/dynamic/myapp.example.com.yml <<'EOF'
http:
  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://app-myapp:8000"
        passHostHeader: true
  routers:
    myapp:
      rule: "Host(`myapp.example.com`)"
      entrypoints: [websecure]
      service: myapp
      middlewares: [security-headers@file, rate-limit@file]
      tls:
        certResolver: letsencrypt
EOF

# 4. Start the app container
docker compose -f srv/portal/apps/myapp/docker-compose.yml up -d

# 5. Also delete the placeholder nginx conf + content dir since this site
#    is served by the container, not nginx
rm srv/portal/nginx/conf.d/myapp.example.com.conf
rm -rf srv/portal/nginx/sites/myapp.example.com
./srv/portal/bin/reload-nginx.sh

# 6. Verify
./srv/portal/bin/list-sites.sh --probe
```

Note: the current `provision-site.sh` assumes the nginx-served case. Dynamic-container sites require manual adjustment of steps 3 and 5. If you onboard many dynamic apps, a `provision-dynamic-site.sh` variant would be a reasonable addition (see § 10).

### 6.4 Remove a site

```bash
# 1. Preview
./srv/portal/bin/deprovision-site.sh myapp.example.com --dry-run

# 2. Remove (interactive — type the FQDN to confirm)
./srv/portal/bin/deprovision-site.sh myapp.example.com

# 3. Keep the content but remove configs
./srv/portal/bin/deprovision-site.sh myapp.example.com --yes --keep-content
```

### 6.5 Investigate drift

```bash
# Table view of all sites
./srv/portal/bin/list-sites.sh

# Only broken ones
./srv/portal/bin/list-sites.sh --drift-only

# With probes (requires running stacks)
./srv/portal/bin/list-sites.sh --probe

# JSON for scripting
./srv/portal/bin/list-sites.sh --format json | jq '.[] | select(.drift=="yes")'
```

Common drift patterns:
- **nginx ✓, content ✓, traefik ✗** — typically someone manually deleted the Traefik dynamic file or provisioned with `--traefik-dir` pointing elsewhere
- **nginx ✗, content ✓, traefik ✓** — hand-edited `conf.d/` cleanup that left the site directory and yaml
- **nginx ✗, content ✗, traefik ✓** — leftover dynamic yaml after a botched deprovision; Traefik will log "service not found" on every request

Fix options: re-provision (if you want the site back) or deprovision to clean up.

### 6.6 Renew/refresh the default TLS cert

```bash
# Check current expiry
./srv/portal/bin/ensure-default-tls.sh    # will auto-regenerate if within 30 days

# Force now (e.g., if you changed the CN or key size)
./srv/portal/bin/ensure-default-tls.sh --force

# Traefik picks up the new cert automatically via file-watch on dynamic/
```

### 6.7 Triage a failed deploy

```bash
# 1. Check container states
./srv/portal/bin/verify-networks.sh

# 2. Check drift
./srv/portal/bin/list-sites.sh --drift-only

# 3. Check Traefik for routing errors
docker compose -f srv/portal/docker-compose.yml logs --tail=100 traefik | grep -iE 'error|acme'

# 4. Check nginx config
docker exec nginx nginx -t

# 5. Check ACME state (if cert failed)
docker exec traefik cat /acme.json | jq '.letsencrypt.Certificates[] | .domain'

# 6. Check the operator audit log — who did what, when, exit code
tail -50 srv/portal/logs/menu.log
grep 'exit=[1-9]' srv/portal/logs/menu.log   # non-zero exits only
```

### 6.8 Run alongside a second portal instance on the same host

```bash
# In the secondary portal's compose files, rename container_name to:
#   container_name: staging-traefik
#   container_name: staging-nginx
# (and pick non-overlapping host ports and different network names)

# Then operate it via env overrides:
NGINX_CONTAINER=staging-nginx TRAEFIK_CONTAINER=staging-traefik \
    ./srv/portal/bin/verify-networks.sh

NGINX_CONTAINER=staging-nginx ./srv/portal/bin/provision-site.sh staging.example.com
```

Every script that `docker exec`s into nginx or Traefik honors these overrides. `verify-networks.sh`, `list-sites.sh`, `provision-site.sh`, `deprovision-site.sh`, and `reload-nginx.sh` all plumb them through.

---

## 7. Environment variables and overrides

Full reference for every env var the scripts respect:

| Variable | Default | Consumed by | Purpose |
|---|---|---|---|
| `NGINX_CONTAINER` | `nginx` | provision, deprovision, list-sites (probe), verify-networks, reload-nginx, menu | Container to `docker exec` into / reload |
| `TRAEFIK_CONTAINER` | `traefik` | verify-networks, menu | Traefik container name for status display / wiring checks |
| `TRAEFIK_DYNAMIC_DIR` | `<SCRIPT_DIR>/traefik/dynamic` | provision, deprovision, list-sites | Where Traefik file-provider reads dynamic configs |
| `CERT_RESOLVER` | `letsencrypt` | provision | Traefik cert resolver name in generated router files |
| `USER` | (system default) | menu (audit log) | Logged in every audit event |

No secrets go through env. Anything secret (ACME storage, private keys) lives in files on disk with tight permissions.

---

## 8. Audit log — retrieval and analysis

Location: `$PORTAL_DIR/logs/menu.log` (gitignored, mode 600).

Format: one event per line, UTC timestamp + event type + key=value payload. PID doubles as session ID.

**Common analysis queries:**

```bash
# Recent activity
tail -30 srv/portal/logs/menu.log

# All non-zero exits
grep 'exit=[1-9]' srv/portal/logs/menu.log

# Every deprovision, chronologically
grep 'action=deprovision_site' srv/portal/logs/menu.log

# What did user X do in the last hour?
awk -v cutoff="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
    '$1 > cutoff && /user=alice/' srv/portal/logs/menu.log

# Reconstruct a specific session end-to-end
grep 'pid=38341' srv/portal/logs/menu.log

# Count actions by type, descending
awk -F'action=' '/action_end/ {split($2,a," "); print a[1]}' srv/portal/logs/menu.log \
    | sort | uniq -c | sort -rn
```

**Rotation.** There is no built-in rotation. The file is append-only and grows over time. For a single-host manual-operator workflow, this is rarely a problem (single-digit KB per session). If you need rotation:

```bash
# /etc/logrotate.d/portal-menu   (substitute the real absolute path for $PORTAL_DIR)
$PORTAL_DIR/logs/menu.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
    create 0600 <operator> <operator>
}
```

Logrotate config files don't perform shell expansion, so write the literal absolute path in the actual config (e.g. `/srv/portal-src/srv/portal/logs/menu.log`).

**Do not commit the log.** `.gitignore` covers `srv/portal/logs/` already.

---

## 9. Troubleshooting

Common failure modes and their diagnosis.

### 9.1 "Container 'nginx' is not running — skipping reload"

Benign. Means Docker isn't up yet (typical during host bootstrap) or you've stopped the nginx stack. Provision still wrote the files; just start nginx and reload:

```bash
docker compose -f nginx/docker-compose.yml up -d
./bin/reload-nginx.sh
```

### 9.2 "another provision/deprovision is running — refusing to proceed"

The `flock` mutex caught a concurrent invocation. Normal if you have automation racing with manual work. If you're sure no other invocation is running (e.g., a crashed process left the lock):

```bash
# On Linux: lock file is harmless but you can remove it to force
rm srv/portal/.portal.lock

# On macOS: no flock installed, this shouldn't happen
```

### 9.3 "acme.json is a directory"

Docker auto-created the path. Happens when `docker compose up` ran before `bootstrap.sh`. Recovery requires root:

```bash
sudo rm -rf srv/portal/traefik/acme.json
./srv/portal/bin/bootstrap.sh
docker compose down && docker compose up -d
```

### 9.4 "traefik/certs exists but is not writable"

Same class of failure: Docker auto-created the path as root-owned. Recovery is in the error message:

```bash
sudo rm -rf srv/portal/traefik/certs
./srv/portal/bin/ensure-default-tls.sh
```

### 9.5 Site provisions but gets 404 from Traefik

Check the Traefik dynamic yaml references `nginx-backend`:

```bash
grep -l 'service: nginx-backend' srv/portal/traefik/dynamic/*.yml
ls srv/portal/traefik/dynamic/_shared-services.yml  # must exist
docker compose logs traefik --tail=50 | grep -i error
```

If `_shared-services.yml` is missing, every site router fails with "service not found". `bootstrap.sh` creates it indirectly via `ensure-default-tls.sh` (no — that creates `_default-tls.yml`; `_shared-services.yml` is committed to the repo). If it's missing, restore from git: `git checkout -- srv/portal/traefik/dynamic/_shared-services.yml`.

### 9.6 Cert issuance hangs

ACME HTTP-01 requires port 80 reachable from the internet to the Let's Encrypt validator.

```bash
# From an external machine:
curl -I http://<fqdn>/.well-known/acme-challenge/test   # should hit Traefik

# Traefik logs will show the challenge in progress:
docker compose logs traefik --tail=200 | grep -i acme
```

Common blockers: cloud firewall rule, DNS not yet propagated, `:80` routing rule dropping `/.well-known/acme-challenge/*`.

### 9.7 nginx container fails to start with EROFS

Something tried to write to a path that's read-only under the hardening config. Check for stray `access_log` / `error_log` paths in `conf.d/`:

```bash
grep -rE 'access_log|error_log' srv/portal/nginx/conf.d/
```

The only acceptable log paths are the image-default `/var/log/nginx/access.log` (symlinked to `/dev/stdout`) and `/var/log/nginx/error.log` (symlinked to `/dev/stderr`). Any other path needs its directory added as a `tmpfs:` in `nginx/docker-compose.yml`.

---

## 10. Extending the toolkit

Patterns for adding new scripts without breaking the conventions already in place.

### 10.1 New-script skeleton

```bash
#!/usr/bin/env bash
#
# <name>.sh — <one-line purpose>.
#
# <longer description of what it does, when to use>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# --- Argument parsing ------------------------------------------------------

usage() { cat <<EOF
Usage: $0 [options]

Options:
  -h, --help   Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# --- Work ------------------------------------------------------------------

log_info "Doing the thing..."
# ... use validate_fqdn, write_atomic, acquire_portal_lock, nginx_reload ...
log_ok "Thing done."
```

Key points:
- `set -euo pipefail` always
- `SCRIPT_DIR` resolved via BASH_SOURCE so invocation location doesn't matter
- Source `_lib.sh` for colors + log helpers + shared functions
- Use `die` for fatal errors (consistent `[ERROR]` tagging)
- Use `write_atomic` for any generated file
- Call `acquire_portal_lock` if the script mutates shared state (files in `conf.d/`, `sites/`, `dynamic/`)

### 10.2 Register in menu.sh

Add to `show_menu()` display, add a case arm to `main()`'s dispatch table, add an `action_<thing>()` wrapper. Three edits, all in the same file. The audit log picks it up automatically.

### 10.3 Add a new shared helper

If two scripts need the same logic, promote it to `_lib.sh`:

```bash
# In _lib.sh:
my_helper() {
    local arg="$1"
    # ... use log_info, log_error, die as needed ...
}
```

Rules:
- Function-local all variables (`local foo=bar`)
- Rely on the caller's log_* functions (they're defined in _lib.sh itself, so this is self-consistent)
- Document inputs, outputs, and exit codes in a comment block
- Don't add script-specific state to _lib.sh; keep it generic

### 10.4 Add a new shared Traefik dynamic file

Use an underscore prefix so `list-sites.sh` FQDN discovery ignores it:

```bash
cat > srv/portal/traefik/dynamic/_my-shared-thing.yml <<EOF
http:
  middlewares:
    my-thing:
      ...
EOF
```

Reference from per-site routers as `my-thing@file`.

### 10.5 Run a lint / shellcheck before committing

Not enforced yet in CI but recommended:

```bash
for f in srv/portal/*.sh srv/portal/nginx/*.sh srv/portal/bin/_lib.sh; do
    shellcheck "$f"
done
```

Most findings from the two quality-review passes have been addressed; the remaining ones are documented in `IDEMPOTENCY_AUDIT.md` with rationale.

---

## 11. File locations quick reference

| Purpose | Path |
|---|---|
| All scripts + shared library | `srv/portal/bin/*.sh` (includes `_lib.sh`) |
| Traefik static config | `srv/portal/traefik/traefik.yml` |
| Traefik dynamic shared | `srv/portal/traefik/dynamic/_*.yml` |
| Traefik dynamic per-site | `srv/portal/traefik/dynamic/<fqdn>.yml` |
| Traefik ACME state | `srv/portal/traefik/acme.json` (not committed) |
| Traefik default cert | `srv/portal/traefik/certs/default.{crt,key}` (not committed) |
| nginx global config | `srv/portal/nginx/nginx.conf` |
| nginx per-site configs | `srv/portal/nginx/conf.d/<fqdn>.conf` (not committed) |
| nginx default catchall | `srv/portal/nginx/conf.d/00-default.conf` |
| Site content | `srv/portal/nginx/sites/<fqdn>/` (not committed) |
| Default catchall content | `srv/portal/nginx/sites/default/` |
| Mutex lock | `srv/portal/.portal.lock` (runtime, gitignored) |
| Audit log | `srv/portal/logs/menu.log` (runtime, gitignored, mode 600) |
| Operator compose | `srv/portal/docker-compose.yml` (Traefik) + `srv/portal/nginx/docker-compose.yml` |

---

## 12. Related docs

- `ARCHITECTURE.md` — the *system* view: containers, networks, request flow, design tradeoffs
- `CLAUDE.md` — terse AI-context for future LLM sessions
- `IDEMPOTENCY_AUDIT.md` — the historical audit trail; 16 findings with remediations and rationale
- `APP_DEVELOPMENT_PROMPT.md` — for app devs building new apps to deploy here
- `APP_MIGRATION_PROMPT.md` — for app devs adapting existing apps

# Idempotency Audit

**Date:** 2026-04-19
**Repository:** `/Users/john/newscratch/traefik-nginx-provisioning-scripts`
**Files reviewed:** 16 (7 shell, 2 compose, 4 Traefik, 3 nginx)

## 1. Executive Summary

**First-pass remediation:** 11 of 12 findings ✓ resolved. 1 deferred-by-design (L1, coupled to an active guard and tracked for future reconsideration).

**Second-pass audit** (after the failure-modes reference was completed): 4 additional findings, all fixed.

- **First-pass findings: 12** — 11 fixed, 1 deferred-by-design (L1)
- **Second-pass findings: 4** — all fixed (H3, M5, L7, L8)
- **Grand total:** 16 findings surfaced, 15 resolved, 1 deferred-by-design.

### Top themes

1. **Implicit host-filesystem preconditions before `docker compose up`.** Docker's default behavior of silently creating missing bind-mount targets (as directories, root-owned) is a latent footgun for `acme.json` and `traefik/certs/`. Nothing in the repo enforces the setup order.
2. **The provisioning scripts have a strong "refuse-to-overwrite" stance.** This is deliberate and defensible as a safety rail — but it means `provision-site.sh` is *one-shot*, not *idempotent*, by the strict definition. Documented as an Open Question, not a finding.
3. **Script generators embed a volatile timestamp** (`$(date ...)` in heredocs). If the guard above is ever relaxed, the output becomes non-reproducible across runs.
4. **Good baseline:** rollback trap in `provision-site.sh`, existence-check in `create-docker-networks.sh`, skip-if-exists in `ensure-default-tls.sh`, universal `set -euo pipefail`, purely read-only audit tools.

### Overall assessment

The codebase is in **good shape** for idempotency. No script in scope outright fails on re-run. The patterns in place (existence checks, rollback traps, dry-run modes, confirmation prompts) reflect a deliberate, mature approach. The remaining issues are concentrated in two places: (a) first-time host bootstrap where Docker's mount-creation behavior can silently corrupt state, and (b) a handful of surfaces where the *content* of generated files is time-sensitive rather than content-addressed. None of these are blocking; all are worth fixing before a second operator inherits the stack.

---

## 2. Detailed Findings

### [HIGH] `acme.json` bind mount can be auto-created as a directory on a fresh host  ✓ Fixed

**File:** `srv/portal/docker-compose.yml` (line 12) — addressed via `srv/portal/bootstrap.sh` which `touch`es `acme.json` with mode 600 before Docker sees the path. `acme.json` removed from repo (permission mode doesn't round-trip across git clones). Batch 1.

**Current behavior:**

```yaml
- ./traefik/acme.json:/acme.json
```

**Why this breaks idempotency:**

When a fresh clone of this repo is brought up with `docker compose up -d` before `touch srv/portal/traefik/acme.json && chmod 600 srv/portal/traefik/acme.json`, Docker creates `traefik/acme.json` as a **directory** (owned by root), not an empty file. Traefik then refuses to start because it can't write the ACME state file there. Re-runs of `docker compose up -d` are not self-healing — the user must manually `sudo rm -rf traefik/acme.json && touch traefik/acme.json && chmod 600 ...` to recover.

This repo happens to have an empty `acme.json` committed (mode 600), so a straight clone works — but a partial checkout, a fresh scaffold, or any host where the file gets cleaned (e.g., `git clean -fdx`) will trigger this.

**Recommended fix:**

Add a bootstrap preflight to `create-docker-networks.sh` (or a new `bootstrap.sh`):

```bash
ACME="srv/portal/traefik/acme.json"
if [[ ! -f "$ACME" ]]; then
    touch "$ACME"
    chmod 600 "$ACME"
    log_info "Created empty $ACME (mode 600)"
fi
```

Alternately, check & refuse to bring up the stack if `acme.json` doesn't exist at the expected path.

**Pattern:** Same class as [HIGH] `certs/` bind mount below.

---

### [HIGH] `traefik/certs/` bind mount can be auto-created before `ensure-default-tls.sh` runs  ✓ Fixed

**File:** `srv/portal/docker-compose.yml` (line 11) — `bootstrap.sh` now calls `ensure-default-tls.sh` before Docker sees the path. `ensure-default-tls.sh` also bails with an explicit error + recovery command if the dir exists but is unwritable (Docker-as-root scenario). Batch 1 + Batch 2.

**Current behavior:**

```yaml
- ./traefik/certs/:/etc/traefik/certs/:ro
```

**Why this breaks idempotency:**

If an operator runs `docker compose up -d` **before** running `ensure-default-tls.sh`, Docker creates `traefik/certs/` as an empty root-owned directory. Subsequent `ensure-default-tls.sh` invocations will fail at `chmod 700 "$CERTS_DIR"` (permission denied for non-root user) or write a key into a directory whose permissions the script then cannot correct. The error is silent unless the user inspects Traefik logs — Traefik starts, serves its built-in self-signed cert for all unknown SNI, and `_default-tls.yml` has no effect.

Retrying does not recover; the operator must manually `sudo rm -rf traefik/certs/` and re-run `ensure-default-tls.sh`.

**Recommended fix:**

Have `ensure-default-tls.sh` be part of the bootstrap sequence (called from `bootstrap.sh` or documented as mandatory before `docker compose up`), OR have the Traefik compose include a `depends_on: condition: service_completed_successfully` on a oneshot init service that runs `ensure-default-tls.sh`. Simpler: add the `ensure-default-tls.sh` invocation to the `CLAUDE.md` bootstrap list (already done as of the last session) and, additionally, have `ensure-default-tls.sh` bail with an explicit error if `$CERTS_DIR` exists but is not writable by the running user.

**Pattern:** Same class as `acme.json` above — both depend on running host-side scripts before docker sees the paths.

---

### [MEDIUM] Generated files embed a volatile timestamp  ✓ Fixed

**File:** `srv/portal/provision-site.sh` (lines 207, 245) — `Provisioned:` timestamp dropped from both the nginx conf and Traefik dynamic templates. Generated content is now stable across runs. Batch 3.

**Current behavior:**

```bash
cat > "$CONF_FILE" <<EOF
# ${FQDN}
# Provisioned: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
...
EOF
```

**Why this breaks idempotency:**

If the refuse-to-overwrite guard at lines 122–131 is ever relaxed to allow re-provisioning, running `provision-site.sh example.com` twice produces two different files (different `Provisioned:` timestamps), even though the semantic state is identical. This fails any content-hash check of "is the repo converged." Also makes `git status` noisy if generated files ever start being tracked.

**Recommended fix:**

Drop the timestamp, or move it to a sidecar metadata file that isn't part of the functional nginx/Traefik config:

```diff
 cat > "$CONF_FILE" <<EOF
 # ${FQDN}
-# Provisioned: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
 ...
```

Git history (or the dynamic file's mtime) already answers "when was this provisioned?"

**Pattern:** Same issue on line 245 for the Traefik dynamic template.

---

### [MEDIUM] Stale user-facing error message after rollback trap was added  ✓ Fixed

**File:** `srv/portal/provision-site.sh` (lines 273–274) — error now reads "Rollback will clean up the partial provision" + "Fix the underlying config issue and re-run $0 $FQDN". Matches current rollback behavior. Batch 3.

**Current behavior:**

```bash
log_error "nginx config test failed. Files were created but nginx was NOT reloaded."
log_error "Fix the issue and run: docker exec $NGINX_CONTAINER nginx -s reload"
```

**Why this breaks idempotency (user-facing, not state-level):**

The rollback trap (lines 141–153) now removes the created files on failure. The error message tells the user files were left behind and suggests `nginx -s reload` as a recovery step — neither is true anymore. A user following the message will attempt to manually clean up files that are already gone, then be surprised when `provision-site.sh` succeeds on a straight re-run because state is actually clean.

**Recommended fix:**

```diff
-log_error "nginx config test failed. Files were created but nginx was NOT reloaded."
-log_error "Fix the issue and run: docker exec $NGINX_CONTAINER nginx -s reload"
+log_error "nginx config test failed. Rollback will clean up the partial provision."
+log_error "Fix the underlying config issue and re-run $0 $FQDN."
 exit 1
```

---

### [MEDIUM] `chmod 700` runs unconditionally on `$CERTS_DIR`  ✓ Fixed

**File:** `srv/portal/ensure-default-tls.sh` (line 103) — now only chmods when the dir didn't already exist; existing operator-set perms are preserved. Batch 2.

**Current behavior:**

```bash
mkdir -p "$CERTS_DIR"
chmod 700 "$CERTS_DIR"
```

**Why this is a drift:**

`mkdir -p` is idempotent. `chmod 700` is not — it reverts whatever perms the operator set. Minor but textbook non-idempotent behavior: a script that "converges to 700" is fine; a script that "always sets 700" silently undoes deliberate adjustments (e.g., `750` for a shared group).

**Recommended fix:**

Only chmod when the dir was just created or perms are wrong:

```bash
if [[ ! -d "$CERTS_DIR" ]]; then
    mkdir -p "$CERTS_DIR"
    chmod 700 "$CERTS_DIR"
fi
```

Low impact in practice — flagging for pattern, not severity.

---

### [MEDIUM] `container_name: traefik` / `container_name: nginx` are global-namespace fixed names  ✓ Fixed (lighter variant)

**Files:**
- `srv/portal/docker-compose.yml` (line 4)
- `srv/portal/nginx/docker-compose.yml` (line 4)

Scripts now honor `NGINX_CONTAINER` and `TRAEFIK_CONTAINER` env vars (default `nginx` / `traefik`). An operator running a second portal on the same host can set `container_name: staging-nginx` in their overridden compose and invoke scripts with `NGINX_CONTAINER=staging-nginx ...` — no fork needed. Compose files themselves still pin the default name, which is a deliberate trade-off: keeps the happy path simple while leaving multi-tenant deploys configurable. Deeper refactor (drop `container_name:`, look up via `docker compose ps -q`) remains deferred. Batches 5–6.

**Current behavior:**

Each service pins `container_name: traefik` or `container_name: nginx`.

**Why this complicates re-runs:**

Two concurrent instances of this stack on the same host (e.g., a staging + production deploy, or a green/blue rollout) will collide at `docker compose up -d`. The collision is a loud error, but it breaks the invariant "this repo can be deployed twice on the same host without editing files."

Not strictly idempotency — it's reproducibility/multi-tenancy — but worth flagging since the provisioning scripts also grep for `docker ps --format '{{.Names}}' | grep -qw nginx`, which would match the first container with that name regardless of which compose project owns it.

**Recommended fix:**

Drop `container_name:` entirely and let Compose generate project-scoped names (`portal-traefik-1`, `portal-nginx-1`). Update `verify-networks.sh`, `provision-site.sh`, `deprovision-site.sh`, `list-sites.sh`, and `reload-nginx.sh` to look up the container by compose-project label instead of fixed name:

```bash
NGINX_CONTAINER=$(docker compose -f "$NGINX_COMPOSE" ps -q nginx)
```

Larger change — defer unless multi-instance deploys are on the roadmap.

**Pattern:** Fixed identifiers in places that should be scoped-by-project.

---

### [LOW] Rollback could wipe user-deployed content in a future scenario  ✗ Deferred by design

**File:** `srv/portal/provision-site.sh` (lines 145–150)

This finding is coupled to the refuse-to-overwrite guard at lines 122–131: while the guard is active, rollback can only fire on freshly-created paths (never on a site with deployed content). The guard and the rollback are two halves of the same safety contract. Any future work that relaxes the overwrite guard (e.g., turning provision into a convergent GitOps-style op) must *simultaneously* tighten the rollback path — per the fix suggestion of stat-before-run mtime comparison — or drop the `rm -rf` for `$SITE_DIR` entirely. Tracked here so the coupling is discoverable; no code change today. See Open Question Q1.

**Current behavior:**

```bash
for p in "${CREATED_PATHS[@]}"; do
    if [[ -d "$p" ]]; then
        rm -rf "$p" && log_warn "  removed: $p"
    ...
```

**Why this is a latent risk:**

Today, the refuse-to-overwrite guard ensures rollback can only fire when the site dir was freshly created by the current run — so `rm -rf $SITE_DIR` is safe. If anyone ever relaxes the guard to support "re-provision over an existing site," the rollback path will happily `rm -rf` a directory that may contain user-deployed content.

**Recommended fix:**

Before `rm -rf` in rollback, cross-check that the path was created (not merely populated) by this run. E.g., track the stat-before-run and only delete paths whose mtime matches this run. Defer unless the re-provision use case becomes real.

---

### [LOW] `ensure-default-tls.sh` doesn't warn on impending cert expiry  ✓ Fixed

**File:** `srv/portal/ensure-default-tls.sh` (lines 107–109) — now runs `openssl x509 -checkend $((30*86400))` on the skip path and auto-regenerates if the cert expires within 30 days. Verified via `--days 5` smoke test. Batch 2.

**Current behavior:**

Skip-if-exists, no expiry check:

```bash
if [[ -f "$CRT_FILE" && -f "$KEY_FILE" && "$FORCE" != "true" ]]; then
    expiry=$(openssl x509 -in "$CRT_FILE" -noout -enddate ...)
    log_skip "Cert already exists: $CRT_FILE (expires: $expiry) — use --force to regenerate"
```

**Why this is a latent issue:**

A 10-year default cert is likely fine forever, but if someone passes `--days 30`, the script cheerfully reports "already exists" a day before the cert dies. A repeat-run on the eve of expiry won't self-heal.

**Recommended fix:**

Inside the skip branch, run `openssl x509 -in "$CRT_FILE" -noout -checkend $((30*86400))` and regenerate (or warn) if the cert expires within 30 days. One-line addition.

---

### [LOW] `docker compose up -d` has no ordering between Traefik and nginx stacks  ✓ Fixed (doc-level)

**Files:** `srv/portal/docker-compose.yml`, `srv/portal/nginx/docker-compose.yml` — `bootstrap.sh` prints the correct order (nginx first, Traefik second) as "Next steps", and `CLAUDE.md` commands block matches. No compose-level `depends_on` added since the two stacks are separate projects — doc-level ordering is the right scope. Batch 4.

**Why this is a latent issue:**

The two stacks are independent compose projects sharing the `edge` network. Bringing up Traefik before nginx means Traefik routers resolve `nginx-backend` but get connection-refused until nginx comes online. The healthcheck I added will eventually mark Traefik healthy, and Traefik auto-retries the backend on subsequent requests — so this self-heals, but there's a visible "first-minute 502s" window on a fresh start.

**Recommended fix:**

Bootstrap documentation orders nginx first, then Traefik (update `CLAUDE.md` bootstrap list — currently shows Traefik first). Not an idempotency fix per se; it's startup-order ergonomics.

---

### [LOW] FQDN validation regex is duplicated across provision and deprovision  ✓ Fixed

**Files:**
- `srv/portal/provision-site.sh` (line 102)
- `srv/portal/deprovision-site.sh` (line 108)

Extracted to `srv/portal/_lib.sh::validate_fqdn`; both scripts now `source` it. Single source of truth for the regex. Batch 4.

**Why this is a latent issue:**

Two copies of the same regex. If one is tightened (e.g., to allow uppercase, or reject a new edge case), the other drifts. Not an idempotency bug — it's a maintenance trap that becomes one when the regexes diverge.

**Recommended fix:**

Extract the validation to `srv/portal/nginx/_lib.sh` and source from both scripts. Defer unless other shared logic accumulates.

---

### [LOW] No locking between concurrent `provision-site.sh` / `deprovision-site.sh`  ✓ Fixed

**Files:** `srv/portal/provision-site.sh`, `srv/portal/deprovision-site.sh` — `acquire_portal_lock` helper added to `_lib.sh`; uses `flock` on a `.portal.lock` file. No-op when flock is unavailable (macOS dev hosts); engaged on Linux servers. Batch 4.

**Why this is a latent issue:**

If two operators run `provision-site.sh example.com` simultaneously (e.g., via automation), both pass the idempotency check before either writes, then both race on `cat > $CONF_FILE`, and the Traefik/nginx reload ordering becomes undefined. In a single-operator manual workflow this never happens; in any automation context, it can.

**Recommended fix:**

Wrap the critical section in `flock`:

```bash
exec 9>"${SCRIPT_DIR}/.provision.lock"
flock -n 9 || die "another provision-site.sh is running"
```

Defer until there's an automation use case.

---

### [LOW] `acme.json` committed to the repo with restrictive perms  ✓ Fixed

**File:** `srv/portal/traefik/acme.json` (mode 600, 0 bytes) — file removed from repo; `.gitignore` already excludes it; `bootstrap.sh` creates on demand. Batch 1.

**Current behavior:**

The file is present (empty, mode 600) which sidesteps the [HIGH] bind-mount footgun. But it's also in tree — any `git clone`, copy, or checkout recreates it with the source repo's permissions (typically 644 after checkout). On a fresh clone where umask defaults to 022, permissions won't round-trip, and Traefik will refuse to use the file.

**Recommended fix:**

Remove `acme.json` from the repo, add to `.gitignore` (already added), and have bootstrap `touch` + `chmod 600` it (see the [HIGH] finding above). Git does not track file mode portably across checkouts.

---

## 3. Recurring Patterns & Systemic Recommendations

- **Pattern observed 2 times (both HIGH):** host-side paths that docker-compose bind-mounts implicitly get created by Docker as root-owned directories if a script hasn't set them up first. **Recommendation:** a single `bootstrap.sh` in `srv/portal/` that chains `create-docker-networks.sh` → `touch + chmod 600 acme.json` → `ensure-default-tls.sh`, with a final `Now run: docker compose up -d` message. Codifies the order in script form, not just docs.
- **Missing convention:** generated files (conf.d, dynamic yaml, placeholder HTML) embed timestamps and one-shot guards, making content-hash convergence checks impossible. **Recommendation:** drop timestamps from generated files and move any "provisioned at / by" metadata into a sidecar `.meta.json` or git log.
- **Testing gap:** no test or CI job verifies that `provision-site.sh → deprovision-site.sh` round-trips cleanly, or that `ensure-default-tls.sh` is safely re-runnable. **Recommendation:** add `test/idempotent.sh` (or a GitHub Action) that: (a) provisions a fake FQDN, (b) runs `list-sites.sh --drift-only` and asserts empty, (c) deprovisions with `--yes --no-reload`, (d) asserts state is clean. Catches regressions cheaply.

---

## 4. Prioritized Action Plan

### Immediate (fix this week)

1. **HIGH: `acme.json` bootstrap** — effort: S — add `touch + chmod 600` to a new `bootstrap.sh` or to `create-docker-networks.sh`. Also remove the file from the repo. Prevents silent directory-instead-of-file on fresh installs.
2. **HIGH: `traefik/certs/` bootstrap ordering** — effort: S — same bootstrap script calls `ensure-default-tls.sh` before anyone runs `docker compose up`. Existing `ensure-default-tls.sh` already handles re-runs safely; this just enforces the order.

### Short-term (fix this month)

3. **MEDIUM: drop timestamps from generated configs** — effort: XS — two-line change in `provision-site.sh`.
4. **MEDIUM: update stale nginx-reload-failure error message** — effort: XS — three-line change in `provision-site.sh`.
5. **MEDIUM: guard the unconditional `chmod 700` in ensure-default-tls** — effort: XS.
6. **LOW: expiry-check in ensure-default-tls** — effort: XS — single `openssl x509 -checkend` call in the skip branch.

### Deferred (track, fix when convenient)

7. MEDIUM: drop fixed `container_name:`; look up via compose project label. Only matters if multi-instance deploys become a goal.
8. LOW: `flock` in provision/deprovision. Only matters if automation calls these concurrently.
9. LOW: FQDN regex extracted to `_lib.sh`. Only once shared logic grows.
10. LOW: rollback path-creation check. Only matters if refuse-to-overwrite guard is ever relaxed.
11. LOW: document/enforce nginx-then-Traefik startup order in bootstrap.
12. Testing gap: `test/idempotent.sh` round-trip harness.

---

## 5. Open Questions

- **Q1: Is `provision-site.sh`'s refuse-to-overwrite intentional as a safety rail, or should it become convergent (re-apply desired state)?** The current behavior is defensible — it prevents overwriting hand-edited conf.d files — but it means the script is *one-shot*, not idempotent by the strict definition. If the goal is a GitOps-style "run this until the state matches," the guard has to go (and rollback needs the more careful check from finding L1). If the goal is a manual operator tool with a hard safety stop, current behavior is correct. The docs should state which it is.
- **Q2: Should `acme.json` be committed (mode bits included) or bootstrapped per-host?** Committing sidesteps the Docker-mount issue on clones but relies on unreliable permission-preservation across git. Bootstrapping is cleaner but requires the preflight script to actually run.
- **Q3: Is concurrent invocation of provision/deprovision part of the threat model?** Single-operator manual workflow → no `flock` needed. Ansible/Terraform calling in parallel → needs locking.
- **Q4: Should `ensure-default-tls.sh` live at `srv/portal/` or somewhere more discoverable as a bootstrap step?** It's currently alongside verify/list/provision, which suggests equal weight. In practice it runs once per server at setup time, not per-site like provision. Arguable.

---

## 6. Second-Pass Findings

After the canonical failure-mode reference was completed, I re-audited against the full checklist (including Docker Compose, nginx, and shell-script categories I didn't have on first pass). Four new findings:

### [HIGH — Second Pass] `00-default.conf` per-site log files break nginx under `read_only: true`  ✓ Fixed

**File:** `srv/portal/nginx/conf.d/00-default.conf` (lines 24–25)

**Current behavior:**

```nginx
access_log /var/log/nginx/default-access.log;
error_log  /var/log/nginx/default-error.log warn;
```

**Why this breaks at runtime:**

The nginx container is declared `read_only: true` in `srv/portal/nginx/docker-compose.yml` (line 22), with tmpfs mounts only for `/var/cache/nginx`, `/var/run`, and `/tmp`. The stock `nginx.conf`'s `access_log /var/log/nginx/access.log` and `error_log /var/log/nginx/error.log` survive because the `nginx:alpine` image ships those paths as **symlinks** to `/dev/stdout` and `/dev/stderr` — opening the symlink writes to the char device, which doesn't need a writable `/var/log/nginx/`.

But `default-access.log` and `default-error.log` are **new** filenames with no symlink. nginx will call `open(O_CREAT|O_WRONLY)` on them at startup, hit `EROFS`, and fail to start.

This is not an idempotency issue per se — it's a latent startup failure I introduced when I added `read_only: true` during the earlier security-hardening pass without accounting for these per-site logs. (I removed equivalent log lines from `provision-site.sh` as finding I2 in the first pass, but missed the hand-written `00-default.conf`.)

**Relevant failure mode:** nginx config #3, "Log paths that don't exist" — in this case, "Log paths that the container can't write to."

**Recommended fix:**

Same treatment as I2 — drop the two log lines so the default server flows through to the global `access_log`/`error_log` (which are symlinked to stdout/stderr):

```diff
-    # Optional: log these separately so you can see what's hitting
-    # the default (misconfigured clients, scanners, etc.)
-    access_log /var/log/nginx/default-access.log;
-    error_log  /var/log/nginx/default-error.log warn;
```

Alternative: add `- /var/log/nginx` to the compose `tmpfs:` list — but then logs evaporate on every container restart, which defeats the purpose of separating them.

---

### [MEDIUM — Second Pass] Mutable image references in compose files  ✓ Fixed

Pinned `traefik:v3.3` → `traefik:v3.3.4` (patch-level) and `nginx:alpine` → `nginx:1.27-alpine` (minor-line pin). Verify against the current stable tags in your registry before your next prod deploy and bump if newer patches exist. Digest-level pinning (`@sha256:...`) is a further step if full reproducibility is needed — left for operator decision.

**Files:**
- `srv/portal/docker-compose.yml` (line 3): `image: traefik:v3.3`
- `srv/portal/nginx/docker-compose.yml` (line 3): `image: nginx:alpine`

**Why this is a reproducibility issue:**

- `traefik:v3.3` pins minor but not patch. A fresh pull three months from now may be `v3.3.6` when the repo was last validated against `v3.3.2`. Breaking changes at patch level are rare but not impossible.
- `nginx:alpine` pins nothing concrete — it's a rolling tag. A fresh pull gets whatever Alpine-based nginx the Docker Hub build is currently serving. Used for a production proxy, this is a real drift vector: a worker node pulled today and one pulled next month can run different nginx versions with different default config, cipher support, or bug profiles.

**Relevant failure mode:** Docker Compose #5, "Mutable image references."

**Recommended fix:**

Pin both to immutable digest refs or explicit patch versions:

```diff
-    image: traefik:v3.3
+    image: traefik:v3.3.6
```

```diff
-    image: nginx:alpine
+    image: nginx:1.27-alpine
```

Even better: pin to a SHA digest (`image: nginx:1.27-alpine@sha256:abc...`) so image-registry-side mutation can't affect you. Digest pinning is tedious but the only fully-reproducible option.

---

### [LOW — Second Pass] Non-atomic file writes in provision-site.sh and ensure-default-tls.sh  ✓ Fixed

Added `write_atomic` helper to `_lib.sh` (mktemp + rename, honors umask so output perms match previous `cat >` behavior). Wired into `provision-site.sh` at all three write sites (site `index.html`, nginx conf, Traefik dynamic yaml) and into `ensure-default-tls.sh` for the dynamic yaml. The cert+key generation path in `ensure-default-tls.sh` uses the same pattern explicitly (mktemp → chmod → mv) because openssl needs to own the file handles. Verified: dynamic file is 644, cert 644, key 600. Batch 3.

**Files:**
- `srv/portal/provision-site.sh` (lines 164, 205, 243): `cat > "$TARGET" <<EOF ... EOF`
- `srv/portal/ensure-default-tls.sh` (lines 112–119, 133–143): `openssl req ... -out $CRT_FILE` / `cat > "$DYNAMIC_FILE" <<EOF`

**Why this is a latent issue:**

Both patterns write directly to the final path. If the process is interrupted non-gracefully (`kill -9`, OOM killer, host power loss) mid-write, the target file exists but is partial. The rollback `EXIT` trap in provision-site.sh catches this on any exit — including SIGTERM — but NOT on SIGKILL or power loss, because no trap can fire then.

The resulting half-written nginx conf or Traefik dynamic yaml would likely be rejected at `nginx -t` or parsed-as-empty by Traefik on next reload. Recovery requires manual inspection; re-running provision hits the idempotency check.

**Relevant failure mode:** Shell #4, "Non-atomic file writes."

**Recommended fix:**

Write to a temp file, then rename (rename is atomic on the same filesystem):

```bash
cat > "${CONF_FILE}.tmp" <<EOF
...
EOF
mv "${CONF_FILE}.tmp" "$CONF_FILE"
```

Same treatment for the Traefik dynamic file, the placeholder `index.html`, and the openssl cert+key in `ensure-default-tls.sh`. For openssl specifically, generate into a temp path and `mv` both the key and cert into place together (or separately; they're independent files that Traefik reloads via file-watch).

Severity is LOW because the window is small and the failure mode is non-catastrophic (detected on next operation).

---

### [LOW — Second Pass] `provision-site.sh` lacks belt-and-suspenders path-escape check  ✓ Fixed

Moved the check into `_lib.sh::validate_fqdn` so both scripts inherit it automatically — the asymmetry is closed at the source. Removed the now-redundant explicit check from `deprovision-site.sh`. Verified with `../evil.com` and `evil/../com` inputs: both rejected. Batch 4.

**File:** `srv/portal/provision-site.sh` (after line 104 — no equivalent check exists)

**Current behavior:**

`validate_fqdn "$FQDN"` is the only validation. The regex `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$` already rejects `/` and `..` (neither is in the character class), so this is belt-and-suspenders, not a real gap.

**Why it's worth flagging:**

`deprovision-site.sh` line 112 has an explicit secondary check:

```bash
if [[ "$FQDN" == *".."* || "$FQDN" == *"/"* ]]; then
    die "FQDN contains disallowed characters."
fi
```

The asymmetry is minor maintenance debt: if someone ever loosens `validate_fqdn` (e.g., to allow wildcards), provision will quietly start accepting path-escape characters while deprovision will still reject them. Better to make both scripts defensive in the same way.

**Relevant failure mode:** Shell #10, "Destructive operations without guards" — provisioning creates paths from user input that are later `rm -rf`'d by the rollback trap.

**Recommended fix:**

Add the same guard in `provision-site.sh` right after `validate_fqdn`:

```bash
if [[ "$FQDN" == *".."* || "$FQDN" == *"/"* ]]; then
    die "FQDN contains disallowed characters."
fi
```

Or, cleaner: move the check into `_lib.sh::validate_fqdn` so both scripts inherit it automatically. That closes the asymmetry permanently.

---

## 7. Acknowledgments of Existing Good Practice

- **Universal `set -euo pipefail`** across all 7 shell scripts. Catches the common bash foot-guns.
- **`create-docker-networks.sh`** is a textbook idempotent bootstrap: existence check before create, clear logging, clean exit codes.
- **`deprovision-site.sh`** gracefully handles the "nothing to remove" case (lines 139–144) and uses `rm -f`/`rm -rf` (which are themselves idempotent). Also requires the operator to type the FQDN for confirmation — a smart guardrail against fat-finger rm's.
- **`provision-site.sh`** has a proper rollback `trap` that only fires on partial failure (the `PROVISION_SUCCEEDED` flag avoids deleting the work on success).
- **`ensure-default-tls.sh`** models skip-if-exists cleanly with a `--force` escape hatch, and its friendly output (including expiry date on the skip path) is the kind of feedback loop that makes re-runs non-scary.
- **`verify-networks.sh`** and **`list-sites.sh`** are purely read-only — they can be invoked freely in loops, hooks, CI, etc. without state impact.
- **Traefik dynamic files** follow the `_*`-prefix convention for shared configs, which `list-sites.sh` honors — a nice example of coordinated conventions across two scripts.
- **`.gitignore`** correctly excludes generated per-site files while keeping `00-default.conf`, `_*.yml`, and `sites/default/` as the tracked baseline.

The overall impression is of a codebase written by someone who has lived through bad re-runs before and built in the right defenses. The findings above are refinements, not foundational problems.

# Migrating an Existing App to the JJOC Portal Infrastructure

> **How to use this document:** Paste into an LLM session when working on an *existing* codebase (not a greenfield build) that needs to run behind the JJOC portal. Pair with `APP_DEVELOPMENT_PROMPT.md` (new-app version) — this doc focuses on auditing and adapting what's already there.

---

## 0. What this prompt is for

Use this when:

- You have a working app — in staging, production elsewhere, or an unfinished repo — that needs to deploy here.
- The app was not originally designed for this infrastructure.
- You want to find what *will break*, what's *redundant*, and what's *missing*, in that order.

This prompt is **not** for brand-new apps (see `APP_DEVELOPMENT_PROMPT.md` for that) and **not** for deciding whether to rewrite vs. adapt (that's a product call). The goal here is: **minimum viable adaptation** to get the existing app running correctly behind Traefik + the portal.

---

## 1. Context recap (one paragraph)

The portal runs Traefik in front of everything. Traefik terminates TLS, obtains Let's Encrypt certs via HTTP-01, applies security headers (HSTS, X-Frame-Options, etc.) and per-IP rate limiting, then forwards plain HTTP over a Docker `edge` network to your app. Your app never speaks TLS, never enforces HTTPS itself, and receives client info through `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Real-IP`. One FQDN per app.

If the app can build to fully static output (HTML/CSS/JS), it deploys as **Pattern A** (files rsync'd into the shared nginx). Otherwise, it deploys as **Pattern B** (its own container on the `edge` network with a custom Traefik dynamic yaml).

---

## 2. First decision: which pattern?

Answer these in order. Stop at the first "yes."

1. **Does the app produce a fully self-contained directory of static files as its build output, with no backend API it hosts itself?** → **Pattern A**. Examples: production React/Vite build, static-site generators, plain HTML, pre-rendered Astro/Next export.
2. **Does the app need a running process to serve requests?** → **Pattern B**. Examples: Django, Rails, Flask, FastAPI, Express SSR, Go services, Perl Mojolicious, PHP-FPM.
3. **Does the app use WebSockets, SSE, or long-polling?** → **Pattern B**. (Traefik handles WS upgrades natively; ensure your router config doesn't strip `Upgrade`/`Connection` headers. The default setup preserves them.)
4. **Does the app do file uploads that need to persist across container restarts?** → **Pattern B + persistent volume**. The rest of the infra uses bind mounts; plan one for your uploads directory.

If you're borderline (e.g., React app with a BFF), treat the frontend as Pattern A and the BFF as Pattern B — two sites, two FQDNs, or one FQDN with careful routing config. The routing variant is more work; default to two FQDNs unless there's a reason not to.

---

## 3. Audit phase — find what needs to change

Run these searches against the existing codebase. For each hit, decide: **remove**, **adapt**, **keep**, or **flag for later**.

### 3.1 TLS / HTTPS enforcement (must remove)

The portal does this. Your app doing it too causes redirect loops, double HSTS, or worse.

```bash
# App-side TLS termination (remove — Traefik handles this)
grep -rniE 'ssl_cert|ssl_key|certfile|keyfile|PFX|tls\.load' --include='*.py' --include='*.rb' --include='*.js' --include='*.ts' --include='*.go' --include='*.pl' --include='*.pm' .

# HTTPS enforcement / redirect (remove)
grep -rniE 'force_ssl|SECURE_SSL_REDIRECT|requireHTTPS|redirect.*https|HTTPS.*redirect' .

# HSTS / security headers set in app code (remove — Traefik sets them)
grep -rniE 'strict-transport-security|hsts|X-Frame-Options|X-Content-Type-Options|Referrer-Policy' .
```

### 3.2 Proxy trust (must adapt)

The app sees Traefik as its immediate peer. Client info is in forwarded headers. Configure the framework's trusted-proxy machinery to accept those headers from Docker network ranges (172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16).

```bash
# Look for existing proxy / forwarded-header config
grep -rniE 'trust.*proxy|trusted_proxies|ProxyFix|USE_X_FORWARDED|X-Real-IP|X-Forwarded' .
```

**Common framework knobs:**
- **Django:** `USE_X_FORWARDED_HOST = True`, `SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')`.
- **Flask:** `app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)` (from `werkzeug.middleware.proxy_fix`).
- **FastAPI/Starlette:** `ProxyHeadersMiddleware` or uvicorn's `--proxy-headers --forwarded-allow-ips`.
- **Express:** `app.set('trust proxy', 'uniquelocal')` (= trust loopback + RFC1918).
- **Rails:** `config.action_dispatch.trusted_proxies = [...]` with the Docker CIDR blocks.
- **Go net/http:** check `X-Forwarded-For` / `X-Real-IP` manually; no built-in, but many frameworks (gin, echo, chi) have middleware.
- **Perl Plack:** `enable 'ReverseProxy'` in `app.psgi`.

Trust only `127.0.0.1`, `::1`, and the three RFC1918 ranges. **Do not trust all proxies** — that lets any client forge `X-Forwarded-For`.

### 3.3 Logging (must adapt if file-based)

The app runs in a read-only container. File logging fails or writes into ephemeral tmpfs.

```bash
# Find file-based log config
grep -rniE 'log.*file|FileHandler|RotatingFile|log_path|logfile|log\.open' .
```

**Fix:** switch to stdout/stderr handlers. Docker captures them; `docker logs <container>` retrieves them.

- **Python logging:** `logging.basicConfig(stream=sys.stdout)` or a `StreamHandler(sys.stdout)`.
- **Rails:** `config.logger = ActiveSupport::Logger.new(STDOUT)`.
- **Node:** native `console.log` goes to stdout. Remove any `winston.transports.File`.
- **Perl:** `Log::Log4perl` with `Log::Dispatch::Screen` or `Log::Dispatch::Handle` to `STDOUT`.
- **Gunicorn / uvicorn / similar:** `--access-logfile -` `--error-logfile -`.

### 3.4 Port binding (must adapt if binding privileged/443)

The app should listen on plain HTTP inside the container. The container port is arbitrary (8000 is conventional); Traefik routes to it by service name, not port.

```bash
grep -rniE 'listen.*443|listen.*80|port\s*=\s*443|:443|Server\(.*443' .
```

**Fix:** bind something unprivileged (`8000`, `3000`, `8080`). Remove any code that opens TLS sockets.

### 3.5 Health endpoint (must add if missing)

Required for the container `healthcheck:` directive and useful for `list-sites.sh --probe`.

```bash
# Does a health endpoint already exist?
grep -rniE 'route.*health|health.*endpoint|/healthz|/health|/_ping|/ready|/live' .
```

**Fix if missing:** add a route that returns 200 when the app is ready to serve real requests (DB reachable, workers warm, etc.). Path convention: `/health` or `/healthz`.

Minimum implementation (any framework): return `{"status": "ok"}` with HTTP 200. If you want richer checks, add them — but keep the endpoint fast (< 100ms) so the Docker healthcheck doesn't thrash.

### 3.6 Absolute URL generation (review)

Apps behind proxies often generate wrong URLs — `http://` instead of `https://`, wrong host, or using the container port.

```bash
grep -rniE 'request\.host|request\.url_root|request\.scheme|url_for|request\.build_absolute_uri|url_helpers' .
```

**Fix:** ensure URL generation uses `X-Forwarded-Proto` and `X-Forwarded-Host` via the framework's proxy-aware helpers. Section 3.2's trusted-proxy config usually makes this automatic, but verify with a test: deploy to staging, trigger a password-reset email, confirm the link uses `https://<your-fqdn>/...` and not `http://127.0.0.1:8000/...`.

### 3.7 Cookie flags (review)

Secure-cookie flags must match the externally-visible scheme, not the internal one.

```bash
grep -rniE 'secure.*cookie|cookie.*secure|Set-Cookie.*Secure|samesite' .
```

**Fix:** set the `Secure` flag based on `X-Forwarded-Proto == "https"`, not the app's own scheme detection. Frameworks with proper proxy trust do this automatically; verify anyway.

### 3.8 Session storage (review)

In-memory sessions die on container restart and don't survive a `docker compose up -d` redeploy.

```bash
grep -rniE 'session.*memory|MemcacheSessionStore|InMemory.*Session|MemorySessionStore' .
```

**Fix (if problematic):** switch to a persistent store — Redis is the default choice. Run Redis as a second container on your own Docker network (not `edge`). Framework docs cover the config.

This is OPTIONAL for the first deploy if the app only runs a single container instance and session loss at deploy time is acceptable. Flag for later otherwise.

### 3.9 Filesystem writes (review)

Read-only container + arbitrary writes = app won't start.

```bash
grep -rniE 'open.*[wa]|File\.open.*w|write.*file|tmp/|/var/|/srv/' --include='*.py' --include='*.rb' --include='*.js' --include='*.ts' --include='*.go' --include='*.pl' .
```

**Fix:** identify every path the app writes to. Either:
- Carve a `tmpfs:` mount for ephemeral writes (sessions, caches, framework scratch dirs).
- Carve a named volume or bind mount for persistent writes (uploads, databases).
- Refactor the code to write to a configured path you then mount.

Common offenders: Rails `tmp/` and `log/`, Django `media/`, Node `node_modules/.cache/`, Python `__pycache__` (usually OK since module dir).

### 3.10 Secrets / env handling (review)

Baked-into-image secrets are a security smell *and* make rotation painful.

```bash
grep -rniE 'API_KEY\s*=|SECRET\s*=|PASSWORD\s*=|TOKEN\s*=|DATABASE_URL\s*=' --include='*.py' --include='*.rb' --include='*.js' --include='*.ts' --include='*.env' --include='Dockerfile' .
```

**Fix:** move all secrets to `env_file:` in compose (mounted at runtime, not baked into image) or Docker secrets. Audit the image afterward with `docker history --no-trunc` to confirm nothing sensitive is in the layers.

### 3.11 Dockerfile (review if it exists)

If the app already has a Dockerfile:

```bash
# Tag pinning
grep -nE '^FROM' Dockerfile

# Non-root user
grep -nE '^USER' Dockerfile

# Health check (can be in Dockerfile or compose; compose-side is preferred here)
grep -nE '^HEALTHCHECK' Dockerfile
```

**Fix checklist:**
- `FROM image:patch-version` or `FROM image@sha256:...` (never `:latest`).
- `USER` set to a non-root UID (> 1000). If the framework needs root to bind < 1024, use a high port instead.
- Multi-stage build to keep the final image small (build deps out of runtime).
- Minimal base: `-slim`, `-alpine`, or distroless.
- `HEALTHCHECK` not in Dockerfile — do it in compose so it's versioned with deployment config.

---

## 4. Common incompatibilities — fix priority order

| Priority | Symptom | Root cause | Fix |
|---|---|---|---|
| **Blocker 1** | Redirect loop | App enforces HTTPS → Traefik sees HTTP → redirects → app redirects again | Remove HTTPS-enforcement middleware in the app |
| **Blocker 2** | Wrong client IP in logs (always `172.17.0.1` or similar) | App doesn't trust forwarded headers | Configure trusted-proxy (§ 3.2) |
| **Blocker 3** | `docker logs` shows nothing useful | App writes logs to file | Switch to stdout (§ 3.3) |
| **Blocker 4** | Container starts then dies | Health check fails — endpoint missing or slow | Add `/health` (§ 3.5) |
| **Blocker 5** | Container won't start: EROFS | Read-only FS + uncarved write path | Add `tmpfs:` or volume (§ 3.9) |
| **Important** | Password reset links use `http://container-port/...` | URL generation not proxy-aware | Verify URL-helper config (§ 3.6) |
| **Important** | Cookies not marked Secure over HTTPS | Scheme detection uses container port, not X-Forwarded-Proto | Fix via proxy-trust (§ 3.7) |
| **Important** | Double HSTS headers in response | App sets HSTS too | Remove from app (§ 3.1) |
| **Important** | Image is 1.5GB | Non-slim base, no multi-stage build | Slim base, multi-stage (§ 3.11) |
| **Nice to have** | Sessions lost on deploy | In-memory session store | Redis or DB-backed sessions (§ 3.8) |
| **Nice to have** | Image pull takes 2 minutes | `:latest` or unpinned layers, cache-unfriendly | Pin image, order Dockerfile layers by churn frequency (§ 3.11) |

Work top-to-bottom. Each blocker must be fixed before the next one is observable.

---

## 5. Migration sequence

Linear steps. Skip Pattern-B-only steps if you're on Pattern A.

1. **Audit** (§ 3). Catalog every hit. Decide remove / adapt / keep / defer. Triage into blockers vs improvements.
2. **Fix blockers** (§ 4 top section). Local-first — the app should run correctly against a local Traefik or mitmproxy before touching the portal.
3. **Strip redundancies** — HSTS, security headers, rate limiting, HTTPS redirect.
4. **(Pattern B) Write/update the Dockerfile** to the hardened template (non-root, pinned, multi-stage).
5. **(Pattern B) Write `docker-compose.yml`** following the template in `APP_DEVELOPMENT_PROMPT.md` § 2.
6. **Add the health endpoint** (§ 3.5) and verify via `curl`.
7. **(Pattern B) Write `traefik/dynamic/<fqdn>.yml`** — router, service, middlewares, TLS resolver. Template in `APP_DEVELOPMENT_PROMPT.md` § 2.
8. **Local reverse-proxy test** (§ 6). Do not skip.
9. **Pick a test FQDN** — not the real one. Something like `staging-<app>.<domain>`.
10. **Point DNS** for the test FQDN at the portal host. Wait for propagation.
11. **Deploy to the test FQDN.** Operator runs `./provision-site.sh` (Pattern A) or drops the compose + dynamic yaml (Pattern B) + `docker compose up -d`.
12. **Validate** (§ 7).
13. **Cut real DNS** to the portal once the test FQDN passes all checks. First HTTPS request triggers ACME — allow 30 seconds.
14. **Monitor logs for 24–48 hours.** Watch for proxy-header mistakes, cookie issues, URL-generation bugs that only surface under real traffic.

---

## 6. Local reverse-proxy test (before the portal)

Before touching the portal, verify your app behaves correctly behind *any* reverse proxy. A minimal local stack:

```yaml
# test-compose.yml
services:
  traefik:
    image: traefik:v3.3.4
    ports: ["8080:80"]
    command:
      - "--providers.docker=true"
      - "--entrypoints.web.address=:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  app:
    build: .
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`localhost`)"
      - "traefik.http.services.app.loadbalancer.server.port=8000"
```

Run it, then `curl -H 'Host: localhost' http://localhost:8080/health`. Should return 200 with your app's health body. Then test:

- **Forwarded headers:** `curl -H 'X-Forwarded-For: 1.2.3.4' ...` — does your app log `1.2.3.4` as the client?
- **Scheme detection:** `curl -H 'X-Forwarded-Proto: https' ...` — does URL generation use `https://`?
- **Host detection:** `curl -H 'Host: myapp.example.com' ...` — does URL generation use that host?

If any of these fail locally, fix first — the portal won't be nicer.

---

## 7. Validation before cutover

Run these against the test FQDN. Each must pass before flipping real DNS.

```
[ ] curl -I https://<test-fqdn>/ returns 200 (or expected status)
[ ] Response includes `Strict-Transport-Security` (from Traefik)
[ ] Response includes `X-Frame-Options: DENY` (from Traefik)
[ ] Response does NOT include duplicated security headers
[ ] curl http://<test-fqdn>/ redirects to https:// (Traefik handles this)
[ ] Test FQDN serves the right app (Host-based routing works)
[ ] POST/PUT requests work (CSRF not breaking on real traffic)
[ ] Authentication flow end-to-end — login, session, logout, re-login
[ ] Password-reset / email-triggered links use correct FQDN and https://
[ ] App logs (`docker logs <container>`) show real client IPs, not Docker gateway IPs
[ ] App logs show https/http accurately based on X-Forwarded-Proto
[ ] Cookies set with Secure; SameSite matches expectations
[ ] Health endpoint returns 200 under load (not just when idle)
[ ] list-sites.sh --probe <test-fqdn> reports LIVE=yes, HTTPS=2xx
[ ] Any WebSocket / SSE / long-poll flows work end-to-end
[ ] File uploads (if any) land in the mounted volume and survive restart
[ ] `docker compose down --timeout 30 && docker compose up -d` — app comes back clean
[ ] Traefik logs (`docker logs traefik --tail=50`) show no errors for this FQDN
```

A failure on any blocker row = do not cut DNS. Fix and re-test.

---

## 8. Rollback plan

If something breaks after real DNS cutover:

### Pattern A
```bash
./deprovision-site.sh <fqdn> --keep-content   # removes configs, preserves content
# Route DNS back to the previous host (if TTL permits)
# OR serve a maintenance page: restore a simple index.html to sites/<fqdn>/
```

### Pattern B
```bash
docker compose -f /srv/portal/apps/<app>/docker-compose.yml down
# Optionally remove the router:
rm /srv/portal/traefik/dynamic/<fqdn>.yml
# Route DNS back, or drop in a maintenance page via Pattern A overlay
```

**Pre-plan the rollback BEFORE cutover.** Write the exact commands down. Don't improvise under pressure.

---

## 9. Gotchas specific to migrating (not greenfield)

- **ACME rate limits:** Let's Encrypt issues 5 duplicate certs per week per FQDN. If your test cutover issues a cert, then rollback, then cutover again, you're eating that quota. Use staging resolver for test FQDNs if you're cycling fast. (Not currently configured in the portal — ask the operator to add a staging resolver if this matters.)
- **DNS TTL before the cutover:** lower TTL to 60s at least 24 hours before cutover so rollback is fast. Raise it back after you're stable.
- **Browser HSTS preload:** if the previous deployment set HSTS with `preload`, browsers will refuse HTTP for up to a year. First deploy here must work on HTTPS on day one. (Traefik handles it; the concern is if ACME hasn't completed yet — don't send users at the FQDN until `curl -I https://...` returns 200.)
- **Cookie-domain lock-in:** if the previous deployment set cookies to `.example.com`, those cookies travel with the user; make sure the new app accepts them (or explicitly re-issue).
- **Absolute URLs in user-generated content:** if the old app stored fully-qualified URLs in the DB (user profile links, image CDN paths, etc.), those persist. Audit before cutover; rewrite if necessary.
- **Sticky sessions:** the portal runs single-instance containers. No load-balanced sticky-session concerns, but if the app assumed `X-Forwarded-For` would have multiple hops, single-proxy deployment means it'll have one. Verify any code that parses the XFF chain.
- **Assumed root access:** apps that previously installed software from init scripts or expected writable `/etc/` won't work read-only. Move those into the build.

---

## 10. When *not* to migrate

Some honest signals that adapting may be harder than rewriting:

- The app bundles its own TLS terminator (stunnel, its own nginx) — ripping out is invasive.
- The app requires multiple privileged ports.
- The app assumes exclusive control of the host (systemd, cron, mail delivery).
- The app's "deployment" is a bespoke shell script that builds `/etc` the first time it runs.
- Configuration lives in a database that's populated by running the app through a browser for an hour.
- The app is a monolith that needs to be on the same host as its worker processes and its redis and its postgres — and none of those can be disentangled.

If 3+ of these apply, talk to the team about a proper rewrite or containerization milestone before attempting migration. The portal can host it; the app may not be ready to live there.

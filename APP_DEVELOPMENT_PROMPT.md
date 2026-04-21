# Building an App for the JJOC Portal Infrastructure

> **How to use this document:** Paste the contents into the top of a new LLM session, share with a developer starting a new app, or keep in the repo as a reference. It tells you *exactly* what constraints to design around so the app slots into the existing deployment without rework.
>
> **Adapting an existing app?** Use `APP_MIGRATION_PROMPT.md` instead — it focuses on auditing and retrofitting a codebase that already exists. This doc assumes you're starting fresh.
>
> **Path convention.** Where this doc mentions `/srv/portal/`, treat it as a conventional example — the portal's scripts resolve their own directory at runtime and work at any checkout path (`/srv/ai/portal/`, `/opt/portal/`, etc.). Operators substitute the real path when running commands.

---

## 1. What you're deploying into

Your app will run on a single Docker host behind a shared **Traefik + nginx** fronting layer. The topology:

```
  Internet (:80, :443)
        │
        ▼
   ┌────────────────────────────────────┐
   │  Traefik v3.3.4 container          │
   │  - Terminates TLS                  │
   │  - Redirects :80 → :443            │
   │  - Obtains Let's Encrypt certs     │
   │    (HTTP-01 challenge, per FQDN)   │
   │  - Applies security headers + rate │
   │    limiting to all routed traffic  │
   └────────────┬───────────────────────┘
                │ Docker network: `edge` (plain HTTP)
                ▼
   ┌────────────────────────────────────┐
   │  Your app (OR the shared nginx)    │
   └────────────────────────────────────┘
```

**You never speak TLS.** Traefik handles that. Your app receives plain HTTP over an internal Docker network. You trust the headers Traefik sets.

---

## 2. Two deployment patterns — pick one

### Pattern A — **Static site** (recommended when possible)

**Use when:** your app produces a built artifact of static files (HTML/CSS/JS/images). This includes SPA bundles (React/Vite, Vue, Svelte), static site generators (Astro, Eleventy, Hugo, Jekyll), or plain HTML.

**What you ship:** a directory of files. That's it.

**How it deploys:**
1. Operator runs `./provision-site.sh myapp.example.com` on the host.
2. Your build output gets `rsync`'d into `$PORTAL_DIR/nginx/sites/myapp.example.com/`.
3. The shared nginx serves it. No container, no process management.

**Your job:** ensure `npm run build` (or equivalent) produces a self-contained directory with an `index.html` at the root.

**SPA routing:** if your app uses client-side routing (React Router, Vue Router), tell the operator to provision with `--spa`. That adds `try_files $uri $uri/ /index.html;` so deep links work.

### Pattern B — **Dynamic app** (runtime-rendered or API-backed)

**Use when:** your app needs a running process to handle each request. This includes Django/Flask/FastAPI, Express/Next.js SSR, Rails, Go services, Perl Mojolicious/Plack/Mason, PHP-FPM setups.

**What you ship:** a Docker image plus a small deployment bundle.

**How it deploys:**
1. Your image runs as a container named `app-<slug>` on the `edge` Docker network.
2. The operator drops a Traefik dynamic config file (`traefik/dynamic/<fqdn>.yml`) that routes `Host(\`<fqdn>\`)` to your container.
3. Traefik handles TLS and forwarding.

**Deployment bundle template for your app** (provide these to the operator):

`docker-compose.yml` for your app:
```yaml
services:
  app:
    image: your-registry/your-app:1.2.3   # PIN TO A DIGEST OR PATCH VERSION
    container_name: app-myapp             # unique per app
    restart: unless-stopped
    networks: [edge]
    security_opt: ["no-new-privileges:true"]
    cap_drop: [ALL]
    read_only: true
    tmpfs: ["/tmp"]                       # plus any dirs your app writes to
    mem_limit: 512m
    cpus: 1.0
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8000/health"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 10s
    # If you have secrets, use Docker secrets or env files — NOT ENV in compose
    env_file: .env

networks:
  edge:
    external: true
```

`traefik/dynamic/<fqdn>.yml` for the operator:
```yaml
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
      entrypoints:
        - websecure
      service: myapp
      middlewares:
        - security-headers@file
        - rate-limit@file
      tls:
        certResolver: letsencrypt
```

---

## 3. Hard constraints (apply to both patterns)

These are non-negotiable. The deployment assumes them.

1. **HTTP only from your process.** Never speak TLS. Never try to bind port 443. Listen on HTTP inside the container (any port you want — 8000 is conventional). Traefik terminates TLS on the way in.

2. **Do not redirect HTTP to HTTPS yourself.** Traefik's `:80` entrypoint already does an unconditional redirect. If your app does it too, you create a redirect loop or double redirect.

3. **Trust the forwarded headers, but only from Docker networks.** Your app sees real client info in:
   - `X-Forwarded-For` — client IP (and proxy chain)
   - `X-Forwarded-Proto` — `https` (always, after Traefik)
   - `X-Forwarded-Host` — original Host header
   - `X-Real-IP` — client IP (single value)

   Configure your framework to trust these **only when the immediate peer is inside RFC1918** (172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16 — the Docker bridge ranges).

   Framework examples:
   - **Django:** `USE_X_FORWARDED_HOST = True`; `SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')`.
   - **Flask:** `app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)`.
   - **Express:** `app.set('trust proxy', 'uniquelocal')`.
   - **Rails:** `config.action_dispatch.trusted_proxies` set to the Docker ranges.
   - **Perl/Plack:** `Plack::Middleware::ReverseProxy`.

4. **Log to stdout and stderr.** Do not write logs to files inside the container — the container is (or should be) read-only. Docker captures stdout/stderr; `docker logs <container>` retrieves them.

5. **Use one FQDN per app.** The infrastructure routes by `Host()` header. Serving multiple apps off one FQDN via path prefixes is possible but adds complexity to your Traefik config — prefer one FQDN per app.

6. **Do not block `/.well-known/acme-challenge/*`.** Let's Encrypt HTTP-01 requires those paths to be reachable over plain HTTP. Traefik handles the challenge itself, but if your app overwrites that route, cert renewals break. (Most frameworks won't; just don't add a catchall that swallows it.)

7. **Health check endpoint.** Dynamic apps must expose a health-check path (e.g. `/health` or `/_health`) that returns 2xx when the app is healthy. This is referenced in the compose `healthcheck` block and also useful for the operator's `list-sites.sh --probe` diagnostics.

8. **Pin your image.** `image: myapp:1.2.3` or better, `image: myapp:1.2.3@sha256:...`. Never `:latest`. Matches the portal's existing patch-pinned Traefik (`v3.3.4`) and minor-pinned nginx (`1.27-alpine`).

9. **Harden the container.** `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, resource limits. Use `tmpfs:` for any directory the app writes to at runtime (session dirs, cache, etc.). If you can't go read-only, document why.

10. **Join only the `edge` network** (unless you need backend services). The `edge` network is the channel between Traefik and nginx — and now you. If your app needs a database or cache, create a second Docker network for that internal traffic and attach your app + those services to it, keeping backend traffic off `edge`.

---

## 4. What the infrastructure provides (do NOT duplicate)

Traefik already applies these middlewares to every routed app:

- **HTTP→HTTPS redirect** on port 80.
- **TLS 1.2+ with curated cipher suites.**
- **HSTS** (`Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`).
- **`X-Content-Type-Options: nosniff`**
- **`X-Frame-Options: DENY`**
- **`X-XSS-Protection`** (legacy but set)
- **`Referrer-Policy: strict-origin-when-cross-origin`**
- **`X-Permitted-Cross-Domain-Policies: none`**
- **Rate limiting** — 100 req/sec average, 200 burst, per-IP.
- **Let's Encrypt cert issuance and auto-renewal.**

**Your app should not re-add any of these.** Do not set HSTS from your app (Traefik does it and double-setting can cause quirky behavior). Do not add `X-Frame-Options` in app code. Do not try to implement rate limiting in your framework (you'd be rate-limiting after Traefik already did).

**If you need to override one** (e.g., allow `frame-ancestors` for embedding), tell the operator — they'll write a custom middleware for your FQDN.

---

## 5. What the infrastructure does NOT provide (you MUST handle)

The portal does routing + TLS + headers + rate limiting. That's it. Everything else is your responsibility:

- **Authentication and authorization.**
- **Session storage** — you pick Redis, Postgres, cookies, etc.
- **Database and data stores** — you run these as separate containers on your own Docker network.
- **Internal service-to-service discovery** — use Docker DNS (service/container names) on your own network; don't expose internal APIs on `edge`.
- **CSRF protection** — frameworks usually handle this; make sure it's on.
- **Content Security Policy** — set via your app response; Traefik doesn't.
- **Backups** — of your data, your container images, your config.
- **Observability** beyond Docker logs — if you need metrics, dashboards, tracing, run your own.
- **Scaling / multiple instances** — the portal runs single instances. If you need horizontal scaling, that's a larger architectural change (reach for k8s/nomad).

---

## 6. Security posture the app is expected to carry

- **Secrets:** never bake into the image. Use env files mounted at runtime (`env_file:`), Docker secrets, or a KMS/vault.
- **CSRF:** enabled by default in your framework. If you disable it for an API, authenticate requests some other way (tokens, OAuth).
- **Input validation:** at the edge of every handler.
- **Dependency pinning:** lockfiles committed, automated update PRs, security-advisory watch.
- **Minimal base image:** `alpine`, `-slim`, or distroless where practical. Smaller = less attack surface = faster pulls.
- **Run as non-root** inside the container. Use a dedicated user (UID > 1000).

---

## 7. Concrete checklist — use this while building

Copy this into your new project's README or ticket. Tick each item before the first deploy.

```
[ ] App speaks HTTP only; no TLS code, no binding :443.
[ ] No HTTP-to-HTTPS redirect in the app.
[ ] Trusted-proxy config added for the framework.
[ ] All logs go to stdout/stderr.
[ ] Health-check endpoint implemented (returns 2xx when healthy).
[ ] Dockerfile pinned to an image digest or patch version.
[ ] `docker-compose.yml` uses `networks: [edge]` with edge as external.
[ ] Compose has read_only: true and tmpfs for any writable paths.
[ ] Compose has cap_drop: [ALL] + no-new-privileges.
[ ] Compose has mem_limit / cpus bounds.
[ ] Compose healthcheck calls the app's /health endpoint.
[ ] Secrets via env_file or Docker secrets — never in the image.
[ ] App runs as a non-root user inside the container.
[ ] `traefik/dynamic/<fqdn>.yml` drafted for the operator (dynamic pattern).
[ ] The FQDN chosen and DNS records will point at the portal host.
[ ] Build output tested locally via `curl -H 'Host: <fqdn>' ...`.
[ ] No HSTS / X-Frame-Options / rate-limit code in the app.
[ ] CSRF enabled, input validation at handler boundaries.
[ ] README documents: how to run locally, how to build the image, how to deploy.
```

---

## 8. Handoff to the operator

When your app is ready, hand the operator:

1. **The FQDN** you want (e.g., `myapp.jjocllc.com`).
2. **DNS confirmation** — the A/AAAA record points at the portal host's public IP. Traefik's Let's Encrypt HTTP-01 challenge requires this *before* the first deploy.
3. **For Pattern A (static):** a tarball or git repo URL of the build output.
4. **For Pattern B (dynamic):**
   - Your image pull reference (`registry/myapp:1.2.3`)
   - `docker-compose.yml` for your app
   - `traefik/dynamic/<fqdn>.yml` router + service definition
   - Any `.env` file (via secure channel) or Docker secrets list
   - A one-page runbook: how to check logs, how to restart, how to roll back

The operator will:

- **Pattern A:** run `./provision-site.sh <fqdn>` and rsync your build in.
- **Pattern B:** drop your compose in, add the dynamic yaml, `docker compose up -d`, verify with `./list-sites.sh --probe`.

Both patterns get Let's Encrypt certs automatically on first HTTPS request. That may take 10–30 seconds the first time as Traefik completes the ACME dance.

---

## 9. Operational gotchas (read once, save pain)

- **Port 80 must stay reachable** for Let's Encrypt HTTP-01 renewals. Don't ask the operator to firewall it off — renewals will silently fail ~60 days later.
- **No wildcard certs.** The portal uses HTTP-01, which doesn't support wildcards. Each subdomain needs its own provisioning run.
- **DNS must resolve *before* the first deploy.** If you provision a site before DNS propagates, you'll get cert issuance failures and 502s until it catches up.
- **Cold starts:** on the very first request after a cert is issued, Traefik may take a few seconds. Not a bug, just the ACME round-trip.
- **Read-only container + framework quirks:** frameworks like Rails or Django may try to write to `tmp/` by default. Carve out `tmpfs:` mounts for those paths.
- **Container logs are Docker's source of truth.** If your app writes to a log file inside the container, you'll never see those logs — they evaporate on restart.
- **One operator at a time:** the portal's provision/deprovision scripts take a flock; two parallel deploys on the same host will block. This is by design.

---

## 10. Quick-reference: the deployment conversation

When the operator asks "how do I add your app?", the answer should be one of these two templates:

**Pattern A:**
> "It's static. Run `./provision-site.sh myapp.example.com` (or add `--spa` if it's an SPA), then rsync the contents of my `dist/` directory into `srv/portal/nginx/sites/myapp.example.com/`. DNS is already pointed."

**Pattern B:**
> "It's a container. Here's the image reference and two yaml files — the `docker-compose.yml` for the app and the `traefik/dynamic/myapp.example.com.yml` for the router. Drop them both into place, `docker compose -f myapp/docker-compose.yml up -d`, and verify with `./list-sites.sh --probe`. DNS is already pointed."

If either answer feels wrong, the app is probably not structured for this deployment — re-check sections 2–3.

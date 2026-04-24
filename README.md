# Traefik + nginx Multi-Site Provisioning Toolkit

A single-host, multi-tenant web hosting stack built on **Traefik** (TLS termination + routing) in front of **nginx** (static content). Provisioning, drift detection, auditing, and operational tooling come as shell scripts that follow a strict three-artifact-per-site invariant and leave the system in a consistent state on any failure.

## What you get

- **One Traefik instance** handling TLS for many FQDNs, with Let's Encrypt certificates obtained automatically via HTTP-01.
- **One nginx instance** serving static content (built SPA output, HTML, assets) per FQDN.
- **Ten shell scripts** that manage the full site lifecycle: bootstrap a host, provision/deprovision sites atomically, detect drift, verify container wiring, regenerate the default TLS cert, tail logs, and route everything through an interactive menu with an audit log.
- **Hardened containers**: read-only root filesystems, dropped capabilities, `no-new-privileges`, healthchecks, resource limits, image pinning.
- **Complete documentation** spanning architecture, operator procedures, AI context, app-development briefings, and a full idempotency audit.

## Installation

### Fresh server — one-line install (recommended)

Single-command install. Self-elevates via sudo, checks dependencies, creates the `portal` service user, installs systemd units, runs bootstrap, optionally provisions a first site:

```bash
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh | bash
```

Interactive prompts drive everything (install dir, ACME email, first FQDN, optional OAuth). Same paired teardown:

```bash
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/teardown.sh | bash
```

### Passing flags — download first

`bash -s -- --flag VALUE` doesn't cleanly forward through curl-pipe, so when you need flags (e.g. `--restore-acme` / `--backup-acme` for cert preservation across a reinstall), download first:

```bash
# Install with an acme.json restored from a prior teardown
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh --restore-acme /var/backups/portal-acme-<ts>.json

# Teardown with an explicit backup path
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/teardown.sh -o /tmp/teardown.sh
sudo bash /tmp/teardown.sh --backup-acme=/var/backups/portal-acme-pre-upgrade.json
```

> **Before first deploy:** ensure DNS for your FQDNs points at the host *before* provisioning — ACME HTTP-01 validation needs the hostname to resolve. `install.sh` asks for your Let's Encrypt contact email and patches it into `traefik/traefik.yml` for you; you don't need to edit files manually.

### Local development / manual install

For a dev machine or custom install where you want to drive each step yourself:

```bash
git clone <this-repo> /srv/portal
cd /srv/portal

# One-shot host setup (idempotent — safe to re-run)
./bin/bootstrap.sh

# Start the stacks (nginx first so Traefik finds a ready backend)
docker compose -f nginx/docker-compose.yml up -d
docker compose up -d

# Interactive menu (recommended operator entry point; writes audit log)
./bin/menu.sh

# Or invoke scripts directly:
./bin/provision-site.sh myapp.example.com
./bin/list-sites.sh
./bin/verify-networks.sh
```

Replace the `letsencrypt@example.com` placeholder in `traefik/traefik.yml` before starting Traefik (it only matters once you're issuing real certs, but easy to forget later).

## Documentation map

| Document | Audience | Purpose |
|---|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Human operators, new engineers | System topology, request flow, file layout, the three-artifact invariant, idempotency model, security hardening |
| [SCRIPTS_GUIDE.md](SCRIPTS_GUIDE.md) | Infrastructure engineers | Per-script reference, operator workflows, troubleshooting, extending the toolkit |
| [APP_DEVELOPMENT_PROMPT.md](APP_DEVELOPMENT_PROMPT.md) | App developers (greenfield) | Hard constraints for new apps deploying here; paste into an LLM to anchor design |
| [APP_MIGRATION_PROMPT.md](APP_MIGRATION_PROMPT.md) | App developers (existing apps) | Audit-then-migrate checklist for adapting existing apps to this infra |
| [IDEMPOTENCY_AUDIT.md](IDEMPOTENCY_AUDIT.md) | Anyone curious about rationale | Full audit trail — 16 findings, 15 resolved, 1 deferred-by-design with reasoning |
| [CLAUDE.md](CLAUDE.md) | AI assistants | Terse, opinionated context for AI pair-programming sessions |
| [SECURITY.md](SECURITY.md) | Security researchers | Disclosure policy, supported versions |

## Design principles

- **Three-artifact invariant per site.** A site is exactly `nginx/conf.d/<fqdn>.conf` + `nginx/sites/<fqdn>/` + `traefik/dynamic/<fqdn>.yml`. Provisioning is atomic across all three; missing any one is "drift" and caught by `list-sites.sh`.
- **Path-agnostic scripts.** Every script self-locates via `$BASH_SOURCE`. Works at `/srv/portal/`, `/opt/portal/`, `~/work/portal/` — any clone location.
- **Atomic file writes.** Generated configs go through `write_atomic` (mktemp → rename) so SIGKILL or power loss can never leave a half-written conf that crashes nginx.
- **Rollback on partial failure.** `provision-site.sh` installs an EXIT trap that removes any artifacts it created if `nginx -t` fails. Next run finds a clean slate.
- **Flock-based mutex.** Concurrent provision/deprovision invocations serialize safely; never race on the same FQDN.
- **Bash 3.2 compatible.** Every script parses and runs on stock macOS bash 3.2 (dev) and modern bash 4+ (prod).
- **Full audit trail.** `menu.sh` writes every session and every action to `logs/menu.log` — metadata format, greppable, pid-grouped for session reconstruction.

## Status

Single-host, single-operator design. Production-hardened for a small portfolio of static sites and (with operator-provided compose + Traefik dynamic yaml) dynamic containerized apps.

Not included: multi-host orchestration, wildcard certs (HTTP-01 only), centralized log aggregation, built-in monitoring beyond Docker healthchecks. See `ARCHITECTURE.md §13` for the full list of deliberate tradeoffs.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contributor guide — local setup with `pre-commit`, bash 3.2 portability expectations, commit conventions, and what gets merged. Security vulnerabilities: [SECURITY.md](SECURITY.md) (private disclosure, not a public issue).

## License

MIT — see [LICENSE](LICENSE).

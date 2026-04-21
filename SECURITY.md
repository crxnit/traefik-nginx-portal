# Security Policy

## Supported Versions

This project is a single-branch toolkit with no formal release cadence. Security fixes are applied to `main` and backported on request.

| Branch | Status |
|---|---|
| `main` | Actively maintained; security fixes land here first |
| tagged releases | If/when tagged, the most recent tag receives security patches |

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, email a description to **the repository maintainer** via the contact email listed on the GitHub profile associated with this repo's primary maintainer. Include:

- A clear description of the issue.
- Steps to reproduce, ideally as a minimal proof-of-concept.
- The commit SHA or release tag you reproduced against.
- Your assessment of the severity (informational / low / medium / high / critical).
- Whether you intend to disclose publicly, and on what timeline.

You should receive an acknowledgement within **5 business days**. If the issue is confirmed, a fix will typically land within 30 days for high/critical issues and on a best-effort basis for lower-severity issues. You'll be credited in the commit message and release notes unless you request anonymity.

## Scope

In scope:

- Code injection via the `provision-site.sh` / `deprovision-site.sh` FQDN argument.
- Path traversal via any user-supplied argument.
- Privilege escalation within the portal containers.
- Authentication/authorization weaknesses in the audit log.
- Secrets leakage via logs, error messages, or commit history.
- Race conditions in the provision/deprovision flow that could yield inconsistent state.
- Misconfiguration in shipped Traefik / nginx templates that weakens the default security posture (e.g., missing security headers, improperly scoped rate limits).

Out of scope:

- Issues in third-party images (Traefik, nginx, OpenSSL, etc.) — report those to their respective maintainers. If our pinned version is affected by a disclosed CVE, file an issue and we'll update the pin.
- DoS via legitimate traffic that the rate-limit middleware's documented tuning cannot absorb — tune for your deployment.
- Certificate-trust issues for the default self-signed cert — it's self-signed by design (see `ARCHITECTURE.md §13`).
- Compromise of the host OS or Docker daemon.

## Disclosure Policy

I follow **coordinated disclosure**: reports are acknowledged privately, fixed in a private branch if necessary, then merged and announced simultaneously. I aim to credit reporters publicly; please let me know if you prefer anonymity.

If a 90-day window elapses without a fix and you wish to disclose publicly, please give 14 days of written notice so I can prepare a statement.

## Operator Responsibilities

This toolkit ships templates with placeholders (e.g., `letsencrypt@example.com` in `traefik/traefik.yml`). **Operators must replace these with real values** before deploying. Failure to do so is not a vulnerability in this codebase — it's a deployment error. The per-site files (ACME state, private keys, generated configs) are gitignored and must be kept out of version control on your deployment.

See `ARCHITECTURE.md §10` for the shipped security posture and `IDEMPOTENCY_AUDIT.md` for a full rationale of hardening decisions.

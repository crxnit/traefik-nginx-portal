# CrowdSec AppSec/WAF (optional)

Adds a [CrowdSec](https://crowdsec.net) Security Engine in front of portal sites:
an **AppSec/WAF** (SQLi, XSS, path traversal, RCE, CVE virtual-patching) plus
**IP-reputation** blocking. Ported from the archived `traefik-docker-hosting-2026`
and adapted to this stack (Traefik v3.3 file-provider, read-only rootfs, external
`traefik` network).

**It is OFF by default** — the base `docker-compose.yml`, `traefik.yml`, and the
running proxy are unchanged until you complete the steps below. Everything ships
disabled (`.example` suffixes + a commented plugin block) so an un-wired state
can't error the live proxy.

## How it fits together

```
client ─▶ Traefik ──(bouncer plugin)──▶ CrowdSec :7422 (AppSec/WAF)   inline, per request
                  └─(bouncer plugin)──▶ CrowdSec :8080 (LAPI)          IP-reputation decisions
                                            ▲
                  Traefik access.log ───────┘ (optional behavioral scenarios)
```

- **AppSec/WAF** works inline and needs **no access log**.
- **Behavioral scenarios** (brute force, scanners) need Traefik's access log as a
  **file** — an optional add-on (step 6).
- The plugin authenticates to CrowdSec with a **bouncer API key**, read from a
  mounted file (`crowdsecLapiKeyFile`) — Traefik's file provider does not
  interpolate `${ENV}` in dynamic YAML, and the key must never be committed.

## Files this feature adds

| File | Purpose |
|------|---------|
| `docker-compose.crowdsec.yml` | The `crowdsec` service + a writable `/plugins-storage` volume for Traefik |
| `traefik/crowdsec/acquis.d/appsec.yaml` | AppSec/WAF acquisition (active when crowdsec runs) |
| `traefik/crowdsec/acquis.d/traefik.yaml.example` | Access-log acquisition (rename to activate — step 6) |
| `traefik/dynamic/_crowdsec.yml.example` | The `crowdsec-appsec` / `crowdsec-ip-only` middlewares (rename to activate) |
| `traefik/crowdsec/lapi-key` | **gitignored** — operator-created bouncer key file |
| commented block in `traefik/traefik.yml` | The `experimental.plugins.bouncer` declaration |

## Enable

All commands run from the install dir as the portal user.

```bash
# 1. Generate one bouncer key; it goes in BOTH places (same value).
KEY=$(openssl rand -hex 32)
install -m 600 /dev/null traefik/crowdsec/lapi-key
printf '%s' "$KEY" > traefik/crowdsec/lapi-key

# 2. Tell compose to include the overlay, and hand the key to the crowdsec
#    service for bouncer pre-registration. Append to .env (mode 600):
{
  echo "COMPOSE_FILE=docker-compose.yml:docker-compose.crowdsec.yml"
  echo "CROWDSEC_BOUNCER_API_KEY=$KEY"
} >> .env

# 3. Declare the plugin: uncomment the experimental.plugins.bouncer block at the
#    bottom of traefik/traefik.yml.

# 4. Activate the middlewares.
mv traefik/dynamic/_crowdsec.yml.example traefik/dynamic/_crowdsec.yml

# 5. Bring it up (systemd path shown; or `docker compose up -d`).
sudo systemctl restart portal-traefik
docker compose logs -f traefik crowdsec   # watch plugin download + crowdsec start
```

Then attach the WAF to a site by adding `crowdsec-appsec@file` to its middleware
chain in `traefik/dynamic/<fqdn>.yml` (regenerated sites: add it in the
`provision-site.sh` middleware list), e.g.:

```yaml
      middlewares:
        - security-headers@file
        - crowdsec-appsec@file      # full WAF + IP reputation
        - rate-limit@file
```

Use `crowdsec-ip-only@file` for internal/low-risk sites that don't need AppSec.

## Step 6 — optional behavioral detection (access-log scenarios)

```bash
# In traefik/traefik.yml replace `accessLog: {}` with:
#   accessLog:
#     filePath: /var/log/traefik/access.log
# Mount ./logs:/var/log/traefik (rw) on the traefik service (base compose),
# then:
mv traefik/crowdsec/acquis.d/traefik.yaml.example traefik/crowdsec/acquis.d/traefik.yaml
sudo systemctl restart portal-traefik
```

## Verify / operate

```bash
docker exec crowdsec cscli bouncers list     # traefik-bouncer should be present + valid
docker exec crowdsec cscli metrics           # AppSec + parser activity
docker exec crowdsec cscli decisions list    # active blocks
docker exec crowdsec cscli decisions add --ip 1.2.3.4 --duration 4h   # manual test block
```

## Disable / roll back

Remove the two lines from `.env` (or drop `docker-compose.crowdsec.yml` from
`COMPOSE_FILE`), re-comment the plugin block in `traefik.yml`, rename
`_crowdsec.yml` back to `.example`, remove `crowdsec-*@file` from any site, and
`systemctl restart portal-traefik`. Delete the `crowdsec_*` volumes to purge state.

## Notes

- Pinned plugin `maxlerebourg/crowdsec-bouncer-traefik-plugin@v1.4.7` (the version
  carried over from `traefik-docker-hosting-2026`); supports Traefik v3.x. Bump
  deliberately and re-test against this stack's Traefik version.
- Declaring the plugin makes Traefik **download + compile it at startup**, so the
  container needs egress and the `traefik_plugins` volume (provided by the
  overlay) for its read-only rootfs.
- `crowdsecAppsecUnreachableBlock: true` **fails closed** — if CrowdSec is down,
  protected requests are blocked. Flip to `false` (fail-open) if availability of
  the protected site matters more than the WAF during a CrowdSec outage.

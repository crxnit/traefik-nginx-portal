#!/usr/bin/env bash
#
# provision-site.sh — Provision a new static site in the nginx stack.
#
# Creates:
#   - conf.d/<fqdn>.conf          (nginx server block)
#   - sites/<fqdn>/index.html     (placeholder content)
#   - dynamic/<fqdn>.yml          (Traefik dynamic routing config)
#
# Then tests and reloads nginx.
#
# Usage:
#   ./provision-site.sh <fqdn> [--spa] [--no-reload] [--traefik-dir <path>]
#
# Examples:
#   ./provision-site.sh myapp.example.com
#   ./provision-site.sh app.example.com --spa
#   ./provision-site.sh landing.example.com --traefik-dir /opt/traefik/dynamic

set -euo pipefail

# --- Configuration ---------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"
# Non-script paths are resolved against $PORTAL_DIR (set by _lib.sh).
NGINX_DIR="${PORTAL_DIR}/nginx"
CONF_D="${NGINX_DIR}/conf.d"
SITES_DIR="${NGINX_DIR}/sites"
TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-${PORTAL_DIR}/traefik/dynamic}"
NGINX_CONTAINER="${NGINX_CONTAINER:-nginx}"
CERT_RESOLVER="${CERT_RESOLVER:-letsencrypt}"
NGINX_SERVICE_NAME="$PORTAL_NGINX_SERVICE_NAME"  # from _lib.sh; must match _shared-services.yml

# --- Argument parsing ------------------------------------------------------

FQDN=""
SPA_MODE=false
DO_RELOAD=true

usage() {
    cat <<EOF
Usage: $0 <fqdn> [options]

Options:
  --spa               Configure the site with SPA fallback (try_files ... /index.html)
  --no-reload         Skip nginx config test and reload
  --traefik-dir DIR   Override Traefik dynamic config directory
  -h, --help          Show this help

Environment variables:
  TRAEFIK_DYNAMIC_DIR  Alternative way to set Traefik dynamic dir (default: ./traefik/dynamic)

Notes:
  FQDN must be lowercase, DNS-legal, and contain at least one dot. Wildcards
  (*.example.com) and IDN/punycode labels (xn--*) are not supported — encode
  them manually and bypass validation if you need them.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          usage ;;
        --spa)              SPA_MODE=true; shift ;;
        --no-reload)        DO_RELOAD=false; shift ;;
        --traefik-dir)      TRAEFIK_DYNAMIC_DIR="$2"; shift 2 ;;
        --*)                die "Unknown option: $1" ;;
        *)
            if [[ -z "$FQDN" ]]; then
                FQDN="$1"
                shift
            else
                die "Unexpected argument: $1"
            fi
            ;;
    esac
done

[[ -z "$FQDN" ]] && die "FQDN is required. Run with --help for usage."

# --- Validation ------------------------------------------------------------

validate_fqdn "$FQDN" || die "Invalid FQDN: '$FQDN'. Must be lowercase, contain at least one dot, and follow DNS naming rules."

acquire_portal_lock "$PORTAL_DIR"

# Check required directories exist
[[ -d "$CONF_D" ]]   || die "nginx conf.d directory not found: $CONF_D"
[[ -d "$SITES_DIR" ]] || die "nginx sites directory not found: $SITES_DIR"

if [[ ! -d "$TRAEFIK_DYNAMIC_DIR" ]]; then
    log_warn "Traefik dynamic dir not found: $TRAEFIK_DYNAMIC_DIR"
    log_warn "Skipping Traefik dynamic file creation. Use --traefik-dir to override."
    TRAEFIK_DYNAMIC_DIR=""
fi

# Paths derived from FQDN
CONF_FILE="${CONF_D}/${FQDN}.conf"
SITE_DIR="${SITES_DIR}/${FQDN}"
TRAEFIK_FILE="${TRAEFIK_DYNAMIC_DIR:+${TRAEFIK_DYNAMIC_DIR}/${FQDN}.yml}"

# Idempotency: check for existing files
existing=()
[[ -e "$CONF_FILE" ]] && existing+=("$CONF_FILE")
[[ -e "$SITE_DIR"  ]] && existing+=("$SITE_DIR")
[[ -n "$TRAEFIK_FILE" && -e "$TRAEFIK_FILE" ]] && existing+=("$TRAEFIK_FILE")

if [[ ${#existing[@]} -gt 0 ]]; then
    log_error "The following paths already exist:"
    for p in "${existing[@]}"; do log_error "  - $p"; done
    die "Refusing to overwrite. Remove them first or choose a different FQDN."
fi

# --- Rollback trap ---------------------------------------------------------
# Track paths this run creates so a partial failure can be rolled back.
# Without this, a failed `nginx -t` leaves artifacts on disk and the next
# run refuses to proceed because of the idempotency check above.

CREATED_PATHS=()
PROVISION_SUCCEEDED=false

rollback() {
    $PROVISION_SUCCEEDED && return 0
    [[ ${#CREATED_PATHS[@]} -eq 0 ]] && return 0
    log_warn "Rolling back partial provision for $FQDN"
    for p in "${CREATED_PATHS[@]}"; do
        if [[ -d "$p" ]]; then
            rm -rf "$p" && log_warn "  removed: $p"
        elif [[ -e "$p" ]]; then
            rm -f "$p"  && log_warn "  removed: $p"
        fi
    done
}
trap rollback EXIT

# --- Provisioning ----------------------------------------------------------

log_info "Provisioning site: $FQDN"

# 1. Create the site content directory with a placeholder index.html
log_info "Creating content directory: $SITE_DIR"
mkdir -p "$SITE_DIR"
CREATED_PATHS+=("$SITE_DIR")

write_atomic "${SITE_DIR}/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${FQDN}</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; margin: 0; background: #f5f5f5; color: #333;
    }
    .container { text-align: center; padding: 2rem; max-width: 500px; }
    h1 { margin-bottom: 0.5rem; }
    p { color: #666; line-height: 1.5; }
    code { background: #eee; padding: 2px 6px; border-radius: 3px; }
  </style>
</head>
<body>
  <div class="container">
    <h1>${FQDN}</h1>
    <p>This site has been provisioned but content has not yet been deployed.</p>
    <p>Content root: <code>/var/www/${FQDN}</code></p>
  </div>
</body>
</html>
EOF
log_ok "Content directory created with placeholder index.html"

# 2. Create the nginx server block
log_info "Creating nginx config: $CONF_FILE"

if $SPA_MODE; then
    TRY_FILES_LINE='try_files $uri $uri/ /index.html;'
    MODE_COMMENT='# SPA fallback — unmatched paths return index.html'
else
    TRY_FILES_LINE='try_files $uri $uri/ =404;'
    MODE_COMMENT='# Static site — unmatched paths return 404'
fi

write_atomic "$CONF_FILE" <<EOF
# ${FQDN}

server {
    listen 80;
    server_name ${FQDN};

    root /var/www/${FQDN};
    index index.html;

    # Cache static assets aggressively
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    ${MODE_COMMENT}
    location / {
        ${TRY_FILES_LINE}
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }
}
EOF
CREATED_PATHS+=("$CONF_FILE")
log_ok "nginx config written"

# 3. Create the Traefik dynamic config (if dynamic dir available)
if [[ -n "$TRAEFIK_FILE" ]]; then
    log_info "Creating Traefik dynamic config: $TRAEFIK_FILE"

    # Router name: replace dots with hyphens for a valid Traefik identifier
    ROUTER_NAME="${FQDN//./-}"

    write_atomic "$TRAEFIK_FILE" <<EOF
# ${FQDN}

http:
  routers:
    ${ROUTER_NAME}:
      rule: "Host(\`${FQDN}\`)"
      entrypoints:
        - websecure
      service: ${NGINX_SERVICE_NAME}
      middlewares:
        - security-headers@file
        - rate-limit@file
      tls:
        certResolver: ${CERT_RESOLVER}
EOF
    CREATED_PATHS+=("$TRAEFIK_FILE")
    log_ok "Traefik dynamic config written"
else
    log_warn "Skipped Traefik dynamic config (no dynamic dir)"
fi

# 4. Test and reload nginx
if $DO_RELOAD; then
    if ! nginx_reload "$NGINX_CONTAINER"; then
        log_error "Rollback will clean up the partial provision."
        log_error "Fix the underlying config issue and re-run: $(basename "$0") $FQDN"
        exit 1
    fi
else
    log_info "Skipped nginx reload (--no-reload)"
fi

# --- Summary ---------------------------------------------------------------

PROVISION_SUCCEEDED=true
echo
log_ok "Site '$FQDN' provisioned successfully."
echo
echo "  nginx conf:      $CONF_FILE"
echo "  content dir:     $SITE_DIR"
[[ -n "$TRAEFIK_FILE" ]] && echo "  traefik dynamic: $TRAEFIK_FILE"
echo
echo "Next steps:"
echo "  - Deploy content to: $SITE_DIR"
echo "  - Verify DNS points $FQDN to this server"
echo "  - Test: curl -I https://$FQDN"

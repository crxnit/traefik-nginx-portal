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
#                              [--oauth] [--oauth-provider=<name>]
#                              [--oauth-public=/a,/b,...]
#
# Examples:
#   ./provision-site.sh myapp.example.com
#   ./provision-site.sh app.example.com --spa
#   ./provision-site.sh landing.example.com --traefik-dir /opt/traefik/dynamic
#   ./provision-site.sh api.example.com --oauth
#   ./provision-site.sh api.example.com --oauth --oauth-public=/healthz,/webhooks/
#   ./provision-site.sh app.acme.com --oauth-provider=acme   # second sidecar

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
OAUTH_MODE=false
# OAUTH_PROVIDER selects which forward-auth sidecar's middleware to attach.
# Empty = the default `oauth-google-forward-auth@file` (the original sidecar
# defined in _oauth.yml). Non-empty = `oauth-google-forward-auth-<name>@file`,
# which assumes the operator has stood up a sibling sidecar per CLAUDE.md
# "Adding a second OAuth client" / "Adding a second provider later" pattern.
OAUTH_PROVIDER=""
OAUTH_PUBLIC_PATHS=""

usage() {
    cat <<EOF
Usage: $0 <fqdn> [options]

Options:
  --spa                      Configure the site with SPA fallback (try_files ... /index.html)
  --no-reload                Skip nginx config test and reload
  --traefik-dir DIR          Override Traefik dynamic config directory
  --oauth                    Protect the whole site with OAuth (Google Workspace)
  --oauth-provider=NAME      Use sibling forward-auth sidecar's middleware
                             (oauth-google-forward-auth-NAME@file). Implies
                             --oauth. Default attaches the original
                             oauth-google-forward-auth@file.
  --oauth-public=/a,/b,...   Comma-separated PathPrefixes exempt from OAuth (implies --oauth)
  -h, --help                 Show this help

Environment variables:
  TRAEFIK_DYNAMIC_DIR  Alternative way to set Traefik dynamic dir (default: ./traefik/dynamic)

Notes:
  FQDN must be lowercase, DNS-legal, and contain at least one dot. Wildcards
  (*.example.com) and IDN/punycode labels (xn--*) are not supported — encode
  them manually and bypass validation if you need them.

  --oauth requires OAuth to be configured in \$PORTAL_DIR/.env — see install.sh
  output or CLAUDE.md "OAuth protection" section for setup.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          usage ;;
        --spa)              SPA_MODE=true; shift ;;
        --no-reload)        DO_RELOAD=false; shift ;;
        --traefik-dir)      TRAEFIK_DYNAMIC_DIR="$2"; shift 2 ;;
        --oauth)            OAUTH_MODE=true; shift ;;
        # --oauth-provider=NAME (preferred) and --oauth-provider NAME both
        # imply --oauth. NAME is the suffix on the sibling sidecar's middleware
        # (oauth-google-forward-auth-NAME@file).
        --oauth-provider=*) OAUTH_MODE=true; OAUTH_PROVIDER="${1#*=}"; shift ;;
        --oauth-provider)   OAUTH_MODE=true; OAUTH_PROVIDER="$2"; shift 2 ;;
        # Accept both `--oauth-public=VAL` (preferred) and `--oauth-public VAL`
        --oauth-public=*)   OAUTH_MODE=true; OAUTH_PUBLIC_PATHS="${1#*=}"; shift ;;
        --oauth-public)     OAUTH_MODE=true; OAUTH_PUBLIC_PATHS="$2"; shift 2 ;;
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

# --- OAuth public-path validation ------------------------------------------
# Each prefix must start with "/" and must not contain backticks (the
# Traefik rule syntax uses them to delimit values, and we don't want
# operator input breaking out of the quoted value into arbitrary rule
# syntax). Rejected early so a typo here fails before we write any files.

OAUTH_PUBLIC_PATHS_ARRAY=()
if [[ -n "$OAUTH_PUBLIC_PATHS" ]]; then
    $OAUTH_MODE || die "--oauth-public requires --oauth"
    IFS=',' read -r -a OAUTH_PUBLIC_PATHS_ARRAY <<< "$OAUTH_PUBLIC_PATHS"
    for _path in "${OAUTH_PUBLIC_PATHS_ARRAY[@]}"; do
        [[ -z "$_path" ]] && die "Empty entry in --oauth-public list"
        case "$_path" in
            /*) ;;
            *) die "Public path must start with '/': '$_path'" ;;
        esac
        case "$_path" in
            *'`'*) die "Public path cannot contain backticks: '$_path'" ;;
        esac
    done
fi

# --- OAuth provider name validation ---------------------------------------
# NAME is interpolated into a Traefik middleware reference and (in the
# next-steps message) into the operator-facing setup hint, so we restrict
# to lowercase alphanumeric + hyphens, no leading/trailing hyphens, max 32
# chars. Same character class the existing middleware names use; matches
# the convention in _oauth-<name>.yml.
if [[ -n "$OAUTH_PROVIDER" ]]; then
    $OAUTH_MODE || die "--oauth-provider requires --oauth"
    if [[ ! "$OAUTH_PROVIDER" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]]; then
        die "Invalid --oauth-provider name: '$OAUTH_PROVIDER'. Must be lowercase alphanumeric with optional hyphens (no leading/trailing hyphens), max 32 chars."
    fi
fi

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

    # Middleware list for the primary/protected router. OAuth is appended
    # (not prepended) so rate-limit runs before auth — brute-force against
    # the forward-auth endpoint is capped by our rate limiter.
    MIDDLEWARES="        - security-headers@file
        - rate-limit@file"
    if $OAUTH_MODE; then
        # Default sidecar's middleware unless --oauth-provider=<name> picks
        # a sibling sidecar (oauth-google-forward-auth-<name>@file).
        if [[ -n "$OAUTH_PROVIDER" ]]; then
            OAUTH_MIDDLEWARE="oauth-google-forward-auth-${OAUTH_PROVIDER}@file"
        else
            OAUTH_MIDDLEWARE="oauth-google-forward-auth@file"
        fi
        MIDDLEWARES="${MIDDLEWARES}
        - ${OAUTH_MIDDLEWARE}"
    fi

    # Dual-router mode: one high-priority "public" router for OAuth-exempt
    # PathPrefixes, one low-priority catchall with OAuth. Priorities are
    # explicit so the precedence is unambiguous (Traefik's default rule-
    # length tiebreak would likely pick the right one, but explicit > lucky).
    PUBLIC_ROUTER=""
    MAIN_PRIORITY_LINE=""
    if [[ ${#OAUTH_PUBLIC_PATHS_ARRAY[@]} -gt 0 ]]; then
        # Build the PathPrefix OR-chain: PathPrefix(`/a`) || PathPrefix(`/b`)
        _path_rule=""
        for p in "${OAUTH_PUBLIC_PATHS_ARRAY[@]}"; do
            if [[ -z "$_path_rule" ]]; then
                _path_rule="PathPrefix(\`${p}\`)"
            else
                _path_rule="${_path_rule} || PathPrefix(\`${p}\`)"
            fi
        done
        # Wrap in parens when >1 prefix, so && binds tighter than ||
        [[ ${#OAUTH_PUBLIC_PATHS_ARRAY[@]} -gt 1 ]] && _path_rule="(${_path_rule})"

        PUBLIC_ROUTER="    ${ROUTER_NAME}-public:
      rule: \"Host(\`${FQDN}\`) && ${_path_rule}\"
      priority: 100
      entrypoints:
        - websecure
      service: ${NGINX_SERVICE_NAME}
      middlewares:
        - security-headers@file
        - rate-limit@file
      tls:
        certResolver: ${CERT_RESOLVER}
"
        MAIN_PRIORITY_LINE="      priority: 10
"
    fi

    write_atomic "$TRAEFIK_FILE" <<EOF
# ${FQDN}

http:
  routers:
${PUBLIC_ROUTER}    ${ROUTER_NAME}:
      rule: "Host(\`${FQDN}\`)"
${MAIN_PRIORITY_LINE}      entrypoints:
        - websecure
      service: ${NGINX_SERVICE_NAME}
      middlewares:
${MIDDLEWARES}
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
if $OAUTH_MODE; then
    echo
    if [[ -n "$OAUTH_PROVIDER" ]]; then
        echo "  OAuth is enabled for this site, using sidecar '${OAUTH_PROVIDER}'"
        echo "  (middleware oauth-google-forward-auth-${OAUTH_PROVIDER}@file)."
        echo "  In the Google Cloud Console for the '${OAUTH_PROVIDER}' OAuth client"
        echo "  (whose ID is in .env as OAUTH_PROVIDERS_GOOGLE_CLIENT_ID_$(echo "$OAUTH_PROVIDER" | tr '[:lower:]-' '[:upper:]_')),"
        echo "  add this redirect URI:"
    else
        echo "  OAuth is enabled for this site. In the Google Cloud Console"
        echo "  (console.cloud.google.com → Credentials → OAuth 2.0 Client),"
        echo "  add this redirect URI to the client configured in .env:"
    fi
    echo
    echo "      https://${FQDN}/_oauth"
    echo
    if [[ ${#OAUTH_PUBLIC_PATHS_ARRAY[@]} -gt 0 ]]; then
        echo "  Public (unauthenticated) path prefixes:"
        for p in "${OAUTH_PUBLIC_PATHS_ARRAY[@]}"; do
            echo "      $p"
        done
    fi
fi

#!/usr/bin/env bash
#
# deprovision-site.sh — Remove a provisioned static site from the nginx stack.
#
# Removes:
#   - conf.d/<fqdn>.conf          (nginx server block)
#   - sites/<fqdn>/               (content directory and all contents)
#   - dynamic/<fqdn>.yml          (Traefik dynamic routing config)
#
# Then tests and reloads nginx.
#
# Usage:
#   ./deprovision-site.sh <fqdn> [--dry-run] [--yes] [--no-reload] [--keep-content] [--traefik-dir <path>]
#
# Examples:
#   ./deprovision-site.sh myapp.example.com --dry-run
#   ./deprovision-site.sh old-client.example.com
#   ./deprovision-site.sh old-client.example.com --yes  # skip confirmation

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

# --- Script-specific log helper --------------------------------------------

log_dry() { printf "${YELLOW}[DRY ]${RESET}  %s\n" "$*"; }

# --- Argument parsing ------------------------------------------------------

FQDN=""
DRY_RUN=false
SKIP_CONFIRM=false
DO_RELOAD=true
KEEP_CONTENT=false

usage() {
    cat <<EOF
Usage: $0 <fqdn> [options]

Options:
  --dry-run           Show what would be removed without doing it
  --yes, -y           Skip the confirmation prompt (use with caution)
  --no-reload         Skip nginx config test and reload
  --keep-content      Remove configs but keep the sites/<fqdn>/ directory
  --traefik-dir DIR   Override Traefik dynamic config directory
  -h, --help          Show this help

Environment variables:
  TRAEFIK_DYNAMIC_DIR  Alternative way to set Traefik dynamic dir (default: ./traefik/dynamic)

Notes:
  FQDN must match the same lowercase/DNS-legal rules as provision-site.sh.
  Wildcards and IDN/punycode labels are not supported.

Examples:
  $0 old-client.example.com --dry-run
  $0 old-client.example.com
  $0 old-client.example.com --yes --keep-content
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          usage ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --yes|-y)           SKIP_CONFIRM=true; shift ;;
        --no-reload)        DO_RELOAD=false; shift ;;
        --keep-content)     KEEP_CONTENT=true; shift ;;
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

validate_fqdn "$FQDN" || die "Invalid FQDN: '$FQDN'."

acquire_portal_lock "$PORTAL_DIR"

# Paths derived from FQDN
CONF_FILE="${CONF_D}/${FQDN}.conf"
SITE_DIR="${SITES_DIR}/${FQDN}"
TRAEFIK_FILE=""
if [[ -d "$TRAEFIK_DYNAMIC_DIR" ]]; then
    TRAEFIK_FILE="${TRAEFIK_DYNAMIC_DIR}/${FQDN}.yml"
else
    log_warn "Traefik dynamic dir not found: $TRAEFIK_DYNAMIC_DIR"
    log_warn "Will not attempt to remove a Traefik dynamic file."
fi

# --- Discover what exists --------------------------------------------------

to_remove=()
[[ -e "$CONF_FILE" ]] && to_remove+=("$CONF_FILE")

if ! $KEEP_CONTENT; then
    [[ -e "$SITE_DIR" ]] && to_remove+=("$SITE_DIR")
fi

[[ -n "$TRAEFIK_FILE" && -e "$TRAEFIK_FILE" ]] && to_remove+=("$TRAEFIK_FILE")

if [[ ${#to_remove[@]} -eq 0 ]]; then
    log_warn "Nothing to remove for '$FQDN'. All expected paths are already absent."
    if $KEEP_CONTENT && [[ -e "$SITE_DIR" ]]; then
        log_info "(Content directory $SITE_DIR exists but --keep-content is set.)"
    fi
    exit 0
fi

# --- Show plan -------------------------------------------------------------

echo
printf "${BOLD}De-provisioning plan for: %s${RESET}\n" "$FQDN"
echo
echo "The following will be ${RED}${BOLD}removed${RESET}:"
for p in "${to_remove[@]}"; do
    if [[ -d "$p" ]]; then
        size=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
        [[ -n "$size" ]] || size="?"
        printf "  - %s ${YELLOW}(directory, %s)${RESET}\n" "$p" "$size"
    else
        printf "  - %s\n" "$p"
    fi
done

if $KEEP_CONTENT && [[ -e "$SITE_DIR" ]]; then
    echo
    printf "The following will be ${GREEN}kept${RESET} (--keep-content):\n"
    printf "  - %s\n" "$SITE_DIR"
fi

echo

# --- Dry run short-circuit -------------------------------------------------

if $DRY_RUN; then
    log_dry "Dry run mode — no changes will be made."
    exit 0
fi

# --- Confirmation ----------------------------------------------------------

if ! $SKIP_CONFIRM; then
    printf "${BOLD}Type the FQDN to confirm removal:${RESET} "
    read -r confirmation
    if [[ "$confirmation" != "$FQDN" ]]; then
        die "Confirmation did not match. Aborted."
    fi
fi

# --- Execute removal -------------------------------------------------------

log_info "Removing files..."
for p in "${to_remove[@]}"; do
    if [[ -d "$p" ]]; then
        rm -rf "$p"
    else
        rm -f "$p"
    fi
    log_ok "Removed: $p"
done

# --- Test and reload nginx -------------------------------------------------

if $DO_RELOAD; then
    if ! nginx_reload "$NGINX_CONTAINER"; then
        log_error "This is unexpected — check conf.d/ for other leftover issues."
        exit 1
    fi
else
    log_info "Skipped nginx reload (--no-reload)"
fi

# --- Summary ---------------------------------------------------------------

echo
log_ok "Site '$FQDN' de-provisioned successfully."

if $KEEP_CONTENT && [[ -e "$SITE_DIR" ]]; then
    echo
    log_info "Content preserved at: $SITE_DIR"
    log_info "To remove it later: rm -rf '$SITE_DIR'"
fi

echo
echo "Reminders:"
echo "  - DNS records for $FQDN may still exist — clean up in your DNS provider."
echo "  - TLS certificate for $FQDN may be cached by Traefik's acme.json."
echo "    (Safe to leave — will expire naturally.)"

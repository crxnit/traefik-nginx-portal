#!/usr/bin/env bash
#
# ensure-default-tls.sh — Generate a self-signed default TLS cert and wire it
# into Traefik so unknown-SNI requests get YOUR cert (not Traefik's built-in).
#
# Creates (idempotent — re-run is safe):
#   - traefik/certs/default.crt        self-signed X.509 cert
#   - traefik/certs/default.key        matching private key (mode 600)
#   - traefik/dynamic/_default-tls.yml tls.stores.default.defaultCertificate
#
# After running this script you must:
#   1. Mount traefik/certs/ into the Traefik container (docker-compose.yml).
#   2. Restart Traefik so it picks up the new volume.
# The script prints the exact compose snippet to add, and skips this step
# if it detects the mount already exists.
#
# Usage:
#   ./ensure-default-tls.sh                  # safe defaults
#   ./ensure-default-tls.sh --force          # regenerate even if files exist
#   ./ensure-default-tls.sh --cn host.example --days 365 --key-size 4096

set -euo pipefail

# --- Configuration ---------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"
# Non-script paths are resolved against $PORTAL_DIR (set by _lib.sh).
TRAEFIK_DIR="${PORTAL_DIR}/traefik"
CERTS_DIR="${TRAEFIK_DIR}/certs"
DYNAMIC_DIR="${TRAEFIK_DIR}/dynamic"
COMPOSE_FILE="${PORTAL_DIR}/docker-compose.yml"

CN="default.invalid"
DAYS=3650
KEY_SIZE=2048
FORCE=false

CRT_FILE="${CERTS_DIR}/default.crt"
KEY_FILE="${CERTS_DIR}/default.key"
DYNAMIC_FILE="${DYNAMIC_DIR}/_default-tls.yml"

# --- Argument parsing ------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --cn CN             Subject Common Name for the cert (default: default.invalid)
  --days N            Cert validity in days (default: 3650, i.e. ~10 years)
  --key-size BITS     RSA key size (default: 2048)
  --force             Regenerate cert/key and rewrite dynamic file even if present
  -h, --help          Show this help

Notes:
  The CN 'default.invalid' is intentional — .invalid is RFC 2606 reserved and
  will never collide with a real hostname. Change it if you want the default
  cert to show a specific string to curious clients (e.g. your company name).
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage ;;
        --cn)           CN="$2"; shift 2 ;;
        --days)         DAYS="$2"; shift 2 ;;
        --key-size)     KEY_SIZE="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        *)              die "Unknown option: $1" ;;
    esac
done

# --- Preflight -------------------------------------------------------------

command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH."
[[ -d "$TRAEFIK_DIR" ]]  || die "Traefik directory not found: $TRAEFIK_DIR"
[[ -d "$DYNAMIC_DIR" ]]  || die "Traefik dynamic directory not found: $DYNAMIC_DIR"

[[ "$DAYS" =~ ^[0-9]+$ ]]     || die "--days must be a positive integer"
[[ "$KEY_SIZE" =~ ^[0-9]+$ ]] || die "--key-size must be a positive integer"

if [[ ! -d "$CERTS_DIR" ]]; then
    mkdir -p "$CERTS_DIR"
    chmod 700 "$CERTS_DIR"
else
    # If a previous `docker compose up` created certs/ as a root-owned empty
    # dir before this script ever ran, we cannot recover without root.
    if [[ ! -w "$CERTS_DIR" ]]; then
        die "$CERTS_DIR exists but is not writable by $(whoami). Likely created by Docker as root. Remove it (sudo rm -rf '$CERTS_DIR') and re-run."
    fi
fi

# --- Generate cert + key ---------------------------------------------------

expiry="unknown"
REGENERATE_REASON=""
if [[ -f "$CRT_FILE" && -f "$KEY_FILE" && "$FORCE" != "true" ]]; then
    expiry=$(openssl x509 -in "$CRT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
    # Regenerate if cert expires within 30 days.
    if ! openssl x509 -in "$CRT_FILE" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
        REGENERATE_REASON="expires within 30 days ($expiry)"
    fi
fi

if [[ -f "$CRT_FILE" && -f "$KEY_FILE" && "$FORCE" != "true" && -z "$REGENERATE_REASON" ]]; then
    log_skip "Cert already exists: $CRT_FILE (expires: $expiry) — use --force to regenerate"
else
    [[ -n "$REGENERATE_REASON" ]] && log_warn "Regenerating: cert $REGENERATE_REASON"
    log_info "Generating self-signed cert (CN=$CN, ${KEY_SIZE}-bit RSA, ${DAYS} days)"

    # Write to temp paths and atomically rename — prevents a half-written cert
    # or key from being served if the process dies mid-generation.
    tmp_crt="$(mktemp "${CRT_FILE}.XXXXXX")"
    tmp_key="$(mktemp "${KEY_FILE}.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_crt' '$tmp_key'" EXIT

    openssl req -x509 -nodes \
        -newkey "rsa:${KEY_SIZE}" \
        -keyout "$tmp_key" \
        -out "$tmp_crt" \
        -days "$DAYS" \
        -subj "/CN=${CN}" \
        -addext "subjectAltName=DNS:${CN}" \
        >/dev/null 2>&1

    chmod 600 "$tmp_key"
    chmod 644 "$tmp_crt"
    mv "$tmp_key" "$KEY_FILE"
    mv "$tmp_crt" "$CRT_FILE"
    trap - EXIT

    log_ok "Cert written: $CRT_FILE"
    log_ok "Key  written: $KEY_FILE (mode 600)"
fi

# --- Write Traefik dynamic config ------------------------------------------

if [[ -f "$DYNAMIC_FILE" && "$FORCE" != "true" ]]; then
    log_skip "Dynamic file already exists: $DYNAMIC_FILE — use --force to overwrite"
else
    log_info "Writing Traefik dynamic config: $DYNAMIC_FILE"
    write_atomic "$DYNAMIC_FILE" <<EOF
# Default TLS certificate for unknown SNI.
# Generated by ensure-default-tls.sh — regenerate with --force.

tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/default.crt
        keyFile: /etc/traefik/certs/default.key
EOF
    log_ok "Dynamic file written"
fi

# --- Check docker-compose mount --------------------------------------------

echo
if [[ -f "$COMPOSE_FILE" ]] && grep -q '/etc/traefik/certs' "$COMPOSE_FILE"; then
    log_ok "docker-compose.yml already mounts traefik/certs/ — no compose edit needed"
else
    log_warn "Traefik container does NOT mount the certs directory yet."
    echo
    printf "${BOLD}Add this line to the traefik service 'volumes:' in ${COMPOSE_FILE}:${RESET}\n"
    echo
    echo "      - ./traefik/certs/:/etc/traefik/certs/:ro"
    echo
    printf "Then restart Traefik:\n"
    echo
    echo "      docker compose -f \"$COMPOSE_FILE\" up -d"
fi

# --- Gitignore reminder ----------------------------------------------------

# Prefer `git rev-parse` over a hardcoded relative path so the check keeps
# working if the repo is ever restructured; fall back to the old assumption
# when git isn't available or the dir isn't a working tree.
repo_root=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PORTAL_DIR")
gitignore="${repo_root}/.gitignore"
if [[ -f "$gitignore" ]] && ! grep -q 'traefik/certs' "$gitignore"; then
    log_warn "Private key lives under traefik/certs/ — consider adding to .gitignore:"
    echo "        traefik/certs/"
fi

echo
log_ok "Default TLS cert is configured."

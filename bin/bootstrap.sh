#!/usr/bin/env bash
#
# bootstrap.sh — One-shot host setup. Run once per server before
# `docker compose up -d`.
#
# Does, in order:
#   1. Touches traefik/acme.json with mode 600 if missing.
#      (Without this, Docker's bind mount silently creates the path
#      as a root-owned directory, which breaks Traefik permanently.)
#   2. Generates a self-signed default TLS cert via ensure-default-tls.sh.
#   3. Creates the `traefik` and `edge` Docker networks (delegates).
#      This step is last because it requires a running Docker daemon;
#      the first two work even without Docker available, so you can
#      prepare host state in advance.
#   4. Prints the docker-compose command the operator should run next.
#
# Safe to re-run: each step skips itself if the work is already done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"
# $PORTAL_DIR is exported by _lib.sh (one level above bin/).
ACME_FILE="${PORTAL_DIR}/traefik/acme.json"

# Script-specific helper; others inherited from _lib.sh.
log_step() { printf "\n${BOLD}==> %s${RESET}\n" "$*"; }

# --- 1. acme.json preflight ------------------------------------------------

log_step "Ensuring traefik/acme.json exists with correct permissions"

if [[ -d "$ACME_FILE" ]]; then
    die "$ACME_FILE is a directory, not a file. Docker likely auto-created it. Remove it (sudo rm -rf '$ACME_FILE') and re-run."
fi

if [[ -f "$ACME_FILE" ]]; then
    current_mode=$(stat -f '%Lp' "$ACME_FILE" 2>/dev/null || stat -c '%a' "$ACME_FILE" 2>/dev/null || echo "unknown")
    if [[ "$current_mode" == "600" ]]; then
        log_skip "$ACME_FILE already exists with mode 600"
    else
        log_info "Fixing permissions on $ACME_FILE (was: $current_mode)"
        chmod 600 "$ACME_FILE"
        log_ok "$ACME_FILE now mode 600"
    fi
else
    log_info "Creating $ACME_FILE (mode 600)"
    touch "$ACME_FILE"
    chmod 600 "$ACME_FILE"
    log_ok "$ACME_FILE created"
fi

# --- 2. Default TLS cert ---------------------------------------------------

log_step "Ensuring default TLS certificate"
"${SCRIPT_DIR}/ensure-default-tls.sh"

# --- 3. Docker networks ----------------------------------------------------

log_step "Ensuring Docker networks"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log_skip "Docker daemon not reachable — skipping network creation."
    log_skip "Re-run $(basename "$0") once Docker is up to finish this step."
    NETWORKS_DONE=false
else
    "${SCRIPT_DIR}/create-docker-networks.sh"
    NETWORKS_DONE=true
fi

# --- 4. Next steps ---------------------------------------------------------

log_step "Bootstrap complete"
if ! $NETWORKS_DONE; then
    printf "${YELLOW}Docker networks were not created — start Docker and re-run this script.${RESET}\n"
fi
cat <<EOF

Next steps:

  # 1. Start nginx first so Traefik finds a ready backend
  docker compose -f "${PORTAL_DIR}/nginx/docker-compose.yml" up -d

  # 2. Then Traefik
  docker compose -f "${PORTAL_DIR}/docker-compose.yml" up -d

  # 3. Verify
  ${SCRIPT_DIR}/verify-networks.sh
  ${SCRIPT_DIR}/list-sites.sh

EOF

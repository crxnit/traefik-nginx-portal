#!/usr/bin/env bash
#
# ensure-networks.sh — Ensure required Docker networks exist.
# Creates the 'traefik' and 'edge' networks if they are not already present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# Networks to ensure exist
NETWORKS=("traefik" "edge")

# Verify Docker is available and the daemon is reachable
if ! command -v docker >/dev/null 2>&1; then
    log_error "docker command not found in PATH."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    log_error "Cannot connect to the Docker daemon. Is it running?"
    exit 1
fi

# Ensure each network exists
for net in "${NETWORKS[@]}"; do
    if docker network inspect "$net" >/dev/null 2>&1; then
        log_info "Network '$net' already exists — skipping."
    else
        log_warn "Network '$net' not found — creating."
        if docker network create "$net" >/dev/null; then
            log_info "Network '$net' created."
        else
            log_error "Failed to create network '$net'."
            exit 1
        fi
    fi
done

log_info "All required networks are present."

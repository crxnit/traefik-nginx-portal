#!/usr/bin/env bash
#
# verify-networks.sh — Confirm Traefik and nginx are running and
# attached to the expected Docker networks.
#
# Expected:
#   traefik -> edge, traefik
#   nginx   -> edge

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# Container -> space-separated list of expected networks.
# Names are overridable so this works alongside multiple portal deployments
# on the same host (e.g. staging + prod).
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"
NGINX_CONTAINER="${NGINX_CONTAINER:-nginx}"
declare -A EXPECTED=(
    ["$TRAEFIK_CONTAINER"]="edge traefik"
    ["$NGINX_CONTAINER"]="edge"
)

# Preflight
if ! command -v docker >/dev/null 2>&1; then
    log_error "docker command not found in PATH."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    log_error "Cannot connect to the Docker daemon. Is it running?"
    exit 1
fi

exit_code=0

for container in "${!EXPECTED[@]}"; do
    expected_networks="${EXPECTED[$container]}"

    # Check container exists
    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_error "Container '$container' does not exist."
        exit_code=1
        continue
    fi

    # Check container is running
    running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
    if [[ "$running" != "true" ]]; then
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        log_error "Container '$container' is not running (status: $status)."
        exit_code=1
        continue
    fi

    log_ok "Container '$container' is running."

    # Get actual networks (space-separated, sorted)
    actual_networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$container" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')

    # Check each expected network is attached
    missing=()
    for net in $expected_networks; do
        if ! grep -qw "$net" <<< "$actual_networks"; then
            missing+=("$net")
        fi
    done

    # Check for extra networks (informational, not a failure)
    extra=()
    for net in $actual_networks; do
        found=false
        for expected in $expected_networks; do
            if [[ "$net" == "$expected" ]]; then
                found=true
                break
            fi
        done
        [[ "$found" == "false" ]] && extra+=("$net")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_ok "Container '$container' is attached to all expected networks: $expected_networks"
    else
        log_error "Container '$container' is missing networks: ${missing[*]}"
        log_error "  (attached to: $actual_networks)"
        exit_code=1
    fi

    if [[ ${#extra[@]} -gt 0 ]]; then
        log_warn "Container '$container' is attached to unexpected networks: ${extra[*]}"
    fi
done

echo
if [[ $exit_code -eq 0 ]]; then
    log_ok "All checks passed."
else
    log_error "One or more checks failed."
fi

exit $exit_code

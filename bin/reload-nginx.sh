#!/usr/bin/env bash
#
# reload-nginx.sh — Test and gracefully reload nginx config.
# Thin wrapper around _lib.sh::nginx_reload for direct operator use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

nginx_reload "${NGINX_CONTAINER:-nginx}"

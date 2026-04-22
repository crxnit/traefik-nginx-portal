#!/usr/bin/env bash
#
# list-sites.sh — Audit all provisioned sites in the nginx stack.
#
# Reconciles three sources of truth:
#   - conf.d/<fqdn>.conf          (nginx server block)
#   - sites/<fqdn>/               (content directory)
#   - dynamic/<fqdn>.yml          (Traefik dynamic routing config)
#
# Optionally probes HTTP/HTTPS reachability.
#
# Usage:
#   ./list-sites.sh                  # basic table
#   ./list-sites.sh --probe          # include reachability checks
#   ./list-sites.sh --drift-only     # show only sites with inconsistencies
#   ./list-sites.sh --format json    # machine-readable output

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
PROBE_TIMEOUT=5

# Files in conf.d that are NOT per-site configs (e.g. default catchall)
EXCLUDED_CONFS=("00-default.conf" "default.conf")

# --- Argument parsing ------------------------------------------------------

DO_PROBE=false
DRIFT_ONLY=false
FORMAT="table"
PROBE_HOST="127.0.0.1"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --probe              Probe HTTP/HTTPS reachability for each site
  --probe-host HOST    IP to resolve each FQDN to when probing (default: 127.0.0.1).
                       Set this when running off-host to point at the Traefik IP.
  --drift-only         Show only sites with inconsistencies
  --format FMT         Output format: table (default) or json
  --traefik-dir DIR    Override Traefik dynamic config directory
  -h, --help           Show this help

Legend (table columns):
  NGINX    nginx conf file present in conf.d/
  CONTENT  sites/<fqdn>/ directory present
  TRAEFIK  Traefik dynamic file present
  LIVE     nginx container recognizes the config (if --probe)
  HTTPS    HTTPS reachable (if --probe)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          usage ;;
        --probe)            DO_PROBE=true; shift ;;
        --probe-host)       PROBE_HOST="$2"; shift 2 ;;
        --drift-only)       DRIFT_ONLY=true; shift ;;
        --format)           FORMAT="$2"; shift 2 ;;
        --traefik-dir)      TRAEFIK_DYNAMIC_DIR="$2"; shift 2 ;;
        *)                  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ "$FORMAT" == "table" || "$FORMAT" == "json" ]] || {
    echo "Invalid format: $FORMAT (use 'table' or 'json')" >&2
    exit 1
}

# --- Discovery -------------------------------------------------------------

# Collect FQDNs from all three sources, then merge into a unique sorted list.

declare -A nginx_fqdns traefik_fqdns content_fqdns

is_excluded() {
    local name="$1"
    for ex in "${EXCLUDED_CONFS[@]}"; do
        [[ "$name" == "$ex" ]] && return 0
    done
    return 1
}

# From nginx conf.d/
if [[ -d "$CONF_D" ]]; then
    while IFS= read -r f; do
        local_bname=$(basename "$f")
        is_excluded "$local_bname" && continue
        fqdn="${local_bname%.conf}"
        nginx_fqdns["$fqdn"]=1
    done < <(find "$CONF_D" -maxdepth 1 -name '*.conf' -type f 2>/dev/null)
fi

# From sites/
if [[ -d "$SITES_DIR" ]]; then
    while IFS= read -r d; do
        fqdn=$(basename "$d")
        # Skip 'default' content dir
        [[ "$fqdn" == "default" ]] && continue
        content_fqdns["$fqdn"]=1
    done < <(find "$SITES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
fi

# From Traefik dynamic/
if [[ -d "$TRAEFIK_DYNAMIC_DIR" ]]; then
    while IFS= read -r f; do
        local_bname=$(basename "$f")
        # Skip shared/special files (underscore prefix convention)
        [[ "$local_bname" == _* ]] && continue
        fqdn="${local_bname%.yml}"
        fqdn="${fqdn%.yaml}"
        traefik_fqdns["$fqdn"]=1
    done < <(find "$TRAEFIK_DYNAMIC_DIR" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f 2>/dev/null)
fi

# Merge all FQDNs
declare -A all_fqdns
for k in "${!nginx_fqdns[@]}"   ; do all_fqdns["$k"]=1; done
for k in "${!content_fqdns[@]}" ; do all_fqdns["$k"]=1; done
for k in "${!traefik_fqdns[@]}" ; do all_fqdns["$k"]=1; done

# Sorted list. Filter empty lines: when all_fqdns has no keys,
# `printf '%s\n' "${!all_fqdns[@]}"` still emits one empty line (printf
# cycles its format string once even with zero data args), which would
# slip an empty-string element into sorted_fqdns and blow up the main
# loop below on ${nginx_fqdns[""]} with "bad array subscript".
sorted_fqdns=()
while IFS= read -r fqdn; do
    [[ -z "$fqdn" ]] && continue
    sorted_fqdns+=("$fqdn")
done < <(printf '%s\n' "${!all_fqdns[@]}" | sort)

# --- Probe helpers ---------------------------------------------------------

# Check if nginx container recognizes the site (via nginx -T)
nginx_recognizes() {
    local fqdn="$1"
    docker exec "$NGINX_CONTAINER" nginx -T 2>/dev/null \
        | grep -E "^\s*server_name\s+" \
        | grep -qw "$fqdn"
}

# Probe HTTPS reachability. Curl writes "000" as %{http_code} when the
# connection fails; that's returned as-is. `|| true` keeps set -e from killing
# the function on non-zero curl exit.
probe_https() {
    local fqdn="$1"
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time "$PROBE_TIMEOUT" \
        --resolve "${fqdn}:443:${PROBE_HOST}" \
        "https://${fqdn}/" 2>/dev/null || true)
    echo "${code:-000}"
}

NGINX_RUNNING=false
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$NGINX_CONTAINER"; then
    NGINX_RUNNING=true
fi

# --- Build rows ------------------------------------------------------------

# Explicit empty init (not just `declare -a`) so `${#rows[@]}` below
# doesn't error with "unbound variable" under set -u when no sites exist.
rows=()
for fqdn in "${sorted_fqdns[@]}"; do
    has_nginx="no"
    has_content="no"
    has_traefik="no"
    live="?"
    https="?"

    [[ -n "${nginx_fqdns[$fqdn]:-}" ]]   && has_nginx="yes"
    [[ -n "${content_fqdns[$fqdn]:-}" ]] && has_content="yes"
    [[ -n "${traefik_fqdns[$fqdn]:-}" ]] && has_traefik="yes"

    if $DO_PROBE; then
        if $NGINX_RUNNING && nginx_recognizes "$fqdn"; then
            live="yes"
        else
            live="no"
        fi
        https=$(probe_https "$fqdn")
    fi

    # Determine drift: all three should be present for a healthy site
    drift="no"
    if [[ "$has_nginx" != "yes" || "$has_content" != "yes" || "$has_traefik" != "yes" ]]; then
        drift="yes"
    fi

    # Skip non-drift rows if --drift-only
    if $DRIFT_ONLY && [[ "$drift" == "no" ]]; then
        continue
    fi

    rows+=("$fqdn|$has_nginx|$has_content|$has_traefik|$live|$https|$drift")
done

# --- Output ----------------------------------------------------------------

if [[ "$FORMAT" == "json" ]]; then
    echo "["
    first=true
    for row in "${rows[@]}"; do
        IFS='|' read -r fqdn n c t l h d <<< "$row"
        $first || echo ","
        first=false
        printf '  {"fqdn":"%s","nginx":"%s","content":"%s","traefik":"%s","live":"%s","https":"%s","drift":"%s"}' \
            "$fqdn" "$n" "$c" "$t" "$l" "$h" "$d"
    done
    echo
    echo "]"
    exit 0
fi

# Table output
mark() {
    case "$1" in
        yes)  printf "${GREEN}✓${RESET}  " ;;
        no)   printf "${RED}✗${RESET}  " ;;
        "?")  printf "${DIM}-${RESET}  " ;;
        *)    printf "%s  " "$1" ;;
    esac
}

http_color() {
    local code="$1"
    case "$code" in
        2*)     printf "${GREEN}%s${RESET}" "$code" ;;
        3*)     printf "${BLUE}%s${RESET}" "$code" ;;
        4*|5*)  printf "${YELLOW}%s${RESET}" "$code" ;;
        000|"?") printf "${DIM}%s${RESET}" "$code" ;;
        *)      printf "%s" "$code" ;;
    esac
}

if [[ ${#rows[@]} -eq 0 ]]; then
    if $DRIFT_ONLY; then
        printf "${GREEN}No drift detected — all sites are consistent across nginx, content, and Traefik.${RESET}\n"
    else
        printf "${YELLOW}No sites found.${RESET}\n"
    fi
    exit 0
fi

# Header
printf "\n${BOLD}%-40s  %-5s  %-7s  %-7s"  "FQDN" "NGINX" "CONTENT" "TRAEFIK"
if $DO_PROBE; then
    printf "  %-4s  %-5s" "LIVE" "HTTPS"
fi
printf "  %s${RESET}\n" "STATUS"

# Separator
if $DO_PROBE; then
    printf "%s\n" "$(printf -- '-%.0s' $(seq 1 90))"
else
    printf "%s\n" "$(printf -- '-%.0s' $(seq 1 70))"
fi

# Rows
drift_count=0
for row in "${rows[@]}"; do
    IFS='|' read -r fqdn n c t l h d <<< "$row"
    [[ "$d" == "yes" ]] && : $((drift_count++))

    printf "%-40s  " "$fqdn"
    printf "%-5b  " "$(mark "$n")"
    printf "%-7b  " "$(mark "$c")"
    printf "%-7b  " "$(mark "$t")"

    if $DO_PROBE; then
        printf "%-4b  " "$(mark "$l")"
        printf "%-5b  " "$(http_color "$h")"
    fi

    if [[ "$d" == "yes" ]]; then
        printf "${YELLOW}drift${RESET}\n"
    else
        printf "${GREEN}ok${RESET}\n"
    fi
done

# Summary
echo
total=${#rows[@]}
if [[ $drift_count -eq 0 ]]; then
    printf "${GREEN}${BOLD}%d site(s) — all consistent.${RESET}\n" "$total"
else
    printf "${YELLOW}${BOLD}%d site(s) — %d with drift.${RESET}\n" "$total" "$drift_count"
fi

#!/usr/bin/env bash
#
# install.sh — One-shot server installer for the Traefik + nginx portal.
#
# Intended flow:
#   curl -sSL https://raw.githubusercontent.com/crxnit/traefik-nginx-provisioning-scripts/main/install.sh | bash
#
# Phases:
#   0. Guard against existing portal installations
#   1. Dependency checks (Linux, docker, compose, git, openssl, permissions)
#   2. Interactive prompts (install dir, ACME email, optional first FQDN, ...)
#   3. Summary + confirmation
#   4. Install (clone, patch ACME email, bootstrap, bring up stacks, optional first site)
#   5. Verify (verify-networks.sh, list-sites.sh, HTTP/HTTPS probes)
#   6. Cleanup (no temp files in this script, but stub is retained for logging)
#   7. Final log + success banner
#
# Bash 3.2 compatible. shellcheck --severity=warning clean.

set -euo pipefail

# --- Constants -------------------------------------------------------------

REPO_URL="https://github.com/crxnit/traefik-nginx-provisioning-scripts.git"
ACME_EMAIL_PLACEHOLDER="letsencrypt@example.com"
TRAEFIK_YML_SUBPATH="traefik/traefik.yml"
BOOTSTRAP_SCRIPT="bin/bootstrap.sh"
PROVISION_SCRIPT="bin/provision-site.sh"
VERIFY_SCRIPT="bin/verify-networks.sh"
LIST_SCRIPT="bin/list-sites.sh"
MIN_DISK_KB=2097152      # 2 GB
HEALTH_POLL_TIMEOUT=60
HEALTH_POLL_INTERVAL=3

# --- Globals (initialized by main) -----------------------------------------

INSTALL_DIR="/opt/traefik-nginx-portal"
ACME_EMAIL=""
INITIAL_FQDN=""
SPA_MODE="no"
NGINX_CONTAINER="nginx"
TRAEFIK_CONTAINER="traefik"
DC_CMD=""
CLONE_STARTED=0
INSTALL_LOG=""

# --- Colors ----------------------------------------------------------------

setup_colors() {
    if [ -t 1 ]; then
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        RED='\033[0;31m'
        BLUE='\033[0;34m'
        BOLD='\033[1m'
        RESET='\033[0m'
    else
        GREEN=''; YELLOW=''; RED=''; BLUE=''; BOLD=''; RESET=''
    fi
}

# --- Logging ---------------------------------------------------------------

log_info()  { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
log_step()  { printf "\n${BOLD}==> %s${RESET}\n" "$*"; }

# Write a line only to the install log (used before the tee redirect in
# phase 4, so early prompts/errors don't clobber the user's terminal).
log_file_only() {
    [ -n "$INSTALL_LOG" ] || return 0
    printf '%s\n' "$*" >> "$INSTALL_LOG"
}

# Pick a writable log path. Prefer /var/log so multi-user hosts can audit.
# Log contains the operator's ACME email + any provisioned FQDN, so it's
# chmod'd 600 at creation time to avoid leaking PII to other local users.
setup_log() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local candidate="/var/log/portal-install-${ts}.log"
    if touch "$candidate" 2>/dev/null; then
        chmod 600 "$candidate" 2>/dev/null || true
        INSTALL_LOG="$candidate"
    else
        INSTALL_LOG="${HOME:-/tmp}/portal-install-${ts}.log"
        if touch "$INSTALL_LOG" 2>/dev/null; then
            chmod 600 "$INSTALL_LOG" 2>/dev/null || true
        else
            INSTALL_LOG=""
        fi
    fi
    [ -n "$INSTALL_LOG" ] && log_info "Install log: $INSTALL_LOG"
}

# --- Utilities -------------------------------------------------------------

# Detect "curl ... | bash" invocation so we know to reopen stdin from /dev/tty
# for interactive prompts. When piped, bash sets $0 to "bash" (or similar).
is_curl_pipe_mode() {
    case "$0" in
        bash|-bash|/bin/bash|/usr/bin/bash|sh|/bin/sh) return 0 ;;
    esac
    return 1
}

validate_email() {
    printf '%s' "$1" | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
}

# Inlined copy of _lib.sh::validate_fqdn regex (installer runs before clone).
validate_fqdn_inline() {
    local fqdn="$1"
    case "$fqdn" in
        *..*|*/*) return 1 ;;
    esac
    printf '%s' "$fqdn" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
}

# prompt_with_default VAR_NAME "prompt text" "default"
# Bash 3.2 has no nameref (`declare -n`), so we eval-assign.
prompt_with_default() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local answer
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt_text" "$default_value"
    else
        printf '%s: ' "$prompt_text"
    fi
    IFS= read -r answer || answer=""
    [ -z "$answer" ] && answer="$default_value"
    # Quote to survive spaces; var_name is operator-controlled (not user input).
    eval "$var_name=\$answer"
}

# prompt_yes_no VAR_NAME "prompt text" "yes|no"
prompt_yes_no() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local answer
    while :; do
        printf '%s [%s]: ' "$prompt_text" "$default_value"
        IFS= read -r answer || answer=""
        [ -z "$answer" ] && answer="$default_value"
        answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
            y|yes) eval "$var_name=yes"; return 0 ;;
            n|no)  eval "$var_name=no";  return 0 ;;
            *)     printf '  Please answer yes or no.\n' ;;
        esac
    done
}

# df -k walks up until we find an existing ancestor.
check_disk_space() {
    local dir="$1"
    local probe="$dir"
    while [ ! -d "$probe" ] && [ "$probe" != "/" ] && [ -n "$probe" ]; do
        probe="$(dirname "$probe")"
    done
    [ -d "$probe" ] || probe="/"
    local avail
    avail="$(df -k "$probe" | awk 'NR==2 {print $4}')"
    if [ -z "$avail" ] || [ "$avail" -lt "$MIN_DISK_KB" ] 2>/dev/null; then
        log_warn "Less than 2 GB free on $(df -k "$probe" | awk 'NR==2 {print $6}'). Installation may fail."
    fi
}

# Prefer `docker compose` (v2 plugin); fall back to legacy `docker-compose`.
docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        printf 'docker compose'
    elif command -v docker-compose >/dev/null 2>&1; then
        printf 'docker-compose'
    fi
}

# --- Trap handlers ---------------------------------------------------------

handle_sigint() {
    log_warn "Interrupted. Exiting."
    logger -t portal-install "Interrupted by user." 2>/dev/null || true
    exit 130
}

handle_exit() {
    local code=$?
    if [ "$code" -ne 0 ] && [ "$CLONE_STARTED" -eq 1 ]; then
        log_warn "Install failed after the repo was cloned into: $INSTALL_DIR"
        log_warn "Not auto-deleting. Inspect the directory, then remove manually if undesired:"
        log_warn "  sudo rm -rf \"$INSTALL_DIR\""
    fi
    return "$code"
}

# --- Phase 0: existing-config guard ----------------------------------------

phase0_existing_config_guard() {
    log_step "Checking for existing portal installation"
    local found=""

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qwE "^(${NGINX_CONTAINER}|${TRAEFIK_CONTAINER})$"; then
            found="running container ($NGINX_CONTAINER or $TRAEFIK_CONTAINER)"
        elif docker network ls --format '{{.Name}}' 2>/dev/null | grep -qwE '^(traefik|edge)$'; then
            found="docker network (traefik or edge)"
        fi
    fi

    if [ -z "$found" ] && [ -d "${INSTALL_DIR}/srv/portal" ]; then
        found="install directory ${INSTALL_DIR}/srv/portal"
    fi

    if [ -n "$found" ]; then
        log_warn "Existing portal installation detected: $found"
        log_warn "Aborting to avoid clobbering existing state."
        log_file_only "[phase 0] aborted: $found"
        logger -t portal-install "Existing installation detected ($found) — aborting." 2>/dev/null || true
        exit 0
    fi
}

# --- Phase 1: dependency checks --------------------------------------------

phase1_dependency_checks() {
    log_step "Checking dependencies"
    local uname_s missing=""
    uname_s="$(uname -s)"
    if [ "$uname_s" != "Linux" ]; then
        log_error "This installer targets Linux servers. Detected: $uname_s"
        logger -t portal-install "Non-Linux host: $uname_s" 2>/dev/null || true
        exit 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        missing="${missing} docker"
    elif ! docker info >/dev/null 2>&1; then
        missing="${missing} docker-daemon"
    fi

    DC_CMD="$(docker_compose_cmd)"
    [ -z "$DC_CMD" ] && missing="${missing} docker-compose"

    command -v git >/dev/null 2>&1     || missing="${missing} git"
    command -v openssl >/dev/null 2>&1 || missing="${missing} openssl"

    # Either root, or member of the `docker` group.
    if [ "$(id -u)" -ne 0 ]; then
        if ! id -nG | tr ' ' '\n' | grep -qx 'docker'; then
            missing="${missing} root-or-docker-group"
        fi
    fi

    if [ -n "$missing" ]; then
        # Strip leading space.
        missing="${missing# }"
        log_error "Missing or unusable: $missing"
        logger -t portal-install "Dependency check failed: $missing" 2>/dev/null || true
        exit 1
    fi

    log_info "All dependencies satisfied. Compose command: $DC_CMD"
}

# --- Phase 2: interactive prompts ------------------------------------------

phase2_interactive_prompts() {
    log_step "Configuration"

    # When piped from curl, stdin is the pipe — swap it for the terminal.
    if is_curl_pipe_mode; then
        if [ -r /dev/tty ]; then
            exec < /dev/tty
        else
            log_error "Running in non-interactive pipe with no /dev/tty; cannot prompt."
            exit 1
        fi
    fi

    prompt_with_default INSTALL_DIR "Install directory" "$INSTALL_DIR"
    check_disk_space "$INSTALL_DIR"

    while :; do
        prompt_with_default ACME_EMAIL "Let's Encrypt contact email (required)" ""
        if [ -z "$ACME_EMAIL" ]; then
            printf '  Email is required.\n'
            continue
        fi
        if validate_email "$ACME_EMAIL"; then
            break
        fi
        printf '  Not a valid email address.\n'
    done

    prompt_with_default INITIAL_FQDN "First site FQDN (optional, blank to skip)" ""
    if [ -n "$INITIAL_FQDN" ] && ! validate_fqdn_inline "$INITIAL_FQDN"; then
        log_warn "Invalid FQDN '$INITIAL_FQDN' — skipping initial site provision."
        INITIAL_FQDN=""
    fi

    if [ -n "$INITIAL_FQDN" ]; then
        prompt_yes_no SPA_MODE "Treat '$INITIAL_FQDN' as a single-page app (SPA fallback)?" "no"
    fi

    prompt_with_default NGINX_CONTAINER   "nginx container name"   "$NGINX_CONTAINER"
    prompt_with_default TRAEFIK_CONTAINER "Traefik container name" "$TRAEFIK_CONTAINER"
}

# --- Phase 3: confirmation -------------------------------------------------

phase3_confirmation() {
    log_step "Review configuration"
    printf '  %-25s %s\n' "Install directory:"    "$INSTALL_DIR"
    printf '  %-25s %s\n' "ACME email:"           "$ACME_EMAIL"
    printf '  %-25s %s\n' "Initial FQDN:"         "${INITIAL_FQDN:-<none>}"
    [ -n "$INITIAL_FQDN" ] && printf '  %-25s %s\n' "SPA mode:" "$SPA_MODE"
    printf '  %-25s %s\n' "nginx container:"      "$NGINX_CONTAINER"
    printf '  %-25s %s\n' "Traefik container:"    "$TRAEFIK_CONTAINER"
    printf '  %-25s %s\n' "Install log:"          "${INSTALL_LOG:-<none>}"
    echo

    local answer
    printf "Type 'yes' to proceed: "
    IFS= read -r answer || answer=""
    if [ "$answer" != "yes" ]; then
        log_info "Aborted by user."
        logger -t portal-install "Aborted by user at confirmation." 2>/dev/null || true
        exit 0
    fi
}

# --- Phase 4: install ------------------------------------------------------

phase4_wait_healthy() {
    local container="$1"
    local elapsed=0
    local status=""
    while [ "$elapsed" -lt "$HEALTH_POLL_TIMEOUT" ]; do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)"
        case "$status" in
            healthy) log_info "$container: healthy"; return 0 ;;
            "")      log_warn "$container: no HEALTHCHECK defined — skipping wait."; return 0 ;;
        esac
        sleep "$HEALTH_POLL_INTERVAL"
        elapsed=$((elapsed + HEALTH_POLL_INTERVAL))
    done
    log_warn "$container: did not become healthy within ${HEALTH_POLL_TIMEOUT}s (last: $status). Continuing."
}

phase4_install() {
    # Capture stdout + stderr for the rest of the run. ANSI SGR escapes are
    # stripped on the file-bound branch so the log stays readable weeks later;
    # the terminal branch keeps them. $'\033' is the literal ESC byte.
    if [ -n "$INSTALL_LOG" ]; then
        exec 1> >(tee >(sed $'s/\033\\[[0-9;]*m//g' >> "$INSTALL_LOG"))
        exec 2>&1
    fi

    log_step "Cloning repository"
    logger -t portal-install "Cloning $REPO_URL -> $INSTALL_DIR" 2>/dev/null || true
    CLONE_STARTED=1
    git clone "$REPO_URL" "$INSTALL_DIR"

    log_step "Patching ACME email in $TRAEFIK_YML_SUBPATH"
    local traefik_yml="${INSTALL_DIR}/srv/portal/${TRAEFIK_YML_SUBPATH}"
    [ -f "$traefik_yml" ] || { log_error "Missing: $traefik_yml"; exit 1; }
    sed -i "s|${ACME_EMAIL_PLACEHOLDER}|${ACME_EMAIL}|g" "$traefik_yml"
    if ! grep -q "$ACME_EMAIL" "$traefik_yml"; then
        log_error "ACME email patch failed — placeholder still present in $traefik_yml"
        exit 1
    fi
    log_info "ACME email set to $ACME_EMAIL"

    log_step "Running bootstrap.sh"
    logger -t portal-install "Running bootstrap" 2>/dev/null || true
    ( cd "${INSTALL_DIR}/srv/portal" && bash "$BOOTSTRAP_SCRIPT" )

    log_step "Starting nginx stack"
    logger -t portal-install "Starting nginx" 2>/dev/null || true
    ( cd "${INSTALL_DIR}/srv/portal" && $DC_CMD -f nginx/docker-compose.yml up -d )

    log_step "Starting Traefik stack"
    logger -t portal-install "Starting Traefik" 2>/dev/null || true
    ( cd "${INSTALL_DIR}/srv/portal" && $DC_CMD up -d )

    log_step "Waiting for containers to be healthy"
    phase4_wait_healthy "$NGINX_CONTAINER"
    phase4_wait_healthy "$TRAEFIK_CONTAINER"

    if [ -n "$INITIAL_FQDN" ]; then
        log_step "Provisioning initial site: $INITIAL_FQDN"
        logger -t portal-install "Provisioning $INITIAL_FQDN" 2>/dev/null || true
        local spa_flag=""
        [ "$SPA_MODE" = "yes" ] && spa_flag="--spa"
        # shellcheck disable=SC2086  # spa_flag is empty or '--spa'; must not be quoted
        ( cd "${INSTALL_DIR}/srv/portal" && bash "$PROVISION_SCRIPT" "$INITIAL_FQDN" $spa_flag )
    fi
}

# --- Phase 5: verify -------------------------------------------------------

phase5_verify() {
    log_step "Verifying install"
    local net_rc=0 curl_rc="n/a"

    ( cd "${INSTALL_DIR}/srv/portal" && bash "$VERIFY_SCRIPT" ) || net_rc=$?
    if [ "$net_rc" -eq 0 ]; then
        log_info "verify-networks.sh: PASS"
    else
        log_warn "verify-networks.sh: FAIL (rc=$net_rc)"
    fi

    ( cd "${INSTALL_DIR}/srv/portal" && bash "$LIST_SCRIPT" ) || true

    if [ -n "$INITIAL_FQDN" ]; then
        local http_code https_code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${INITIAL_FQDN}/" || printf '000')"
        if [ "$http_code" = "301" ]; then
            log_info "HTTP probe $INITIAL_FQDN: 301 (redirect to HTTPS — expected)"
            curl_rc="PASS"
        else
            log_warn "HTTP probe $INITIAL_FQDN: $http_code (expected 301)"
            curl_rc="WARN"
        fi
        https_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${INITIAL_FQDN}/" || printf '000')"
        case "$https_code" in
            200|301|302) log_info "HTTPS probe $INITIAL_FQDN: $https_code" ;;
            *) log_warn "HTTPS probe $INITIAL_FQDN: $https_code (ACME may still be issuing the cert)" ;;
        esac
    fi

    logger -t portal-install "Verification: net=$([ "$net_rc" -eq 0 ] && echo PASS || echo FAIL) curl=$curl_rc" 2>/dev/null || true
}

# --- Phase 6: cleanup ------------------------------------------------------

phase6_cleanup() {
    log_step "Cleanup"
    log_info "No temp files created by installer; nothing to remove."
    logger -t portal-install "Cleanup complete." 2>/dev/null || true
}

# --- Phase 7: final log + banner -------------------------------------------

phase7_final_log() {
    log_step "Done"
    if [ -n "$INSTALL_LOG" ]; then
        {
            printf '\n=== portal-install summary ===\n'
            printf 'timestamp:       %s\n' "$(date -Iseconds 2>/dev/null || date)"
            printf 'install_dir:     %s\n' "$INSTALL_DIR"
            printf 'acme_email:      %s\n' "$ACME_EMAIL"
            printf 'initial_fqdn:    %s\n' "${INITIAL_FQDN:-<none>}"
            printf 'nginx_container: %s\n' "$NGINX_CONTAINER"
            printf 'traefik_container: %s\n' "$TRAEFIK_CONTAINER"
        } >> "$INSTALL_LOG"
    fi

    cat <<EOF

${GREEN}${BOLD}Install complete.${RESET}

Next steps:
  - Provision more sites:   ${INSTALL_DIR}/srv/portal/bin/provision-site.sh <fqdn>
  - Interactive menu:       ${INSTALL_DIR}/srv/portal/bin/menu.sh
  - Verify at any time:     ${INSTALL_DIR}/srv/portal/bin/verify-networks.sh
  - Install log:            ${INSTALL_LOG:-<not captured>}

Point DNS for your site(s) at this host and Let's Encrypt will issue certs
on the first HTTPS request.
EOF

    # Flush the tee subshell before main returns.
    wait 2>/dev/null || true
}

# --- Entry point -----------------------------------------------------------

main() {
    setup_colors
    trap handle_sigint INT
    trap handle_exit EXIT
    setup_log

    phase0_existing_config_guard
    phase1_dependency_checks
    phase2_interactive_prompts
    phase3_confirmation
    phase4_install
    phase5_verify
    phase6_cleanup
    phase7_final_log
}

main "$@"

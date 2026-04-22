#!/usr/bin/env bash
#
# install.sh — One-shot server installer for the Traefik + nginx portal.
#
# Intended flow:
#   curl -sSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh | bash
#
# Phases:
#   0. Guard against existing portal installations
#   1. Dependency checks (Linux, docker, compose, git, openssl, permissions)
#   2. Interactive prompts (install dir, ACME email, optional first FQDN, ...)
#   3. Summary + confirmation
#   4. Install (clone, patch ACME email, bootstrap, bring up stacks, optional first site)
#   5. Verify (verify-networks.sh, list-sites.sh, HTTP/HTTPS probes)
#   6. Final log + success banner
#
# Bash 3.2 compatible. shellcheck --severity=warning clean.

set -euo pipefail

# --- Constants -------------------------------------------------------------

REPO_URL="https://github.com/crxnit/traefik-nginx-portal.git"
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

INSTALL_DIR="/srv/portal"
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
    # ANSI-C quoting ($'...') stores the actual ESC byte, not the literal
    # 4-char `\033` sequence. Required so the final banner's heredoc renders
    # colors; `cat` doesn't interpret `\033` the way printf does.
    if [ -t 1 ]; then
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[0;33m'
        RED=$'\033[0;31m'
        BLUE=$'\033[0;34m'
        BOLD=$'\033[1m'
        RESET=$'\033[0m'
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

# Emit a syslog entry tagged portal-install. No-op if logger is unavailable
# or writing to syslog fails (e.g., unprivileged container without /dev/log).
syslog_event() { logger -t portal-install "$*" 2>/dev/null || true; }

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
# Uses `printf -v` (bash 3.1+) so we avoid eval and the quoting hazards
# that come with it. The internal buffer is named with an unlikely prefix
# so a caller passing a var named "answer"/"input"/etc. doesn't get
# shadowed by our local — printf -v binds to the nearest-enclosing scope.
prompt_with_default() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local _pwd_buf
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt_text" "$default_value"
    else
        printf '%s: ' "$prompt_text"
    fi
    IFS= read -r _pwd_buf || _pwd_buf=""
    [ -z "$_pwd_buf" ] && _pwd_buf="$default_value"
    printf -v "$var_name" '%s' "$_pwd_buf"
}

# prompt_yes_no VAR_NAME "prompt text" "yes|no"
# See comment on prompt_with_default for the `_pyn_buf` name choice.
prompt_yes_no() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local _pyn_buf
    while :; do
        printf '%s [%s]: ' "$prompt_text" "$default_value"
        IFS= read -r _pyn_buf || _pyn_buf=""
        [ -z "$_pyn_buf" ] && _pyn_buf="$default_value"
        _pyn_buf="$(printf '%s' "$_pyn_buf" | tr '[:upper:]' '[:lower:]')"
        case "$_pyn_buf" in
            y|yes) printf -v "$var_name" 'yes'; return 0 ;;
            n|no)  printf -v "$var_name" 'no';  return 0 ;;
            *)     printf '  Please answer yes or no.\n' ;;
        esac
    done
}

# Returns 0 if the install directory is writable by the current user
# (either already exists-and-writable, or the nearest existing ancestor
# is writable so mkdir/git-clone can create it). Emits a targeted error
# with concrete remediation options otherwise. Called from phase 2 so
# the user learns about perms up front — before git clone fails with
# a bare "Permission denied" four phases later.
check_install_dir_writable() {
    local dir="$1"
    case "$dir" in
        /*) ;;
        *) log_error "Install directory must be an absolute path: $dir"
           return 1 ;;
    esac

    if [ -d "$dir" ]; then
        [ -w "$dir" ] && return 0
        log_error "Install directory exists but is not writable by $(id -un): $dir"
        log_error "Fix with one of:"
        log_error "  1. sudo chown $(id -un):$(id -gn) $dir"
        log_error "  2. Choose a different directory (must be writable by $(id -un))"
        return 1
    fi

    # Doesn't exist yet — we need write permission on the nearest
    # existing ancestor to mkdir / git-clone into.
    local parent="$dir"
    while [ ! -e "$parent" ] && [ "$parent" != "/" ] && [ -n "$parent" ]; do
        parent="$(dirname "$parent")"
    done
    [ -d "$parent" ] || parent="/"
    [ -w "$parent" ] && return 0
    log_error "Cannot create $dir — parent $parent is not writable by $(id -un)."
    log_error "Fix with one of:"
    log_error "  1. sudo mkdir -p $dir && sudo chown $(id -un):$(id -gn) $dir"
    log_error "  2. Choose a different directory under a path you own (e.g. \$HOME/...)"
    return 1
}

# If $1 isn't currently writable, offer to sudo-fix it interactively.
# Returns 0 if the dir ends up writable (already was, or the fix worked),
# 1 if the user declined, sudo is unavailable, or the fix failed.
ensure_install_dir_writable() {
    local dir="$1"
    if check_install_dir_writable "$dir"; then
        return 0
    fi

    # Silent no-op if sudo isn't installed — user will retry with a
    # different path or Ctrl-C out and fix permissions manually.
    command -v sudo >/dev/null 2>&1 || return 1

    local user group fix_desc
    user="$(id -un)"
    group="$(id -gn)"
    if [ -d "$dir" ]; then
        fix_desc="sudo chown $user:$group $dir"
    else
        fix_desc="sudo mkdir -p $dir && sudo chown $user:$group $dir"
    fi

    echo
    log_info "I can run this for you (sudo will prompt for your password if needed):"
    printf '    %s\n' "$fix_desc"
    local answer=""
    prompt_yes_no answer "Run it now?" "no"
    [ "$answer" = "yes" ] || return 1

    if [ -d "$dir" ]; then
        sudo chown "$user:$group" "$dir" || { log_error "sudo chown failed."; return 1; }
    else
        sudo mkdir -p "$dir" || { log_error "sudo mkdir failed."; return 1; }
        sudo chown "$user:$group" "$dir" || { log_error "sudo chown failed."; return 1; }
    fi
    log_info "Fixed: $dir now owned by $user:$group."

    # Re-check so a partial/no-op sudo command doesn't silently pass.
    check_install_dir_writable "$dir"
}

# df -k walks up until we find an existing ancestor. One df invocation
# feeds both fields; we verify the size is numeric before comparing, so
# a df output change doesn't silently skip the warning.
check_disk_space() {
    local dir="$1"
    local probe="$dir"
    while [ ! -d "$probe" ] && [ "$probe" != "/" ] && [ -n "$probe" ]; do
        probe="$(dirname "$probe")"
    done
    [ -d "$probe" ] || probe="/"
    local avail="" mount=""
    read -r avail mount < <(df -k "$probe" | awk 'NR==2 {print $4, $6}')
    case "$avail" in
        ''|*[!0-9]*)
            log_warn "Could not determine free disk space on $probe."
            ;;
        *)
            if [ "$avail" -lt "$MIN_DISK_KB" ]; then
                log_warn "Less than 2 GB free on ${mount:-$probe}. Installation may fail."
            fi
            ;;
    esac
}

# Prefer `docker compose` (v2 plugin); fall back to legacy `docker-compose`.
docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        printf 'docker compose'
    elif command -v docker-compose >/dev/null 2>&1; then
        printf 'docker-compose'
    fi
}

# Run a command inside ${INSTALL_DIR}. Used for every compose /
# helper-script invocation in phases 4-5 so the cd+subshell pattern lives
# in one place.
run_in_portal() {
    ( cd "${INSTALL_DIR}" && "$@" )
}

# Probe a URL and return just its HTTP status code (or 000 on failure).
# Second arg is an optional extra curl flag (e.g. -k for the HTTPS probe
# while Traefik is still serving the self-signed default cert).
probe_http() {
    local url="$1"
    local extra="${2:-}"
    # shellcheck disable=SC2086  # extra is empty or a single short flag
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 $extra "$url" \
        || printf '000'
}

# --- Trap handlers ---------------------------------------------------------

handle_sigint() {
    log_warn "Interrupted. Exiting."
    syslog_event "Interrupted by user."
    exit 130
}

handle_exit() {
    local code=$?
    # Only warn if phase 4 started AND actually created the install dir.
    # If `git clone` failed before creating the target (e.g., no write
    # permission on the parent), there's nothing to inspect and the old
    # message was misleading.
    if [ "$code" -ne 0 ] && [ "$CLONE_STARTED" -eq 1 ] && [ -d "$INSTALL_DIR" ]; then
        log_warn "Installer exited with a partial install directory: $INSTALL_DIR"
        log_warn "Not auto-deleting. Inspect it, then remove manually if undesired:"
        log_warn "  sudo rm -rf \"$INSTALL_DIR\""
    fi
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

    if [ -z "$found" ] && [ -f "${INSTALL_DIR}/docker-compose.yml" ] && [ -d "${INSTALL_DIR}/bin" ]; then
        found="install directory ${INSTALL_DIR} (contains docker-compose.yml and bin/)"
    fi

    if [ -n "$found" ]; then
        log_warn "Existing portal installation detected: $found"
        log_warn "Aborting to avoid clobbering existing state."
        log_file_only "[phase 0] aborted: $found"
        syslog_event "Existing installation detected ($found) — aborting."
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
        syslog_event "Non-Linux host: $uname_s"
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

    # We do NOT gate on "is the user root or in the docker group" — that's a
    # rootful-era proxy. Rootless Docker (Lima's current default, Podman-
    # compatible setups) doesn't use the docker group at all: the daemon
    # runs as the user and owns the socket. The `docker info` call above is
    # the authoritative test for "can this user talk to a docker daemon."

    if [ -n "$missing" ]; then
        # Strip leading space.
        missing="${missing# }"
        log_error "Missing or unusable: $missing"
        syslog_event "Dependency check failed: $missing"
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

    while :; do
        prompt_with_default INSTALL_DIR "Install directory" "$INSTALL_DIR"
        if ensure_install_dir_writable "$INSTALL_DIR"; then
            break
        fi
        echo
    done
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
        syslog_event "Aborted by user at confirmation."
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
    # Phase 0 only checked the default INSTALL_DIR. Now that the operator's
    # chosen path is final, refuse to clone into a non-empty directory so
    # `git clone` doesn't fail later with its opaque "not an empty directory"
    # error after the user has already confirmed.
    if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        log_error "Install directory is not empty: $INSTALL_DIR"
        log_error "Remove its contents or choose a different directory, then re-run."
        syslog_event "Install dir not empty pre-clone: $INSTALL_DIR"
        exit 1
    fi
    syslog_event "Cloning $REPO_URL -> $INSTALL_DIR"
    CLONE_STARTED=1
    git clone "$REPO_URL" "$INSTALL_DIR"

    log_step "Patching ACME email in $TRAEFIK_YML_SUBPATH"
    local traefik_yml="${INSTALL_DIR}/${TRAEFIK_YML_SUBPATH}"
    [ -f "$traefik_yml" ] || { log_error "Missing: $traefik_yml"; exit 1; }
    sed -i "s|${ACME_EMAIL_PLACEHOLDER}|${ACME_EMAIL}|g" "$traefik_yml"
    if ! grep -q "$ACME_EMAIL" "$traefik_yml"; then
        log_error "ACME email patch failed — placeholder still present in $traefik_yml"
        exit 1
    fi
    log_info "ACME email set to $ACME_EMAIL"

    log_step "Running bootstrap.sh"
    syslog_event "Running bootstrap"
    run_in_portal bash "$BOOTSTRAP_SCRIPT"

    log_step "Starting nginx stack"
    syslog_event "Starting nginx"
    # shellcheck disable=SC2086  # $DC_CMD may be 'docker compose' (two words)
    run_in_portal $DC_CMD -f nginx/docker-compose.yml up -d

    log_step "Starting Traefik stack"
    syslog_event "Starting Traefik"
    # shellcheck disable=SC2086  # $DC_CMD may be 'docker compose' (two words)
    run_in_portal $DC_CMD up -d

    log_step "Waiting for containers to be healthy"
    phase4_wait_healthy "$NGINX_CONTAINER"
    phase4_wait_healthy "$TRAEFIK_CONTAINER"

    if [ -n "$INITIAL_FQDN" ]; then
        log_step "Provisioning initial site: $INITIAL_FQDN"
        syslog_event "Provisioning $INITIAL_FQDN"
        local spa_flag=""
        [ "$SPA_MODE" = "yes" ] && spa_flag="--spa"
        # shellcheck disable=SC2086  # spa_flag is empty or '--spa'; must not be quoted
        run_in_portal bash "$PROVISION_SCRIPT" "$INITIAL_FQDN" $spa_flag
    fi
}

# --- Phase 5: verify -------------------------------------------------------

phase5_verify() {
    log_step "Verifying install"
    local net_rc=0 curl_rc="n/a"

    run_in_portal bash "$VERIFY_SCRIPT" || net_rc=$?
    if [ "$net_rc" -eq 0 ]; then
        log_info "verify-networks.sh: PASS"
    else
        log_warn "verify-networks.sh: FAIL (rc=$net_rc)"
    fi

    run_in_portal bash "$LIST_SCRIPT" || true

    if [ -n "$INITIAL_FQDN" ]; then
        local http_code https_code
        http_code="$(probe_http "http://${INITIAL_FQDN}/")"
        if [ "$http_code" = "301" ]; then
            log_info "HTTP probe $INITIAL_FQDN: 301 (redirect to HTTPS — expected)"
            curl_rc="PASS"
        else
            log_warn "HTTP probe $INITIAL_FQDN: $http_code (expected 301)"
            curl_rc="WARN"
        fi
        https_code="$(probe_http "https://${INITIAL_FQDN}/" -k)"
        case "$https_code" in
            200|301|302) log_info "HTTPS probe $INITIAL_FQDN: $https_code" ;;
            *) log_warn "HTTPS probe $INITIAL_FQDN: $https_code (ACME may still be issuing the cert)" ;;
        esac
    fi

    syslog_event "Verification: net=$([ "$net_rc" -eq 0 ] && echo PASS || echo FAIL) curl=$curl_rc"
}

# --- Phase 6: final log + banner -------------------------------------------

phase6_final_log() {
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
  - Provision more sites:   ${INSTALL_DIR}/bin/provision-site.sh <fqdn>
  - Interactive menu:       ${INSTALL_DIR}/bin/menu.sh
  - Verify at any time:     ${INSTALL_DIR}/bin/verify-networks.sh
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
    phase6_final_log
}

main "$@"

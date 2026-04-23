#!/usr/bin/env bash
#
# install.sh — One-shot server installer for the Traefik + nginx portal.
#
# Intended flow:
#   curl -sSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh | bash
#
# The installer self-elevates via sudo if not already root (re-downloading
# to a temp file for the curl-pipe case), and offers to install any missing
# dependencies via apt on Debian/Ubuntu. So the `curl | bash` form above
# works for any user with sudo access — no need to remember `sudo bash`.
#
# Phases:
#   0. Guard against existing portal installations
#   1. Dependency checks (Linux, docker, compose, git, openssl, sudo, useradd, ...);
#      offers apt-install on missing Debian/Ubuntu packages
#   2. Interactive prompts (install dir, ACME email, optional first FQDN, ...)
#   3. Summary + confirmation
#   4. Install:
#        - clone repo
#        - patch ACME email in traefik.yml
#        - create portal service user + add to docker group
#        - chown $INSTALL_DIR to service user
#        - install systemd unit templates to /etc/systemd/system/
#        - install /usr/local/bin/portal wrapper symlink
#        - run bootstrap.sh as service user
#        - systemctl enable --now both stacks (or fallback: compose up -d)
#        - optional first-site provision
#   5. Verify (verify-networks.sh, list-sites.sh, systemctl is-active, HTTP/HTTPS probes)
#   6. Final log + success banner
#
# Bash 3.2 compatible. shellcheck --severity=warning clean.

set -euo pipefail

# --- Self-elevate ----------------------------------------------------------
# Runs before any other logic so the operator gets at most one terse line
# of output ("Re-executing via sudo ...") before the real installer UI
# begins as root. The installer needs root for useradd, systemd unit
# installation, /usr/local/bin symlink, and (on most distros) docker
# socket access before the operator has been added to the docker group.

INSTALLER_URL="https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh"

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        printf '[ERROR] Installer requires root privileges and sudo is not installed.\n' >&2
        printf '[ERROR] Re-run as root (e.g., via `su -`) or install sudo first.\n' >&2
        exit 1
    fi
    printf '[INFO]  Not running as root — re-executing via sudo (you may be prompted for your password).\n'

    # If we're running from a real file, sudo can exec that file directly.
    # If we're curl-piped (BASH_SOURCE[0] is the literal "bash" / "main" /
    # empty and there's no file to exec), re-download to a temp file so
    # sudo has something concrete to run. The temp file is owned by the
    # invoking user, mode 0600 from mktemp — safe on a shared host.
    _src="${BASH_SOURCE[0]:-}"
    if [ -n "$_src" ] && [ -f "$_src" ]; then
        exec sudo -E bash "$_src" "$@"
    fi
    _tmp="$(mktemp -t portal-install.XXXXXX)"
    if ! curl -fsSL "$INSTALLER_URL" -o "$_tmp"; then
        printf '[ERROR] Failed to re-download installer from %s\n' "$INSTALLER_URL" >&2
        rm -f "$_tmp"
        exit 1
    fi
    exec sudo -E bash "$_tmp" "$@"
fi

# --- Constants -------------------------------------------------------------

REPO_URL="https://github.com/crxnit/traefik-nginx-portal.git"
ACME_EMAIL_PLACEHOLDER="letsencrypt@example.com"
TRAEFIK_YML_SUBPATH="traefik/traefik.yml"
BOOTSTRAP_SCRIPT="bin/bootstrap.sh"
PROVISION_SCRIPT="bin/provision-site.sh"
VERIFY_SCRIPT="bin/verify-networks.sh"
LIST_SCRIPT="bin/list-sites.sh"
PORTAL_WRAPPER="bin/portal"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
SYSTEMD_UNIT_SRC="systemd"   # subpath inside the install dir
SYSTEMD_UNITS="portal-nginx.service portal-traefik.service"
WRAPPER_SYMLINK="/usr/local/bin/portal"
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
PORTAL_USER="${PORTAL_USER:-portal}"   # service account that owns $INSTALL_DIR
DC_CMD=""
DC_CMD_ABS=""
CLONE_STARTED=0
INSTALL_LOG=""
SYSTEMD_AVAILABLE=0

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

# Idempotent: reopen stdin from the controlling TTY if stdin isn't already
# interactive. Safe to call multiple times. Used by phase 1 (deps-install
# offer) and phase 2 (normal prompt flow). After self-elevation via the
# temp-file re-exec above, bash is reading the *script* from the temp file,
# so redirecting stdin doesn't affect script parsing.
ensure_tty_stdin() {
    [ -t 0 ] && return 0
    if [ -r /dev/tty ]; then
        exec < /dev/tty
    else
        log_error "Cannot read from a TTY; stdin is not interactive and /dev/tty is unavailable."
        exit 1
    fi
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

# Same as docker_compose_cmd but with the first token resolved to an
# absolute path — systemd unit ExecStart fields require that.
docker_compose_cmd_abs() {
    local cmd first rest abs
    cmd="$(docker_compose_cmd)"
    [ -z "$cmd" ] && return 1
    first="${cmd%% *}"
    rest="${cmd#"$first"}"
    abs="$(command -v "$first")" || return 1
    printf '%s%s' "$abs" "$rest"
}

# Returns 0 if systemd is the running init and we can install units.
have_systemd() {
    command -v systemctl >/dev/null 2>&1 \
        && [ -d /run/systemd/system ]
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
    # permission on the parent), there's nothing to inspect.
    if [ "$code" -ne 0 ] && [ "$CLONE_STARTED" -eq 1 ] && [ -d "$INSTALL_DIR" ]; then
        log_warn "Installer exited with a partial install directory: $INSTALL_DIR"
        log_warn "Not auto-deleting. Inspect it, then if you want to start clean:"
        log_warn "  # stop + remove any started containers"
        log_warn "  sudo systemctl disable --now portal-nginx portal-traefik 2>/dev/null || true"
        log_warn "  # remove systemd units, wrapper symlink, service user, install dir"
        log_warn "  sudo rm -f /etc/systemd/system/portal-nginx.service /etc/systemd/system/portal-traefik.service"
        log_warn "  sudo systemctl daemon-reload"
        log_warn "  sudo rm -f $WRAPPER_SYMLINK"
        log_warn "  sudo userdel --remove $PORTAL_USER 2>/dev/null || true"
        log_warn "  sudo rm -rf \"$INSTALL_DIR\""
        log_warn "  # Docker networks (shared with any other portal instance — review before removing):"
        log_warn "  # docker network rm traefik edge"
        log_warn "Each step is a no-op if the corresponding resource wasn't created, so running them all is safe."
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

# Pure check: returns a space-separated list of missing/unusable dependency
# tokens via stdout. Empty output == everything is fine. Called from phase 1
# twice if the operator accepts the auto-install offer (once to build the
# initial list, once to confirm nothing was left out).
_detect_missing_deps() {
    local missing=""
    if ! command -v docker >/dev/null 2>&1; then
        missing="${missing} docker"
    elif ! docker info >/dev/null 2>&1; then
        missing="${missing} docker-daemon"
    fi
    [ -n "$(docker_compose_cmd)" ] || missing="${missing} docker-compose"
    command -v git     >/dev/null 2>&1 || missing="${missing} git"
    command -v openssl >/dev/null 2>&1 || missing="${missing} openssl"
    command -v useradd >/dev/null 2>&1 || missing="${missing} useradd"
    command -v usermod >/dev/null 2>&1 || missing="${missing} usermod"
    command -v getent  >/dev/null 2>&1 || missing="${missing} getent"
    command -v sudo    >/dev/null 2>&1 || missing="${missing} sudo"
    printf '%s' "${missing# }"
}

# Install Docker CE + the compose v2 plugin from docker.com's official repo.
# Ubuntu/Debian only. Returns 0 on success.
_install_docker_ce() {
    local distro codename keyring repo_file
    distro="$(. /etc/os-release && printf '%s' "$ID")"
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    case "$distro" in
        ubuntu|debian) ;;
        *) log_error "Docker auto-install only supports Ubuntu/Debian (detected: $distro)."; return 1 ;;
    esac
    if [ -z "$codename" ]; then
        log_error "Could not read VERSION_CODENAME from /etc/os-release."
        return 1
    fi

    log_info "Installing Docker CE from docker.com's apt repo ($distro $codename)..."
    apt-get install -y ca-certificates curl gnupg \
        || { log_error "Installing docker prerequisites failed."; return 1; }
    install -m 0755 -d /etc/apt/keyrings

    keyring="/etc/apt/keyrings/docker.gpg"
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
        | gpg --dearmor -o "$keyring" \
        || { log_error "Failed to fetch Docker GPG key."; return 1; }
    chmod a+r "$keyring"

    repo_file="/etc/apt/sources.list.d/docker.list"
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$keyring" "$distro" "$codename" \
        > "$repo_file"

    apt-get update -y \
        || { log_error "apt-get update (after adding docker repo) failed."; return 1; }
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
        || { log_error "Installing docker-ce failed."; return 1; }

    systemctl enable --now docker \
        || { log_error "Could not enable/start dockerd."; return 1; }
    log_info "Docker CE installed; dockerd is running."
    return 0
}

# Offer to install the detected missing packages via apt. Returns 0 if all
# installs succeeded, 1 if the operator declines / auto-install is unsupported
# on this distro / any package failed.
_offer_auto_install_deps() {
    local missing="$1"
    if ! command -v apt-get >/dev/null 2>&1; then
        log_error "Automatic dependency install is only supported on Debian/Ubuntu (apt-get missing)."
        log_error "Install these manually and re-run: $missing"
        return 1
    fi

    echo
    log_warn "Missing or unusable dependencies: $missing"
    log_info "This installer can fetch and install them for you now."
    ensure_tty_stdin
    local answer=""
    prompt_yes_no answer "Install missing packages now?" "yes"
    [ "$answer" = "yes" ] || {
        log_error "Declined — please install the packages manually and re-run."
        return 1
    }

    log_step "Installing missing dependencies via apt"
    apt-get update -y || { log_error "apt-get update failed."; return 1; }

    # Partition the missing list: simple apt packages vs the docker bundle.
    local simple_pkgs="" need_docker=0 item
    for item in $missing; do
        case "$item" in
            docker|docker-daemon|docker-compose) need_docker=1 ;;
            git)                    simple_pkgs="$simple_pkgs git" ;;
            openssl)                simple_pkgs="$simple_pkgs openssl" ;;
            useradd|usermod|getent) simple_pkgs="$simple_pkgs login" ;;  # provides useradd/usermod/getent on Debian family
            sudo)                   simple_pkgs="$simple_pkgs sudo" ;;
        esac
    done
    # Dedupe simple_pkgs (a user might have multiple "login"-provided binaries missing).
    simple_pkgs="$(printf '%s\n' $simple_pkgs | awk 'NF && !seen[$0]++' | tr '\n' ' ')"

    if [ -n "$simple_pkgs" ]; then
        # shellcheck disable=SC2086  # intentional word-split on the package list
        apt-get install -y $simple_pkgs \
            || { log_error "apt-get install ($simple_pkgs) failed."; return 1; }
    fi
    if [ "$need_docker" -eq 1 ]; then
        _install_docker_ce || return 1
    fi
    log_info "Dependency install complete."
    return 0
}

phase1_dependency_checks() {
    log_step "Checking dependencies"
    local uname_s
    uname_s="$(uname -s)"
    if [ "$uname_s" != "Linux" ]; then
        log_error "This installer targets Linux servers. Detected: $uname_s"
        syslog_event "Non-Linux host: $uname_s"
        exit 1
    fi

    # We do NOT gate on "is the user root or in the docker group" — that's a
    # rootful-era proxy. Rootless Docker (Lima's current default, Podman-
    # compatible setups) doesn't use the docker group at all: the daemon
    # runs as the user and owns the socket. The `docker info` call inside
    # _detect_missing_deps is the authoritative test for "can this user
    # talk to a docker daemon."

    local missing
    missing="$(_detect_missing_deps)"

    if [ -n "$missing" ]; then
        _offer_auto_install_deps "$missing" || {
            syslog_event "Dependency check failed: $missing"
            exit 1
        }
        # Re-check: a successful install run should leave nothing missing,
        # but a partial apt failure (network, repo drift, etc.) could.
        missing="$(_detect_missing_deps)"
        if [ -n "$missing" ]; then
            log_error "Still missing after install attempt: $missing"
            syslog_event "Dependency check failed after install attempt: $missing"
            exit 1
        fi
    fi

    # Now cache the compose command variants for the rest of the script.
    DC_CMD="$(docker_compose_cmd)"
    DC_CMD_ABS="$(docker_compose_cmd_abs)" || DC_CMD_ABS="$DC_CMD"

    # Systemd isn't *required* (falls back to docker-compose-up-managed mode),
    # but it's expected on a production Linux host. Warn loudly if missing.
    if have_systemd; then
        SYSTEMD_AVAILABLE=1
    else
        SYSTEMD_AVAILABLE=0
        log_warn "systemd not detected (no /run/systemd/system or no systemctl)."
        log_warn "Install will skip the unit install — stacks won't auto-start on boot."
    fi

    log_info "All dependencies satisfied. Compose command: $DC_CMD"
    [ "$SYSTEMD_AVAILABLE" -eq 1 ] && log_info "systemd detected — will install portal-{nginx,traefik}.service units."
}

# --- Phase 2: interactive prompts ------------------------------------------

phase2_interactive_prompts() {
    log_step "Configuration"

    # Idempotent: phase 1's auto-install offer may have already reopened stdin.
    ensure_tty_stdin

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
    printf '  %-25s %s\n' "Service user:"         "$PORTAL_USER (owns $INSTALL_DIR)"
    printf '  %-25s %s\n' "ACME email:"           "$ACME_EMAIL"
    printf '  %-25s %s\n' "Initial FQDN:"         "${INITIAL_FQDN:-<none>}"
    [ -n "$INITIAL_FQDN" ] && printf '  %-25s %s\n' "SPA mode:" "$SPA_MODE"
    printf '  %-25s %s\n' "nginx container:"      "$NGINX_CONTAINER"
    printf '  %-25s %s\n' "Traefik container:"    "$TRAEFIK_CONTAINER"
    if [ "$SYSTEMD_AVAILABLE" -eq 1 ]; then
        printf '  %-25s %s\n' "Lifecycle:"        "systemd (portal-nginx.service, portal-traefik.service)"
    else
        printf '  %-25s %s\n' "Lifecycle:"        "docker compose (no systemd — no auto-restart on boot)"
    fi
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

# Create the portal service user (idempotent: no-op if it already exists).
# Adds the user to the docker group if that group is present — rootful
# Docker setups use /var/run/docker.sock owned by group `docker`. Rootless
# setups don't have the group, so we skip with a warning and the operator
# is responsible for making sure `portal` can talk to its docker daemon.
phase4_ensure_service_user() {
    log_step "Ensuring service user: $PORTAL_USER"
    if getent passwd "$PORTAL_USER" >/dev/null; then
        log_info "User '$PORTAL_USER' already exists — reusing."
    else
        syslog_event "Creating service user $PORTAL_USER"
        sudo useradd \
            --system \
            --home-dir "$INSTALL_DIR" \
            --shell /bin/bash \
            --user-group \
            "$PORTAL_USER" \
            || { log_error "useradd $PORTAL_USER failed."; exit 1; }
        log_info "Created system user '$PORTAL_USER' (home: $INSTALL_DIR, shell: /bin/bash, no password — login only via sudo)."
    fi

    if ! getent group docker >/dev/null; then
        # Rootless Docker (and Podman's docker-compat) don't use the docker
        # group: the daemon runs as the operator and owns a user-local socket
        # under /run/user/UID/. The service-user model can't work here —
        # when systemctl tries to bring up the portal stacks as `portal`,
        # compose would fail to reach the operator's rootless daemon.
        log_error "'docker' group not found — this looks like a rootless Docker setup."
        log_error "The service-user + systemd model requires a rootful Docker install"
        log_error "where the 'docker' group exists and the daemon socket is group-accessible."
        log_error "Either switch to rootful Docker (apt install docker-ce + systemctl enable docker),"
        log_error "or skip this installer and run the portal directly as your operator user"
        log_error "against your rootless daemon (docker compose up -d manually from \$INSTALL_DIR)."
        syslog_event "Aborted: rootless Docker (no docker group) not supported by service-user model."
        exit 1
    fi

    if id -nG "$PORTAL_USER" | tr ' ' '\n' | grep -qx 'docker'; then
        log_info "'$PORTAL_USER' is already in the docker group."
    else
        sudo usermod -aG docker "$PORTAL_USER" \
            || { log_error "usermod -aG docker $PORTAL_USER failed."; exit 1; }
        log_info "Added '$PORTAL_USER' to the docker group."
    fi
}

# chown $INSTALL_DIR to the service user. Everything under it — generated
# configs, acme.json, default certs, per-site content — ends up owned by
# `portal` going forward.
phase4_chown_install_dir() {
    log_step "Setting ownership: $PORTAL_USER:$PORTAL_USER -> $INSTALL_DIR"
    sudo chown -R "$PORTAL_USER:$PORTAL_USER" "$INSTALL_DIR" \
        || { log_error "chown failed."; exit 1; }
}

# Install the two systemd units (nginx + traefik) by substituting our
# @PORTAL_DIR@ / @PORTAL_USER@ / @DC_CMD@ placeholders into the templates
# shipped under systemd/ and dropping the result into /etc/systemd/system/.
phase4_install_systemd_units() {
    [ "$SYSTEMD_AVAILABLE" -eq 1 ] || {
        log_warn "Skipping systemd units (systemd not detected)."
        return 0
    }
    log_step "Installing systemd units"
    local unit src dest tmp
    for unit in $SYSTEMD_UNITS; do
        src="${INSTALL_DIR}/${SYSTEMD_UNIT_SRC}/${unit}"
        dest="${SYSTEMD_UNIT_DIR}/${unit}"
        if [ ! -f "$src" ]; then
            log_error "Unit template missing: $src"
            exit 1
        fi
        tmp="$(mktemp)"
        sed \
            -e "s|@PORTAL_DIR@|${INSTALL_DIR}|g" \
            -e "s|@PORTAL_USER@|${PORTAL_USER}|g" \
            -e "s|@DC_CMD@|${DC_CMD_ABS}|g" \
            "$src" > "$tmp"
        sudo install -m 0644 -o root -g root "$tmp" "$dest" \
            || { rm -f "$tmp"; log_error "install $dest failed."; exit 1; }
        rm -f "$tmp"
        log_info "Installed $dest"
    done
    sudo systemctl daemon-reload \
        || { log_error "systemctl daemon-reload failed."; exit 1; }
}

# Run a script inside $INSTALL_DIR as the service user. Uses `sudo -iu`
# so HOME, group membership (including the just-added docker group), and
# working directory are all established as `portal` would have them at
# login. The script path is absolute, so the service user's search PATH
# doesn't matter.
run_as_portal() {
    sudo -iu "$PORTAL_USER" -- "$@"
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

    phase4_ensure_service_user
    phase4_chown_install_dir
    phase4_install_systemd_units

    # Install-time wrapper symlink so operators type `portal` from anywhere.
    if [ -f "${INSTALL_DIR}/${PORTAL_WRAPPER}" ]; then
        log_step "Installing wrapper symlink: $WRAPPER_SYMLINK -> ${INSTALL_DIR}/${PORTAL_WRAPPER}"
        sudo ln -sf "${INSTALL_DIR}/${PORTAL_WRAPPER}" "$WRAPPER_SYMLINK" \
            || log_warn "Could not create $WRAPPER_SYMLINK — operators will need to invoke the wrapper by full path."
    fi

    log_step "Running bootstrap.sh as $PORTAL_USER"
    syslog_event "Running bootstrap"
    run_as_portal "${INSTALL_DIR}/${BOOTSTRAP_SCRIPT}"

    if [ "$SYSTEMD_AVAILABLE" -eq 1 ]; then
        log_step "Enabling + starting systemd units"
        syslog_event "Enabling systemd units"
        # portal-traefik Requires= portal-nginx, so enabling/starting traefik
        # alone would pull nginx in — but explicit is clearer in the logs.
        sudo systemctl enable --now portal-nginx.service \
            || { log_error "enable --now portal-nginx failed."; exit 1; }
        sudo systemctl enable --now portal-traefik.service \
            || { log_error "enable --now portal-traefik failed."; exit 1; }
    else
        # Fallback: no systemd, run compose directly as portal.
        log_step "Starting stacks via docker compose (no systemd available)"
        syslog_event "Starting stacks (no systemd)"
        # shellcheck disable=SC2086  # $DC_CMD may be 'docker compose' (two words)
        run_as_portal bash -c "cd '$INSTALL_DIR' && $DC_CMD -f nginx/docker-compose.yml up -d && $DC_CMD up -d"
    fi

    log_step "Waiting for containers to be healthy"
    phase4_wait_healthy "$NGINX_CONTAINER"
    phase4_wait_healthy "$TRAEFIK_CONTAINER"

    if [ -n "$INITIAL_FQDN" ]; then
        log_step "Provisioning initial site: $INITIAL_FQDN"
        syslog_event "Provisioning $INITIAL_FQDN"
        local spa_flag=""
        [ "$SPA_MODE" = "yes" ] && spa_flag="--spa"
        # shellcheck disable=SC2086  # spa_flag is empty or '--spa'; must not be quoted
        run_as_portal "${INSTALL_DIR}/${PROVISION_SCRIPT}" "$INITIAL_FQDN" $spa_flag
    fi
}

# --- Phase 5: verify -------------------------------------------------------

phase5_verify() {
    log_step "Verifying install"
    local net_rc=0 curl_rc="n/a"

    run_as_portal "${INSTALL_DIR}/${VERIFY_SCRIPT}" || net_rc=$?
    if [ "$net_rc" -eq 0 ]; then
        log_info "verify-networks.sh: PASS"
    else
        log_warn "verify-networks.sh: FAIL (rc=$net_rc)"
    fi

    run_as_portal "${INSTALL_DIR}/${LIST_SCRIPT}" || true

    if [ "$SYSTEMD_AVAILABLE" -eq 1 ]; then
        local u
        for u in portal-nginx.service portal-traefik.service; do
            if systemctl is-active --quiet "$u"; then
                log_info "systemd: $u active"
            else
                log_warn "systemd: $u not active (journalctl -u $u for details)"
            fi
        done
    fi

    if [ -n "$INITIAL_FQDN" ]; then
        local http_code https_code
        http_code="$(probe_http "http://${INITIAL_FQDN}/")"
        # Traefik's default HTTP→HTTPS redirect is 308 (Permanent Redirect,
        # method-preserving); older configs / operators may use 301. Accept
        # both as the expected response to a plain-HTTP request.
        case "$http_code" in
            301|308)
                log_info "HTTP probe $INITIAL_FQDN: $http_code (redirect to HTTPS — expected)"
                curl_rc="PASS"
                ;;
            *)
                log_warn "HTTP probe $INITIAL_FQDN: $http_code (expected 301 or 308)"
                curl_rc="WARN"
                ;;
        esac
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

Portal service user: $PORTAL_USER (owns $INSTALL_DIR). Admins drop into
that identity on demand via the 'portal' wrapper — no need to su or
touch files in the install dir directly.

Next steps:
  - Interactive menu:       portal menu
  - Provision more sites:   portal provision-site <fqdn>
  - List/drift check:       portal list-sites
  - Verify wiring:          portal verify-networks
  - Systemd status:         systemctl status portal-nginx portal-traefik
  - Install log:            ${INSTALL_LOG:-<not captured>}

Point DNS for your site(s) at this host and Let's Encrypt will issue certs
on the first HTTPS request. Both stacks will restart automatically on
reboot (enabled at the systemd level).
EOF

    # Flush the tee subshell before main returns.
    #
    # Order matters: bash 5.1+ tracks process-substitution children in
    # `wait`, so calling wait while we still hold fd 1 open (pointing
    # into tee's input pipe) deadlocks — tee blocks waiting for EOF on
    # its stdin, we block waiting for tee to exit. Close fd 1/2 first
    # so tee sees EOF and can drain, then wait.
    if [ -n "$INSTALL_LOG" ]; then
        exec 1>&- 2>&-
    fi
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

#!/usr/bin/env bash
#
# teardown.sh — Fully remove a portal installation from the host.
#
# Undoes everything install.sh creates:
#   - Stops + disables systemd units, removes unit files
#   - Force-removes any lingering portal containers
#   - Removes the traefik + edge docker networks
#   - Removes the /usr/local/bin/portal wrapper symlink
#   - Removes $INSTALL_DIR entirely (acme.json, certs, sites, .env — all of it)
#   - Removes the portal service user + home
#   - Cleans up install logs under /var/log/
#
# Intended use: prep a host for a fresh install, or decommission.
# Self-elevates via sudo, same pattern as install.sh. By default prompts
# for confirmation by typing the install directory path.
#
# Usage:
#   Remote (curl-piped, symmetric with install.sh):
#     curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/teardown.sh | bash
#   Local file:
#     bash teardown.sh [options]
#
# Options:
#   -y, --yes            Skip confirmation prompt (for automation)
#   --install-dir DIR    Install directory to remove (default: /srv/portal)
#   --portal-user USER   Service user to remove (default: portal)
#   -h, --help           Show this help
#
# Env overrides:
#   INSTALL_DIR          default /srv/portal
#   PORTAL_USER          default portal
#
# Let's Encrypt cert preservation: the script wipes $INSTALL_DIR wholesale,
# so acme.json goes with it. If you want to carry certs to the next install,
# back up manually before running:
#     sudo cp /srv/portal/traefik/acme.json ~/acme.json.bak
# and restore after install.sh completes.
#
# Bash 3.2 compatible. shellcheck --severity=warning clean.

set -euo pipefail
umask 022

# --- Early --help (before self-elevate — no reason to ask for a password
#     just to print usage text). Everything else after elevation.

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: teardown.sh [options]

Fully remove a portal installation from the host.

Options:
  -y, --yes            Skip confirmation prompt (for automation)
  --install-dir DIR    Install directory to remove (default: /srv/portal)
  --portal-user USER   Service user to remove (default: portal)
  -h, --help           Show this help

Without --yes, prompts for confirmation by typing the install directory path.

Remote invocation (no local checkout needed):
  curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/teardown.sh | bash
EOF
        exit 0
        ;;
esac

# --- Self-elevate (mirrors install.sh) -------------------------------------

TEARDOWN_URL="https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/teardown.sh"

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        printf '[ERROR] Teardown requires root and sudo is not installed.\n' >&2
        exit 1
    fi
    printf '[INFO]  Not running as root — re-executing via sudo.\n'
    _src="${BASH_SOURCE[0]:-}"
    if [ -n "$_src" ] && [ -f "$_src" ]; then
        exec sudo -E bash "$_src" "$@"
    fi
    # curl-pipe branch: re-download to a temp file so sudo has something
    # concrete to exec. Temp is cleaned up in handle_exit below.
    _tmp="$(mktemp -t portal-teardown.XXXXXX)"
    if ! curl -fsSL "$TEARDOWN_URL" -o "$_tmp"; then
        printf '[ERROR] Failed to re-download teardown script from %s\n' "$TEARDOWN_URL" >&2
        rm -f "$_tmp"
        exit 1
    fi
    exec sudo -E PORTAL_TEARDOWN_SELF_TMP="$_tmp" bash "$_tmp" "$@"
fi

# --- Globals ---------------------------------------------------------------

INSTALL_DIR="${INSTALL_DIR:-/srv/portal}"
PORTAL_USER="${PORTAL_USER:-portal}"
SKIP_CONFIRM=0
WRAPPER_SYMLINK="/usr/local/bin/portal"
# Same container set install.sh manages. Keep in sync if the compose services
# ever grow (the OAuth sidecar was added here when that feature landed).
PORTAL_CONTAINERS="traefik nginx traefik-forward-auth-google"
PORTAL_NETWORKS="traefik edge"

# --- Colors (TTY-aware) ----------------------------------------------------

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BLUE=''; BOLD=''; RESET=''
fi

log_info()  { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${RESET}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
log_step()  { printf "\n${BOLD}==> %s${RESET}\n" "$*"; }

# --- Trap: clean up self-elevate temp --------------------------------------

handle_exit() {
    if [ -n "${PORTAL_TEARDOWN_SELF_TMP:-}" ] && [ -f "$PORTAL_TEARDOWN_SELF_TMP" ]; then
        rm -f "$PORTAL_TEARDOWN_SELF_TMP" 2>/dev/null || true
    fi
}
trap handle_exit EXIT

# --- Arg parsing -----------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [options]

Fully remove a portal installation from the host.

Options:
  -y, --yes            Skip confirmation prompt (for automation)
  --install-dir DIR    Install directory to remove (default: $INSTALL_DIR)
  --portal-user USER   Service user to remove (default: $PORTAL_USER)
  -h, --help           Show this help

Without --yes, prompts for confirmation by typing the install directory path.
EOF
    exit 0
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)       usage ;;
        -y|--yes)        SKIP_CONFIRM=1; shift ;;
        --install-dir)   INSTALL_DIR="$2"; shift 2 ;;
        --portal-user)   PORTAL_USER="$2"; shift 2 ;;
        *) log_error "Unknown argument: $1"; echo; usage ;;
    esac
done

# --- Safety: refuse system paths + refuse root user ------------------------
# Same blacklist install.sh uses. A typo here would rm -rf a system dir.

case "$INSTALL_DIR" in
    /|/bin|/sbin|/usr|/etc|/boot|/home|/root|/var|/tmp|/dev|/proc|/sys|/lib|/lib32|/lib64|/libx32|/opt|/srv|/mnt|/media|/run)
        log_error "Refusing to teardown $INSTALL_DIR — that would wipe a system directory."
        log_error "Override via --install-dir if the actual portal lives elsewhere."
        exit 1
        ;;
esac

if [ "$PORTAL_USER" = "root" ]; then
    log_error "Refusing to remove the 'root' user."
    exit 1
fi

# --- Detection: what's actually present? -----------------------------------

UNITS_PRESENT=0
INSTALL_DIR_PRESENT=0
WRAPPER_PRESENT=0
USER_PRESENT=0
CONTAINERS_PRESENT=""
NETWORKS_PRESENT=""

[ -f /etc/systemd/system/portal-nginx.service ]   && UNITS_PRESENT=1
[ -f /etc/systemd/system/portal-traefik.service ] && UNITS_PRESENT=1
[ -d "$INSTALL_DIR" ] && INSTALL_DIR_PRESENT=1
if [ -L "$WRAPPER_SYMLINK" ] || [ -f "$WRAPPER_SYMLINK" ]; then
    WRAPPER_PRESENT=1
fi
getent passwd "$PORTAL_USER" >/dev/null 2>&1 && USER_PRESENT=1

if command -v docker >/dev/null 2>&1; then
    for c in $PORTAL_CONTAINERS; do
        if docker ps -aq --filter "name=^${c}\$" 2>/dev/null | grep -q .; then
            CONTAINERS_PRESENT="${CONTAINERS_PRESENT}${c} "
        fi
    done
    for n in $PORTAL_NETWORKS; do
        if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qwE "^${n}\$"; then
            NETWORKS_PRESENT="${NETWORKS_PRESENT}${n} "
        fi
    done
fi

# Early exit if nothing's here.
if [ "$UNITS_PRESENT" -eq 0 ] && [ "$INSTALL_DIR_PRESENT" -eq 0 ] \
    && [ "$WRAPPER_PRESENT" -eq 0 ] && [ "$USER_PRESENT" -eq 0 ] \
    && [ -z "$CONTAINERS_PRESENT" ] && [ -z "$NETWORKS_PRESENT" ]; then
    log_info "Nothing to tear down — no portal artifacts found."
    exit 0
fi

# --- Summary ---------------------------------------------------------------

log_step "Portal artifacts detected"
[ "$INSTALL_DIR_PRESENT" -eq 1 ] && log_info "Install directory:  $INSTALL_DIR"
[ "$USER_PRESENT" -eq 1 ]        && log_info "Service user:       $PORTAL_USER"
[ "$UNITS_PRESENT" -eq 1 ]       && log_info "Systemd units:      portal-nginx.service, portal-traefik.service"
[ "$WRAPPER_PRESENT" -eq 1 ]     && log_info "Wrapper symlink:    $WRAPPER_SYMLINK"
[ -n "$CONTAINERS_PRESENT" ]     && log_info "Containers:         ${CONTAINERS_PRESENT% }"
[ -n "$NETWORKS_PRESENT" ]       && log_info "Docker networks:    ${NETWORKS_PRESENT% }"

# --- Confirmation ----------------------------------------------------------

if [ "$SKIP_CONFIRM" -ne 1 ]; then
    echo
    log_warn "This is destructive and cannot be undone."
    log_warn "Any Let's Encrypt certs in $INSTALL_DIR/traefik/acme.json will be lost."
    log_warn "(Back up with: sudo cp $INSTALL_DIR/traefik/acme.json ~/acme.json.bak)"
    echo
    printf 'Type the install directory path to confirm:\n  %s\n> ' "$INSTALL_DIR"
    IFS= read -r answer || answer=""
    if [ "$answer" != "$INSTALL_DIR" ]; then
        log_info "Aborted — confirmation did not match."
        exit 0
    fi
fi

# --- Execution order -------------------------------------------------------
#
#   1. systemd units — stops containers via compose down, removes unit files
#   2. Containers   — safety net for anything that leaked past compose down
#   3. Networks     — must follow container removal (networks pin by endpoint)
#   4. Wrapper      — just a symlink
#   5. Install dir  — wipes the tree
#   6. Service user — after home (install dir) is gone
#   7. Logs         — final cosmetic sweep
#
# Every step is idempotent: missing resource → log_warn and continue. The
# post-execution verification step below catches anything that survived.

# 1. systemd units. Reverse dep order (traefik Requires= nginx).
if [ "$UNITS_PRESENT" -eq 1 ]; then
    log_step "Disabling + stopping systemd units"
    systemctl disable --now portal-traefik.service 2>/dev/null || true
    systemctl disable --now portal-nginx.service 2>/dev/null || true
    rm -f /etc/systemd/system/portal-nginx.service
    rm -f /etc/systemd/system/portal-traefik.service
    systemctl daemon-reload 2>/dev/null || true
    log_ok "systemd units removed"
fi

# 2. Lingering containers.
if [ -n "$CONTAINERS_PRESENT" ]; then
    log_step "Force-removing containers"
    for c in $CONTAINERS_PRESENT; do
        if docker rm -f "$c" >/dev/null 2>&1; then
            log_ok "container $c removed"
        else
            log_warn "container $c could not be removed (may already be gone)"
        fi
    done
fi

# 3. Docker networks. Must come after containers.
if [ -n "$NETWORKS_PRESENT" ]; then
    log_step "Removing docker networks"
    for n in $NETWORKS_PRESENT; do
        if docker network rm "$n" >/dev/null 2>&1; then
            log_ok "network $n removed"
        else
            log_warn "network $n could not be removed (still in use?)"
        fi
    done
fi

# 4. Wrapper symlink.
if [ "$WRAPPER_PRESENT" -eq 1 ]; then
    log_step "Removing wrapper"
    rm -f "$WRAPPER_SYMLINK"
    log_ok "$WRAPPER_SYMLINK removed"
fi

# 5. Install directory.
if [ "$INSTALL_DIR_PRESENT" -eq 1 ]; then
    log_step "Removing install directory: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    log_ok "Install directory removed"
fi

# 6. Service user. `--remove` also deletes the home dir; if install dir
# (= home) is already gone, --remove can fail on some distros, so fall
# back to plain userdel.
if [ "$USER_PRESENT" -eq 1 ]; then
    log_step "Removing service user: $PORTAL_USER"
    if userdel --remove "$PORTAL_USER" 2>/dev/null; then
        log_ok "user $PORTAL_USER removed"
    elif userdel "$PORTAL_USER" 2>/dev/null; then
        log_ok "user $PORTAL_USER removed (home was already gone)"
    else
        log_warn "userdel $PORTAL_USER failed — check for lingering processes"
    fi
fi

# 7. Install logs.
log_step "Removing install logs"
rm -f /var/log/portal-install-*.log
log_ok "Install logs cleaned"

# --- Verification ----------------------------------------------------------

log_step "Verifying teardown"
remaining=""
[ -d "$INSTALL_DIR" ]                             && remaining="${remaining}install-dir "
if [ -L "$WRAPPER_SYMLINK" ] || [ -f "$WRAPPER_SYMLINK" ]; then
    remaining="${remaining}wrapper "
fi
[ -f /etc/systemd/system/portal-nginx.service ]   && remaining="${remaining}nginx-unit "
[ -f /etc/systemd/system/portal-traefik.service ] && remaining="${remaining}traefik-unit "
getent passwd "$PORTAL_USER" >/dev/null 2>&1      && remaining="${remaining}user "
if command -v docker >/dev/null 2>&1; then
    for c in $PORTAL_CONTAINERS; do
        if docker ps -aq --filter "name=^${c}\$" 2>/dev/null | grep -q .; then
            remaining="${remaining}container:${c} "
        fi
    done
fi

if [ -n "$remaining" ]; then
    log_warn "Some artifacts remain: ${remaining% }"
    log_warn "Investigate the output above, then re-run or remove manually."
    exit 1
fi

log_step "Done"
log_ok "Teardown complete. Ready for a fresh install:"
echo "   curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-nginx-portal/main/install.sh | bash"

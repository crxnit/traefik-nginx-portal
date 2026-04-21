#!/usr/bin/env bash
#
# menu.sh — Interactive menu for portal operations.
#
# Wraps every operator action in the portal toolkit (bootstrap, stack
# lifecycle, site provisioning, logs, diagnostics) behind a single
# numbered menu. Delegates to the existing scripts; does not reimplement.
#
# Run from anywhere: the script resolves paths relative to its own location.

# NOTE: no `set -e` here. Interactive menu should survive a failed action
# and loop back. Individual commands have their own error handling.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# Non-script paths are resolved against $PORTAL_DIR (set by _lib.sh).
NGINX_COMPOSE="${PORTAL_DIR}/nginx/docker-compose.yml"
TRAEFIK_COMPOSE="${PORTAL_DIR}/docker-compose.yml"
NGINX_CONTAINER="${NGINX_CONTAINER:-nginx}"
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"

# --- Audit log -------------------------------------------------------------
# Every session start/end, every menu choice, and every action invocation
# is recorded to srv/portal/logs/menu.log for operator audit trails.
# One event per line, key=value format for easy grep/awk:
#   2026-04-20T12:34:56Z session_start user=john host=mac pid=12345 tty=/dev/ttys003
#   2026-04-20T12:34:58Z menu_choice choice=10 label=provision_site pid=12345
#   2026-04-20T12:34:59Z action_start action=provision_site pid=12345
#   2026-04-20T12:35:02Z action_end action=provision_site exit=0 duration=3s pid=12345
#   2026-04-20T12:35:10Z session_end duration=14s pid=12345
#
# Logging failures never crash the menu — if the log dir isn't writable, a
# one-time warning is printed and subsequent writes are silent no-ops.

LOG_DIR="${PORTAL_DIR}/logs"
LOG_FILE="${LOG_DIR}/menu.log"
SESSION_ID="$$"
SESSION_START_EPOCH=$(date +%s)
LOG_WRITABLE=true

init_log() {
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf "${YELLOW}[WARN]${RESET} Could not create log dir %s — audit logging disabled.\n" "$LOG_DIR" >&2
        LOG_WRITABLE=false
        return
    fi
    if ! touch "$LOG_FILE" 2>/dev/null; then
        printf "${YELLOW}[WARN]${RESET} Could not write to %s — audit logging disabled.\n" "$LOG_FILE" >&2
        LOG_WRITABLE=false
        return
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

audit_log() {
    $LOG_WRITABLE || return 0
    local event="$1"; shift
    local ts user host
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    user="${USER:-$(whoami 2>/dev/null || echo unknown)}"
    host=$(hostname -s 2>/dev/null || echo unknown)
    # `$*` is the already-formatted key=value tail; caller passes it pre-formatted.
    printf '%s %s user=%s host=%s pid=%s %s\n' \
        "$ts" "$event" "$user" "$host" "$SESSION_ID" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
}

session_end_once() {
    # Idempotent: the EXIT trap may fire multiple times in some bash edge cases.
    [[ -n "${_SESSION_ENDED:-}" ]] && return 0
    _SESSION_ENDED=1
    local duration=$(( $(date +%s) - SESSION_START_EPOCH ))
    audit_log session_end "duration=${duration}s"
}
trap session_end_once EXIT

# --- Action runner ---------------------------------------------------------
# Wraps every menu action with audit log entries and duration tracking.
# The action function handles its own prompts and output — we just record
# start, end, and exit code.

run_action() {
    local label="$1"; shift
    local fn="$1"; shift
    audit_log action_start "action=$label"
    local start_epoch exit_code
    start_epoch=$(date +%s)
    "$fn" "$@"
    exit_code=$?
    local duration=$(( $(date +%s) - start_epoch ))
    audit_log action_end "action=$label exit=$exit_code duration=${duration}s"
    return $exit_code
}

# The menu needs an interactive terminal — all reads go to /dev/tty so
# destructive-action prompts can't be bypassed by piped input.
# Exception: --cheatsheet is non-interactive and skips this check.
if [[ "${1:-}" != "--cheatsheet" ]] && { [[ ! -t 0 ]] || [[ ! -r /dev/tty ]]; }; then
    echo "menu.sh requires an interactive terminal. Invoke the underlying" >&2
    echo "scripts directly for automation — see './bin/menu.sh --cheatsheet'" >&2
    echo "or run option C from the menu on a real TTY."                    >&2
    exit 1
fi

# --- UI helpers ------------------------------------------------------------

clear_screen() { printf '\033[2J\033[H'; }

header() { printf "\n${BOLD}${BLUE}━━━ %s ━━━${RESET}\n\n" "$*"; }

pause() {
    echo
    read -rp "Press Enter to continue..." _ </dev/tty
}

prompt_yes_no() {
    local prompt="$1" default="${2:-n}" reply
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    read -rp "$prompt $hint " reply </dev/tty
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_fqdn() {
    local prompt="${1:-Enter FQDN}" fqdn
    while true; do
        read -rp "$prompt (or Enter to cancel): " fqdn </dev/tty
        [[ -z "$fqdn" ]] && return 1
        if validate_fqdn "$fqdn"; then
            printf '%s' "$fqdn"
            return 0
        fi
        log_error "Invalid FQDN: '$fqdn' — try again."
    done
}

# --- Status banner ---------------------------------------------------------

stack_status() {
    local traefik_state nginx_state
    if docker inspect "$TRAEFIK_CONTAINER" >/dev/null 2>&1; then
        traefik_state=$(docker inspect -f '{{.State.Status}}' "$TRAEFIK_CONTAINER" 2>/dev/null)
    else
        traefik_state="absent"
    fi
    if docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1; then
        nginx_state=$(docker inspect -f '{{.State.Status}}' "$NGINX_CONTAINER" 2>/dev/null)
    else
        nginx_state="absent"
    fi

    local t_color n_color
    case "$traefik_state" in
        running) t_color="$GREEN"  ;;
        absent)  t_color="$DIM"    ;;
        *)       t_color="$YELLOW" ;;
    esac
    case "$nginx_state" in
        running) n_color="$GREEN"  ;;
        absent)  n_color="$DIM"    ;;
        *)       n_color="$YELLOW" ;;
    esac

    local site_count=0
    if [[ -d "${PORTAL_DIR}/traefik/dynamic" ]]; then
        site_count=$(find "${PORTAL_DIR}/traefik/dynamic" -maxdepth 1 -name '*.yml' -type f ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')
    fi

    printf "  Traefik: ${t_color}%s${RESET}    nginx: ${n_color}%s${RESET}    sites: %s\n" \
        "$traefik_state" "$nginx_state" "$site_count"
}

# --- Actions ---------------------------------------------------------------

action_bootstrap() {
    header "Bootstrap host"
    "${SCRIPT_DIR}/bootstrap.sh"
}

action_regen_default_tls() {
    header "Regenerate default TLS cert"
    log_warn "This will overwrite the existing default cert and key."
    if prompt_yes_no "Continue?"; then
        "${SCRIPT_DIR}/ensure-default-tls.sh" --force
    else
        log_info "Cancelled."
    fi
}

action_start_stacks() {
    header "Start stacks (nginx first, then Traefik)"
    docker compose -f "$NGINX_COMPOSE" up -d && \
        docker compose -f "$TRAEFIK_COMPOSE" up -d
}

action_stop_stacks() {
    header "Stop stacks"
    if ! prompt_yes_no "Really stop both Traefik and nginx?"; then
        log_info "Cancelled."
        return 0
    fi
    # --timeout 30 gives in-flight connections up to 30s to drain before SIGKILL.
    # Traefik first so new requests stop arriving, then nginx.
    docker compose -f "$TRAEFIK_COMPOSE" down --timeout 30
    docker compose -f "$NGINX_COMPOSE"   down --timeout 30
}

action_restart_stacks() {
    header "Restart stacks"
    docker compose -f "$NGINX_COMPOSE" restart
    docker compose -f "$TRAEFIK_COMPOSE" restart
}

action_verify_networks() {
    header "Verify network wiring"
    "${SCRIPT_DIR}/verify-networks.sh"
}

action_list_sites() {
    header "All sites"
    "${SCRIPT_DIR}/list-sites.sh"
}

action_list_sites_probe() {
    header "All sites (with reachability probe)"
    local probe_host
    read -rp "Probe host [127.0.0.1]: " probe_host </dev/tty
    if [[ -n "$probe_host" ]]; then
        "${SCRIPT_DIR}/list-sites.sh" --probe --probe-host "$probe_host"
    else
        "${SCRIPT_DIR}/list-sites.sh" --probe
    fi
}

action_list_drift() {
    header "Sites with drift"
    "${SCRIPT_DIR}/list-sites.sh" --drift-only
}

action_provision_site() {
    header "Provision a new site"
    local fqdn
    fqdn=$(prompt_fqdn "FQDN to provision") || return 0

    local args=("$fqdn")
    if prompt_yes_no "SPA mode (try_files fallback to /index.html)?"; then
        args+=(--spa)
    fi
    if ! prompt_yes_no "Test + reload nginx after writing files?" y; then
        args+=(--no-reload)
    fi

    echo
    log_info "Running: ./bin/provision-site.sh ${args[*]}"
    echo
    "${SCRIPT_DIR}/provision-site.sh" "${args[@]}"
}

action_deprovision_site() {
    header "Deprovision a site"
    local fqdn
    fqdn=$(prompt_fqdn "FQDN to deprovision") || return 0

    echo
    log_info "Dry-run preview:"
    echo
    if ! "${SCRIPT_DIR}/deprovision-site.sh" "$fqdn" --dry-run; then
        log_error "Dry-run failed. Aborting."
        return 0
    fi

    echo
    if ! prompt_yes_no "Proceed with removal?"; then
        log_info "Cancelled."
        return 0
    fi

    local args=("$fqdn" --yes)
    if prompt_yes_no "Keep the sites/<fqdn>/ content directory?"; then
        args+=(--keep-content)
    fi

    echo
    log_info "Running: ./bin/deprovision-site.sh ${args[*]}"
    echo
    "${SCRIPT_DIR}/deprovision-site.sh" "${args[@]}"
}

action_reload_nginx() {
    header "Reload nginx"
    "${SCRIPT_DIR}/reload-nginx.sh"
}

show_logs() {
    local name="$1" compose="$2" service="$3" follow="$4"
    if [[ "$follow" == "true" ]]; then
        header "${name} logs (follow, Ctrl-C to exit)"
        docker compose -f "$compose" logs -f --tail=50 "$service"
    else
        header "${name} logs (last 100 lines)"
        docker compose -f "$compose" logs --tail=100 "$service"
    fi
}

action_traefik_logs_tail()   { show_logs Traefik "$TRAEFIK_COMPOSE" traefik false; }
action_traefik_logs_follow() { show_logs Traefik "$TRAEFIK_COMPOSE" traefik true;  }
action_nginx_logs_tail()     { show_logs nginx   "$NGINX_COMPOSE"   nginx   false; }
action_nginx_logs_follow()   { show_logs nginx   "$NGINX_COMPOSE"   nginx   true;  }

action_view_audit_log() {
    header "Recent audit log entries (last 30)"
    if [[ ! -f "$LOG_FILE" ]]; then
        log_warn "No audit log yet at $LOG_FILE"
        return 0
    fi
    echo "${DIM}log file: $LOG_FILE${RESET}"
    echo
    tail -n 30 "$LOG_FILE"
}

action_cheatsheet() {
    header "Equivalent CLI commands"
    cat <<EOF
Host setup:
  ./bin/bootstrap.sh                          # full idempotent bootstrap
  ./bin/ensure-default-tls.sh [--force]       # default TLS cert
  ./bin/create-docker-networks.sh             # just the networks

Stacks:
  docker compose -f nginx/docker-compose.yml up -d
  docker compose up -d                        # Traefik
  docker compose down                         # Traefik stop
  ./bin/verify-networks.sh                    # health check

Sites:
  ./bin/list-sites.sh [--probe] [--drift-only] [--format json]
  ./bin/provision-site.sh <fqdn> [--spa] [--no-reload]
  ./bin/deprovision-site.sh <fqdn> [--dry-run] [--yes] [--keep-content]
  ./bin/reload-nginx.sh

Environment overrides:
  NGINX_CONTAINER=staging-nginx ./bin/verify-networks.sh
  TRAEFIK_CONTAINER=staging-traefik ./bin/list-sites.sh --probe
  TRAEFIK_DYNAMIC_DIR=/opt/dynamic ./bin/provision-site.sh foo.example.com

Logs:
  docker compose logs -f traefik
  docker compose -f nginx/docker-compose.yml logs -f nginx
EOF
}

# --- Main menu -------------------------------------------------------------

show_menu() {
    clear_screen
    printf "${BOLD}Portal Operations${RESET}    ${DIM}(%s)${RESET}\n" "$PORTAL_DIR"
    stack_status
    cat <<EOF

  ${BOLD}Host setup${RESET}
    1) Bootstrap host (acme.json, default TLS, docker networks)
    2) Regenerate default TLS cert

  ${BOLD}Stacks${RESET}
    3) Start stacks (nginx first, then Traefik)
    4) Stop stacks
    5) Restart stacks
    6) Verify network wiring

  ${BOLD}Sites${RESET}
    7) List sites
    8) List sites with reachability probe
    9) List only drifted sites
   10) Provision a new site
   11) Deprovision a site
   12) Reload nginx

  ${BOLD}Logs${RESET}
   13) Traefik logs (recent)
   14) Traefik logs (follow)
   15) nginx logs (recent)
   16) nginx logs (follow)

  ${BOLD}Reference${RESET}
    L) View recent audit log entries
    C) Show equivalent CLI commands
    Q) Quit

EOF
}

main() {
    # Non-interactive escape hatch: `./bin/menu.sh --cheatsheet` prints the
    # equivalent CLI reference and exits. Useful for docs / CI.
    if [[ "${1:-}" == "--cheatsheet" ]]; then
        action_cheatsheet
        exit 0
    fi

    init_log
    local tty_name
    tty_name=$(tty 2>/dev/null || echo unknown)
    audit_log session_start "tty=$tty_name"

    # Dispatch table: menu choice → (label for audit log, action function)
    # Labels are stable identifiers for grep/analytics; action fn names may change.
    while true; do
        show_menu
        local choice label="" fn="" lower
        read -rp "Choice: " choice </dev/tty || { echo; exit 0; }
        # Portable lowercase — bash 3.2 (stock macOS) does not support ${var,,}.
        lower=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')

        case "$lower" in
            1)  label=bootstrap_host        ; fn=action_bootstrap ;;
            2)  label=regen_default_tls     ; fn=action_regen_default_tls ;;
            3)  label=start_stacks          ; fn=action_start_stacks ;;
            4)  label=stop_stacks           ; fn=action_stop_stacks ;;
            5)  label=restart_stacks        ; fn=action_restart_stacks ;;
            6)  label=verify_networks       ; fn=action_verify_networks ;;
            7)  label=list_sites            ; fn=action_list_sites ;;
            8)  label=list_sites_probe      ; fn=action_list_sites_probe ;;
            9)  label=list_drift            ; fn=action_list_drift ;;
            10) label=provision_site        ; fn=action_provision_site ;;
            11) label=deprovision_site      ; fn=action_deprovision_site ;;
            12) label=reload_nginx          ; fn=action_reload_nginx ;;
            13) label=traefik_logs_tail     ; fn=action_traefik_logs_tail ;;
            14) label=traefik_logs_follow   ; fn=action_traefik_logs_follow ;;
            15) label=nginx_logs_tail       ; fn=action_nginx_logs_tail ;;
            16) label=nginx_logs_follow     ; fn=action_nginx_logs_follow ;;
            l)  label=view_audit_log        ; fn=action_view_audit_log ;;
            c)  label=cheatsheet            ; fn=action_cheatsheet ;;
            q|"")
                audit_log menu_choice "choice=quit label=quit"
                echo
                exit 0
                ;;
            *)
                audit_log menu_choice "choice=$choice label=invalid"
                log_error "Unknown choice: '$choice'"
                pause
                continue
                ;;
        esac

        audit_log menu_choice "choice=$choice label=$label"
        run_action "$label" "$fn"
        pause
    done
}

main "$@"

#!/usr/bin/env bash
# Shared helpers for the portal scripts. Source this file — do NOT invoke it.
#
# Provides:
#   - TTY-aware color variables (GREEN/YELLOW/RED/BLUE/BOLD/DIM/RESET)
#   - Standard log helpers: log_info, log_ok, log_warn, log_error, log_skip, die
#   - validate_fqdn <fqdn>
#   - write_atomic <target>     (stdin → tmp → rename)
#   - acquire_portal_lock <dir> (flock, no-op if flock unavailable)
#   - nginx_reload [container]  (test + graceful reload)
#
# Scripts are free to add their own specialized helpers on top
# (e.g. log_step in bootstrap, log_dry in deprovision).

# --- Colors ----------------------------------------------------------------

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    GREEN='' YELLOW='' RED='' BLUE='' BOLD='' DIM='' RESET=''
fi

# --- Log helpers -----------------------------------------------------------

log_info()  { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${RESET}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
log_skip()  { printf "${YELLOW}[SKIP]${RESET}  %s\n" "$*"; }
die() { log_error "$*"; exit 1; }

# --- FQDN validation -------------------------------------------------------
# Lowercase ASCII only, at least one dot, DNS-legal.
# Wildcards and IDN/punycode labels intentionally rejected.

fqdn_regex='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'

validate_fqdn() {
    local fqdn="$1"
    # Belt-and-suspenders: explicitly reject path-escape characters even though
    # the regex already excludes them. Defense-in-depth in case the regex is
    # ever loosened to allow e.g. wildcards — rm -rf paths are derived from
    # this value, so the check earns its keep.
    [[ "$fqdn" != *".."* && "$fqdn" != *"/"* ]] && [[ "$fqdn" =~ $fqdn_regex ]]
}

# --- Atomic file writes ----------------------------------------------------
# Write stdin to <target> via a temp file on the same filesystem, then rename.
# Atomic rename on POSIX filesystems means the target is either the old content
# or the new content — never a half-written file — even on SIGKILL or power loss.
#
# Usage:
#   some_command | write_atomic /path/to/target
#   write_atomic /path/to/target <<EOF
#   ...content...
#   EOF

write_atomic() {
    local target="$1"
    local tmp
    tmp="$(mktemp "${target}.XXXXXX")"
    # If we fail between mktemp and mv, clean up the temp.
    trap 'rm -f "$tmp"' RETURN
    cat > "$tmp"
    # mktemp creates the temp at 0600; apply umask so the final file matches
    # what a plain `cat > target` would have produced (typically 0644).
    chmod "$(printf '%o' $((0666 & ~0$(umask))))" "$tmp"
    mv "$tmp" "$target"
    trap - RETURN
}

# --- Provision/deprovision mutex -------------------------------------------
# Serializes concurrent invocations of provision/deprovision against the
# same portal directory, so two operators (or automation jobs) cannot race
# on the same FQDN's artifacts. No-op if flock is not installed.

acquire_portal_lock() {
    local script_dir="$1"
    local lock_file="${script_dir}/.portal.lock"
    if ! command -v flock >/dev/null 2>&1; then
        return 0
    fi
    # File descriptor 9 stays open for the life of the shell; the lock
    # releases automatically on exit.
    exec 9>"$lock_file"
    if ! flock -n 9; then
        echo "another provision/deprovision is running — refusing to proceed" >&2
        exit 1
    fi
}

# --- nginx test-and-reload -------------------------------------------------
# Validate nginx config in the running container, then gracefully reload.
# No-op with a warning if the container isn't running (dev/CI scenarios).
# Returns 0 on success or skip, 1 on config-test failure or reload failure.
#
# Callers are expected to have log_info/log_ok/log_warn/log_error defined.
#
# Arguments:
#   $1 - container name (optional; defaults to $NGINX_CONTAINER, then "nginx")

nginx_reload() {
    local container="${1:-${NGINX_CONTAINER:-nginx}}"

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$container"; then
        log_warn "Container '$container' is not running — skipping reload."
        return 0
    fi

    log_info "Testing nginx configuration..."
    if ! docker exec "$container" nginx -t; then
        log_error "nginx config test failed. Not reloading."
        return 1
    fi
    log_ok "nginx config test passed"

    log_info "Reloading nginx..."
    docker exec "$container" nginx -s reload || return 1
    log_ok "nginx reloaded"
    return 0
}

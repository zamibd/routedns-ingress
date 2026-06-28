#!/usr/bin/env bash
# routedns-ingress — zero-downtime HAProxy reload
set -euo pipefail

HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
PREFLIGHT_STRICT="${PREFLIGHT_STRICT:-false}"

log() { printf '[reload] %s\n' "$*"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "ERROR: Must run as root."
    exit 1
fi

if [[ "${PREFLIGHT_STRICT}" == "true" ]] && [[ -x /usr/local/lib/routedns-ingress/preflight.sh ]]; then
    log "Running production preflight..."
    /usr/local/lib/routedns-ingress/preflight.sh
fi

log "Validating ${HAPROXY_CFG}..."
if ! haproxy -c -f "${HAPROXY_CFG}"; then
    log "ERROR: Configuration validation failed. Reload aborted."
    exit 1
fi

log "Reloading HAProxy (zero-downtime)..."
systemctl reload haproxy

if systemctl is-active --quiet haproxy; then
    log "HAProxy reloaded successfully."
    exit 0
fi

log "ERROR: HAProxy is not active after reload."
exit 1

#!/usr/bin/env bash
# routedns-ingress — Keepalived VRRP health check for HAProxy
# Returns 0 if HAProxy is healthy, non-zero otherwise.
set -euo pipefail

HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
ADMIN_SOCK="/run/haproxy/admin.sock"

# HAProxy systemd unit must be active
if ! systemctl is-active --quiet haproxy; then
    exit 1
fi

# Configuration must be valid
if ! haproxy -c -f "${HAPROXY_CFG}" &>/dev/null; then
    exit 1
fi

# Stats socket must respond (confirms master-worker process is running)
if [[ -S "${ADMIN_SOCK}" ]]; then
    if echo "show info" | socat stdio "${ADMIN_SOCK}" 2>/dev/null | grep -q "Name:"; then
        exit 0
    fi
fi

# Fallback: check if HAProxy is listening on port 853
if ss -ltn '( sport = :853 )' 2>/dev/null | grep -q ':853'; then
    exit 0
fi

exit 1

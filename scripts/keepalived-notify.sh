#!/usr/bin/env bash
# routedns-ingress — Keepalived state transition notifications
set -euo pipefail

STATE="${1:-unknown}"
TIMESTAMP="$(date -Iseconds)"
HOSTNAME="$(hostname -s)"

logger -t routedns-ingress "Keepalived state transition: ${STATE} on ${HOSTNAME} at ${TIMESTAMP}"

case "${STATE}" in
    master)
        # VIP acquired — ensure HAProxy is running
        systemctl start haproxy 2>/dev/null || true
        ;;
    backup|fault)
        ;;
esac

exit 0

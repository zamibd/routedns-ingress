#!/usr/bin/env bash
# routedns-ingress — portable rsyslog HUP after logrotate (Debian + RHEL)
set -euo pipefail

if systemctl is-active --quiet rsyslog 2>/dev/null; then
    systemctl kill -s HUP rsyslog.service 2>/dev/null || systemctl reload rsyslog.service 2>/dev/null || true
    exit 0
fi

for helper in \
    /usr/lib/rsyslog/rsyslog-rotate \
    /usr/libexec/rsyslog/rsyslog-rotate \
    /usr/lib/rsyslog/rsyslog-rotate.sh; do
    if [[ -x "${helper}" ]]; then
        "${helper}"
        exit 0
    fi
done

# journald-only systems — nothing to signal
exit 0

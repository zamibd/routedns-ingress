#!/usr/bin/env bash
# routedns-ingress — uninstaller
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

REMOVE_PACKAGES=false
PURGE_CONFIGS=false

usage() {
    cat <<'EOF'
routedns-ingress uninstaller

Usage: sudo ./uninstall.sh [OPTIONS]

Options:
  --remove-packages   Also remove haproxy and keepalived packages
  --purge-configs     Remove routedns-ingress configuration files
  -h, --help          Show this help

By default, services are stopped/disabled and routedns-ingress overlays
are removed. Original backed-up configs remain in /var/backups/routedns-ingress/.
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove-packages) REMOVE_PACKAGES=true; shift ;;
            --purge-configs)   PURGE_CONFIGS=true; shift ;;
            -h|--help)         usage ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

main() {
    parse_args "$@"
    require_root

    info "Stopping services..."
    systemctl stop keepalived 2>/dev/null || true
    systemctl stop haproxy 2>/dev/null || true
    systemctl disable keepalived 2>/dev/null || true
    systemctl disable haproxy 2>/dev/null || true

    info "Removing routedns-ingress files..."

    rm -rf "${INSTALL_PREFIX}"
    rm -f /etc/sysctl.d/99-routedns-ingress.conf
    rm -f /etc/sysctl.d/98-routedns-ingress-keepalived.conf
    rm -f /etc/security/limits.d/99-routedns-ingress.conf
    rm -f /etc/logrotate.d/routedns-ingress
    rm -f /etc/rsyslog.d/49-routedns-ingress.conf

    sysctl --system >/dev/null 2>&1 || true
    systemctl restart rsyslog 2>/dev/null || true

    if [[ "${PURGE_CONFIGS}" == "true" ]]; then
        warn "Purging configuration files..."
        rm -f /etc/haproxy/haproxy.cfg
        rm -f /etc/keepalived/keepalived.conf
    fi

    if [[ "${REMOVE_PACKAGES}" == "true" ]]; then
        detect_os
        info "Removing packages..."
        case "${PKG_MANAGER}" in
            apt)
                apt-get remove -y haproxy keepalived 2>/dev/null || true
                ;;
            dnf|yum)
                ${PKG_MANAGER} remove -y haproxy keepalived 2>/dev/null || true
                ;;
        esac
    fi

    info "Uninstall complete."
    info "Backups (if any) remain in ${BACKUP_DIR}/"
}

main "$@"

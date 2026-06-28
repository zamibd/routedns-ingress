#!/usr/bin/env bash
# routedns-ingress — main installer
# Layer-4 TCP ingress for DNS-over-TLS using HAProxy and Keepalived.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROUTEDNS_ROOT="${ROOT}"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

KEEPALIVED_ROLE=""
CONFIGURE_FIREWALL=false
FIREWALL_RESET=false
SKIP_KEEPALIVED=false

usage() {
    cat <<'EOF'
routedns-ingress installer

Usage: sudo ./install.sh [OPTIONS]

Options:
  --role master|backup     Keepalived role (required unless --skip-keepalived)
  --firewall               Configure firewall (UFW or firewalld; incremental, safe)
  --firewall-reset         With --firewall: reset UFW rules first (destructive)
  --ufw                    Alias for --firewall (deprecated)
  --skip-keepalived        Install HAProxy only (no Keepalived/VIP)
  -h, --help               Show this help

Examples:
  sudo ./install.sh --role master
  sudo ./install.sh --role backup --firewall
  sudo ./install.sh --role master --firewall --firewall-reset
  sudo ./install.sh --skip-keepalived

Supported platforms:
  Debian 13 (Trixie)     amd64, arm64
  Ubuntu 24.04, 25.04+   amd64, arm64
  AlmaLinux (all)        amd64, arm64
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)
                KEEPALIVED_ROLE="$2"
                shift 2
                ;;
            --firewall|--ufw)
                CONFIGURE_FIREWALL=true
                shift
                ;;
            --firewall-reset)
                FIREWALL_RESET=true
                CONFIGURE_FIREWALL=true
                shift
                ;;
            --skip-keepalived)
                SKIP_KEEPALIVED=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

print_next_steps() {
    cat <<EOF

================================================================================
  routedns-ingress installation complete
================================================================================

Next steps:

  1. Add backend servers in /etc/haproxy/haproxy.cfg (uncomment/edit server lines)
  2. Remove the _install_placeholder server line
  3. Reload HAProxy:
       sudo make reload

EOF

    if [[ "${SKIP_KEEPALIVED}" == "false" ]]; then
        cat <<EOF
  4. Edit /etc/keepalived/keepalived.conf — replace all CHANGE_ME_* values:
       - CHANGE_ME_INTERFACE
       - CHANGE_ME_VIP / CHANGE_ME_VIP_PREFIX
       - CHANGE_ME_VRRP_SECRET
  5. Restart Keepalived:
       sudo systemctl restart keepalived

EOF
    fi

    cat <<EOF
  6. Run production preflight before go-live:
       sudo make preflight

  Administration:
       make status
       make reload
       make validate
       make preflight

  Documentation:
       ${ROOT}/docs/

================================================================================
EOF
}

main() {
    parse_args "$@"
    require_root

    if [[ "${SKIP_KEEPALIVED}" == "false" && -z "${KEEPALIVED_ROLE}" ]]; then
        die "Keepalived role required. Use --role master|backup or --skip-keepalived."
    fi

    info "Starting routedns-ingress installation..."
    detect_os

    pkg_update
    case "${PKG_MANAGER}" in
        apt) pkg_install haproxy keepalived socat rsyslog logrotate ;;
        dnf|yum) pkg_install haproxy keepalived socat rsyslog logrotate ;;
    esac

    install_scripts

    "${ROOT}/scripts/install-haproxy.sh"

    if [[ "${SKIP_KEEPALIVED}" == "true" ]]; then
        info "Skipping Keepalived installation."
    else
        export KEEPALIVED_ROLE
        "${ROOT}/scripts/install-keepalived.sh"
    fi

    apply_sysctl
    apply_limits
    apply_logrotate
    apply_rsyslog

    if [[ "${CONFIGURE_FIREWALL}" == "true" ]]; then
        export FIREWALL_RESET
        configure_firewall
    fi

    if [[ "${SKIP_KEEPALIVED}" == "true" ]]; then
        export SKIP_KEEPALIVED=true
    fi
    "${ROOT}/scripts/validate.sh"

    print_next_steps
}

main "$@"

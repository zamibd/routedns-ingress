#!/usr/bin/env bash
# routedns-ingress — full A-Z production setup
# Edit .env (3 backend IPs + VIP + role), then: sudo make setup
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

step() { info "==> $*"; }

run_setup() {
    require_root

    step "Loading and rendering configuration from .env..."
    # shellcheck source=scripts/render-config.sh
    source "${ROOT}/scripts/render-config.sh"
    render_configs

    export HAPROXY_CONFIG_SRC="${RENDERED_HAPROXY}"
    export KEEPALIVED_CONFIG_SRC="${RENDERED_KEEPALIVED}"
    export KEEPALIVED_ROLE="${ROLE}"
    export SKIP_KEEPALIVED_DEFAULTS=true

    step "Installing packages and system tuning..."
    detect_os
    pkg_update
    case "${PKG_MANAGER}" in
        apt) pkg_install haproxy keepalived socat rsyslog logrotate ;;
        dnf|yum) pkg_install haproxy keepalived socat rsyslog logrotate ;;
    esac

    install_scripts

    step "Installing HAProxy configuration..."
    "${ROOT}/scripts/install-haproxy.sh"

    step "Installing Keepalived (${ROLE})..."
    "${ROOT}/scripts/install-keepalived.sh"

    step "Applying sysctl, limits, logging..."
    apply_sysctl
    apply_limits
    apply_logrotate
    apply_rsyslog

    if [[ "${CONFIGURE_FIREWALL}" == "yes" ]]; then
        step "Configuring firewall..."
        configure_firewall
    fi

    step "Validating installation..."
    "${ROOT}/scripts/validate.sh"

    step "Running production preflight..."
    "${ROOT}/scripts/preflight.sh"

    cat <<EOF

================================================================================
  routedns-ingress setup complete — production ready
================================================================================

  Role:      ${ROLE}
  VIP:       ${VIP}/${VIP_PREFIX} on ${INTERFACE}
  Backends:  ${BACKEND_1}, ${BACKEND_2}, ${BACKEND_3}:${BACKEND_PORT}

  Verify:
    make status
    make stats
    nc -zv ${VIP} 853

  Config:    ${ROOT}/.env
  Secrets:   VRRP_SECRET is stored in .env (copy to peer node)

================================================================================
EOF
}

run_setup "$@"

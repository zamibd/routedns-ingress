#!/usr/bin/env bash
# routedns-ingress — install Keepalived configuration
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

KEEPALIVED_ROLE="${KEEPALIVED_ROLE:-}"

usage() {
    cat <<EOF
Usage: KEEPALIVED_ROLE=master|backup ${0##*/}

Environment:
  KEEPALIVED_ROLE   Required. Set to 'master' or 'backup'.
EOF
    exit 1
}

install_keepalived() {
    require_root
    detect_os

    [[ -n "${KEEPALIVED_ROLE}" ]] || usage
    case "${KEEPALIVED_ROLE}" in
        master|backup) ;;
        *) die "KEEPALIVED_ROLE must be 'master' or 'backup', got: ${KEEPALIVED_ROLE}" ;;
    esac

    info "Installing Keepalived (${KEEPALIVED_ROLE})..."
    # When INSTALL_LATEST_PACKAGES=yes, install-packages.sh already provided
    # Keepalived (built from source). Re-running apt here would overwrite that
    # binary with the older distro package, so only install when needed.
    if [[ "${INSTALL_LATEST_PACKAGES:-no}" =~ ^(yes|true|1)$ ]]; then
        command -v keepalived &>/dev/null || \
            die "INSTALL_LATEST_PACKAGES=${INSTALL_LATEST_PACKAGES} but keepalived not found — run scripts/install-packages.sh first."
        info "Using existing Keepalived $(parse_keepalived_version) (latest packages mode)."
    else
        pkg_update
        pkg_install keepalived
    fi

    install_scripts

    local src="${KEEPALIVED_CONFIG_SRC:-${ROOT}/configs/keepalived-${KEEPALIVED_ROLE}.conf}"
    [[ -f "${src}" ]] || die "Config not found: ${src}"

    install_file "${src}" "${KEEPALIVED_CFG}"

    install_keepalived_scripts "${ROOT}"

    if [[ "${SKIP_KEEPALIVED_DEFAULTS:-false}" != "true" ]]; then
        apply_keepalived_install_defaults "${KEEPALIVED_CFG}"
    fi

    # Enable IP forwarding and non-local bind for VIP
    cat > /etc/sysctl.d/98-routedns-ingress-keepalived.conf <<'SYSCTL'
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.ip_forward = 1
SYSCTL
    sysctl -p /etc/sysctl.d/98-routedns-ingress-keepalived.conf

    systemctl enable keepalived
    systemctl restart keepalived
    verify_service keepalived

    info "Keepalived installation complete (${KEEPALIVED_ROLE})."
    if [[ "${SKIP_KEEPALIVED_DEFAULTS:-false}" != "true" ]]; then
        warn "Edit ${KEEPALIVED_CFG}: set VIP (replace 203.0.113.100) and auth_pass (replace CHANGE_ME_VRRP_SECRET)."
    fi
}

apply_keepalived_install_defaults() {
    local cfg="${1:-${KEEPALIVED_CFG}}"
    local iface

    iface="$(detect_interface)"
    [[ -n "${iface}" ]] || die "Could not detect network interface for Keepalived."

    sed -i \
        -e "s/CHANGE_ME_INTERFACE/${iface}/g" \
        -e 's/CHANGE_ME_VIP/203.0.113.100/g' \
        -e 's/CHANGE_ME_VIP_PREFIX/32/g' \
        "${cfg}"

    info "Keepalived defaults applied: interface=${iface}, VIP=203.0.113.100/32 (change before production)."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_keepalived
fi

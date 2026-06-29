#!/usr/bin/env bash
# routedns-ingress — install HAProxy configuration
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

install_haproxy() {
    require_root
    detect_os

    info "Installing HAProxy..."
    # When INSTALL_LATEST_PACKAGES=yes, install-packages.sh already provided
    # HAProxy (from backports or built from source). Re-running apt/dnf here
    # could overwrite that with the older distro package, so skip when present.
    if [[ "${INSTALL_LATEST_PACKAGES:-no}" =~ ^(yes|true|1)$ ]]; then
        command -v haproxy &>/dev/null || \
            die "INSTALL_LATEST_PACKAGES=${INSTALL_LATEST_PACKAGES} but haproxy not found — run scripts/install-packages.sh first."
        info "Using existing HAProxy $(parse_haproxy_version) (latest packages mode)."
    else
        pkg_update
        pkg_install haproxy
    fi

    # Ensure runtime directories exist
    mkdir -p /run/haproxy
    chown haproxy:haproxy /run/haproxy 2>/dev/null || true

    local src="${HAPROXY_CONFIG_SRC:-${ROOT}/configs/haproxy.cfg}"
    [[ -f "${src}" ]] || die "HAProxy config not found: ${src}"

    install_file "${src}" "${HAPROXY_CFG}"

    # Validate before starting
    if haproxy -c -f "${HAPROXY_CFG}"; then
        info "HAProxy configuration is valid."
    else
        die "HAProxy configuration validation failed."
    fi

    systemctl enable haproxy
    systemctl restart haproxy
    verify_service haproxy

    info "HAProxy installation complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_haproxy
fi

#!/usr/bin/env bash
# routedns-ingress — platform compatibility test (CI + local containers)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROUTEDNS_ROOT="${ROOT}"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

step() { info "==> $*"; }

keepalived_test_config() {
    local role="$1"
    local src="${ROOT}/configs/keepalived-${role}.conf"
    local dst="/tmp/keepalived-test-${role}.conf"
    local iface

    iface="$(detect_interface)"

    install_keepalived_scripts "${ROOT}"

    sed \
        -e "s/CHANGE_ME_INTERFACE/${iface}/g" \
        -e 's/CHANGE_ME_VRRP_SECRET/testsec1/g' \
        -e 's|CHANGE_ME_VIP/CHANGE_ME_VIP_PREFIX|127.0.0.1/32|g' \
        "${src}" > "${dst}"
    echo "${dst}"
}

install_test_packages() {
    step "Detecting OS and installing packages..."
    export INSTALL_LATEST_PACKAGES="${INSTALL_LATEST_PACKAGES:-no}"
    export HAPROXY_VERSION="${HAPROXY_VERSION:-3.4.1}"
    export KEEPALIVED_VERSION="${KEEPALIVED_VERSION:-2.4.1}"

    # shellcheck source=scripts/install-packages.sh
    source "${ROOT}/scripts/install-packages.sh"
    install_packages

    case "${PKG_MANAGER}" in
        apt) pkg_install make netcat-openbsd ;;
        dnf|yum) pkg_install make nc ;;
    esac
}

validate_haproxy_config() {
    step "Validating HAProxy configuration..."
    make -C "${ROOT}" test-config
    info "HAProxy configuration OK."
}

validate_keepalived_config() {
    step "Validating Keepalived configurations..."

    for role in master backup; do
        local test_cfg
        test_cfg="$(keepalived_test_config "${role}")"
        if keepalived -t -f "${test_cfg}"; then
            info "Keepalived ${role} configuration OK."
        else
            die "Keepalived ${role} configuration validation failed."
        fi
        rm -f "${test_cfg}"
    done
}

verify_scripts() {
    step "Verifying scripts..."
    for script in install.sh uninstall.sh scripts/*.sh; do
        test -x "${ROOT}/${script}" || die "Not executable: ${script}"
    done
    info "All scripts executable."
}

verify_makefile() {
    step "Verifying Makefile targets..."
    make -C "${ROOT}" help >/dev/null
    info "Makefile targets OK."
}

print_platform_summary() {
    step "Platform test summary"
    info "OS:      ${OS_NAME} ${OS_VERSION_ID}"
    info "Arch:    ${OS_ARCH}"
    info "Pkg mgr: ${PKG_MANAGER}"
    info "HAProxy: $(haproxy -v | head -1)"
    info "Keepalived: $(keepalived -v 2>&1 | head -1 || true)"
    info "Platform test passed."
}

main() {
    require_root
    install_test_packages
    verify_scripts
    validate_haproxy_config
    validate_keepalived_config
    verify_makefile
    print_platform_summary
}

main "$@"

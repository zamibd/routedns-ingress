#!/usr/bin/env bash
# routedns-ingress — end-to-end install test (CI with systemd containers)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

step() { info "==> $*"; }

prepare_keepalived_for_test() {
    local cfg="${ROOT}/configs/keepalived-master.conf"
    local test_cfg="/tmp/keepalived-e2e.conf"
    local iface

    install_keepalived_scripts "${ROOT}"
    iface="$(detect_interface)"

    sed \
        -e "s/CHANGE_ME_INTERFACE/${iface}/g" \
        -e 's/CHANGE_ME_VRRP_SECRET/e2etest1/g' \
        -e 's|CHANGE_ME_VIP/CHANGE_ME_VIP_PREFIX|127.0.0.1/32|g' \
        "${cfg}" > "${test_cfg}"

    keepalived -t -f "${test_cfg}"
    rm -f "${test_cfg}"
    info "Keepalived template validates with test substitutions."
}

configure_test_backends() {
    local cfg="/etc/haproxy/haproxy.cfg"
    local backend_port=1853

    step "Starting mock backend on port ${backend_port}..."
    socat "TCP-LISTEN:${backend_port},reuseaddr,fork" "SYSTEM:sleep 1" &
    local socat_pid=$!
    sleep 1

    step "Configuring HAProxy test backend..."
    sed -i '/server _install_placeholder/d' "${cfg}"
    cat >> "${cfg}" <<EOF
    server e2e_test 127.0.0.1:${backend_port} check inter 2s fall 2 rise 1
EOF

    haproxy -c -f "${cfg}"
    systemctl reload haproxy
    sleep 2

    step "Testing TCP ingress on port 853..."
    if ! (echo >/dev/tcp/127.0.0.1/853) 2>/dev/null; then
        kill "${socat_pid}" 2>/dev/null || true
        die "HAProxy is not listening on port 853."
    fi

    kill "${socat_pid}" 2>/dev/null || true
    info "End-to-end TCP path verified."
}

main() {
    require_root

    # jrei/systemd images block service starts during apt via policy-rc.d
    rm -f /usr/sbin/policy-rc.d

    step "Running E2E install test..."
    cd "${ROOT}"

    export ROUTEDNS_ROOT="${ROOT}"
    export ROUTEDNS_CI=1
    export SKIP_KEEPALIVED=true
    ./install.sh --skip-keepalived

    configure_test_backends

    step "Running validate..."
    SKIP_KEEPALIVED=true "${INSTALL_PREFIX}/validate.sh"

    step "Running preflight (expect backend pass, keepalived skipped)..."
    SKIP_KEEPALIVED=true "${INSTALL_PREFIX}/preflight.sh"

    prepare_keepalived_for_test

    step "E2E install test passed."
}

main "$@"

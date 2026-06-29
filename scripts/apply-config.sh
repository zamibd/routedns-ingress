#!/usr/bin/env bash
# routedns-ingress — render configs from .env and apply them live.
# Renders HAProxy/Keepalived from .env, installs the RENDERED files to /etc,
# then reloads both services. Use after editing .env (no full reinstall needed).
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROUTEDNS_ROOT:-$(cd "${_script_dir}/.." && pwd)}"
export ROUTEDNS_ROOT="${ROOT}"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=scripts/render-config.sh
source "${ROOT}/scripts/render-config.sh"

reload_or_restart() {
    local svc="$1"
    if systemctl reload "${svc}" 2>/dev/null; then
        return 0
    fi
    warn "${svc} reload failed; restarting..."
    systemctl restart "${svc}"
}

apply_config() {
    require_root
    detect_os

    step_msg() { info "==> $*"; }

    step_msg "Rendering configs from .env..."
    render_configs

    step_msg "Installing rendered HAProxy config to ${HAPROXY_CFG}..."
    install_file "${RENDERED_HAPROXY}" "${HAPROXY_CFG}"
    haproxy -c -f "${HAPROXY_CFG}" >/dev/null
    info "HAProxy config valid."

    step_msg "Installing rendered Keepalived config to ${KEEPALIVED_CFG}..."
    install_file "${RENDERED_KEEPALIVED}" "${KEEPALIVED_CFG}"
    install_keepalived_scripts "${ROOT}"

    step_msg "Reloading services..."
    reload_or_restart haproxy
    reload_or_restart keepalived

    verify_service haproxy
    verify_service keepalived

    info "Apply complete. Verify with: sudo make preflight"
}

apply_config "$@"

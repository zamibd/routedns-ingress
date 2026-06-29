#!/usr/bin/env bash
# routedns-ingress — render production configs from .env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

SETUP_ENV="${SETUP_ENV:-${ROOT}/.env}"
RENDER_DIR="${ROOT}/config/rendered"
HAPROXY_TEMPLATE="${ROOT}/configs/haproxy.cfg"
KEEPALIVED_MASTER="${ROOT}/configs/keepalived-master.conf"
KEEPALIVED_BACKUP="${ROOT}/configs/keepalived-backup.conf"

is_valid_ip() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

generate_vrrp_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 4
        return
    fi
    # head closes the pipe early; without this, pipefail treats tr's SIGPIPE (141) as failure
    set +o pipefail
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8
    set -o pipefail
}

load_setup_env() {
    if [[ ! -f "${SETUP_ENV}" ]]; then
        die "Missing ${SETUP_ENV}. Run: make init"
    fi

    # shellcheck source=/dev/null
    source "${SETUP_ENV}"

    BACKEND_1="${BACKEND_1:-}"
    BACKEND_2="${BACKEND_2:-}"
    BACKEND_3="${BACKEND_3:-}"
    VIP="${VIP:-}"
    VIP_PREFIX="${VIP_PREFIX:-24}"
    ROLE="${ROLE:-master}"
    BACKEND_PORT="${BACKEND_PORT:-853}"
    USE_PROXY_PROTOCOL="${USE_PROXY_PROTOCOL:-yes}"
    CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-yes}"
    VRRP_SECRET="${VRRP_SECRET:-}"
    INTERFACE="${INTERFACE:-}"

    [[ -n "${BACKEND_1}" && -n "${BACKEND_2}" && -n "${BACKEND_3}" ]] || \
        die "Set BACKEND_1, BACKEND_2, BACKEND_3 in ${SETUP_ENV}"
    [[ -n "${VIP}" ]] || die "Set VIP in ${SETUP_ENV}"

    for ip in "${BACKEND_1}" "${BACKEND_2}" "${BACKEND_3}" "${VIP}"; do
        is_valid_ip "${ip}" || die "Invalid IP address: ${ip}"
    done

    case "${ROLE}" in
        master|backup) ;;
        *) die "ROLE must be 'master' or 'backup', got: ${ROLE}" ;;
    esac

    if [[ -z "${INTERFACE}" ]]; then
        INTERFACE="$(detect_interface)"
    fi
    [[ -n "${INTERFACE}" ]] || die "Could not detect network interface — set INTERFACE in ${SETUP_ENV}"

    if [[ -z "${VRRP_SECRET}" ]]; then
        VRRP_SECRET="$(generate_vrrp_secret)"
        info "Generated VRRP_SECRET (saved to ${SETUP_ENV})"
        if grep -q '^VRRP_SECRET=' "${SETUP_ENV}"; then
            sed -i "s/^VRRP_SECRET=.*/VRRP_SECRET=${VRRP_SECRET}/" "${SETUP_ENV}"
        elif grep -q '^# VRRP_SECRET=' "${SETUP_ENV}"; then
            sed -i "s/^# VRRP_SECRET=.*/VRRP_SECRET=${VRRP_SECRET}/" "${SETUP_ENV}"
        else
            echo "VRRP_SECRET=${VRRP_SECRET}" >> "${SETUP_ENV}"
        fi
    fi

    [[ "${#VRRP_SECRET}" -le 8 ]] || die "VRRP_SECRET must be max 8 characters (Keepalived limit)"
}

render_backend_lines() {
    local proxy_flag=""
    local i ip_var ip weight

    if [[ "${USE_PROXY_PROTOCOL}" == "yes" ]]; then
        # check-send-proxy: health checks must use PROXY v2 when backends accept-proxy only.
        # (tcp-check send proxy v2 was removed in HAProxy 3.4.)
        proxy_flag=" send-proxy-v2 check-send-proxy"
    fi

    for i in 1 2 3; do
        ip_var="BACKEND_${i}"
        ip="${!ip_var}"
        weight=100
        [[ "${i}" -eq 3 ]] && weight=50
        printf '    server dot%d %s:%s check inter 5s fall 3 rise 2 weight %d%s\n' \
            "${i}" "${ip}" "${BACKEND_PORT}" "${weight}" "${proxy_flag}"
    done
}

render_haproxy() {
    local out="${RENDER_DIR}/haproxy.cfg"
    mkdir -p "${RENDER_DIR}"

    # Copy template up to the placeholder (awk is portable; no sed -i).
    awk '/server _install_placeholder/ { exit } { print }' "${HAPROXY_TEMPLATE}" > "${out}"

    render_backend_lines >> "${out}"

    haproxy -c -f "${out}" >/dev/null
    info "Rendered ${out}"
}

render_keepalived() {
    local src="${KEEPALIVED_MASTER}"
    [[ "${ROLE}" == "backup" ]] && src="${KEEPALIVED_BACKUP}"
    local out="${RENDER_DIR}/keepalived.conf"

    mkdir -p "${RENDER_DIR}"
    sed \
        -e "s/CHANGE_ME_INTERFACE/${INTERFACE}/g" \
        -e "s/CHANGE_ME_VRRP_SECRET/${VRRP_SECRET}/g" \
        -e "s|CHANGE_ME_VIP/CHANGE_ME_VIP_PREFIX|${VIP}/${VIP_PREFIX}|g" \
        "${src}" > "${out}"

    if command -v keepalived &>/dev/null; then
        install_keepalived_scripts "${ROOT}"
        keepalived -t -f "${out}"
    else
        warn "Keepalived not installed; rendered ${out} without validation."
    fi
    info "Rendered ${out} (role=${ROLE})"
}

render_configs() {
    load_setup_env
    render_haproxy
    render_keepalived

    export RENDERED_HAPROXY="${RENDER_DIR}/haproxy.cfg"
    export RENDERED_KEEPALIVED="${RENDER_DIR}/keepalived.conf"
    export KEEPALIVED_ROLE="${ROLE}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    render_configs
    info "Config render complete."
fi

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

    VIP="${VIP:-}"
    VIP_PREFIX="${VIP_PREFIX:-24}"
    ROLE="${ROLE:-master}"
    BACKEND_PORT="${BACKEND_PORT:-853}"
    USE_PROXY_PROTOCOL="${USE_PROXY_PROTOCOL:-yes}"
    CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-yes}"
    VRRP_SECRET="${VRRP_SECRET:-}"
    INTERFACE="${INTERFACE:-}"
    NODE_IP="${NODE_IP:-}"
    VRRP_PEER="${VRRP_PEER:-}"

    load_backend_ips
    [[ ${#BACKEND_IPS[@]} -ge 1 ]] || \
        die "Set at least one backend in ${SETUP_ENV} (BACKEND_1, BACKEND_2, ... or BACKENDS=ip1,ip2,...)"
    [[ -n "${VIP}" ]] || die "Set VIP in ${SETUP_ENV}"

    for ip in "${BACKEND_IPS[@]}" "${VIP}"; do
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

    if [[ -n "${NODE_IP}" ]]; then
        is_valid_ip "${NODE_IP}" || die "Invalid NODE_IP: ${NODE_IP}"
    fi
    if [[ -n "${VRRP_PEER}" ]]; then
        is_valid_ip "${VRRP_PEER}" || die "Invalid VRRP_PEER: ${VRRP_PEER}"
    fi
}

resolve_keepalived_vrrp() {
    if [[ -z "${NODE_IP}" ]]; then
        NODE_IP="$(detect_node_ip "${INTERFACE}")"
    fi
    [[ -n "${NODE_IP}" ]] || die "No IPv4 on ${INTERFACE} — set NODE_IP in ${SETUP_ENV}"

    if [[ "${VIP}" == "${NODE_IP}" ]]; then
        if [[ "${ROLE}" == "master" ]]; then
            # VIP is this host's primary IP (common on single-node / cloud primary IP).
            # Priority 255 = VRRP address owner; avoids FAULT when no other source IP exists.
            VRRP_PRIORITY=255
            info "VIP ${VIP} is this node's interface IP — using VRRP address owner (priority 255)"
        else
            VRRP_PRIORITY=90
            warn "VIP equals NODE_IP on backup — VIP should be a floating IP, not this host's primary"
        fi
    else
        case "${ROLE}" in
            master) VRRP_PRIORITY=100 ;;
            backup) VRRP_PRIORITY=90 ;;
        esac
    fi

    # Address owner (priority 255) cannot use weighted track_script — keepalived -t fails.
    if [[ "${VRRP_PRIORITY}" -eq 255 ]]; then
        VRRP_SCRIPT_WEIGHT=""
    else
        VRRP_SCRIPT_WEIGHT="weight -20"
    fi

    # Always pin the VRRP source IP. This sets it from config, so Keepalived does
    # not scan the interface for a source address. Critical when VIP == NODE_IP:
    # otherwise Keepalived ignores the VIP and faults with "no IPv4 address".
    KEEPALIVED_UNICAST_SNIP="${RENDER_DIR}/.keepalived-unicast.snip"
    if [[ -n "${VRRP_PEER}" ]]; then
        cat > "${KEEPALIVED_UNICAST_SNIP}" <<EOF
    unicast_src_ip ${NODE_IP}
    unicast_peer {
        ${VRRP_PEER}
    }
EOF
        info "VRRP unicast enabled: ${NODE_IP} <-> ${VRRP_PEER}"
    else
        printf '    mcast_src_ip %s\n' "${NODE_IP}" > "${KEEPALIVED_UNICAST_SNIP}"
        info "VRRP source pinned to ${NODE_IP} (multicast; set VRRP_PEER for cloud HA)"
    fi
}

render_backend_lines() {
    local proxy_flag="" i ip weight n

    if [[ "${USE_PROXY_PROTOCOL}" == "yes" ]]; then
        # check-send-proxy: health checks must use PROXY v2 when backends accept-proxy only.
        # (tcp-check send proxy v2 was removed in HAProxy 3.4.)
        proxy_flag=" send-proxy-v2 check-send-proxy"
    fi

    n=${#BACKEND_IPS[@]}
    for i in "${!BACKEND_IPS[@]}"; do
        ip="${BACKEND_IPS[$i]}"
        weight=100
        printf '    server dot%d %s:%s check inter 5s fall 3 rise 2 weight %d%s\n' \
            "$((i + 1))" "${ip}" "${BACKEND_PORT}" "${weight}" "${proxy_flag}"
    done
    # stdout is redirected into haproxy.cfg by the caller; log to stderr so this
    # line does not end up in the rendered config (HAProxy would parse the leading
    # "[" timestamp as a scope declaration and fail).
    info "Rendered ${n} backend server line(s)" >&2
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

    resolve_keepalived_vrrp

    mkdir -p "${RENDER_DIR}"
    sed \
        -e "s/CHANGE_ME_INTERFACE/${INTERFACE}/g" \
        -e "s/CHANGE_ME_VRRP_SECRET/${VRRP_SECRET}/g" \
        -e "s/CHANGE_ME_PRIORITY/${VRRP_PRIORITY}/g" \
        -e "s/CHANGE_ME_SCRIPT_WEIGHT/${VRRP_SCRIPT_WEIGHT}/g" \
        -e "s|CHANGE_ME_VIP/CHANGE_ME_VIP_PREFIX|${VIP}/${VIP_PREFIX}|g" \
        "${src}" | awk -v snip="${KEEPALIVED_UNICAST_SNIP}" '
        /CHANGE_ME_UNICAST/ {
            while ((getline line < snip) > 0) print line
            next
        }
        { print }
    ' > "${out}"

    if command -v keepalived &>/dev/null; then
        install_keepalived_scripts "${ROOT}"
        keepalived -t -f "${out}"
    else
        warn "Keepalived not installed; rendered ${out} without validation."
    fi
    info "Rendered ${out} (role=${ROLE}, priority=${VRRP_PRIORITY})"
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

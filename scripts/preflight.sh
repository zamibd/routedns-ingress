#!/usr/bin/env bash
# routedns-ingress — production preflight checks (fails on placeholders)
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_script_dir}/lib.sh" ]]; then
    # shellcheck source=lib.sh
    source "${_script_dir}/lib.sh"
    ROOT="${ROUTEDNS_ROOT:-$(cd "${_script_dir}/.." && pwd)}"
elif [[ -f "${_script_dir}/../scripts/lib.sh" ]]; then
    ROOT="$(cd "${_script_dir}/.." && pwd)"
    # shellcheck source=scripts/lib.sh
    source "${ROOT}/scripts/lib.sh"
else
    echo "lib.sh not found" >&2
    exit 1
fi

SKIP_KEEPALIVED="${SKIP_KEEPALIVED:-false}"
ERRORS=0

fail_check() {
    warn "PREFLIGHT FAIL: $*"
    ERRORS=$((ERRORS + 1))
}

pass_check() {
    info "PREFLIGHT PASS: $*"
}

count_active_backends() {
    awk '
        /^backend dot_backends/ { in_backend=1; next }
        in_backend && /^backend |^frontend |^listen |^global |^defaults / { in_backend=0 }
        in_backend && /^[[:space:]]*server[[:space:]]+/ {
            line=$0
            if (line !~ /^[[:space:]]*#/ && line !~ /disabled/) count++
        }
        END { print count+0 }
    ' "${HAPROXY_CFG}"
}

preflight_haproxy() {
    if [[ ! -f "${HAPROXY_CFG}" ]]; then
        fail_check "HAProxy config not found: ${HAPROXY_CFG}"
        return
    fi

    if ! haproxy -c -f "${HAPROXY_CFG}" &>/dev/null; then
        fail_check "HAProxy configuration is invalid"
        return
    fi
    pass_check "HAProxy configuration syntax"

    local backend_count
    backend_count="$(count_active_backends)"
    if [[ "${backend_count}" -eq 0 ]]; then
        fail_check "No active backend servers in dot_backends — add server lines to ${HAPROXY_CFG}"
    else
        pass_check "At least one active backend server (${backend_count})"
    fi

    if grep -qE '203\.0\.113\.(10|11|12)' "${HAPROXY_CFG}" 2>/dev/null; then
        if grep -E '^[[:space:]]*server.*203\.0\.113\.(10|11|12)' "${HAPROXY_CFG}" | grep -qv '^[[:space:]]*#'; then
            fail_check "HAProxy still uses documentation example backends (203.0.113.x)"
        fi
    fi
}

preflight_keepalived() {
    if [[ "${SKIP_KEEPALIVED}" == "true" ]]; then
        info "Skipping Keepalived preflight (SKIP_KEEPALIVED=true)."
        return
    fi

    if [[ ! -f "${KEEPALIVED_CFG}" ]]; then
        fail_check "Keepalived config not found: ${KEEPALIVED_CFG}"
        return
    fi

    if keepalived_has_placeholders "${KEEPALIVED_CFG}"; then
        fail_check "Keepalived config contains CHANGE_ME placeholders — edit ${KEEPALIVED_CFG}"
    else
        pass_check "Keepalived placeholders resolved"
    fi

    if grep -q '203\.0\.113\.100' "${KEEPALIVED_CFG}" 2>/dev/null; then
        fail_check "Keepalived VIP still uses documentation placeholder 203.0.113.100"
    else
        pass_check "Keepalived VIP is not a documentation placeholder"
    fi

    local iface vip
    iface="$(awk '/^[[:space:]]*interface / {print $2; exit}' "${KEEPALIVED_CFG}")"
    vip="$(awk '/virtual_ipaddress/,/\}/ { if ($1 ~ /\//) { gsub(/\/.*/, "", $1); print $1; exit } }' "${KEEPALIVED_CFG}")"

    if [[ -n "${iface}" ]] && ! ip link show "${iface}" &>/dev/null; then
        fail_check "Keepalived interface '${iface}' does not exist on this host"
    elif [[ -n "${iface}" ]]; then
        pass_check "Keepalived interface '${iface}' exists"
    fi

    if [[ -n "${vip}" ]] && ! keepalived -t -f "${KEEPALIVED_CFG}" &>/dev/null; then
        fail_check "Keepalived configuration validation failed (keepalived -t)"
    elif [[ -n "${vip}" ]]; then
        pass_check "Keepalived configuration syntax"
    fi
}

preflight_firewall() {
    if [[ "${SKIP_FIREWALL_PREFLIGHT:-}" == "true" ]]; then
        info "Skipping firewall preflight (SKIP_FIREWALL_PREFLIGHT=true)."
        return
    fi

    set +o pipefail
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
        if ufw status 2>/dev/null | grep -qE '853/tcp'; then
            :
        else
            fail_check "UFW active but 853/tcp is not allowed"
        fi
        if ufw status 2>/dev/null | grep -qE '22/tcp'; then
            :
        else
            fail_check "UFW active but 22/tcp is not allowed"
        fi
        [[ "${ERRORS}" -eq 0 ]] || return
        pass_check "UFW allows 22/tcp and 853/tcp"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --list-ports 2>/dev/null | grep -q '853/tcp' || \
            firewall-cmd --list-services 2>/dev/null | grep -q ssh || true
        if ! firewall-cmd --query-port=853/tcp &>/dev/null; then
            fail_check "firewalld active but 853/tcp is not allowed"
        else
            pass_check "firewalld allows 853/tcp"
        fi
    else
        info "Firewall preflight skipped (no active ufw/firewalld)."
    fi
    set -o pipefail
}

preflight_packages() {
    local conf="${INSTALL_PREFIX}/packages.conf"
    local target_haproxy target_keepalived installed_h installed_k

    if [[ ! -f "${conf}" ]] || ! grep -q '^INSTALL_LATEST_PACKAGES=yes' "${conf}"; then
        return 0
    fi

    if ! command -v parse_haproxy_version &>/dev/null || ! command -v parse_keepalived_version &>/dev/null; then
        fail_check "Latest package helpers missing from ${INSTALL_PREFIX}/lib.sh — re-run: sudo make setup"
        return
    fi

    target_haproxy="$(awk -F= '/^HAPROXY_TARGET_VERSION=/ {print $2; exit}' "${conf}")"
    target_keepalived="$(awk -F= '/^KEEPALIVED_TARGET_VERSION=/ {print $2; exit}' "${conf}")"
    target_haproxy="${target_haproxy:-3.4.1}"
    target_keepalived="${target_keepalived:-2.4.1}"

    installed_h="$(parse_haproxy_version)"
    installed_k="$(parse_keepalived_version)"

    if printf '%s\n%s\n' "${target_haproxy}" "${installed_h}" | sort -C -V 2>/dev/null; then
        pass_check "HAProxy version ${installed_h} meets target ${target_haproxy}"
    else
        fail_check "HAProxy ${installed_h:-unknown} below target ${target_haproxy} (INSTALL_LATEST_PACKAGES=yes)"
    fi

    if printf '%s\n%s\n' "${target_keepalived}" "${installed_k}" | sort -C -V 2>/dev/null; then
        pass_check "Keepalived version ${installed_k} meets target ${target_keepalived}"
    else
        fail_check "Keepalived ${installed_k:-unknown} below target ${target_keepalived} (INSTALL_LATEST_PACKAGES=yes)"
    fi
}

preflight() {
    info "Running production preflight checks..."

    preflight_haproxy
    preflight_keepalived
    preflight_packages
    preflight_firewall

    echo ""
    if [[ "${ERRORS}" -eq 0 ]]; then
        info "Preflight passed — ready for production traffic."
        exit 0
    fi

    die "Preflight failed with ${ERRORS} error(s). Fix issues above before go-live."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    preflight
fi

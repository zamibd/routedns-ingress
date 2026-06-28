#!/usr/bin/env bash
# routedns-ingress — validate installation and configuration
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

PREFLIGHT="${INSTALL_PREFIX}/preflight.sh"
ERRORS=0
WARNINGS=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        info "PASS: ${desc}"
    else
        warn "FAIL: ${desc}"
        ERRORS=$((ERRORS + 1))
    fi
}

validate() {
    local skip_keepalived="${SKIP_KEEPALIVED:-false}"
    local preflight_script="${PREFLIGHT}"
    [[ -x "${preflight_script}" ]] || preflight_script="${ROOT}/scripts/preflight.sh"

    info "Validating routedns-ingress installation..."

    check "HAProxy is installed" command -v haproxy
    check "HAProxy config exists" test -f "${HAPROXY_CFG}"
    check "HAProxy config is valid" haproxy -c -f "${HAPROXY_CFG}"
    check "HAProxy service is active" systemctl is-active --quiet haproxy
    check "HAProxy service is enabled" systemctl is-enabled --quiet haproxy

    if [[ "${skip_keepalived}" == "true" ]] || ! command -v keepalived &>/dev/null; then
        info "Skipping Keepalived checks."
    else
        check "Keepalived is installed" command -v keepalived
        check "Keepalived service is active" systemctl is-active --quiet keepalived
        check "Keepalived service is enabled" systemctl is-enabled --quiet keepalived
        if grep -q 'CHANGE_ME' "${KEEPALIVED_CFG}" 2>/dev/null; then
            warn "WARN: Keepalived still has CHANGE_ME placeholders — edit before production."
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    check "Health check script exists" test -x "${INSTALL_PREFIX}/healthcheck.sh"
    check "Preflight script exists" test -x "${preflight_script}"
    check "Health check passes" "${INSTALL_PREFIX}/healthcheck.sh"
    check "Sysctl config installed" test -f /etc/sysctl.d/99-routedns-ingress.conf
    check "Limits config installed" test -f /etc/security/limits.d/99-routedns-ingress.conf
    check "Logrotate config installed" test -f /etc/logrotate.d/routedns-ingress
    check "Logrotate postrotate helper exists" test -x "${INSTALL_PREFIX}/logrotate-postrotate.sh"

    if [[ -x "${preflight_script}" ]] && ! SKIP_KEEPALIVED="${skip_keepalived}" "${preflight_script}" &>/dev/null; then
        warn "WARN: Production preflight not passed — run: sudo make preflight"
        WARNINGS=$((WARNINGS + 1))
    fi

    echo ""
    if [[ "${ERRORS}" -eq 0 ]]; then
        info "Validation passed (${WARNINGS} warning(s))."
        exit 0
    else
        die "Validation failed with ${ERRORS} error(s)."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate
fi

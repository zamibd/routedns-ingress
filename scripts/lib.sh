#!/usr/bin/env bash
# routedns-ingress — shared library for install scripts

[[ -n "${ROUTEDNS_LIB_SH:-}" ]] && return 0
ROUTEDNS_LIB_SH=1

set -euo pipefail

readonly PROJECT_NAME="routedns-ingress"
readonly INSTALL_PREFIX="/usr/local/lib/${PROJECT_NAME}"
readonly BACKUP_DIR="/var/backups/${PROJECT_NAME}"
# shellcheck disable=SC2034
readonly HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
# shellcheck disable=SC2034
readonly KEEPALIVED_CFG="/etc/keepalived/keepalived.conf"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root."
}

script_dir() {
    if [[ -n "${ROUTEDNS_ROOT:-}" && -d "${ROUTEDNS_ROOT}" ]]; then
        echo "${ROUTEDNS_ROOT}"
        return
    fi

    local i src dir
    for ((i = 1; i < ${#BASH_SOURCE[@]}; i++)); do
        src="${BASH_SOURCE[$i]}"
        [[ "$(basename "${src}")" == "lib.sh" ]] && continue
        dir="$(cd "$(dirname "${src}")" && pwd)"
        if [[ "$(basename "${dir}")" == "scripts" ]]; then
            echo "$(cd "${dir}/.." && pwd)"
        else
            echo "${dir}"
        fi
        return
    done

    die "Could not determine project root."
}

detect_interface() {
    local iface
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
    if [[ -z "${iface}" ]]; then
        iface="$(ip -o link show | awk -F': ' '$2 != "lo" { print $2; exit }')"
    fi
    iface="${iface%%@*}"
    echo "${iface:-eth0}"
}

install_keepalived_scripts() {
    local root="${1:-$(script_dir)}"
    install -o root -g root -m 755 "${root}/scripts/healthcheck.sh" /etc/keepalived/healthcheck.sh
    install -o root -g root -m 755 "${root}/scripts/keepalived-notify.sh" /etc/keepalived/keepalived-notify.sh
}

keepalived_has_placeholders() {
    local cfg="${1:-${KEEPALIVED_CFG}}"
    [[ -f "${cfg}" ]] || return 1
    grep -Ev '^[[:space:]]*#' "${cfg}" | grep -q 'CHANGE_ME'
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS: /etc/os-release not found."
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_ARCH="$(uname -m)"

    case "${OS_ARCH}" in
        x86_64|amd64) OS_ARCH="amd64" ;;
        aarch64|arm64) OS_ARCH="arm64" ;;
        *) die "Unsupported architecture: ${OS_ARCH}. Supported: amd64, arm64." ;;
    esac

    case "${OS_ID}" in
        debian)
            if [[ "${ROUTEDNS_CI:-}" == "1" ]]; then
                case "${VERSION_ID}" in
                    12|13) PKG_MANAGER="apt" ;;
                    *) die "Unsupported Debian version in CI: ${VERSION_ID}." ;;
                esac
            else
                [[ "${VERSION_ID}" == "13" ]] || die "Unsupported Debian version: ${VERSION_ID}. Supported: 13 (Trixie)."
                PKG_MANAGER="apt"
            fi
            ;;
        ubuntu)
            case "${VERSION_ID}" in
                24.04|25.04|25.10) PKG_MANAGER="apt" ;;
                *) die "Unsupported Ubuntu version: ${VERSION_ID}. Supported: 24.04, 25.04, 25.10." ;;
            esac
            ;;
        almalinux|rocky|centos|rhel)
            PKG_MANAGER="dnf"
            if ! command -v dnf &>/dev/null; then
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            die "Unsupported OS: ${OS_NAME} (${OS_ID}). Supported: Debian 13, Ubuntu 24.04+, AlmaLinux."
            ;;
    esac

    info "Detected: ${OS_NAME} ${OS_VERSION_ID} (${OS_ARCH}) — package manager: ${PKG_MANAGER}"
}

pkg_update() {
    case "${PKG_MANAGER}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            if ! apt-get update -qq; then
                sleep 2
                apt-get update -qq
            fi
            ;;
        dnf|yum)
            ${PKG_MANAGER} makecache -q || true
            ;;
    esac
}

pkg_install() {
    local packages=("$@")
    case "${PKG_MANAGER}" in
        apt)
            apt-get install -y -qq "${packages[@]}"
            ;;
        dnf|yum)
            ${PKG_MANAGER} install -y "${packages[@]}"
            ;;
    esac
}

backup_file() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        mkdir -p "${BACKUP_DIR}"
        local ts
        ts="$(date '+%Y%m%d-%H%M%S')"
        cp -a "${file}" "${BACKUP_DIR}/$(basename "${file}").${ts}.bak"
        info "Backed up ${file} to ${BACKUP_DIR}/"
    fi
}

install_file() {
    local src="$1"
    local dest="$2"
    local mode="${3:-644}"
    backup_file "${dest}"
    install -m "${mode}" -D "${src}" "${dest}"
    info "Installed ${dest}"
}

verify_service() {
    local service="$1"
    if systemctl is-active --quiet "${service}"; then
        info "${service} is active."
    else
        die "${service} is not active. Check: journalctl -u ${service} -n 50"
    fi

    if systemctl is-enabled --quiet "${service}"; then
        info "${service} is enabled."
    else
        warn "${service} is not enabled."
    fi
}

apply_sysctl() {
    local src="${1:-$(script_dir)/configs/sysctl-routedns-ingress.conf}"
    install_file "${src}" "/etc/sysctl.d/99-routedns-ingress.conf"
    if command -v sysctl &>/dev/null; then
        sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-routedns-ingress.conf
    else
        warn "sysctl not found; config installed to /etc/sysctl.d/99-routedns-ingress.conf (apply after reboot or install procps)."
    fi
    info "Applied sysctl tuning."
}

apply_limits() {
    local src="${1:-$(script_dir)/configs/limits-routedns-ingress.conf}"
    install_file "${src}" "/etc/security/limits.d/99-routedns-ingress.conf"
    info "Applied open file limits."
}

apply_logrotate() {
    local src="${1:-$(script_dir)/configs/logrotate-routedns-ingress}"
    install_file "${src}" "/etc/logrotate.d/routedns-ingress"
    info "Installed logrotate configuration."
}

apply_rsyslog() {
    local src="${1:-$(script_dir)/configs/rsyslog-routedns-ingress.conf}"
    if [[ -d /etc/rsyslog.d ]]; then
        install_file "${src}" "/etc/rsyslog.d/49-routedns-ingress.conf"
        systemctl restart rsyslog 2>/dev/null || true
        info "Installed rsyslog configuration."
    else
        warn "rsyslog not found; skipping rsyslog configuration."
    fi
}

install_scripts() {
    local root
    root="$(script_dir)"
    mkdir -p "${INSTALL_PREFIX}"

    install -m 644 "${root}/scripts/lib.sh" "${INSTALL_PREFIX}/lib.sh"

    for script in healthcheck.sh reload.sh validate.sh preflight.sh keepalived-notify.sh logrotate-postrotate.sh; do
        install -m 755 "${root}/scripts/${script}" "${INSTALL_PREFIX}/${script}"
    done
    info "Installed scripts to ${INSTALL_PREFIX}/"
}

rsyslog_rotate_helper() {
    # Used during install before logrotate-postrotate.sh is deployed
    if systemctl is-active --quiet rsyslog 2>/dev/null; then
        systemctl kill -s HUP rsyslog.service 2>/dev/null || true
    elif [[ -x /usr/lib/rsyslog/rsyslog-rotate ]]; then
        /usr/lib/rsyslog/rsyslog-rotate
    elif [[ -x /usr/libexec/rsyslog/rsyslog-rotate ]]; then
        /usr/libexec/rsyslog/rsyslog-rotate
    fi
}

configure_ufw() {
    local reset="${1:-false}"

    if ! command -v ufw &>/dev/null; then
        warn "ufw not installed; skipping UFW configuration."
        return 0
    fi

    if [[ "${reset}" == "true" ]]; then
        warn "Resetting all UFW rules (--firewall-reset)."
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming
        ufw default allow outgoing
    elif ! ufw status 2>/dev/null | grep -qi 'Status: active'; then
        ufw default deny incoming
        ufw default allow outgoing
    else
        info "UFW already active — adding rules without reset."
    fi

    ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || ufw allow 22/tcp
    ufw allow 853/tcp comment 'DNS-over-TLS' >/dev/null 2>&1 || ufw allow 853/tcp
    ufw --force enable
    info "UFW configured: 22/tcp, 853/tcp open."
}

configure_firewalld() {
    if ! command -v firewall-cmd &>/dev/null; then
        warn "firewall-cmd not found; skipping firewalld configuration."
        return 0
    fi

    systemctl enable --now firewalld 2>/dev/null || true

    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || firewall-cmd --permanent --add-port=22/tcp
    firewall-cmd --permanent --add-port=853/tcp
    firewall-cmd --reload
    info "firewalld configured: ssh, 853/tcp open."
}

configure_firewall() {
    local reset="${FIREWALL_RESET:-false}"

    if command -v ufw &>/dev/null; then
        configure_ufw "${reset}"
    elif command -v firewall-cmd &>/dev/null; then
        configure_firewalld
    else
        case "${PKG_MANAGER:-}" in
            dnf|yum)
                warn "Installing firewalld..."
                pkg_install firewalld
                configure_firewalld
                ;;
            apt)
                warn "Installing ufw..."
                pkg_install ufw
                configure_ufw "${reset}"
                ;;
            *)
                warn "No firewall tool available; configure 22/tcp and 853/tcp manually."
                ;;
        esac
    fi
}

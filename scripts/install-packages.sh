#!/usr/bin/env bash
# routedns-ingress — install HAProxy and Keepalived (distro default or pinned latest)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

readonly DEFAULT_HAPROXY_VERSION="3.4.1"
readonly DEFAULT_KEEPALIVED_VERSION="2.4.1"
readonly KEEPALIVED_BASE_URL="https://www.keepalived.org/software"
readonly HAPROXY_SRC_BASE_URL="https://www.haproxy.org/download"
readonly HAPROXY_DEB_KEY="/etc/apt/keyrings/haproxy-archive-keyring.gpg"
readonly HAPROXY_DEB_LIST="/etc/apt/sources.list.d/routedns-haproxy.list"
readonly BUILD_DIR="${BUILD_DIR:-/tmp/routedns-ingress-build}"

INSTALL_LATEST_PACKAGES="${INSTALL_LATEST_PACKAGES:-no}"
HAPROXY_VERSION="${HAPROXY_VERSION:-${DEFAULT_HAPROXY_VERSION}}"
KEEPALIVED_VERSION="${KEEPALIVED_VERSION:-${DEFAULT_KEEPALIVED_VERSION}}"

step() { info "==> $*"; }

keepalived_md5() {
    case "$1" in
        2.4.1) echo "a0142a5c819e8ec909c8fc58d0733ed4" ;;
        2.4.0) echo "efff185055cdc68864cf408336974f76" ;;
        2.3.4) echo "622b09f4502ada4c6d20ef1c29205f77" ;;
        *) return 1 ;;
    esac
}

installed_haproxy_version() {
    parse_haproxy_version
}

installed_keepalived_version() {
    parse_keepalived_version
}

version_at_least() {
    local have="$1" want="$2"
    [[ -n "${have}" && -n "${want}" ]] || return 1
    printf '%s\n%s\n' "${want}" "${have}" | sort -C -V
}

verify_latest_versions() {
    local haproxy_have keepalived_have

    haproxy_have="$(installed_haproxy_version)"
    keepalived_have="$(installed_keepalived_version)"

    if ! version_at_least "${haproxy_have}" "${HAPROXY_VERSION}"; then
        die "HAProxy ${haproxy_have:-unknown} installed; need >= ${HAPROXY_VERSION}"
    fi
    if ! version_at_least "${keepalived_have}" "${KEEPALIVED_VERSION}"; then
        die "Keepalived ${keepalived_have:-unknown} installed; need >= ${KEEPALIVED_VERSION}"
    fi

    info "Verified HAProxy ${haproxy_have} and Keepalived ${keepalived_have}"
}

write_packages_manifest() {
    mkdir -p "${INSTALL_PREFIX}"
    cat > "${INSTALL_PREFIX}/packages.conf" <<EOF
INSTALL_LATEST_PACKAGES=${INSTALL_LATEST_PACKAGES}
INSTALLED_HAPROXY_VERSION=$(installed_haproxy_version)
INSTALLED_KEEPALIVED_VERSION=$(installed_keepalived_version)
EOF
    if [[ "${INSTALL_LATEST_PACKAGES}" == "yes" ]]; then
        cat >> "${INSTALL_PREFIX}/packages.conf" <<EOF
HAPROXY_TARGET_VERSION=${HAPROXY_VERSION}
KEEPALIVED_TARGET_VERSION=${KEEPALIVED_VERSION}
EOF
    fi
    info "Wrote ${INSTALL_PREFIX}/packages.conf"
}

install_aux_packages() {
    case "${PKG_MANAGER}" in
        apt)
            pkg_install socat rsyslog logrotate procps ca-certificates iproute2
            if ! command -v curl &>/dev/null; then
                pkg_install curl
            fi
            ;;
        dnf|yum)
            pkg_install socat rsyslog logrotate procps-ng ca-certificates
            if ! command -v ip &>/dev/null; then
                ${PKG_MANAGER} install -y iproute 2>/dev/null || true
            fi
            if ! command -v curl &>/dev/null; then
                ${PKG_MANAGER} install -y curl-minimal 2>/dev/null || ${PKG_MANAGER} install -y curl
            fi
            ;;
    esac
}

apt_build_deps() {
    pkg_install \
        build-essential \
        ca-certificates \
        curl \
        libipset-dev \
        libnl-3-dev \
        libnl-genl-3-dev \
        libnftnl-dev \
        libpcre2-dev \
        libssl-dev \
        libsystemd-dev \
        liblua5.4-dev \
        pkg-config \
        zlib1g-dev
}

dnf_build_deps() {
    pkg_install \
        gcc \
        make \
        openssl-devel \
        pcre2-devel \
        systemd-devel \
        zlib-devel \
        libnl3-devel \
        libnftnl-devel \
        libmnl-devel \
        libnetfilter_conntrack-devel \
        libipset-devel \
        lua-devel
}

download_verify() {
    local url="$1" dest="$2" expected_md5="$3"

    curl -fsSL "${url}" -o "${dest}"
    local actual_md5
    actual_md5="$(md5sum "${dest}" | awk '{print $1}')"
    [[ "${actual_md5}" == "${expected_md5}" ]] || \
        die "Checksum mismatch for ${url} (expected ${expected_md5}, got ${actual_md5})"
}

install_haproxy_from_source() {
    local tarball="haproxy-${HAPROXY_VERSION}.tar.gz"
    local haproxy_series="${HAPROXY_VERSION%.*}"
    local url="${HAPROXY_SRC_BASE_URL}/${haproxy_series}/src/${tarball}"
    local work="${BUILD_DIR}/haproxy-${HAPROXY_VERSION}"

    step "Building HAProxy ${HAPROXY_VERSION} from source..."

    case "${PKG_MANAGER}" in
        apt) apt_build_deps ;;
        dnf|yum) dnf_build_deps ;;
    esac

    mkdir -p "${BUILD_DIR}"
    rm -rf "${work}"
    curl -fsSL "${url}" -o "${BUILD_DIR}/${tarball}"
    tar -xzf "${BUILD_DIR}/${tarball}" -C "${BUILD_DIR}"

    (
        cd "${work}"
        make -j"$(nproc 2>/dev/null || echo 2)" \
            TARGET=linux-glibc \
            USE_OPENSSL=1 \
            USE_PCRE2=1 \
            USE_ZLIB=1 \
            USE_SYSTEMD=1 \
            USE_PROMEX=1
        make install PREFIX=/usr SBINDIR=/usr/sbin
    )

    if [[ ! -x /usr/sbin/haproxy ]]; then
        die "HAProxy source install failed: /usr/sbin/haproxy missing"
    fi

    # Ensure runtime directories and systemd unit exist.
    mkdir -p /run/haproxy /var/lib/haproxy
    id haproxy &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin haproxy 2>/dev/null || true
    chown haproxy:haproxy /run/haproxy /var/lib/haproxy 2>/dev/null || true

    if [[ ! -f /lib/systemd/system/haproxy.service && ! -f /usr/lib/systemd/system/haproxy.service ]]; then
        install -o root -g root -m 644 "${ROOT}/configs/haproxy.service" \
            /lib/systemd/system/haproxy.service 2>/dev/null || \
            install -o root -g root -m 644 "${ROOT}/configs/haproxy.service" \
            /usr/lib/systemd/system/haproxy.service
        systemctl daemon-reload 2>/dev/null || true
    fi

    info "HAProxy $(installed_haproxy_version) installed from source."
}

install_haproxy_apt_repo() {
    local suite="$1"
    local pin_major_minor="$2"

    step "Installing HAProxy ${pin_major_minor}.x from haproxy.debian.net (${suite})..."

    pkg_install ca-certificates curl
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://haproxy.debian.net/haproxy-archive-keyring.gpg" -o "${HAPROXY_DEB_KEY}"
    echo "deb [signed-by=${HAPROXY_DEB_KEY}] https://haproxy.debian.net ${suite} main" > "${HAPROXY_DEB_LIST}"
    pkg_update
    apt-get install -y -qq "haproxy=${pin_major_minor}.*"
}

install_haproxy_apt_ppa() {
    local ppa="$1"
    local pin_major_minor="$2"

    step "Installing HAProxy ${pin_major_minor}.x from ${ppa}..."

    pkg_install ca-certificates curl software-properties-common
    add-apt-repository -y "${ppa}"
    pkg_update
    apt-get install -y -qq "haproxy=${pin_major_minor}.*"
}

install_haproxy_latest() {
    local pin_major_minor="${HAPROXY_VERSION%.*}"

    case "${PKG_MANAGER}" in
        apt)
            case "${OS_ID}:${OS_VERSION_ID}" in
                debian:13)
                    install_haproxy_apt_repo "trixie-backports-3.4" "${pin_major_minor}"
                    ;;
                ubuntu:25.10)
                    install_haproxy_apt_ppa "ppa:vbernat/haproxy-3.4" "${pin_major_minor}"
                    ;;
                *)
                    install_haproxy_from_source
                    return 0
                    ;;
            esac
            ;;
        dnf|yum)
            install_haproxy_from_source
            return 0
            ;;
        *)
            die "Unsupported package manager: ${PKG_MANAGER}"
            ;;
    esac

    local have
    have="$(installed_haproxy_version)"
    if ! version_at_least "${have}" "${HAPROXY_VERSION}"; then
        warn "HAProxy package ${have:-unknown} below ${HAPROXY_VERSION}; building from source."
        install_haproxy_from_source
    fi
}

install_keepalived_from_source() {
    local tarball="keepalived-${KEEPALIVED_VERSION}.tar.gz"
    local url="${KEEPALIVED_BASE_URL}/${tarball}"
    local expected_md5 work

    expected_md5="$(keepalived_md5 "${KEEPALIVED_VERSION}")" || \
        die "No MD5 checksum on file for Keepalived ${KEEPALIVED_VERSION}"

    step "Building Keepalived ${KEEPALIVED_VERSION} from source..."

    case "${PKG_MANAGER}" in
        apt)
            pkg_install \
                build-essential \
                libssl-dev \
                libnl-3-dev \
                libnl-genl-3-dev \
                libipset-dev \
                libnftnl-dev \
                pkg-config \
                autoconf \
                automake
            ;;
        dnf|yum)
            dnf_build_deps
            pkg_install autoconf automake
            ;;
    esac

    mkdir -p "${BUILD_DIR}"
    work="${BUILD_DIR}/keepalived-${KEEPALIVED_VERSION}"
    rm -rf "${work}"
    download_verify "${url}" "${BUILD_DIR}/${tarball}" "${expected_md5}"
    tar -xzf "${BUILD_DIR}/${tarball}" -C "${BUILD_DIR}"

    local systemd_unit_dir="/lib/systemd/system"
    [[ -d "${systemd_unit_dir}" ]] || systemd_unit_dir="/usr/lib/systemd/system"

    (
        cd "${work}"
        ./configure \
            --prefix=/usr \
            --sysconfdir=/etc \
            --localstatedir=/var \
            --runstatedir=/run \
            --with-systemdsystemunitdir="${systemd_unit_dir}"
        make -j"$(nproc 2>/dev/null || echo 2)"
        make install
    )

    mkdir -p /etc/keepalived
    install -o root -g root -m 644 "${ROOT}/configs/keepalived.service" "${systemd_unit_dir}/keepalived.service"

    systemctl daemon-reload 2>/dev/null || true

    if [[ ! -x /usr/sbin/keepalived && ! -x /usr/local/sbin/keepalived ]]; then
        die "Keepalived source install failed: keepalived binary missing"
    fi

    info "Keepalived $(installed_keepalived_version) installed from source."
}

install_keepalived_latest() {
    install_keepalived_from_source
}

install_distro_haproxy_keepalived() {
    step "Installing HAProxy and Keepalived from ${PKG_MANAGER} repositories..."
    pkg_install haproxy keepalived
}

install_packages() {
    require_root
    detect_os
    pkg_update
    install_aux_packages

    case "${INSTALL_LATEST_PACKAGES}" in
        yes|true|1)
            info "INSTALL_LATEST_PACKAGES=yes — target HAProxy ${HAPROXY_VERSION}, Keepalived ${KEEPALIVED_VERSION}"
            install_haproxy_latest
            install_keepalived_latest
            verify_latest_versions
            ;;
        *)
            install_distro_haproxy_keepalived
            ;;
    esac

    write_packages_manifest
    info "Package installation complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_packages
fi

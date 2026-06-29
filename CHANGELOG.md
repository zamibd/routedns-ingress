# Changelog

All notable changes to routedns-ingress are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- HAProxy 3.4 compatibility: use `check-send-proxy` on server lines instead of removed `tcp-check send proxy v2`

### Added

- **`INSTALL_LATEST_PACKAGES`** in `.env` — opt-in HAProxy 3.4.1 + Keepalived 2.4.1
- **`scripts/install-packages.sh`** — distro default or pinned latest (repo/source per OS)
- **`--latest-packages`** flag on `install.sh`
- **`make test-latest-packages`** and **Latest Packages** CI workflow
- Preflight checks for package versions when latest install is enabled
- Systemd unit templates for source-built HAProxy/Keepalived

## [1.2.0] - 2026-06-29

### Added

- **`make setup`** — one-command A-Z production deploy
- **`.env`** in project root — edit 3 backend IPs + VIP + role, run setup
- **`make init`** — creates `.env` from `.env.example`
- **`scripts/setup.sh`** and **`scripts/render-config.sh`** — auto-render HAProxy/Keepalived configs
- Auto-generates `VRRP_SECRET` and saves to `.env`
- Auto-detects network interface

## [1.1.0] - 2026-06-29

### Added

- Production preflight script (`make preflight`) — fails on placeholders and missing backends
- `make reload-strict` — preflight gate before HAProxy reload
- AlmaLinux firewalld support via `--firewall`
- Safe incremental firewall configuration (no UFW reset by default)
- `--firewall-reset` for destructive UFW reset on fresh nodes
- Portable logrotate postrotate helper (Debian + RHEL)
- E2E install CI workflow with systemd containers
- Release workflow for tagged versions (`v*.*.*`)
- Auto-detect network interface at Keepalived install time

### Fixed

- Keepalived no longer fails to start due to invalid `CHANGE_ME_INTERFACE`
- HAProxy ships with disabled install placeholder; preflight enforces real backends
- Logrotate postrotate path no longer Debian-only

## [1.0.0] - 2026-06-29

### Added

- Makefile for simplified install, reload, validate, and admin commands
- Layer-4 TCP ingress for DNS-over-TLS (port 853) using HAProxy
- TCP passthrough — no TLS termination, no DNS parsing
- Keepalived VRRP high availability with Virtual IP failover
- HAProxy load balancing: least connections, round robin, weighted round robin
- TCP health checks with automatic backend failover
- PROXY Protocol v2 support (frontend accept, backend send)
- IPv4 and IPv6 frontend bindings
- Zero-downtime HAProxy reload via master-worker mode
- Production sysctl kernel tuning
- Open file limit configuration
- rsyslog and logrotate integration
- HAProxy stats socket (localhost)
- Optional UFW firewall configuration (22/tcp, 853/tcp)
- Health check script for Keepalived VRRP tracking
- Install and uninstall scripts with OS detection
- Modular install scripts for HAProxy and Keepalived
- Validation, reload, and health check helper scripts
- Complete documentation (architecture, installation, tuning, monitoring, troubleshooting)
- CI workflow with shellcheck and config validation
- Platform test CI across Debian 13, Ubuntu 24.04/25.04, AlmaLinux 9/10 (amd64 + arm64)
- Support for Debian 13, Ubuntu 24.04+, AlmaLinux (amd64, arm64)

[1.2.0]: https://github.com/routedns/routedns-ingress/releases/tag/v1.2.0
[1.1.0]: https://github.com/routedns/routedns-ingress/releases/tag/v1.1.0
[1.0.0]: https://github.com/routedns/routedns-ingress/releases/tag/v1.0.0

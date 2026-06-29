# Installation

## Supported Platforms

| OS | Versions | Architectures |
|----|----------|---------------|
| Debian | 13 (Trixie) | amd64, arm64 |
| Ubuntu | 24.04, 25.04, 25.10 | amd64, arm64 |
| AlmaLinux | All | amd64, arm64 |

No Docker. All components run as native system packages.

## Prerequisites

- Root or sudo access
- Network interface configured with a static IP
- Outbound internet access for package installation
- Two nodes for HA (optional but recommended)

## Quick Install

Clone the repository and run the installer:

```bash
git clone https://github.com/routedns/routedns-ingress.git
cd routedns-ingress
make help
```

**Primary (MASTER) node:**

```bash
sudo make install-master
```

**Secondary (BACKUP) node:**

```bash
sudo make install-backup
```

**HAProxy only (no VIP):**

```bash
sudo make install-standalone
```

**With firewall (UFW or firewalld):**

```bash
sudo make install-master-firewall
```

Use `--firewall-reset` only on fresh nodes to wipe existing UFW rules:

```bash
sudo ./install.sh --role master --firewall-reset
```

On AlmaLinux, `--firewall` configures firewalld (ssh + 853/tcp).

## Latest upstream packages (optional)

By default, `make setup` installs **HAProxy** and **Keepalived** from your distro repositories (recommended for most deployments).

To install pinned upstream versions (**HAProxy 3.4.1**, **Keepalived 2.4.1**), set in `.env`:

```bash
INSTALL_LATEST_PACKAGES=yes
HAPROXY_VERSION=3.4.1
KEEPALIVED_VERSION=2.4.1
```

Then run `sudo make setup` as usual.

| OS | HAProxy 3.4.1 | Keepalived 2.4.1 |
|----|---------------|------------------|
| Debian 13 | [haproxy.debian.net](https://haproxy.debian.net/) backports | Source build |
| Ubuntu 24.04 / 25.04 | Source build | Source build |
| Ubuntu 25.10 | PPA `vbernat/haproxy-3.4` | Source build |
| AlmaLinux | Source build | Source build |

Or use the installer flag:

```bash
sudo ./install.sh --role master --latest-packages
```

Verify after install:

```bash
haproxy -v | head -1
keepalived -v 2>&1 | head -1
sudo make preflight
```

Test locally (requires root):

```bash
sudo make test-latest-packages
```

## What the Installer Does

1. Detects OS and architecture
2. Updates package cache
3. Installs `haproxy`, `keepalived`, `socat`, `rsyslog`, `logrotate`
4. Backs up existing configuration files
5. Installs production HAProxy and Keepalived configs
6. Applies sysctl kernel tuning
7. Configures open file limits
8. Installs logrotate and rsyslog rules
9. Enables and starts `haproxy.service` and `keepalived.service`
10. Validates the installation
11. Prints next steps

## Post-Installation Configuration

### 1. Backend Servers

Edit `/etc/haproxy/haproxy.cfg` and add your backend HAProxy servers:

```haproxy
backend dot_backends
    balance leastconn
    option tcp-check
    tcp-check connect port 853

    server dot1 10.0.1.10:853 check inter 5s fall 3 rise 2 weight 100 send-proxy-v2
    server dot2 10.0.1.11:853 check inter 5s fall 3 rise 2 weight 100 send-proxy-v2
```

Remove the `_install_placeholder` server line. Reload:

```bash
sudo make reload
```

### 2. Virtual IP (Keepalived)

The installer auto-detects your network interface and sets a documentation VIP (`203.0.113.100/32`).
Edit `/etc/keepalived/keepalived.conf` on both nodes before production:

| Setting | Description |
|---------|-------------|
| `virtual_ipaddress` | Replace `203.0.113.100/32` with your VIP |
| `auth_pass` | Replace `CHANGE_ME_VRRP_SECRET` (max 8 characters) |
| `virtual_router_id` | Same on both nodes (1–255) |
| `priority` | MASTER: 100, BACKUP: 90 |

Restart Keepalived:

```bash
sudo systemctl restart keepalived
```

### 3. DNS Records

Point your DoT hostname A/AAAA records to the VIP.

## Verification

```bash
sudo make validate
sudo make preflight    # production gate — must pass before go-live
```

Check services:

```bash
systemctl status haproxy
systemctl status keepalived
```

Check VIP on MASTER:

```bash
ip addr show | grep 10.0.0.100
```

Test TCP connectivity:

```bash
nc -zv 10.0.0.100 853
```

## Uninstall

```bash
sudo ./uninstall.sh                  # Stop services, remove overlays
sudo ./uninstall.sh --purge-configs  # Also remove haproxy/keepalived configs
sudo ./uninstall.sh --remove-packages # Also remove packages
```

Backups are preserved in `/var/backups/routedns-ingress/`.

## Upgrade

1. Pull the latest release
2. Run `sudo ./install.sh --role master` (or backup)
3. The installer backs up existing configs before overwriting

Review the [CHANGELOG](../CHANGELOG.md) before upgrading.

## Backup

Before making changes, back up:

```bash
sudo cp /etc/haproxy/haproxy.cfg /var/backups/
sudo cp /etc/keepalived/keepalived.conf /var/backups/
```

The installer automatically backs up to `/var/backups/routedns-ingress/` with timestamps.

# routedns-ingress

Layer-4 TCP ingress for DNS-over-TLS (DoT) — the frontend entry point for the [RouteDNS](https://github.com/routedns) platform.

routedns-ingress receives incoming DoT TCP connections on port 853 and forwards them transparently to backend HAProxy servers. It does not terminate TLS, parse DNS packets, or perform any application-layer processing.

## Quick Start (3 steps)

```bash
git clone https://github.com/routedns/routedns-ingress.git
cd routedns-ingress

make init
# Edit .env — set BACKEND_1, BACKEND_2, BACKEND_3, VIP, ROLE

sudo make setup    # does everything A-Z, production ready
```

On the **backup node**, copy `.env` from master, set `ROLE=backup`, run `sudo make setup` again.

## What `make setup` does

1. Reads `.env`
2. Renders HAProxy + Keepalived configs (3 backends, VIP, VRRP)
3. Installs packages (haproxy, keepalived)
4. Applies sysctl, limits, logging
5. Configures firewall (ssh + 853/tcp)
6. Starts and enables services
7. Runs validate + preflight

No manual editing of `/etc/haproxy/haproxy.cfg` required.

## Features

- **Layer-4 TCP ingress** — pure byte forwarding
- **TCP passthrough** — DNS-over-TLS compatible, no TLS termination
- **No DNS parsing** — zero application-layer inspection
- **Load balancing** — least connections, round robin, weighted round robin
- **Backend weights** — distribute traffic by capacity
- **TCP health checks** — automatic backend failover
- **Zero-downtime reload** — graceful HAProxy config reload
- **IPv4 and IPv6** — dual-stack frontends
- **PROXY Protocol v2** — preserve client IP for backends
- **High availability** — Keepalived VRRP with Virtual IP
- **Connection limits** — production-safe defaults
- **Logging** — journald, rsyslog, logrotate
- **Kernel tuning** — sysctl and file descriptor limits

## Architecture

```
                Client
                   │
             DoT TCP :853
                   │
            Virtual IP (VIP)
                   │
              Keepalived
                   │
         HAProxy (TCP Ingress)
                   │
          Backend HAProxy Servers
```

| Component | Role |
|-----------|------|
| Keepalived | VRRP failover, Virtual IP management |
| HAProxy | Layer-4 TCP load balancer on port 853 |
| Backend HAProxy | Downstream RouteDNS infrastructure |

See [docs/setup.md](docs/setup.md) for full setup guide.

## Supported Platforms

| OS | Versions | Architectures |
|----|----------|---------------|
| Debian | 13 (Trixie) | amd64, arm64 |
| Ubuntu | 24.04, 25.04, 25.10 | amd64, arm64 |
| AlmaLinux | All | amd64, arm64 |

Native packages only. No Docker, no Kubernetes.

## CI

| Workflow | Purpose |
|----------|---------|
| [CI](.github/workflows/ci.yml) | ShellCheck, config validation, Makefile |
| [Platform Tests](.github/workflows/platform-test.yml) | Debian 13, Ubuntu 24.04/25.04, AlmaLinux 9/10 on amd64 + arm64 |
| [E2E Install](.github/workflows/e2e-install.yml) | Full install + TCP path test with systemd |
| [Release](.github/workflows/release.yml) | Tagged releases (`v*.*.*`) |

Run locally:

```bash
make ci                              # lint + haproxy config test
sudo make test-platform              # platform test (on target OS)
sudo make test-e2e                   # full E2E install test (systemd required)
sudo make preflight                  # production gate before go-live
```

## Installation

```bash
git clone https://github.com/routedns/routedns-ingress.git
cd routedns-ingress

make help              # list all commands

# Primary node
sudo make install-master

# Secondary node
sudo make install-backup

# With firewall (UFW on Debian/Ubuntu, firewalld on AlmaLinux)
sudo make install-master-firewall
```

Or use the installer directly:

```bash
sudo ./install.sh --role master
sudo ./install.sh --role backup
sudo ./install.sh --role master --firewall
```

See [docs/installation.md](docs/installation.md) for full instructions.

## Quick Start

**1. Install on two nodes:**

```bash
sudo make install-master   # Node 1
sudo make install-backup   # Node 2
```

**2. Add backend servers** in `/etc/haproxy/haproxy.cfg` and remove `_install_placeholder`:

```haproxy
backend dot_backends
    server dot1 10.0.1.10:853 check inter 5s fall 3 rise 2 send-proxy-v2
    server dot2 10.0.1.11:853 check inter 5s fall 3 rise 2 send-proxy-v2
```

**3. Configure Keepalived** — replace `CHANGE_ME_VRRP_SECRET` and VIP `203.0.113.100` in `/etc/keepalived/keepalived.conf` on both nodes, then:

```bash
sudo systemctl restart keepalived
```

**4. Reload HAProxy:**

```bash
sudo make reload-strict
```

**5. Point DNS** A/AAAA records for your DoT hostname to the VIP.

**6. Production preflight:**

```bash
sudo make preflight
nc -zv YOUR_VIP 853
```

## Configuration

All configuration is static file-based. No API, no database, no dynamic discovery.

| File | Purpose |
|------|---------|
| `/etc/haproxy/haproxy.cfg` | Backend servers, balancing, limits |
| `/etc/keepalived/keepalived.conf` | VIP, VRRP, failover |

After editing HAProxy config:

```bash
sudo systemctl reload haproxy
```

Documentation:

- [HAProxy configuration](docs/haproxy.md)
- [Keepalived / VIP setup](docs/keepalived.md)
- [Performance tuning](docs/tuning.md)
- [Monitoring](docs/monitoring.md)

## Example Deployment

Two ingress nodes with three backend HAProxy servers:

```
VIP: 10.0.0.100

ingress-1 (MASTER)          ingress-2 (BACKUP)
  10.0.0.1                    10.0.0.2
  HAProxy + Keepalived        HAProxy + Keepalived
         \                      /
          \                    /
           Backend Pool
           10.0.1.10:853
           10.0.1.11:853
           10.0.1.12:853
```

DNS record: `dot.example.com A 10.0.0.100`

## Administration

```bash
make status                    # Service status
sudo make reload               # Zero-downtime config reload
sudo make restart-haproxy
sudo make restart-keepalived
sudo make healthcheck
sudo make logs
make stats
```

Or use systemd directly:

```bash
systemctl status haproxy
systemctl reload haproxy       # Zero-downtime config reload
systemctl restart haproxy
systemctl status keepalived
systemctl restart keepalived
```

Helper scripts (installed to `/usr/local/lib/routedns-ingress/`):

```bash
validate.sh     # Full installation validation  →  make validate
reload.sh       # Validate and reload HAProxy   →  make reload
healthcheck.sh  # HAProxy health check          →  make healthcheck
```

## Performance Tuning

Kernel tuning is applied automatically during installation. Key settings:

| Parameter | Value |
|-----------|-------|
| `net.core.somaxconn` | 65535 |
| `net.ipv4.tcp_max_syn_backlog` | 65535 |
| `fs.file-max` | 2097152 |
| HAProxy `maxconn` | 50000 |

See [docs/tuning.md](docs/tuning.md) for capacity planning and advanced tuning.

## Security Recommendations

- Change `CHANGE_ME_VRRP_SECRET` and documentation VIP `203.0.113.100` in Keepalived before production
- Use `sudo make install-master-firewall` (safe, incremental) or `--firewall-reset` only on fresh nodes
- AlmaLinux: firewalld is configured automatically with `--firewall`
- Stats socket is bound to localhost only
- No TLS termination — reduced attack surface
- Connection limits prevent resource exhaustion
- Keep systems updated: `apt upgrade` / `dnf upgrade`

## Production Checklist

- [ ] Install on two nodes (MASTER + BACKUP)
- [ ] Add backend servers in `haproxy.cfg`
- [ ] Remove `_install_placeholder` server line
- [ ] Replace `CHANGE_ME_VRRP_SECRET` and VIP `203.0.113.100` in Keepalived
- [ ] Configure firewall: `sudo make install-master-firewall` or cloud security groups
- [ ] Run production preflight: `sudo make preflight`
- [ ] Verify VIP on MASTER: `ip addr show`
- [ ] Point DNS A/AAAA records to VIP
- [ ] Test connectivity: `nc -zv VIP 853`
- [ ] Test failover: stop HAProxy on MASTER, verify VIP moves
- [ ] Set up monitoring (journald, stats socket, optional Prometheus)

## Monitoring

```bash
# Service status
journalctl -u haproxy -f
journalctl -u keepalived -f

# HAProxy stats
curl -s http://127.0.0.1:8404/stats
echo "show stat" | socat stdio /run/haproxy/admin.sock

# Log files
tail -f /var/log/haproxy.log
```

See [docs/monitoring.md](docs/monitoring.md).

## Troubleshooting

```bash
sudo /usr/local/lib/routedns-ingress/validate.sh
haproxy -c -f /etc/haproxy/haproxy.cfg
journalctl -u haproxy -u keepalived -n 50
```

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Uninstall

```bash
sudo ./uninstall.sh                   # Stop services, remove overlays
sudo ./uninstall.sh --purge-configs   # Also remove configs
sudo ./uninstall.sh --remove-packages # Also remove packages
```

## FAQ

**Does routedns-ingress terminate TLS?**
No. It forwards TCP bytes transparently. TLS is handled by backend servers.

**Does it parse DNS packets?**
No. Pure Layer-4 forwarding only.

**How do I add a backend server?**
Add a `server` line to `/etc/haproxy/haproxy.cfg` and run `systemctl reload haproxy`.

**How do I achieve zero-downtime config changes?**
Use `systemctl reload haproxy`. HAProxy master-worker mode preserves existing connections.

**Can I run without Keepalived?**
Yes. Use `sudo ./install.sh --skip-keepalived` for single-node deployment.

**What happens during failover?**
Keepalived moves the VIP to the BACKUP node in 3–6 seconds. Existing TCP sessions are lost; clients reconnect.

**Is Docker supported?**
No. This project uses native OS packages only.

## Repository Structure

```
routedns-ingress/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── Makefile
├── .env.example          # copy to .env via: make init
├── install.sh
├── uninstall.sh
├── config/
│   └── rendered/         # generated configs (gitignored)
├── configs/
│   ├── haproxy.cfg
│   ├── keepalived-master.conf
│   └── keepalived-backup.conf
├── scripts/
│   ├── setup.sh
│   ├── render-config.sh
│   ├── install-haproxy.sh
│   ├── install-keepalived.sh
│   ├── healthcheck.sh
│   ├── reload.sh
│   └── validate.sh
├── docs/
│   ├── architecture.md
│   ├── installation.md
│   ├── keepalived.md
│   ├── haproxy.md
│   ├── monitoring.md
│   ├── tuning.md
│   └── troubleshooting.md
└── .github/
    └── workflows/
        └── ci.yml
```

## License

[MIT License](LICENSE) — Copyright (c) 2026 RouteDNS

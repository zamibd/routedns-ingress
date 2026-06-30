# Setup

## One-command production deploy

### 1. Initialize config

```bash
make init
```

Creates `.env` from `.env.example` in the project root.

### 2. Edit `.env`

Minimum required changes:

```bash
BACKEND_1=10.0.1.10    # backend servers (BACKEND_2, BACKEND_3, ... or BACKENDS=ip1,ip2,...)
BACKEND_2=10.0.1.11
BACKEND_3=10.0.1.12

VIP=10.0.0.100         # Virtual IP clients connect to
VIP_PREFIX=24

ROLE=master            # master on primary, backup on secondary
```

Optional (auto-detected if empty):

| Variable | Default |
|----------|---------|
| `INTERFACE` | Auto-detected from default route |
| `VRRP_SECRET` | Auto-generated (saved to `.env`) |
| `NODE_IP` | Auto-detected primary IPv4 on `INTERFACE` |
| `VRRP_PEER` | Empty (set peer primary IP for cloud unicast VRRP) |
| `BACKEND_PORT` | 853 |
| `BACKENDS` | Empty (comma-separated list; overrides `BACKEND_N` when set) |
| `USE_PROXY_PROTOCOL` | yes |
| `CONFIGURE_FIREWALL` | yes |
| `INSTALL_LATEST_PACKAGES` | no (set `yes` for HAProxy 3.4.1 + Keepalived 2.4.1) |
| `HAPROXY_VERSION` | 3.4.1 (when `INSTALL_LATEST_PACKAGES=yes`) |
| `KEEPALIVED_VERSION` | 2.4.1 (when `INSTALL_LATEST_PACKAGES=yes`) |

### 3. Run setup

```bash
sudo make setup
```

This performs the full installation and passes production preflight.

### 4. Backup node

On the secondary ingress node:

1. Copy `.env` from the master node (includes `VRRP_SECRET`)
2. Set `ROLE=backup`
3. Run `sudo make setup`

## Apply config changes after editing `.env`

After changing backends, VIP, or PROXY settings in `.env`, re-render and reload
in one step (no full reinstall):

```bash
sudo make apply
```

`make apply` renders the configs from `.env`, installs the **rendered** files to
`/etc/haproxy/haproxy.cfg` and `/etc/keepalived/keepalived.conf`, then reloads
both services. Do not hand-copy `configs/haproxy.cfg` — that is the unrendered
template (it has no real backends) and `make reload` will refuse it.

## Re-run setup

Safe to re-run after editing `.env`:

```bash
sudo make setup
```

## Render configs only

Preview generated configs without installing:

```bash
sudo make render
cat config/rendered/haproxy.cfg
cat config/rendered/keepalived.conf
```

## Verify

```bash
make status
sudo make preflight
nc -zv YOUR_VIP 853
```

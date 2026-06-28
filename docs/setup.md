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
BACKEND_1=10.0.1.10    # your 3 backend HAProxy servers
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
| `BACKEND_PORT` | 853 |
| `USE_PROXY_PROTOCOL` | yes |
| `CONFIGURE_FIREWALL` | yes |

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

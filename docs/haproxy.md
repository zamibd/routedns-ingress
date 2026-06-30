# HAProxy

## Overview

HAProxy acts as the Layer-4 TCP ingress for DNS-over-TLS. It accepts TCP connections on port 853 and forwards them to backend HAProxy servers without terminating TLS or inspecting DNS packets.

## Configuration File

Runtime config: `/etc/haproxy/haproxy.cfg`

Template: `configs/haproxy.cfg`

## Frontends

Two frontends handle IPv4 and IPv6 separately:

```haproxy
frontend dot_ingress_v4
    bind *:853
    maxconn 25000
    default_backend dot_backends

frontend dot_ingress_v6
    bind [::]:853 v6only
    maxconn 25000
    default_backend dot_backends
```

- Clients connect with **plain TLS** — do not use `accept-proxy` on ingress frontends.
- Ingress adds PROXY v2 to backends via `send-proxy-v2` on server lines (see Backend Configuration).
- Only add `accept-proxy` on ingress if a **cloud LB in front of the VIP** sends PROXY headers to ingress.

## Backend Configuration

Add backend servers manually:

```haproxy
backend dot_backends
    balance leastconn
    option tcp-check
    tcp-check connect port 853

    server dot1 10.0.1.10:853 check inter 5s fall 3 rise 2 weight 100 send-proxy-v2 check-send-proxy
    server dot2 10.0.1.11:853 check inter 5s fall 3 rise 2 weight 100 send-proxy-v2 check-send-proxy
    server dot3 10.0.1.12:853 check inter 5s fall 3 rise 2 weight 50  send-proxy-v2 check-send-proxy
```

### Server Line Parameters

| Parameter | Description |
|-----------|-------------|
| `check` | Enable health checks |
| `inter 5s` | Check interval |
| `fall 3` | Mark down after 3 failures |
| `rise 2` | Mark up after 2 successes |
| `weight N` | Weight for weighted round robin |
| `send-proxy-v2` | Send PROXY Protocol v2 to backend |
| `check-send-proxy` | Send PROXY on health checks (required when backend uses `accept-proxy`) |
| `disabled` | Temporarily disable without removing |

### Balance Algorithms

Uncomment or change the `balance` directive:

```haproxy
balance leastconn      # Recommended for long-lived DoT sessions
balance roundrobin     # Equal distribution per connection
balance static-rr      # Weighted round robin (use weight on server lines)
```

## Health Checks

TCP connect checks verify backends are reachable on port 853:

```haproxy
option tcp-check
tcp-check connect port 853
```

When `USE_PROXY_PROTOCOL=yes` (backend HAProxy uses `accept-proxy`), rendered server lines include `check-send-proxy` so health checks send PROXY v2 (required on HAProxy 3.4+; `tcp-check send proxy v2` was removed).

Without PROXY on health checks, ingress probes hit the plain SSL bind and log `WRONG_VERSION_NUMBER`.

Failed backends are automatically removed from rotation. They rejoin when checks pass again.

## Connection Limits

| Scope | Limit |
|-------|-------|
| Global (`global maxconn`) | 50,000 |
| Defaults (`defaults maxconn`) | 10,000 |
| Frontend (`maxconn`) | 25,000 |

Adjust based on your hardware and expected load.

## Timeouts

| Timeout | Value | Purpose |
|---------|-------|---------|
| connect | 5s | Backend connection establishment |
| client | 3600s | Client idle (DoT sessions are long-lived) |
| server | 3600s | Server idle |
| check | 3s | Health check timeout |

## Stats Socket

Local stats on `127.0.0.1:8404`:

```bash
curl -s http://127.0.0.1:8404/stats
echo "show stat" | socat stdio /run/haproxy/admin.sock
echo "show info" | socat stdio /run/haproxy/admin.sock
```

Admin socket: `/run/haproxy/admin.sock`

## Zero-Downtime Reload

HAProxy runs in master-worker mode via systemd (`haproxy -Ws` in the unit file). Do not put `master-worker` or `daemon` in `haproxy.cfg` — those keywords are deprecated/removed in HAProxy 3.4+.

```bash
# Validate first
haproxy -c -f /etc/haproxy/haproxy.cfg

# Reload (zero downtime)
systemctl reload haproxy

# Or use the helper script
sudo /usr/local/lib/routedns-ingress/reload.sh
```

During reload, existing connections continue on old workers while new connections use the updated config.

## Administration

```bash
systemctl status haproxy
systemctl reload haproxy      # Zero-downtime config reload
systemctl restart haproxy     # Full restart (drops connections)
haproxy -c -f /etc/haproxy/haproxy.cfg  # Validate config
```

## Adding or Removing Backends

1. Edit `/etc/haproxy/haproxy.cfg`
2. Add or remove `server` lines
3. Validate: `haproxy -c -f /etc/haproxy/haproxy.cfg`
4. Reload: `systemctl reload haproxy`

No other steps required.

## Logging

HAProxy logs to `local0` facility → `/var/log/haproxy.log` via rsyslog.

View logs:

```bash
tail -f /var/log/haproxy.log
journalctl -u haproxy -f
```

Log format is TCP (`option tcplog`), recording connection duration, bytes transferred, and backend used.

## Security Defaults

- Stats bound to localhost only
- No TLS termination (reduced attack surface)
- Connection limits prevent resource exhaustion
- Health checks ensure traffic only reaches healthy backends

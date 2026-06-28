# Keepalived

## Overview

Keepalived provides high availability through VRRP (Virtual Router Redundancy Protocol). It floats a Virtual IP (VIP) between ingress nodes so clients always connect to an active HAProxy instance.

## Configuration Files

| File | Purpose |
|------|---------|
| `configs/keepalived-master.conf` | Primary node template |
| `configs/keepalived-backup.conf` | Secondary node template |
| `/etc/keepalived/keepalived.conf` | Installed runtime config |

## VRRP Instance

The default VRRP instance is named `VI_DOT`:

```conf
vrrp_instance VI_DOT {
    state MASTER          # or BACKUP
    interface eth0
    virtual_router_id 51
    priority 100          # MASTER: 100, BACKUP: 90
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass YOUR_SECRET
    }

    virtual_ipaddress {
        10.0.0.100/24 dev eth0
    }

    track_script {
        chk_haproxy
    }
}
```

## Key Settings

### state

- `MASTER` on the primary node
- `BACKUP` on secondary nodes

### priority

Higher priority wins when both nodes are healthy. Typical values:

- MASTER: `100`
- BACKUP: `90`

Additional BACKUP nodes can use `80`, `70`, etc.

### virtual_router_id

Must be identical on all nodes in the VRRP group. Must be unique per VRRP group on the same network segment (range 1–255).

### auth_pass

Shared secret between VRRP peers. Maximum 8 characters. Change the default `CHANGE_ME_VRRP_SECRET` before production.

### virtual_ipaddress

The VIP that clients connect to. Can include IPv4 and IPv6:

```conf
virtual_ipaddress {
    10.0.0.100/24 dev eth0
    2001:db8::100/64 dev eth0
}
```

## Health Check Script

Keepalived tracks HAProxy health via `chk_haproxy`:

```conf
vrrp_script chk_haproxy {
    script "/usr/local/lib/routedns-ingress/healthcheck.sh"
    interval 2
    weight -20
    fall 3
    rise 2
    timeout 5
}
```

The script verifies:

1. `haproxy.service` is active
2. Configuration is valid
3. Stats socket responds (or port 853 is listening)

If the script fails 3 consecutive times (`fall 3`), the node's priority is reduced by 20, triggering failover.

## Failover Behavior

1. MASTER fails health check → priority drops below BACKUP
2. BACKUP promotes to MASTER and acquires VIP
3. GARP (Gratuitous ARP) announces the VIP on the new MASTER
4. Clients reconnect to the VIP (existing TCP sessions are lost)

Typical failover time: 3–6 seconds.

## State Notifications

State transitions are logged via `keepalived-notify.sh`:

```conf
notify_master "/usr/local/lib/routedns-ingress/keepalived-notify.sh master"
notify_backup "/usr/local/lib/routedns-ingress/keepalived-notify.sh backup"
notify_fault  "/usr/local/lib/routedns-ingress/keepalived-notify.sh fault"
```

View logs:

```bash
journalctl -u keepalived -f
grep routedns-ingress /var/log/syslog
```

## Administration

```bash
systemctl status keepalived
systemctl restart keepalived
systemctl stop keepalived
```

Check VIP ownership:

```bash
ip addr show dev eth0 | grep inet
```

Check VRRP state:

```bash
journalctl -u keepalived --since "5 min ago" | grep -i vrrp
```

## Multi-Node Deployment

For three or more nodes, use one MASTER and multiple BACKUP nodes with decreasing priorities:

| Node | state | priority |
|------|-------|----------|
| ingress-1 | MASTER | 100 |
| ingress-2 | BACKUP | 90 |
| ingress-3 | BACKUP | 80 |

All nodes share the same `virtual_router_id`, `auth_pass`, and `virtual_ipaddress`.

## Troubleshooting

See [troubleshooting.md](troubleshooting.md#keepalived) for common issues.

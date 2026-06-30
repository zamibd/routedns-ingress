# Troubleshooting

## Quick Diagnostics

Run the validation script first:

```bash
sudo /usr/local/lib/routedns-ingress/validate.sh
```

Check both services:

```bash
systemctl status haproxy
systemctl status keepalived
```

## HAProxy

### Service won't start

```bash
# Check config syntax
haproxy -c -f /etc/haproxy/haproxy.cfg

# Check journal
journalctl -u haproxy -n 50 --no-pager
```

Common causes:

- **Invalid config syntax** — run `haproxy -c` and fix reported lines
- **Port 853 already in use** — `ss -ltnp | grep 853`
- **No backend servers** — add at least one active `server` line (remove placeholder)
- **Permission denied on socket** — ensure `/run/haproxy` exists and is owned by `haproxy`

### Backends showing DOWN

```bash
echo "show stat" | socat stdio /run/haproxy/admin.sock | grep dot_backends
```

Check:

1. Backend IP is reachable: `nc -zv 10.0.1.10 853`
2. Firewall allows outbound to backend port 853
3. Backend HAProxy is running and listening on 853
4. Health check port matches backend port

### Connections timing out

- Verify VIP is reachable: `nc -zv VIP 853`
- Check `timeout client` and `timeout server` (default 3600s)
- Check kernel connection limits: `sysctl net.core.somaxconn`
- Check HAProxy maxconn not exceeded: stats socket `scur` vs `slim`

### Reload fails

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg   # Must pass before reload
systemctl reload haproxy
journalctl -u haproxy -n 20
```

If reload fails, the old config remains active (safe failure).

## Keepalived

### FAULT state (no IPv4 address for interface)

Keepalived needs an IPv4 on the VRRP interface **different from the VIP** to send adverts — unless this node **owns** the VIP as its primary IP.

**Single node / VIP = server primary IP (common on Vultr):** `render-config.sh` auto-detects this and sets **priority 255** (VRRP address owner). Re-apply:

```bash
sudo make apply
journalctl -u keepalived -n 20 | grep -iE 'MASTER|BACKUP|FAULT'
```

**Two-node HA on cloud (Vultr, GCP, etc.):**

1. VIP should be a **floating/reserved IP**, not each node's primary IP
2. Set `VIP_PREFIX=32` in `.env` for cloud floating IPs
3. Set `VRRP_PEER` to the **other node's primary IP** (unicast; multicast is usually blocked)

Then `sudo make apply` on both nodes.

### VIP not appearing on MASTER

```bash
ip addr show | grep -A2 "inet "
journalctl -u keepalived -n 50
```

Check:

1. `interface` matches actual NIC name (`ip link show`)
2. `auth_pass` matches on all nodes
3. `virtual_router_id` matches on all nodes
4. Health check script passes: `/usr/local/lib/routedns-ingress/healthcheck.sh; echo $?`
5. `net.ipv4.ip_nonlocal_bind = 1` is set

### Split brain (both nodes claim MASTER)

- Verify network connectivity between nodes
- Ensure `virtual_router_id` is unique per VRRP group on the segment
- Check multicast is not blocked (or configure unicast peers)
- Verify different `priority` values

### Failover not happening

```bash
# Simulate HAProxy failure on MASTER
systemctl stop haproxy

# Watch Keepalived
journalctl -u keepalived -f
```

Check:

- `track_script` is configured in `vrrp_instance`
- `fall` count is not too high
- BACKUP priority + weight reduction < MASTER priority

### auth_pass errors

Keepalived `auth_pass` is limited to 8 characters. Longer passwords are truncated silently, causing authentication failures.

## Network

### Cannot connect to VIP

```bash
# From client
nc -zv 10.0.0.100 853

# On ingress node
ss -ltnp | grep 853
ip addr show dev eth0
```

Check:

- DNS A/AAAA records point to VIP
- Firewall allows 853/tcp (UFW, iptables, cloud security groups)
- VIP is on the correct interface
- Routing is correct

### PROXY Protocol issues

If backends reject connections:

- Remove `send-proxy-v2` from server lines if backends don't support it
- Remove `accept-proxy` from frontend binds if clients don't send PROXY headers

## Logs

| Issue | Command |
|-------|---------|
| HAProxy errors | `journalctl -u haproxy -n 100` |
| Keepalived VRRP | `journalctl -u keepalived -n 100` |
| HAProxy connections | `tail -100 /var/log/haproxy.log` |
| Keepalived state | `grep routedns-ingress /var/log/syslog` |
| Kernel drops | `dmesg \| grep -i drop` |

## Common Error Messages

| Message | Cause | Fix |
|---------|-------|-----|
| `bind(): Address already in use` | Port 853 taken | Stop conflicting service |
| `No server available` | All backends DOWN | Fix backend connectivity |
| `Invalid server name` | Typo in server line | Fix haproxy.cfg syntax |
| `VRRP_Instance(VI_DOT) removing VIPs` | Failover or stop | Expected during failover |
| `Track script chk_haproxy is already configured` | Duplicate script block | Remove duplicate in config |
| `configuration file is not valid` | Syntax error | Run `haproxy -c` |

## Recovery Procedures

### Restore from backup

```bash
ls /var/backups/routedns-ingress/
cp /var/backups/routedns-ingress/haproxy.cfg.TIMESTAMP.bak /etc/haproxy/haproxy.cfg
systemctl reload haproxy
```

### Force VIP to specific node

On the desired MASTER:

```bash
systemctl restart keepalived
# Ensure priority is highest and health check passes
```

### Full service restart

```bash
systemctl restart haproxy
systemctl restart keepalived
```

This causes brief connection interruption. Prefer reload for HAProxy config changes.

## Getting Help

1. Run `/usr/local/lib/routedns-ingress/validate.sh` and save output
2. Collect logs: `journalctl -u haproxy -u keepalived --since "1 hour ago"`
3. Include OS version: `cat /etc/os-release`
4. Include config (redact secrets): `haproxy -c -f /etc/haproxy/haproxy.cfg`
5. Open an issue on GitHub with the above information

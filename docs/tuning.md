# Performance Tuning

## Kernel Parameters (sysctl)

Installed to `/etc/sysctl.d/99-routedns-ingress.conf`:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `net.core.somaxconn` | 65535 | Maximum connection backlog |
| `net.core.netdev_max_backlog` | 65535 | Network device input queue |
| `net.ipv4.ip_local_port_range` | 1024 65535 | Ephemeral port range |
| `net.ipv4.tcp_max_syn_backlog` | 65535 | SYN queue size |
| `net.ipv4.tcp_fin_timeout` | 15 | TIME_WAIT duration |
| `net.ipv4.tcp_tw_reuse` | 1 | Reuse TIME_WAIT sockets |
| `fs.file-max` | 2097152 | System-wide file descriptor limit |

Apply changes:

```bash
sudo sysctl --system
# or
sudo sysctl -p /etc/sysctl.d/99-routedns-ingress.conf
```

Verify:

```bash
sysctl net.core.somaxconn
sysctl fs.file-max
```

## Open File Limits

Installed to `/etc/security/limits.d/99-routedns-ingress.conf`:

```
haproxy   soft  nofile  1048576
haproxy   hard  nofile  1048576
```

Verify after service restart:

```bash
cat /proc/$(pgrep -o haproxy)/limits | grep "open files"
```

## HAProxy Tuning

### Global Settings

```haproxy
global
    maxconn 50000
    tune.bufsize 32768
    tune.maxrewrite 1024
    master-worker
```

Adjust `maxconn` based on available RAM. Each connection uses approximately 1–2 KB of buffer memory.

### Capacity Planning

Rough estimate for concurrent connections:

```
maxconn = (available_RAM_GB × 0.5 × 1024) / 2
```

For 8 GB RAM: ~2000 concurrent connections safely, but with tuning can handle 10,000+.

### Balance Algorithm

For DoT (long-lived TCP sessions):

- **leastconn** (default) — routes to the backend with fewest active connections
- **roundrobin** — equal distribution, good for similar session durations
- **static-rr with weights** — when backends have different capacity

## Network Tuning

### Increase ring buffers (optional)

For high-throughput NICs:

```bash
# Check current values
ethtool -g eth0

# Increase (example, adjust per NIC)
ethtool -G eth0 rx 4096 tx 4096
```

### Disable reverse path filtering for VIP

If VIP traffic is dropped, add to sysctl:

```
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
```

Uncomment the relevant lines in `configs/sysctl-routedns-ingress.conf`.

## Keepalived Tuning

```conf
vrrp_garp_interval 1    # GARP interval during failover
vrrp_gna_interval 1     # IPv6 neighbor advertisement interval
advert_int 1            # VRRP advertisement interval (seconds)
```

Lower `advert_int` reduces failover detection time but increases VRRP traffic.

## Connection Limits

Layer limits to prevent resource exhaustion:

| Layer | Setting | Default |
|-------|---------|---------|
| Kernel | somaxconn | 65535 |
| HAProxy global | maxconn | 50000 |
| HAProxy defaults | maxconn | 10000 |
| HAProxy frontend | maxconn | 25000 |

Ensure kernel limits ≥ HAProxy limits.

## Reload Performance

Zero-downtime reloads use HAProxy master-worker:

```bash
systemctl reload haproxy
```

Reload time is typically under 1 second. Existing connections are not interrupted.

## Benchmarking

Basic connection test:

```bash
# Install testing tools
apt install apache2-utils  # provides ab, or use custom tools

# TCP connection test
for i in $(seq 1 100); do
  nc -z -w1 10.0.0.100 853 &
done
wait

# Check HAProxy stats
echo "show info" | socat stdio /run/haproxy/admin.sock | grep -i conn
```

Monitor during load:

```bash
watch -n1 'echo "show stat" | socat stdio /run/haproxy/admin.sock | grep dot_backends'
```

## Hardware Recommendations

| Load | CPU | RAM | Network |
|------|-----|-----|---------|
| Small (< 1K conn) | 2 cores | 2 GB | 1 Gbps |
| Medium (< 10K conn) | 4 cores | 4 GB | 1 Gbps |
| Large (< 50K conn) | 8+ cores | 8+ GB | 10 Gbps |

DoT ingress is I/O bound, not CPU bound. Network bandwidth and file descriptors are the primary constraints.

# Monitoring

## Overview

routedns-ingress supports multiple monitoring approaches without requiring additional mandatory services.

## journald

Both services log to systemd journal:

```bash
journalctl -u haproxy -f
journalctl -u keepalived -f
journalctl -u haproxy --since "1 hour ago"
journalctl -u keepalived --since today
```

## rsyslog

Dedicated log files (when rsyslog is installed):

| Log file | Source |
|----------|--------|
| `/var/log/haproxy.log` | HAProxy (`local0`) |
| `/var/log/keepalived.log` | Keepalived (`local1`) |

```bash
tail -f /var/log/haproxy.log
grep "dot_backends" /var/log/haproxy.log
```

## logrotate

Logs are rotated automatically:

- HAProxy: daily, 14 rotations, compressed
- Keepalived: weekly, 8 rotations, compressed

Config: `/etc/logrotate.d/routedns-ingress`

## HAProxy Stats Socket

Real-time statistics via admin socket:

```bash
# Human-readable stats page
curl -s http://127.0.0.1:8404/stats

# CSV stats
echo "show stat" | socat stdio /run/haproxy/admin.sock

# Server info
echo "show info" | socat stdio /run/haproxy/admin.sock

# Backend server status
echo "show servers state dot_backends" | socat stdio /run/haproxy/admin.sock
```

Key metrics from `show stat`:

| Column | Meaning |
|--------|---------|
| scur | Current sessions |
| smax | Max sessions |
| status | UP/DOWN/MAINT |
| chkfail | Health check failures |
| qcur | Current queue depth |

## Health Check Script

Keepalived uses the health check script. Run manually:

```bash
/usr/local/lib/routedns-ingress/healthcheck.sh
echo $?  # 0 = healthy
```

## Validation Script

Full installation validation:

```bash
/usr/local/lib/routedns-ingress/validate.sh
```

## Prometheus Exporter (Optional)

HAProxy does not include a built-in Prometheus exporter. To add optional Prometheus metrics:

1. Install the community HAProxy exporter:

   ```bash
   # Debian/Ubuntu
   apt install prometheus-haproxy-exporter

   # Or download from https://github.com/prometheus/haproxy_exporter
   ```

2. Configure it to scrape `/run/haproxy/admin.sock`:

   ```yaml
   # Example systemd override
   ExecStart=/usr/bin/haproxy_exporter \
     --haproxy.socket=/run/haproxy/admin.sock
   ```

3. Scrape `http://localhost:9101/metrics` from Prometheus.

This is optional and not installed by default.

## Key Metrics to Monitor

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| HAProxy service status | systemctl | not active |
| Keepalived service status | systemctl | not active |
| VIP ownership | ip addr | missing on MASTER |
| Backend server status | stats socket | any DOWN |
| Current sessions | stats socket | > 80% maxconn |
| Health check failures | stats socket | chkfail increasing |
| Disk space (logs) | df | > 85% |

## Example Monitoring Checks

```bash
#!/bin/bash
# Simple cron-friendly health check

/usr/local/lib/routedns-ingress/healthcheck.sh || exit 1

DOWN=$(echo "show stat" | socat stdio /run/haproxy/admin.sock 2>/dev/null \
  | awk -F, '$18 == "DOWN" { print $1"/"$2; count++ } END { exit count > 0 ? 1 : 0 }')

exit $?
```

Add to cron:

```cron
*/1 * * * * /usr/local/lib/routedns-ingress/healthcheck.sh || logger -t routedns-ingress "HAProxy health check failed"
```

## Log Analysis

Common log patterns:

```bash
# Connection errors
grep -i "connection refused" /var/log/haproxy.log

# Backend down events
grep -i "Server dot_backends" /var/log/haproxy.log | grep -i down

# Keepalived failover
grep -i "Entering MASTER\|Entering BACKUP" /var/log/syslog
```

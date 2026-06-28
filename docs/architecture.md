# Architecture

## Overview

routedns-ingress is the frontend ingress layer for the RouteDNS platform. It receives incoming DNS-over-TLS (DoT) TCP connections on port 853 and forwards them transparently to backend HAProxy servers.

The ingress operates purely at Layer 4. It does not terminate TLS, parse DNS packets, or perform any application-layer processing.

## Traffic Flow

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

1. **Client** initiates a TLS connection to the VIP on port 853.
2. **Keepalived** manages the Virtual IP (VIP) across two or more ingress nodes using VRRP.
3. **HAProxy** accepts the TCP connection and forwards bytes bidirectionally to a healthy backend.
4. **Backend HAProxy** servers receive the connection (optionally with PROXY Protocol v2 for client IP preservation) and handle downstream routing.

## Components

### HAProxy

- **Role:** Layer-4 TCP load balancer and ingress proxy.
- **Mode:** `mode tcp` — pure byte forwarding.
- **Binding:** Port 853 (IPv4 and IPv6), with optional PROXY Protocol v2 acceptance.
- **Balancing:** Least connections (default), round robin, or weighted round robin.
- **Health checks:** TCP connect checks to backend port 853.
- **Reload:** Zero-downtime via `master-worker` and `systemctl reload haproxy`.

### Keepalived

- **Role:** High availability via VRRP.
- **Function:** Floats a Virtual IP between MASTER and BACKUP nodes.
- **Health check:** Custom script verifies HAProxy is running and healthy.
- **Failover:** Automatic VIP migration when the MASTER fails health checks.

## Design Principles

| Principle | Implementation |
|-----------|----------------|
| Simplicity | Static config files, no dynamic discovery |
| Reliability | TCP health checks, VRRP failover, graceful reload |
| Performance | Kernel tuning, connection limits, leastconn balancing |
| Security | No TLS termination, connection limits, minimal attack surface |
| Observability | Stats socket, journald, rsyslog, logrotate |

## What This Project Does NOT Do

- TLS termination or certificate management
- DNS packet inspection or parsing
- Dynamic backend registration
- REST API, web UI, or database
- Container orchestration (Kubernetes, Docker)
- Service discovery (Consul, etcd, Redis)

Backend servers are configured manually in `/etc/haproxy/haproxy.cfg`.

## Network Requirements

- Ingress nodes must reach backend HAProxy servers on port 853.
- VRRP peers must communicate on the same L2 segment (multicast or unicast).
- VIP must be routable by clients (DNS A/AAAA records point to VIP).
- Firewall must allow TCP 853 inbound to the VIP.

## High Availability Topology

A typical deployment uses two ingress nodes:

```
                    ┌─────────────────┐
                    │   VIP 10.0.0.100 │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
     ┌────────▼────────┐          ┌────────▼────────┐
     │  Ingress Node 1 │          │  Ingress Node 2 │
     │  MASTER (pri 100)│          │  BACKUP (pri 90) │
     │  HAProxy + VIP   │          │  HAProxy (standby)│
     └────────┬────────┘          └────────┬────────┘
              │                             │
              └──────────────┬──────────────┘
                             │
                    Backend HAProxy Pool
                    10.0.1.10, 10.0.1.11, ...
```

Only the MASTER holds the VIP. On failure, the BACKUP promotes and acquires the VIP within seconds.

## IPv6

IPv6 is supported on both frontends and backends. Configure `virtual_ipaddress` with IPv6 addresses in Keepalived and bind `[::]:853` in HAProxy (included by default).

## PROXY Protocol

When enabled (`send-proxy-v2` on backend server lines, `accept-proxy` on frontend binds), HAProxy prepends a PROXY Protocol v2 header so backends learn the original client IP and port. Backends must support PROXY v2.

# Security Architecture

lunet recommends a qmail-style process isolation architecture — the same 
approach that made qmail the most secure mail server for over a decade. 

The principle: decompose your system into trust boundaries where each process 
has minimal privilege and communicates through constrained interfaces. The 
internet-facing attack surface is handled by hardened, battle-tested software; 
lunet never touches the hostile network directly.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         HOSTILE INTERNET                            │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    INTERNET-FACING EDGE                             │
│                         (your choice)                               │
│                                                                     │
│   nginx · OpenResty · Apache httpd · HAProxy · Caddy · Traefik     │
│   AWS ALB/NLB · GCP Load Balancer · Azure App Gateway              │
│   Cloudflare · Fastly · Kong · Kubernetes Ingress                  │
│                                                                     │
│   Responsibilities:                                                 │
│   • TLS termination (HTTPS, HTTP/2, HTTP/3/QUIC)                   │
│   • Protocol validation & attack mitigation                         │
│   • Rate limiting, WAF, DDoS protection                            │
│   • Certificate management                                          │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                    Unix socket (preferred)
                       or TCP loopback
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          lunet                                      │
│                                                                     │
│   • Listens on Unix socket or TCP loopback only                     │
│   • Never exposed to public network interfaces                      │
│   • Receives traffic pre-filtered by your edge                      │
│   • Unix sockets add filesystem permission controls                 │
└─────────────────────────────────────────────────────────────────────┘
```

## Why Unix Sockets Over TCP Loopback?

TCP loopback (`127.0.0.1`) exposes you to other processes on the same host. 
A compromised service, container escape, or misconfigured firewall rule could 
allow local attackers to connect.

Unix sockets use filesystem permissions — only processes with the correct 
UID/GID can connect.

## Supported Protocols

lunet is protocol-agnostic. Whatever your edge forwards, lunet handles:

| Category | Protocols |
|----------|-----------|
| Web | HTTP/1.1, WebSocket |
| RPC | gRPC, JSON-RPC, XML-RPC |
| Messaging | STOMP, MQTT, AMQP, XMPP |
| Data | Redis protocol, Memcached protocol |
| Gaming | Source RCON, Minecraft protocol, Photon, ENet |
| Custom | Any framed or length-prefixed binary protocol |

## Outbound TLS Clients (Optional)

This document’s “terminate TLS at the edge” guidance is about **inbound exposure**.
It does not prohibit outbound HTTPS client traffic.

Some applications (e.g. MCP servers calling LLM providers) need outbound HTTPS but
do not need to accept inbound public HTTPS connections. In that case, keep inbound
binding restricted to Unix sockets or `127.0.0.1`, and use an outbound client module
for remote APIs.

Lunet supports an optional **client-only** HTTPS module:
- `lunet.httpc` (libcurl) for outbound `https://...` requests

TLS verification is enabled by default. A development-only escape hatch may be
enabled via `LUNET_HTTPC_INSECURE=1` (do not use in production).

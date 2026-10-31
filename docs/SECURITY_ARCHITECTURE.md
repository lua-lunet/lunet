# Security Architecture

lunet recommends a qmail-style process isolation architecture - the same
approach that made qmail the most secure mail server for over a decade.

The principle: decompose your system into trust boundaries where each
process has minimal privilege and communicates through constrained
interfaces. The internet-facing attack surface is handled by hardened,
battle-tested software - a cloud load balancer, an API gateway, or a local
sidecar such as nginx, OpenResty, HAProxy, Traefik, Caddy, Envoy - and lunet
never touches the hostile network directly.

```mermaid
flowchart TB
    hostile["Hostile internet"]
    edge["INTERNET-FACING EDGE (your choice)\l
    Responsibilities:\l
    TLS termination (HTTPS, HTTP/2, HTTP/3/QUIC)\l
    Protocol validation and attack mitigation\l
    Rate limiting, WAF, DDoS protection\l
    Certificate management"]
    lunet["lunet (one process per concern)\l
    Listens on Unix socket or TCP loopback only\l
    Never exposed to public network interfaces\l
    Receives traffic pre-filtered by your edge\l
    Treats every byte it reads as hostile"]
    hostile --> edge
    edge -->|"Unix socket or TCP loopback (your choice)"| lunet
```

Software usable in each role:

| Role | Software you can use |
|------|----------------------|
| Internet-facing edge | nginx · Envoy · OpenResty · Apache httpd · HAProxy · Caddy · Traefik · Kong |
| Cloud load balancing / gateway | AWS ALB/NLB · GCP Load Balancer · Azure App Gateway |
| Managed edge / WAF | Cloudflare · Fastly · Kubernetes Ingress |

## Where validation lives in this architecture

The edge removes lunet's **network exposure**: an unauthenticated attacker
on the internet cannot reach lunet's socket at all. For protocols the edge
speaks natively (HTTP/1.1, HTTP/2, HTTP/3, WebSocket) it validates the
protocol before handoff, so what reaches lunet has already been checked by a
component that speaks that protocol. That is the qmail model's core.

For everything else, the edge forwards bytes: an L4 load balancer sees
packets, not protocols; an L7 proxy validates the protocol it speaks, not
the protocol lunet speaks. In those deployments lunet's own protocol layer
does the validation. That division is deliberate: each wire protocol is
checked exactly once, by the component that speaks it on that hop.

The standing discipline for every byte lunet reads, wherever you deploy:

- **Bounds before allocation.** Declared lengths are capped, never trusted;
  length-prefix and frame checks run before allocating or copying.
- **Constrain the process.** Run lunet under a dedicated non-root UID/GID;
  match the Unix socket's filesystem permissions to it; apply seccomp or
  equivalent syscall filtering where the platform offers it.
- **Keep the probes green.** The parser suites and the Http11Probe rig pin
  the documented outcomes; keep fuzz coverage growing with new decoders.

In qmail terms: the edge is the network-facing guard, and every component
still assumes its inputs are hostile. Defense in depth is the point of this
architecture: the edge is the first boundary, not the only one.

## Constrain the process: deployment runbook

The "Constrain the process" bullet above is the policy; this section is the
mechanics. Apply all three layers on every host.

### Dedicated non-root UID/GID

Create a dedicated account and group for the lunet process; never run it as
root, and never share the account with another service.

```sh
groupadd --system lunet
useradd --system --gid lunet --home-dir /var/lib/lunet --create-home --shell /usr/sbin/nologin lunet
```

On macOS use `dscl`/`sysadminctl` equivalents; on Windows use a dedicated
service account with "Log on as a service" rights. Keep the account's UID/GID
stable across upgrades so socket ownership does not drift.

### Unix socket permissions

Bind lunet to a Unix socket owned by the dedicated account, mode `0660`, in a
directory owned by the same account with mode `0750`:

```sh
install -d -o lunet -g lunet -m 0750 /run/lunet
# lunet creates /run/lunet/lunet.sock with mode 0660, owner lunet:lunet
```

The edge (nginx, HAProxy, ...) connects as a member of the `lunet` group, or
runs as the same dedicated account. No other local user can open the socket.
On startup lunet unlinks a stale socket path only if it owns it; on exit it
removes the path. Verify with `ls -l /run/lunet/`.

### Syscall filtering (seccomp and equivalents)

Apply the strictest filter the platform offers:

- Linux: seccomp-bpf in `SCMP_ACT_KILL_PROCESS` (or `SECCOMP_RET_TRAP`) mode,
  allow-listing only the syscalls lunet needs (read, write, epoll_wait,
  accept4, close, mmap, mprotect, futex, clock_gettime, ...). Build the
  profile with `scmp_sys_resolver` or a higher-level tool such as
  `systemd`'s `SystemCallFilter=`, `s6`'s `s6-applyuidgid` plus a seccomp
  helper, or a custom libseccomp program. Deny `execve`, `ptrace`,
  `mount`, `reboot`, and network syscalls beyond the already-bound socket.
- macOS: `sandbox-exec` profile (or the Seatbelt API) restricting file and
  network access to the socket path and loopback.
- Windows: Job Objects with restricted tokens and `PROCESS_CREATION_MITIGATION_POLICY`
  (DEP, ASLR, strict handle checks); run under a low-integrity or
  AppContainer profile where feasible.
- FreeBSD/OpenBSD: `capsicum` / `pledge` / `unveil` with the minimal
  capability set.

The filter is a defense-in-depth layer: it does not replace input validation,
and input validation does not replace the filter.

### Example units

systemd (`/etc/systemd/system/lunet.service`):

```ini
[Unit]
Description=lunet application server
After=network.target

[Service]
Type=simple
User=lunet
Group=lunet
RuntimeDirectory=lunet
RuntimeDirectoryMode=0750
ExecStart=/usr/local/bin/lunet-run /opt/lunet/app.lua
Restart=on-failure
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/run/lunet /var/lib/lunet
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
```

s6 (`/etc/s6/sv/lunet/run`):

```sh
#!/bin/execlineb -P
s6-setuidgid lunet
/usr/local/bin/lunet-run /opt/lunet/app.lua
```

launchd (`/Library/LaunchDaemons/de.example.lunet.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>de.example.lunet</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/lunet-run</string>
        <string>/opt/lunet/app.lua</string>
    </array>
    <key>UserName</key>
    <string>lunet</string>
    <key>GroupName</key>
    <string>lunet</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

## Transport options: Unix socket or TCP loopback

Both keep lunet off the network; pick by what you want the boundary to
enforce:

| Option | What it enforces | Considerations |
|--------|------------------|----------------|
| TCP loopback (`127.0.0.1` / `::1`) | No network exposure; any local process may connect | IP-shaped: fits existing tooling and containers with shared loopback; a compromised local service, container escape, or misconfigured firewall rule can reach it |
| Unix domain socket | No network exposure; only processes with the correct UID/GID may connect | Filesystem permissions are the boundary: match the socket's owner to the lunet process's dedicated UID/GID; needs the edge and lunet on one filesystem |

## Outbound TLS clients (optional)

This document's "terminate TLS at the edge" guidance is about **inbound
exposure**. It does not prohibit outbound HTTPS client traffic.

Some applications (e.g. MCP servers calling LLM providers) need outbound
HTTPS but do not need to accept inbound public HTTPS connections. In that
case, keep inbound binding restricted to Unix sockets or `127.0.0.1`, and
use an outbound client module for remote APIs.

Lunet supports an optional **client-only** HTTPS module:
- `lunet.httpc` (libcurl) for outbound `https://...` requests

TLS verification is enabled by default. A development-only escape hatch may
be enabled via `LUNET_HTTPC_INSECURE=1` (do not use in production).

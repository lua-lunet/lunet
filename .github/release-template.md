## Highlights

- **PAXE packet encryption**: New optional extension module (`lunet.paxe`) for secure peer-to-peer protocols with AES-256-GCM, libsodium, and Lua bindings. Build with `xmake build lunet-paxe`.
- **Downstream documentation**: Badge guide for downstream projects, beginner-friendly xmake integration guide replacing XMAKE_INTEGRATION.
- **Release automation**: Tag-triggered CI now builds Linux/macOS/Windows binaries and publishes GitHub releases with assets.
- **CI improvements**: Minimal lint-only pipeline scope, release quality gate in AGENTS.md.

## Binaries

- `lunet-linux-amd64.tar.gz`
- `lunet-macos.tar.gz`
- `lunet-windows-amd64.zip`

## Quick Start

```bash
tar -xzf lunet-linux-amd64.tar.gz
./lunet-run path/to/app.lua
```

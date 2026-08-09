## Binaries

- `lunet-linux-amd64.tar.gz`
- `lunet-linux-arm64.tar.gz`
- `lunet-macos.tar.gz`
- `lunet-windows-amd64.zip`

## Embeddable SDKs

- `lunet-linux-amd64-sdk.tar.gz`
- `lunet-linux-arm64-sdk.tar.gz`
- `lunet-macos-sdk.tar.gz`
- `lunet-windows-amd64-sdk.zip`

## Quick Start

Fetch a verified, project-local runtime with the release fetcher (SHA-256 checked against the release metadata before extraction):

```bash
curl -fsSLO https://github.com/lua-lunet/lunet/releases/download/@RELEASE_TAG@/lunet_fetch_release_@RELEASE_TAG@.lua
lua lunet_fetch_release_@RELEASE_TAG@.lua   # installs into .lunet/@RELEASE_TAG@/
.lunet/@RELEASE_TAG@/lunet-run path/to/app.lua
```

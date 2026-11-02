# Edge examples: one app, four edges

These are **examples of alternative edge services** in front of the same
application - illustrations of the settings, not recommendations. Always
read the latest documentation of whichever edge you deploy.

The application is the same in every variant: the
[realworld-lua](https://github.com/lua-lunet/realworld-lua) demo app at
v0.18.1 (matched to lunet v0.18.1), running on a shared Debian trixie base
image. Each variant is `FROM` that base and swaps in a different edge
server over the identical app:

| Edge | Dockerfile | Full-request buffering | Body cap without config |
|---|---|---|---|
| [nginx](Dockerfile.nginx) | the base image's reference edge | **default** (opt-out) | 1 MiB |
| [OpenResty](Dockerfile.openresty) | same nginx lineage + Lua scripting doors | **default** (opt-out) | 1 MiB |
| [Traefik](Dockerfile.traefik) | buffering middleware attached per router | opt-in | none |
| [Envoy](Dockerfile.envoy) | buffer filter added to the filter chain | opt-in | none |

That middle column is the point of the examples. nginx (and OpenResty,
which bundles nginx) buffers the entire request body before forwarding by
default. Traefik and Envoy **stream by default**: without the buffering
middleware (Traefik) or the buffer filter (Envoy), a request body of any
size streams straight through, and lunet's own 1 MiB 413 becomes the live
cap instead of the edge answering first. The example configurations
install those behaviours explicitly, so all four edges answer
`413` past 1 MiB and refuse an oversized header section before lunet
sees it.

## Layout

- `Dockerfile.base` - the shared base: Debian trixie, the realworld app
  (fetched digest-verified by its own release script), the lunet v0.18.1
  runtime, and nginx pre-configured as the reference edge
  (`conf/nginx-edge.conf`). Builds native-arch (arm64 on Apple Silicon
  colima, amd64 elsewhere).
- `Dockerfile.nginx` / `Dockerfile.openresty` / `Dockerfile.traefik` /
  `Dockerfile.envoy` - one per edge, each `FROM lunet-edge-base`, each
  adding its edge server and configuration. OpenResty is the one
  exception: its apt repository publishes amd64 packages only, so its
  variant is pinned to linux/amd64 (the driver builds an amd64 base
  first; on Apple Silicon it runs under emulation - the same choice the
  realworld-lua project's own Dockerfile makes).
- `conf/` - one configuration per edge, each carrying the same contract:
  request buffering on (where it is not the default), 1 MiB body cap,
  32 KiB header-section cap, 10s read timeouts.
- `conformance.lua` - the conformance suite (see below).
- `run-conformance.sh` - the driver: builds the base once, then for each
  edge builds the variant, runs PostgreSQL and the variant on a docker
  network, and executes the suite against it.

## The conformance suite

`conformance.lua` runs **on the lunet runtime** (in a container on the
same docker network as the edge) and drives the edge from outside. It
asserts the same contract for every edge:

1. **Happy paths** - the app's `/health` and the RealWorld API endpoints
   (register, authenticate, create and list articles) answer through the
   edge unchanged.
2. **Oversize body** - a 2 MiB body past the 1 MiB cap is answered `413`
   by the edge and never forwarded.
3. **Oversize header section** - a 40 KiB header section past the 32 KiB
   cap is refused by the edge (`400`/`414` on nginx and OpenResty, `431`
   on Traefik and Envoy).
4. **Drip-feed** - a request dribbled one fragment per second is cut off
   by the edge's 10s read timeout; the edge never completes the request.

Run all four (from the repository root; docker required):

```sh
ext/http/edge/run-conformance.sh
```

or one at a time:

```sh
ext/http/edge/run-conformance.sh envoy
```

## Notes

- The app inside the container listens on **loopback TCP** (its pinned
  `server.lua` takes host/port); the edge is the only process with an
  external listener. On a bare-metal deployment the same shape is a Unix
  socket between edge and app - see the security architecture document.
- The nginx variant does nothing in its Dockerfile beyond selecting the
  edge kind: the base image happens to arrive configured for it. That is
  deliberate - it is the reference edge the other three are measured
  against.
- The edge settings mirror the worked settings block in
  [the ext/http README](../README.md); the design discussion lives in
  [the security architecture document](../../../docs/SECURITY_ARCHITECTURE.md).

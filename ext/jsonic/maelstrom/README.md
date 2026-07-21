# Maelstrom rig for the lunet.jsonic demo

End-to-end test rig that grinds the `lunet.jsonic` extension with
[Maelstrom](https://github.com/jepsen-io/maelstrom) (Jepsen's distributed
systems workbench), using its `echo` workload.

Everything runs in Docker on `linux/arm64` (colima-friendly), with the
**classic builder** (`DOCKER_BUILDKIT=0`), **no volume mounts**, and a
**loopback-only** server — consistent with this repository's security rules.

## Architecture

Maelstrom nodes are plain processes driven over stdin/stdout, one JSON-RPC
message per line. lunet's server side is an HTTP service, so a tiny shim
bridges the two protocols inside the rig container:

```
        rig container (shares demo's network namespace)
 ┌──────────────────────────────────────────────────────────┐
 │  maelstrom (JDK 21)                                      │
 │     │ spawns per node                                    │
 │     ▼                                                    │
 │  shim.sh -> lunet-run shim.lua                           │
 │     stdin/stdout JSON lines  ⇄  lunet.httpc (libcurl)    │
 └──────────────┬───────────────────────────────────────────┘
                │ HTTP POST 127.0.0.1:18090/msg (loopback)
 ┌──────────────▼───────────────────────────────────────────┐
 │  demo container                                          │
 │  lunet-run server.lua -> socket.listen + lunet.jsonic    │
 │  (init -> init_ok, echo -> echo_ok)                      │
 └──────────────────────────────────────────────────────────┘
```

`network_mode: "service:demo"` puts both containers in one network
namespace, so `127.0.0.1` works between them without publishing ports or
binding `0.0.0.0`.

## Layout

| File | Purpose |
|---|---|
| `server.lua` | Maelstrom node as a lunet HTTP server (uses `lunet.jsonic` for JSON) |
| `shim.lua` | stdin/stdout ⇄ HTTP bridge via `lunet.httpc` (runs under `lunet-run`) |
| `shim.sh` | `--bin` wrapper Maelstrom spawns per node |
| `run-test.sh` | Rig entrypoint: wait for `/health`, then `maelstrom test -w echo` |
| `Dockerfile.demo` | Builds lunet + jsonic + httpc from source; slim runtime serving the node |
| `Dockerfile.rig` | JDK 21 + graphviz + gnuplot + Maelstrom v0.2.4 (sha256-pinned) + shim |
| `docker-compose.yml` | Orchestrates demo + rig (shared netns) |
| `Makefile` | `build` / `test` / `results` / `clean` |

## Usage

```sh
make -C ext/jsonic/maelstrom test      # build images, run echo workload, exit non-zero on failure
make -C ext/jsonic/maelstrom build     # just build both images (demo first: rig derives FROM it)
make -C ext/jsonic/maelstrom results   # copy /app/store out of a running rig container
make -C ext/jsonic/maelstrom clean     # compose down + delete images
```

Knobs (environment / make variables): `WORKLOAD` (default `echo`),
`NODE_COUNT` (default `1`), `TIME_LIMIT` (default `10` seconds):

```sh
TIME_LIMIT=30 make -C ext/jsonic/maelstrom test
```

Each `make test` run copies Maelstrom's `store/` (history, analysis,
plots) into `.tmp/maelstrom-results-<timestamp>/store/` — no volumes
needed; the path is printed at the end of the run.

Success looks like:

```
:valid? true
Everything looks good! ヽ(‘ー`)ノ
```

## Local (non-Docker) smoke

```sh
# 1. build prerequisites once
xmake build-release && xmake build lunet-httpc && xmake build-jsonic

# 2. start the node server (background)
LUNET_JSONIC_LIB=$PWD/ext/jsonic/target/release/liblunet_jsonic.dylib \
  ./build/macosx/arm64/release/lunet-run ext/jsonic/maelstrom/server.lua &

# 3. push one message through the shim
printf '%s\n' '{"src":"c1","dest":"n1","body":{"type":"echo","msg_id":1,"echo":"hi"}}' \
  | ./build/macosx/arm64/release/lunet-run ext/jsonic/maelstrom/shim.lua
# -> {"dest":"c1","src":"n1","body":{"type":"echo_ok","in_reply_to":1,"echo":"hi",...}}
```

## Notes

- **Maelstrom provenance**: downloaded at image build time from the
  official v0.2.4 GitHub release, SHA256 pinned
  (`301ec71d…85799`). Nothing is vendored into this repo. The release
  tarball ships a prebuilt uberjar, so only a JRE is required — no
  leiningen/clojure toolchain.
- **`git` in the rig image** is required: Jepsen shells out to `git` to
  record the test revision at startup.
- **Why the shim runs under `lunet-run`**: `lunet.httpc` is coroutine +
  libuv based; plain LuaJIT cannot drive it.
- **Loopback-only**: the server binds `127.0.0.1` (enforced by lunet's
  socket layer). Cross-container reachability comes from the shared
  network namespace, not from `0.0.0.0`.

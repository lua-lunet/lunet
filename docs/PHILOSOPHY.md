# The Talos, Ethos and 無為 of Lunet

[中文文档](PHILOSOPHY-CN.md)

Three words describe what Lunet is for and how it behaves: a guardian, a
character, and a way of doing less.

## Talos — the guardian posture

Talos circled Crete three times a day and kept hostile ships off the island.
Lunet takes the same view of your machine: **the network is kept at the
border, and the border is loopback**.

- `lunet-run` refuses to bind a listener to anything other than `127.0.0.1`,
  `::1`, or a Unix socket. There are no remote security holes by default.
- Opening the border is an explicit, audible act:
  `--dangerously-skip-loopback-restriction`. The flag is deliberately long.
  You are meant to say it out loud.
- When you do expose a service, put a battle-hardened sidecar in front —
  nginx, OpenResty, Caddy, Envoy; the choice belongs to the administrator,
  not to Lunet. This is the qmail lesson: the process that speaks to the
  network should be small, dull, and heavily defended, and it should not be
  your application. Protocol-smashing attacks die at the proxy, not in your
  Lua coroutine.
- There is a legitimate exception: on a private client network whose only
  ingress is a hardened cloud proxy that scrubs malformed traffic and
  absorbs DDoS, binding all interfaces can be safe. Lunet does not forbid
  it. Lunet forbids *accidentally* doing it.

## Ethos — the character

- **Stability first.** Lunet's dependencies — LuaJIT, libuv, zlib — are
  mature libraries with long-term distribution support. There is no npm or
  pip churn, and no weekly security patch treadmill for libraries you never
  asked for.
- **Releases are the product.** Building from source with xmake is a fine
  way to *develop* Lunet, but asking every user to assemble a toolchain per
  OS is how a project gets zero users. Worse: a maintainer on one OS cannot
  promise a source build works on another — small drifts in each platform's
  libraries make "works on my machine" the default failure mode. So CI
  builds the binaries for Linux, macOS, and Windows, and what CI ships is
  what we stand behind.
- **Lua at the core.** Other runtimes fight ecosystem wars and port their
  internals between languages. Lua has spent three decades being small,
  stable, and embeddable. Lunet adopts the *affordances* of larger
  ecosystems — an nginx-style shared dictionary (`lnt_shared`), fast JSON
  (`jsonic`), typed-Lua bindings (teal, planned) — without importing their
  churn. The great stagnation is over; the answer is not a bigger runtime,
  it is a smaller one with better manners.
- **Honest surface.** The public C API (`include/lunet.h`) documents its
  contract in the header: one runtime per process, one run, not thread-safe.
  What Lunet cannot do, it says.

## 無為 (wu wei) — doing less

Wu wei is effortless action: achieve by not forcing. Lunet's version is
subtraction as a feature.

- **Build only what you need.** One database driver, not three. No unused
  dependencies, no dead weight, no attack surface you never use. What is
  not linked cannot be exploited and cannot break.
- **Small is a capability.** A Lunet MCP server idles in single-digit
  megabytes of RAM and ships in a fraction of the disk of a Node, Bun, or
  Python equivalent (see the comparison table in the README). Small things
  start fast, audit fast, and fit anywhere.
- **The runtime stays out of the way.** Coroutine-per-connection, one event
  loop, plain Lua. No framework magic between you and the socket.

## Three developer experiences

The same engine serves three audiences; pick the row that is you.

| Path | Who it is for | What you need | Start here |
|------|---------------|---------------|------------|
| **Run Lua** | You write Lua apps; you do not want a C toolchain | A release archive for your OS | [Releases](https://github.com/lua-lunet/lunet/releases) |
| **Package an appliance** | You ship a single self-contained executable (your `main()` + Lunet + your app) to users who have nothing installed | The release SDK + a C compiler | [EMBEDDING.md](EMBEDDING.md) |
| **Hack the core** | You develop Lunet itself, or want a minimal feature build | xmake + system dev libraries | [XMAKE_INTEGRATION.md](XMAKE_INTEGRATION.md) |

## Origin: tiny localhost MCP servers

Lunet began as a way to write **tiny local MCP servers** — Model Context
Protocol tools that run next to an LLM client on loopback, idle in a few
megabytes, and start instantly. That remains the front-page use case and
the design centre: loopback by default (Talos), server-sent events as a
first-class transport, an outbound HTTPS client for calling real APIs, and
an embed mode for turning the result into one self-contained `.run`
executable. See `examples/mcp_openalex_sse/` for the canonical example.

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

## A Few Thoughts on Rust

There are some things people expect to be magic, but there is only code.
One example is the expectation that if you use a language with memory
safety, you will be secure. Logical bugs can leave you wide open, no
matter how strong your compiler is. In the case of Lunet, the
recommendation is to use the qmail security model: use battle-hardened
nginx on the network interface, and then have it talk to Lunet over a
Unix domain socket. This moves the code that has your business logic and
your credentials out of the process that is exposed to the internet. This
is the best security to use, no matter which languages and frameworks you
use. It also means that the code exposed to the network is the code that
everyone else using it is testing for you.

I thought long and hard about adding in Rust simply for the "brand
halo", yet we had extensive memory leak testing, load testing, and the
use of battle-tested C libraries, while allowing LuaJIT to use dynamic
code generation. When the C code was minimal, well-tested glue code for
stable mainstream C projects, adding a splattering of Rust felt a little
"cargo cult" (pun intended). At the same time, there is no reason not to
be belt-and-braces. Security and stability are defence-in-depth.

Recently, to build real-world apps, features like session cache and
atomic counters across requests have proven very useful. To implement
something like the NextCloud Enterprise 31 Login Flow V2, the server
needs to respond to client polls until the user has clicked through some
screens. While this can use the main database, it is, by definition, a
public protocol, since the client uses it to authenticate. This means it
is a surface for a DDoS attack. We should offload the poll to a memory
cache to avoid exposing the database to an unbounded number of
unauthenticated requests. If we do not want that logic inside of Lunet,
then we need to use Memcached or Redis. We suddenly add a lot of
application infrastructure. That then becomes its own maintenance burden.
We can try to move all the logic into OpenResty in front of Lunet, but
that would mean Lunet is not "batteries included". I would still advise
putting nginx in front of any process exposed to the internet, simply
because process separation is the best form of memory safety against all
types of bugs. Lunet deserves its own complete feature set — it deserves
its own `ngx.shared` model (shipped as `lnt.shared` in `lnt_shared`),
written in Rust.

Another example is cjson. That is a nice little lib, yet there are safe
versions that are nominally slower. If cjson was a system library getting
security patches on Debian LTS, then I would have used it. Yet the
ergonomics of cjson is that it is just a single C file you can use. This
created a dilemma for me. Adding in "just a Lua file" such as dkjson
feels safer, since Lua has GC and so no pointer arithmetic. That seems
low-risk for parsing strings that come into the system as JSON. Adding in
a C file from a 3rd party that will be used to parse strings from the
outside world seems like a future DoS attack or, worse, the dreaded
"undefined behaviour". It was therefore a no-brainer to look for an
MIT-licensed single-file Rust JSON parser of the same weight as cjson.
This is why there is jsonic ext to parse JSON while retaining dkjson to
encode Lua tables, as that is efficient.

Lunet is proudly polyglot. We may see some typed Lua Teal coming soon
now that we have a more standard lib to use. The future is bright as it
is built on the shoulders of giants.

# Overriding a Type Hint

The annotations in `types/` are **hints**. They are hand-written against C and
Rust FFI boundaries, so some will be too narrow, or simply wrong.

When a hint rejects code you know is correct, **do not restructure your code
around it**. Spot-fix it in one line, leave a comment linking the issue you
filed, and move on.

## The one-liners

### LuaCATS (lua-language-server)

Suppress the next line:

```lua
---@diagnostic disable-next-line: param-type-mismatch
local resp, err = httpc.request(opts) -- hint too narrow, see the issue link
```

Cast a single expression:

```lua
local n = row.id --[[@as integer]] -- see the issue link
```

Re-type a variable from that point on:

```lua
---@cast dict LntSharedDict -- see the issue link
```

### Teal

Cast:

```teal
local n = row.id as integer -- see the issue link
```

If a single cast is rejected, launder it through `any`:

```teal
local listener = handle as any as Listener -- see the issue link
```

Teal has no per-line suppression comment. A cast is the mechanism.

## Always leave the comment

One line linking the issue is enough. It is what lets you delete the
workaround once upstream is fixed, instead of carrying it forever.

And please do raise the issue. A hint that is wrong for you is wrong for the
next person.

## When a one-liner is not enough

Rare, but in rough order of increasing bluntness:

- **Override one module.** Teal: put your own `.d.tl` in a directory that comes
  earlier in `include_dir` than the shipped one. LuaCATS: copy the shipped file,
  patch it, and point `workspace.library` at your copy.
- **Disable one diagnostic project-wide** with `diagnostics.disable` in
  `.luarc.json`.
- **Stop loading the hints entirely** by removing `types/` from
  `workspace.library`.

Each of these costs you hints everywhere rather than at the one bad line. Prefer
the one-liner.

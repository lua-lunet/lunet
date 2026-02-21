# Optional Modules (`opt/`)

`opt/` is for **optional, non-first-class Lunet modules** that do not have
stable OS package distribution across Lunet's supported platforms.

## How `opt/` differs from `ext/`

- `ext/`:
  - wraps mature libraries commonly available via platform package managers
    (`apt`, Homebrew, vcpkg)
  - intended for regular release packaging
- `opt/`:
  - wraps libraries that must be vendored/built from source in CI/local builds
  - built via explicit xmake tasks only
  - validated in CI, but not shipped as official Lunet release binaries

## Current optional module

- `opt/graphlite` - GraphLite GQL database integration (`require("lunet.graphlite")`)

## Build flow

```bash
# Build pinned GraphLite FFI + lunet graphlite module
xmake opt-graphlite

# Run the optional GraphLite smoke/demo script
xmake opt-graphlite-example
```

GraphLite source and build outputs are staged under `.tmp/opt/graphlite/`
(ignored by git).

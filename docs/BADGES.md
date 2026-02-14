# Badge Guide for Downstream Projects

If your project uses Lunet, you can add badges to your README to show build status, Lunet version, and more. This guide provides ready-to-use Markdown snippets.

## Lunet Version Badge

Show which version of Lunet your project depends on:

```markdown
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.0-blue?logo=lua)](https://github.com/lua-lunet/lunet)
```

Replace `v0.2.0` with your actual Lunet version. For the latest release, check [lunet releases](https://github.com/lua-lunet/lunet/releases).

## Build Status Badge

If your project has GitHub Actions that build or test with Lunet:

```markdown
[![Build](https://github.com/YOUR_ORG/YOUR_REPO/actions/workflows/build.yml/badge.svg)](https://github.com/YOUR_ORG/YOUR_REPO/actions/workflows/build.yml)
```

Replace `YOUR_ORG` and `YOUR_REPO` with your repository path. Adjust the workflow filename if yours differs (e.g. `ci.yml`, `test.yml`).

## License Badge

```markdown
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
```

## Combined Example

A typical README header for a Lunet-based project:

```markdown
# My Lunet App

[![Build](https://github.com/lua-lunet/my-app/actions/workflows/build.yml/badge.svg)](https://github.com/lua-lunet/my-app/actions/workflows/build.yml)
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.0-blue?logo=lua)](https://github.com/lua-lunet/lunet)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A high-performance app built with [Lunet](https://github.com/lua-lunet/lunet).
```

## Customization

- **Shields.io** supports many styles: `?style=flat`, `?style=flat-square`, `?style=for-the-badge`
- **Color**: Append `?color=green` or use semantic colors like `success`, `important`, `informational`
- **Logo**: Add `?logo=github` or `?logo=lua` for icon overlays

Example with flat-square style:

```markdown
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.0-blue?style=flat-square&logo=lua)](https://github.com/lua-lunet/lunet)
```

## Linking to Lunet

Always link the badge to the Lunet repository so users can discover the library:

```markdown
[![Lunet](https://img.shields.io/badge/Lunet-v0.2.0-blue)](https://github.com/lua-lunet/lunet)
```

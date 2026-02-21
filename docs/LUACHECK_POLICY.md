# Luacheck Policy

[中文文档](LUACHECK_POLICY-CN.md)

This document defines the luacheck baseline and CI gate policy for Lunet.

## Scope

- `test/*.lua`
- `spec/*.lua`

The canonical command is:

```bash
xmake check
```

`xmake check` runs:

```bash
luacheck --config .luacheckrc test/ spec/
```

## Warning Policy

- **Target:** zero warnings and zero errors.
- **CI behavior:** warnings are treated as failures (non-zero exit).
- **No permanent allow-fail:** the luacheck CI step is required and blocking.

## Baseline Status

Issue #65 tracked cleanup after CI downscoping in #62.

- Previous baseline: **234 warnings / 0 errors** in `test/` + `spec/`
- Current baseline: **0 warnings / 0 errors**

## Controlled Exceptions

Only one targeted exception is currently allowed:

- `__lunet_exit_code` as a global in `test/smoke_*.lua`

This exception is documented in `.luacheckrc` and limited to smoke scripts because those scripts communicate process status through a global contract.

## Local Developer Expectations

Before pushing changes that touch Lua code in `test/` or `spec/`:

```bash
xmake check
```

If warnings appear, either:

1. Fix the code to eliminate the warning, or
2. Add a narrow, documented exception in `.luacheckrc` with justification.

Broad suppressions are not allowed.

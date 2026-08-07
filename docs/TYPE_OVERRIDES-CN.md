# 覆盖类型提示

`types/` 中的注解是**提示**。它们是针对 C 与 Rust FFI 边界手写的，因此有些会过窄，
或者干脆是错的。

当某个提示拒绝了你确信正确的代码时，**不要为它重构你的代码**。用一行就地修正，
留下注明 issue 的注释，然后继续。

## 一行修正

### LuaCATS（lua-language-server）

抑制下一行：

```lua
---@diagnostic disable-next-line: param-type-mismatch
local resp, err = httpc.request(opts) -- 提示过窄，见 lua-lunet/lunet#1234
```

转换单个表达式：

```lua
local n = row.id --[[@as integer]] -- 见 lua-lunet/lunet#1234
```

从该处起重新指定变量类型：

```lua
---@cast dict LntSharedDict -- 见 lua-lunet/lunet#1234
```

### Teal

类型转换：

```teal
local n = row.id as integer -- 见 lua-lunet/lunet#1234
```

如果单次转换被拒绝，可通过 `any` 中转：

```teal
local listener = handle as any as Listener -- 见 lua-lunet/lunet#1234
```

Teal 没有逐行抑制注释，类型转换就是它的机制。

## 请务必留下注释

一行注明 issue 即可。有了它，上游修复后你才能删掉这个变通做法，而不是一直背着它。

也请提交 issue。对你不正确的提示，对下一个人同样不正确。

## 当一行不够时

这种情况很少见。按影响范围由小到大：

- **覆盖单个模块。** Teal：把你自己的 `.d.tl` 放在 `include_dir` 中比随发布附带
  目录更靠前的位置。LuaCATS：复制随发布附带的文件，打补丁，然后把
  `workspace.library` 指向你的副本。
- **在项目范围内关闭某一项诊断**：在 `.luarc.json` 中使用 `diagnostics.disable`。
- **完全不加载这些提示**：把 `types/` 从 `workspace.library` 中移除。

以上每一种都会让你在所有地方失去提示，而不只是在那一处错误上。优先使用一行修正。

# Luacheck 策略

[English Documentation](LUACHECK_POLICY.md)

本文档定义 Lunet 的 luacheck 基线与 CI 门控策略。

## 范围

- `test/*.lua`
- `spec/*.lua`

标准命令为：

```bash
xmake check
```

`xmake check` 实际执行：

```bash
luacheck --config .luacheckrc test/ spec/
```

## 告警策略

- **目标：** 0 warnings、0 errors
- **CI 行为：** warning 视为失败（非零退出码）
- **禁止永久 allow-fail：** luacheck CI 步骤为必需且阻塞

## 基线状态

Issue #65 跟踪了 #62 降级 CI 后的清理工作。

- 历史基线：`test/` + `spec/` 共 **234 warnings / 0 errors**
- 当前基线：**0 warnings / 0 errors**

## 受控例外

当前仅允许一个定向例外：

- `test/smoke_*.lua` 中使用全局变量 `__lunet_exit_code`

该例外在 `.luacheckrc` 中显式记录，并限制在 smoke 脚本范围内，因为这些脚本通过全局约定传递进程退出状态。

## 本地开发者要求

当修改 `test/` 或 `spec/` 下的 Lua 代码时，推送前应运行：

```bash
xmake check
```

若出现告警，应当：

1. 优先修复代码消除告警，或
2. 在 `.luacheckrc` 中添加范围最小、带理由的例外。

不允许宽泛抑制。

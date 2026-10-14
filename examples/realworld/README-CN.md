# RealWorld：如何用 Lunet 构建一个更典型的应用

一个完整的 RealWorld "Conduit" 实现 —— 一个更朴素、更典型的 Web 应用 ——
位于 [lua-lunet/realworld-lua](https://github.com/lua-lunet/realworld-lua)。
把这里当作路标：看一个更大、更普通的 Lunet 应用是怎么构建的，同时保持更小的
内存占用与更快的启动时间。

运行一个 Web 服务器已经被解决了，而平均的部署并不怎么在意极小的内存占用。
Lunet 背后的想法是「少即是多」：这样你才能在同一台机器上跑多得多的实例。这
要求你更认真地思考你要做什么、怎么做。在 Web 应用这个空间里，大家传统上拚
命追捧的是那条永远在升级的全家桶生态。而在新世界里，更谨慎地只拼装你真正需
要的东西，可以更快地搭出方案，维护成本也低得多。

RealWorld 演示的目的，是让你看到：当你把「一条 Express 命令就全给你」的那一
整套东西都加进来之后，它长什么样。你可能没注意到的是：所有依赖都在那里、非
常稳定、且带有长期安全补丁。剩下的代码很少，是你读得懂的，内存占用小得多，
而且它就是能跑。如果你不在乎它比全家桶方案更小、更稳，那 Lunet 不适合你。

总有人会说「可它不是 JavaScript」。如果你只接受服务器端的 JavaScript，那再
一次，Lunet 不适合你。Lua 既极为简单，又同时极为强大。跑这个演示的 LuaJIT
运行时相比 Node.js 运行时小得多。你不可能在没有 JavaScript 运行时开销的前
提下拥有 JavaScript。Lunet 不用 JavaScript，恰恰是为了用一个高效的嵌入式脚
本运行时 —— 这是核心特性，不是缺陷。

## 快速开始

按演示仓库的 README 操作：

```sh
git clone https://github.com/lua-lunet/realworld-lua.git
cd realworld-lua
# 用项目 README 顶部「获取运行时」小节拿到运行时（无需工具链），
# 然后按其 README 运行演示。
```

这个目录本身不会向 Lunet 仓库拉取任何东西：演示应用在自己的仓库里开发、构
建和版本化，这里的 examples 保持极简。

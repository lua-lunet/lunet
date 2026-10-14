# RealWorld: how to build a more typical app with Lunet

A complete RealWorld "Conduit" implementation — a more vanilla, typical web
application — lives at [lua-lunet/realworld-lua](https://github.com/lua-lunet/realworld-lua).
Use it as the signpost for how to build a bigger, ordinary Lunet application,
and to have a smaller footprint and faster startup time.

Running a webserver is a solved problem where very small footprint is not
something the average installation is paying attention to. The idea behind
Lunet is that less is more so you can run a lot more instances. That requires
thinking more about what you are trying to do and how. In the webapp space the
emotional sweet spot has been the forever upgraded kitchen-sink ecosystems. In
the new world being more careful about putting together just what you need can
be faster to build a solution and far lower cost to maintain.

The purpose of the RealWorld demo is to show what things look like when you do
add in everything that you could get with a one-shot of an Express server. What
you may not see is that all the dependencies are right there, are very stable,
and get long-term security patches. What remains is very little code, that you
can read through, that takes up a lot less memory, and that works. If you don't
care that it is smaller and more stable than a kitchen-sink solution, then
Lunet is not for you.

Now there is going to be someone, somewhere, who says "but it is not JavaScript
on the server". If the only answer you will accept is JavaScript on the server,
then again, Lunet is not for you. Lua is both remarkably simple while at the
same time being remarkably powerful. The LuaJIT runtime that runs the demo app
is tiny compared to a Node.js runtime. You cannot have JavaScript without the
overheads of a JavaScript runtime. Lunet not being JavaScript, so that it can
use an efficient embeddable scripting runtime, is a core feature, not a bug.

## Quick start

Follow the README in the demo repository:

```sh
git clone https://github.com/lua-lunet/realworld-lua.git
cd realworld-lua
# pick up a runtime with the "Get a runtime" section at the top of
# the project README (no toolchain needed), then run the demo per its README.
```

Nothing is fetched into the Lunet tree by this folder: the demo is developed,
built and versioned in its own repository so the examples here stay minimal.

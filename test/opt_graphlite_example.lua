--[[
Optional GraphLite integration smoke script.

This script is intentionally a thin test wrapper around:
  examples/08_opt_graphlite.lua

It mirrors the GraphLite Python bindings/demo flow:
  1) Open DB
  2) Create session
  3) Create schema + graph
  4) Insert protein/compound/assay nodes
  5) Link relationships (TESTED_IN / MEASURES_ACTIVITY_ON / INHIBITS)
  6) Query potent compounds, traversals, and aggregates

Run sequence from repository root:

  # Build core release + optional GraphLite (pinned repo commit + pinned Rust toolchain)
  xmake opt-graphlite

  # Execute this smoke script with LUA_CPATH + LUNET_GRAPHLITE_LIB configured by xmake task
  xmake opt-graphlite-example

Manual run (advanced):
  xmake build-release
  xmake build lunet-graphlite
  # set LUA_CPATH to include build/**/release/opt/?.so
  # set LUNET_GRAPHLITE_LIB to .tmp/opt/graphlite/install/lib/<graphlite-shared-library>
  <lunet-run> test/opt_graphlite_example.lua
]]

dofile("examples/08_opt_graphlite.lua")

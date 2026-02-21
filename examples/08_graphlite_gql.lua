--[[
GraphLite GQL (Graph Query Language) Demo for lunet

This example mirrors the Python SDK basic_usage.py from GraphLite-AI/GraphLite.
It demonstrates the core features of the GraphLite graph database via the
lunet.graphlite coroutine-safe module:

  - Opening a database (via dynamically loaded Rust FFI library)
  - Creating sessions
  - Executing ISO GQL queries (DDL, DML, DQL)
  - Pattern matching with MATCH clauses
  - Filtering with WHERE
  - Aggregation and ordering

GraphLite is an embeddable graph database written in Rust that implements
the ISO GQL (Graph Query Language) standard.

Prerequisites — building the GraphLite FFI library and lunet module:

  Step 1: Build core lunet (if not already built)
    xmake f -m release -y
    xmake build

  Step 2: Build the GraphLite opt module (fetches, builds Rust FFI lib, compiles C shim)
    xmake opt-graphlite

  Step 3: Run this example
    xmake opt-graphlite-example

  Or manually:
    LUNET_BIN=$(find build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)
    LIB_DIR=$(find build -path '*/release/lunet' -type d 2>/dev/null | head -1)
    LD_LIBRARY_PATH="$LIB_DIR:$LD_LIBRARY_PATH" "$LUNET_BIN" examples/08_graphlite_gql.lua

What happens under the hood:
  1. xmake opt-graphlite clones GraphLite-AI/GraphLite at a pinned commit
  2. Builds the `graphlite-ffi` Rust crate with `cargo build --release`
  3. This produces libgraphlite_ffi.so / .dylib / .dll (C FFI shared library)
  4. The lunet-graphlite C module (opt/graphlite/graphlite.c) uses dlopen()
     to load the Rust library at runtime
  5. All database operations are dispatched to libuv worker threads, yielding
     the calling coroutine exactly like the SQLite3 driver does

The GraphLite FFI API (from graphlite-ffi/graphlite.h):
  graphlite_open(path, &error)        -> GraphLiteDB*
  graphlite_create_session(db, user)  -> session_id string
  graphlite_query(db, session, gql)   -> JSON string with results
  graphlite_close_session(db, sid)    -> error code
  graphlite_close(db)                 -> void
  graphlite_version()                 -> version string
]]

local lunet = require("lunet")
local gl = require("lunet.graphlite")

lunet.spawn(function()
    print("=== GraphLite GQL Database Demo ===")
    print()

    -- 1. Open a database (uses a temporary directory)
    --    The `lib` field is optional — if omitted, it looks for the FFI lib
    --    in the default system library search path.
    print("1. Opening database...")
    local db_path = "/tmp/lunet_graphlite_demo_" .. os.time()
    local conn, err = gl.open({ path = db_path })
    if not conn then
        print("Failed to open database:", err)
        return
    end
    print("   Database opened at " .. db_path)
    print()

    -- 2. Create a session
    print("2. Creating session...")
    local session, err = gl.create_session(conn, "admin")
    if not session then
        print("Failed to create session:", err)
        gl.close(conn)
        return
    end
    print("   Session created for user 'admin'")
    print()

    -- 3. Create schema and graph (DDL)
    --    GraphLite uses ISO GQL syntax for schema and graph management
    print("3. Creating schema and graph...")
    local result, err = gl.query(conn, session, "CREATE SCHEMA IF NOT EXISTS /example")
    if err then
        print("   Schema creation warning:", err)
    end

    result, err = gl.query(conn, session, "SESSION SET SCHEMA /example")
    if err then
        print("   Set schema error:", err)
        gl.close(conn)
        return
    end

    result, err = gl.query(conn, session, "CREATE GRAPH IF NOT EXISTS social")
    if err then
        print("   Graph creation warning:", err)
    end

    result, err = gl.query(conn, session, "SESSION SET GRAPH social")
    if err then
        print("   Set graph error:", err)
        gl.close(conn)
        return
    end
    print("   Schema '/example' and graph 'social' created")
    print()

    -- 4. Insert data (DML)
    --    Insert Person nodes with name and age properties
    print("4. Inserting data...")
    local people = {
        {name = "Alice",   age = 30},
        {name = "Bob",     age = 25},
        {name = "Charlie", age = 35},
        {name = "David",   age = 28},
        {name = "Eve",     age = 23},
        {name = "Frank",   age = 40},
    }

    for _, p in ipairs(people) do
        local gql = string.format(
            "INSERT (p:Person {name: '%s', age: %d})", p.name, p.age)
        local result, err = gl.query(conn, session, gql)
        if err then
            print("   Insert failed for " .. p.name .. ":", err)
        end
    end
    print("   Inserted " .. #people .. " persons")
    print()

    -- 5. Query all persons (DQL with MATCH)
    --    ISO GQL uses MATCH for pattern matching in the graph
    print("5. Querying all persons...")
    local json, err = gl.query(conn, session,
        "MATCH (p:Person) RETURN p.name as name, p.age as age")
    if err then
        print("   Query failed:", err)
    else
        print("   Result (JSON): " .. json)
    end
    print()

    -- 6. Filter with WHERE clause
    --    Find persons over age 25, ordered by age descending
    print("6. Querying persons over 25...")
    json, err = gl.query(conn, session,
        "MATCH (p:Person) WHERE p.age > 25 RETURN p.name as name, p.age as age")
    if err then
        print("   Query failed:", err)
    else
        print("   Result (JSON): " .. json)
    end
    print()

    -- 7. Aggregation
    --    Count all persons in the graph
    print("7. Counting all persons...")
    json, err = gl.query(conn, session,
        "MATCH (p:Person) RETURN count(p) as count")
    if err then
        print("   Count query failed:", err)
    else
        print("   Result (JSON): " .. json)
    end
    print()

    -- 8. Get GraphLite version
    print("8. GraphLite version: " .. gl.version())
    print()

    -- 9. Clean up
    print("9. Cleaning up...")
    local ok, err = gl.close_session(conn, session)
    if err then
        print("   Close session warning:", err)
    end

    gl.close(conn)
    print("   Database closed.")
    print()
    print("=== Demo complete! ===")

    -- Clean up temporary database directory
    os.execute("rm -rf " .. db_path)
end)

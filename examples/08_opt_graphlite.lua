--[[
GraphLite optional module demo for Lunet.

This example mirrors the GraphLite Python binding demos:
  - examples/python/bindings/basic_usage.py
  - examples/python/bindings/drug_discovery.py

It creates a small drug-discovery graph (Protein, Compound, Assay), links nodes
with TESTED_IN / MEASURES_ACTIVITY_ON / INHIBITS relationships, and runs
analytics queries similar to the Python examples.

Prerequisites:
  xmake opt-graphlite
  xmake opt-graphlite-example

Manual run:
  xmake build-release
  xmake build lunet-graphlite
  # make sure LUA_CPATH includes build/**/release/opt/?.so
  # and LUNET_GRAPHLITE_LIB points at .tmp/opt/graphlite/install/lib/<shared-lib>
  <lunet-run> examples/08_opt_graphlite.lua
]]

local lunet = require("lunet")
local db = require("lunet.graphlite")

local function print_rows(title, rows)
    print(title)
    if not rows or #rows == 0 then
        print("  (no rows)")
        print()
        return
    end
    for _, row in ipairs(rows) do
        local parts = {}
        for k, v in pairs(row) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
        table.sort(parts)
        print("  - " .. table.concat(parts, ", "))
    end
    print()
end

local function must_exec(conn, gql, label)
    local result, err = db.exec(conn, gql)
    if err then
        error(label .. ": " .. tostring(err), 2)
    end
    return result
end

lunet.spawn(function()
    local conn
    local ok, run_err = pcall(function()
        print("=== Lunet GraphLite Optional Demo ===")
        print()

        local db_path = ".tmp/graphlite_lunet_demo_" .. tostring(os.time())
        local lib_path = os.getenv("LUNET_GRAPHLITE_LIB") or ""

        conn = assert(db.open({
            path = db_path,
            username = "researcher",
            library_path = lib_path
        }))
        print("Connected to GraphLite at: " .. db_path)
        print()

        must_exec(conn, "CREATE SCHEMA IF NOT EXISTS /drug_discovery", "create schema")
        must_exec(conn, "SESSION SET SCHEMA /drug_discovery", "set schema")
        must_exec(conn, "CREATE GRAPH IF NOT EXISTS pharma_research", "create graph")
        must_exec(conn, "SESSION SET GRAPH pharma_research", "set graph")

        must_exec(conn, [[
            INSERT
                (:Protein {id: 'TP53', name: 'Tumor Protein P53', disease: 'Cancer'}),
                (:Protein {id: 'EGFR', name: 'Epidermal Growth Factor Receptor', disease: 'Cancer'}),
                (:Protein {id: 'ACE2', name: 'Angiotensin-Converting Enzyme 2', disease: 'Hypertension'})
        ]], "insert proteins")

        must_exec(conn, [[
            INSERT
                (:Compound {id: 'CP-002', name: 'Gefitinib', development_stage: 'Approved'}),
                (:Compound {id: 'CP-003', name: 'Captopril', development_stage: 'Approved'}),
                (:Compound {id: 'CP-005', name: 'APG-115', development_stage: 'Clinical Trial Phase 2'})
        ]], "insert compounds")

        must_exec(conn, [[
            INSERT
                (:Assay {id: 'AS-001', name: 'EGFR Kinase Assay', assay_type: 'Enzymatic'}),
                (:Assay {id: 'AS-002', name: 'ACE2 Binding Assay', assay_type: 'Binding'}),
                (:Assay {id: 'AS-003', name: 'TP53 Interaction Assay', assay_type: 'PPI'})
        ]], "insert assays")

        must_exec(conn, [[
            MATCH (c:Compound {id: 'CP-002'}), (a:Assay {id: 'AS-001'})
            INSERT (c)-[:TESTED_IN {test_date: '2024-01-15'}]->(a)
        ]], "link tested_in 1")
        must_exec(conn, [[
            MATCH (c:Compound {id: 'CP-003'}), (a:Assay {id: 'AS-002'})
            INSERT (c)-[:TESTED_IN {test_date: '2024-02-20'}]->(a)
        ]], "link tested_in 2")
        must_exec(conn, [[
            MATCH (c:Compound {id: 'CP-005'}), (a:Assay {id: 'AS-003'})
            INSERT (c)-[:TESTED_IN {test_date: '2024-03-25'}]->(a)
        ]], "link tested_in 3")

        must_exec(conn, [[
            MATCH (a:Assay {id: 'AS-001'}), (p:Protein {id: 'EGFR'})
            INSERT (a)-[:MEASURES_ACTIVITY_ON]->(p)
        ]], "link assay to protein 1")
        must_exec(conn, [[
            MATCH (a:Assay {id: 'AS-002'}), (p:Protein {id: 'ACE2'})
            INSERT (a)-[:MEASURES_ACTIVITY_ON]->(p)
        ]], "link assay to protein 2")
        must_exec(conn, [[
            MATCH (a:Assay {id: 'AS-003'}), (p:Protein {id: 'TP53'})
            INSERT (a)-[:MEASURES_ACTIVITY_ON]->(p)
        ]], "link assay to protein 3")

        must_exec(conn, [[
            MATCH (c:Compound {id: 'CP-002'}), (p:Protein {id: 'EGFR'})
            INSERT (c)-[:INHIBITS {IC50: 37.5, IC50_unit: 'nM'}]->(p)
        ]], "inhibits 1")
        must_exec(conn, [[
            MATCH (c:Compound {id: 'CP-003'}), (p:Protein {id: 'ACE2'})
            INSERT (c)-[:INHIBITS {IC50: 23.0, IC50_unit: 'nM'}]->(p)
        ]], "inhibits 2")
        must_exec(conn, [[
            MATCH (c:Compound {id: 'CP-005'}), (p:Protein {id: 'TP53'})
            INSERT (c)-[:INHIBITS {IC50: 12.5, IC50_unit: 'nM'}]->(p)
        ]], "inhibits 3")

        local potent_rows, err = db.query(conn, [[
            MATCH (c:Compound)-[i:INHIBITS]->(p:Protein)
            WHERE i.IC50 < 30
            RETURN c.name AS compound, p.name AS target, i.IC50 AS ic50_nM
            ORDER BY i.IC50
        ]])
        if err then
            error("potent compounds query failed: " .. tostring(err))
        end
        print_rows("Potent compounds (IC50 < 30nM):", potent_rows)

        local traversal_rows, err = db.query(conn, [[
            MATCH (c:Compound {id: 'CP-002'})-[:TESTED_IN]->(a:Assay)-[:MEASURES_ACTIVITY_ON]->(p:Protein)
            RETURN c.name AS compound, a.name AS assay, p.name AS target
        ]])
        if err then
            error("traversal query failed: " .. tostring(err))
        end
        print_rows("Traversal query (compound -> assay -> protein):", traversal_rows)

        local aggregate_rows, err = db.query(conn, [[
            MATCH (p:Protein)<-[:INHIBITS]-(c:Compound)
            RETURN p.name AS protein, COUNT(c) AS inhibitor_count
        ]])
        if err then
            error("aggregation query failed: " .. tostring(err))
        end
        print_rows("Aggregation query (inhibitor count by protein):", aggregate_rows)

        print("GraphLite optional demo completed.")
    end)

    if conn then
        pcall(function()
            db.close(conn)
        end)
    end

    if not ok then
        print("GraphLite demo failed: " .. tostring(run_err))
        __lunet_exit_code = 1
        return
    end
    __lunet_exit_code = 0
end)

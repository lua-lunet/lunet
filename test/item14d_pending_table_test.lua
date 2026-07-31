-- RED PHASE (item14): msg_id correlation via the pending table (unit).
-- Fails until item16 creates examples/advisory_lock_cas/pending.lua.
-- BUG-4: replies are matched to waiters by msg_id; unknown ids dropped.
-- Usage (after rework): lunet-run test/item14d_pending_table_test.lua

local script_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local H = dofile(script_dir .. "/harness.lua")
local lunet = require("lunet")

local root = H.repo_root()
local pending = dofile(root .. "/examples/advisory_lock_cas/pending.lua")

local t = H.new_tally()

lunet.spawn(function()
    local p = pending.new()

    -- Unknown msg_id: deliver returns false (caller logs the drop).
    t.check(p.deliver("deadbeef", { status = "OK" }) == false,
        "deliver on unknown msg_id returns false (drop)")

    -- Waiter still pending after a wrong-id delivery.
    local w = p.register("aa000001")
    t.check(p.deliver("bb000002", { status = "OK", holder = 999 }) == false,
        "wrong-id delivery does not satisfy waiter")
    local reply, timed_out = p.wait(w, 30)
    t.check(reply == nil and timed_out == true,
        "waiter times out when only wrong-id replies arrive")

    -- Correct id delivers.
    local w2 = p.register("cc000003")
    t.check(p.deliver("cc000003", { status = "OK", holder = 42 }) == true,
        "deliver on registered id returns true")
    local reply2, timed_out2 = p.wait(w2, 200)
    t.check(timed_out2 == false and reply2 ~= nil and reply2.holder == 42,
        "waiter receives its own reply by msg_id")

    -- Late delivery after timeout is a drop (waiter already gone).
    local w3 = p.register("dd000004")
    local _, timed_out3 = p.wait(w3, 20)
    t.check(timed_out3 == true, "second waiter times out")
    t.check(p.deliver("dd000004", { status = "OK" }) == false,
        "late reply for expired waiter is dropped")

    t.exit()
end)

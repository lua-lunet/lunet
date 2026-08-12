-- test/smoke_fs.lua — filesystem regression tests
-- Run: ./build/macosx/arm64/release/lunet-run test/smoke_fs.lua
-- Covers: sequential read/write offset advancement, append mode, binary
-- data with embedded NULs, fs.write return type, multi-chunk reads.

local lunet = require("lunet")
local fs = require("lunet.fs")

local tmpdir = ".tmp"
os.execute("mkdir -p " .. tmpdir)

local passed = 0
local failed = 0

local function check(desc, ok, detail)
  if ok then
    passed = passed + 1
    io.stderr:write(string.format("  PASS: %s\n", desc))
  else
    failed = failed + 1
    io.stderr:write(string.format("  FAIL: %s — %s\n", desc, tostring(detail)))
  end
end

lunet.spawn(function()
  -- ---- 1. Sequential read: offset advances per read ----
  io.stderr:write("=== sequential read ===\n")
  do
    local path = tmpdir .. "/smoke_fs_read.tmp"
    -- Write a 200-byte file with distinct halves
    local fd, err = fs.open(path, "w")
    if not err then
      local payload = ("A"):rep(100) .. ("B"):rep(100)
      local n, werr = fs.write(fd, payload)
      check("setup write 200 bytes", not werr and n == 200,
        string.format("n=%s werr=%s", tostring(n), tostring(werr)))
      fs.close(fd)
    end

    -- Read in two 100-byte chunks
    fd, err = fs.open(path, "r")
    check("open for sequential read", not err, err)
    if not err then
      local c1, e1 = fs.read(fd, 100)
      check("chunk1 read 100 bytes", not e1 and #c1 == 100,
        string.format("#c1=%s e1=%s", c1 and #c1 or "nil", tostring(e1)))
      local c2, e2 = fs.read(fd, 100)
      check("chunk2 read 100 bytes", not e2 and #c2 == 100,
        string.format("#c2=%s e2=%s", c2 and #c2 or "nil", tostring(e2)))
      check("chunks differ (offset advanced)",
        c1 ~= c2, "chunk1 == chunk2 — offset stuck")
      check("chunk1 is all A", c1 == ("A"):rep(100),
        string.format("c1=%q...", c1:sub(1, 10)))
      check("chunk2 is all B", c2 == ("B"):rep(100),
        string.format("c2=%q...", c2:sub(1, 10)))
      fs.close(fd)
    end
    os.remove(path)
  end

  -- ---- 2. Sequential write: both writes persist ----
  io.stderr:write("=== sequential write ===\n")
  do
    local path = tmpdir .. "/smoke_fs_write.tmp"
    local fd, err = fs.open(path, "w")
    check("open for sequential write", not err, err)
    if not err then
      local n1, e1 = fs.write(fd, "FIRST")
      check("write1 ok", not e1 and n1 == 5,
        string.format("n1=%s e1=%s", tostring(n1), tostring(e1)))
      local n2, e2 = fs.write(fd, "SECOND")
      check("write2 ok", not e2 and n2 == 6,
        string.format("n2=%s e2=%s", tostring(n2), tostring(e2)))
      fs.close(fd)

      local fd2, err2 = fs.open(path, "r")
      check("open for verify read", not err2, err2)
      if not err2 then
        local content, e3 = fs.read(fd2, 64)
        check("read back", not e3, e3)
        check("both writes persisted",
          content == "FIRSTSECOND",
          string.format("content=%q (%d bytes)", content, #content))
        fs.close(fd2)
      end
    end
    os.remove(path)
  end

  -- ---- 3. Append mode: writes at end of file ----
  io.stderr:write("=== append mode ===\n")
  do
    local path = tmpdir .. "/smoke_fs_append.tmp"
    -- Create file with "BASE"
    local fd, err = fs.open(path, "w")
    if not err then
      fs.write(fd, "BASE")
      fs.close(fd)
    end

    -- Append "+MORE"
    fd, err = fs.open(path, "a")
    check("open for append", not err, err)
    if not err then
      local n, werr = fs.write(fd, "+MORE")
      check("append write ok", not werr and n == 5,
        string.format("n=%s werr=%s", tostring(n), tostring(werr)))
      fs.close(fd)

      local fd2, err2 = fs.open(path, "r")
      if not err2 then
        local content = fs.read(fd2, 64)
        check("append content correct",
          content == "BASE+MORE",
          string.format("content=%q", content))
        fs.close(fd2)
      end
    end
    os.remove(path)
  end

  -- ---- 4. Binary data with embedded NUL ----
  io.stderr:write("=== binary NUL payload ===\n")
  do
    local path = tmpdir .. "/smoke_fs_nul.tmp"
    local fd, err = fs.open(path, "w")
    check("open for NUL write", not err, err)
    if not err then
      local payload = "AB\0CD" .. "\0\0\0"
      local n, werr = fs.write(fd, payload)
      check("write NUL payload byte count correct",
        not werr and n == #payload,
        string.format("wrote %d of %d bytes", tonumber(n) or -1, #payload))
      fs.close(fd)

      local fd2, err2 = fs.open(path, "r")
      if not err2 then
        local content = fs.read(fd2, 64)
        check("NUL payload round-trips",
          content == payload,
          string.format("content=%q (%d bytes) vs payload (%d bytes)",
            content, #content, #payload))
        fs.close(fd2)
      end
    end
    os.remove(path)
  end

  -- ---- 5. fs.write return type: (integer, nil) on success ----
  io.stderr:write("=== fs.write return type ===\n")
  do
    local path = tmpdir .. "/smoke_fs_ret.tmp"
    local fd, err = fs.open(path, "w")
    check("open for return-type check", not err, err)
    if not err then
      local r1, r2 = fs.write(fd, "hello")
      check("fs.write returns (number, nil)",
        type(r1) == "number" and r2 == nil,
        string.format("r1=%s(%s) r2=%s(%s)",
          type(r1), tostring(r1), type(r2), tostring(r2)))
      check("byte count matches", r1 == 5,
        string.format("r1=%s expected 5", tostring(r1)))
      fs.close(fd)
    end
    os.remove(path)
  end

  -- ---- 6. Multi-chunk read to EOF (empty string at EOF) ----
  io.stderr:write("=== read to EOF ===\n")
  do
    local path = tmpdir .. "/smoke_fs_eof.tmp"
    local fd, err = fs.open(path, "w")
    if not err then
      fs.write(fd, "1234567890")
      fs.close(fd)
    end

    fd, err = fs.open(path, "r")
    check("open for EOF read", not err, err)
    if not err then
      local c1 = fs.read(fd, 10)
      check("read all 10 bytes", c1 == "1234567890",
        string.format("c1=%q", c1))
      local c2 = fs.read(fd, 10)
      check("read at EOF returns empty string",
        type(c2) == "string" and #c2 == 0,
        string.format("c2=%q len=%d", tostring(c2), c2 and #c2 or -1))
      fs.close(fd)
    end
    os.remove(path)
  end

  -- ---- 7. Large file multi-chunk read ----
  io.stderr:write("=== large file multi-chunk ===\n")
  do
    local path = tmpdir .. "/smoke_fs_large.tmp"
    local chunk = ("x"):rep(4096)
    local total_chunks = 8
    local fd, err = fs.open(path, "w")
    if not err then
      for i = 1, total_chunks do
        local n, werr = fs.write(fd, chunk)
        check(string.format("write chunk %d", i),
          not werr and n == 4096,
          string.format("n=%s werr=%s", tostring(n), tostring(werr)))
      end
      fs.close(fd)

      local fd2, err2 = fs.open(path, "r")
      check("open large file", not err2, err2)
      if not err2 then
        local total_read = 0
        for i = 1, total_chunks do
          local data, rerr = fs.read(fd2, 4096)
          check(string.format("read chunk %d", i),
            not rerr and #data == 4096,
            string.format("#data=%s rerr=%s", data and #data or "nil", tostring(rerr)))
          total_read = total_read + #data
        end
        -- EOF
        local data = fs.read(fd2, 4096)
        check("EOF after all chunks",
          type(data) == "string" and #data == 0,
          string.format("data=%q", tostring(data)))
        check("total bytes read correct",
          total_read == total_chunks * 4096,
          string.format("total_read=%d expected=%d", total_read, total_chunks * 4096))
        fs.close(fd2)
      end
    end
    os.remove(path)
  end

  -- Summary
  io.stderr:write(string.format("\n=== fs smoke: %d passed, %d failed ===\n", passed, failed))
  os.exit(failed > 0 and 1 or 0)
end)

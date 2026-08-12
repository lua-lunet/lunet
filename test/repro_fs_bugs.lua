local lunet = require("lunet")
local fs = require("lunet.fs")
local tmpfile = ".tmp/fs_bug_rep.tmp"

local fail = false

local function check(desc, ok, detail)
   if not ok then
      fail = true
      io.stderr:write(string.format("FAIL: %s — %s\n", desc, tostring(detail)))
   else
      io.stderr:write(string.format("PASS: %s\n", desc))
   end
end

lunet.spawn(function()
   -- ===== Setup: write a 100-byte file (50 A's then 50 B's) =====
   do
      local fd, err = fs.open(tmpfile, "w")
      check("open tmpfile for write", not err, err)
      local n, err = fs.write(fd, ("A"):rep(50) .. ("B"):rep(50))
      check("write 100 bytes to tmpfile", not err, err)
      io.stderr:write(string.format("  wrote %d bytes\n", n))
      local cerr = fs.close(fd)
      check("close after write", not cerr, cerr)
   end

   -- ===== #155: fs.read offset stuck at 0 =====
   io.stderr:write("=== #155: fs.read offset stuck at 0 ===\n")
   do
      local fd, err = fs.open(tmpfile, "r")
      check("open for read (#155 read)", not err, err)

      local chunk1, err = fs.read(fd, 50)
      check("read chunk1 (50 bytes)", not err, err)
      io.stderr:write(string.format("  chunk1: %d bytes, first=%q last=%q\n",
         #chunk1, chunk1:sub(1,4), chunk1:sub(-4,-1)))

      local chunk2, err = fs.read(fd, 50)
      check("read chunk2 (50 bytes)", not err, err)
      io.stderr:write(string.format("  chunk2: %d bytes, first=%q last=%q\n",
         #chunk2, chunk2:sub(1,4), chunk2:sub(-4,-1)))

      fs.close(fd)

      if chunk1 == chunk2 then
         io.stderr:write("  *** BUG #155 CONFIRMED: chunk1 == chunk2 — read offset never advances past 0\n")
      else
         io.stderr:write("  (bug absent — chunks differ, offset advances correctly)\n")
      end
   end

   -- ===== #155: fs.write offset stuck at 0 =====
   io.stderr:write("\n=== #155: fs.write offset stuck at 0 ===\n")
   do
      local fd, err = fs.open(tmpfile, "w")
      check("open for write (#155 write)", not err, err)

      local n1, err = fs.write(fd, "FIRST")
      check("write1 FIRST", not err, err)
      io.stderr:write(string.format("  write1: %d bytes\n", n1))

      local n2, err = fs.write(fd, "SECOND")
      check("write2 SECOND", not err, err)
      io.stderr:write(string.format("  write2: %d bytes\n", n2))

      fs.close(fd)

      local fd2, err = fs.open(tmpfile, "r")
      check("open for read (#155 write verify)", not err, err)
      local content, err = fs.read(fd2, 64)
      check("read back", not err, err)
      fs.close(fd2)

      io.stderr:write(string.format("  file content (%d bytes): %q\n", #content, content))

      if content == "SECOND" or not content:find("FIRST", 1, true) then
         io.stderr:write("  *** BUG #155 CONFIRMED: only second write survived — write offset stuck at 0\n")
      else
         io.stderr:write("  (bug absent — both writes persisted, offset advances correctly)\n")
      end
   end

   -- ===== #156: fs.write strlen truncation at NUL =====
   io.stderr:write("\n=== #156: fs.write strlen truncation at NUL ===\n")
   do
      local fd, err = fs.open(tmpfile, "w")
      check("open for write (#156)", not err, err)

      local payload = "AB\0CD"
      local n, err = fs.write(fd, payload)
      check("write with embedded NUL", not err, err)
      io.stderr:write(string.format("  payload: %d bytes (AB NUL CD), reported written: %d, data: %q\n",
         #payload, n, payload))
      local hex = ""
      for i = 1, #payload do
         hex = hex .. string.format("%02X ", payload:byte(i))
      end
      io.stderr:write(string.format("  payload hex: %s\n", hex))

      fs.close(fd)

      local fd2, err = fs.open(tmpfile, "r")
      check("open for read (#156 verify)", not err, err)
      local content, err = fs.read(fd2, 64)
      check("read back (#156)", not err, err)
      fs.close(fd2)

      io.stderr:write(string.format("  read back: %d bytes, data: %q\n", #content, content))
      local hex2 = ""
      for i = 1, #content do
         hex2 = hex2 .. string.format("%02X ", content:byte(i))
      end
      io.stderr:write(string.format("  read back hex: %s\n", hex2))

      if n ~= #payload then
         io.stderr:write(string.format("  *** BUG #156 CONFIRMED: wrote %d bytes but payload is %d — strlen truncation at NUL\n", n, #payload))
      end
      if #content ~= #payload then
         io.stderr:write(string.format("  *** BUG #156 CONFIRMED: read back %d bytes but payload was %d\n", #content, #payload))
      end
   end

   -- ===== #157: fs.write returns byte count but types say error-only =====
   io.stderr:write("\n=== #157: fs.write return type annotation mismatch ===\n")
   do
      local fd, err = fs.open(tmpfile, "w")
      check("open for write (#157)", not err, err)
      local r1, r2 = fs.write(fd, "hello")
      check("write returned 2 values (count, nil)", type(r1) == "number" and r2 == nil,
         string.format("r1=%s(%s) r2=%s(%s)", type(r1), tostring(r1), type(r2), tostring(r2)))
      io.stderr:write(string.format("  fs.write returned: (%s, %s)\n", type(r1), type(r2)))
      if type(r1) == "number" then
         io.stderr:write("  *** BUG #157 CONFIRMED: fs.write returns integer byte count, but types say error-only\n")
      end
      fs.close(fd)
   end

   os.remove(tmpfile)
   if fail then
      io.stderr:write("\nSOME CHECKS FAILED\n")
      os.exit(1)
   else
      io.stderr:write("\nALL CHECKS PASSED (bugs absent? or logic needs work)\n")
      os.exit(0)
   end
end)

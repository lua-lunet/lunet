-- Suite for lunet.security: HMAC-SHA-256 sign/verify, base64url, JWT
-- HS256. Pins the glue: the RFC 7518 raw-secret key policy, the
-- constant-time verify, the JWT profile, and the named error strings.
--
-- Module resolution mirrors spec/sodium_spec.lua: package.preload
-- routes require("lunet.security") to the dev-tree file. The pending
-- gates fire exactly when the dependencies are absent.
--
-- KNOWN-ANSWER VECTORS: RFC 4231 cases 1, 2, 5 and 7 verbatim (short
-- and oversize keys), plus tags computed with Python's hmac against
-- plain RFC 2104 HMAC-SHA-256 over the raw secret. The retired
-- SHA-256-subkey tags are pinned as negatives: they must not verify.
--
-- TAMPER-TEST GEOMETRY: base64url carries 6 bits per character, so the
-- final character of an unpadded segment holds bits the decoder may
-- ignore — flipping it can be a no-op. Tampering flips the FIRST
-- character (or raw bytes), which always changes the decoded bytes.

local bit = require("bit")

describe("security module #native", function()
  local spec_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "spec"
  package.preload["lunet.security"] = function()
    return assert(loadfile(spec_dir .. "/../ext/security/security.lua"))()
  end
  package.preload["lunet.sodium"] = function()
    return assert(loadfile(spec_dir .. "/../ext/paxe/sodium.lua"))()
  end
  package.preload["lunet.jsonic"] = function()
    return assert(loadfile(spec_dir .. "/../ext/jsonic/jsonic.lua"))()
  end

  local ok, security = pcall(require, "lunet.security")
  if not ok then
    pending("lunet.security not loadable — lunet.sodium needs liblunet_paxe (xmake build-paxe)",
      function() end)
    return
  end

  local crypto, jwt = security.crypto, security.jwt

  local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end

  local function unhex(s)
    return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
  end

  -- 32 bytes of 0x0b, the "Hi There" vector key.
  local K_0B32 = string.rep("\11", 32)
  -- 0x00..0x1f, a full key of distinct bytes.
  local K_SEQ32
  do
    local parts = {}
    for i = 0, 31 do parts[i + 1] = string.char(i) end
    K_SEQ32 = table.concat(parts)
  end
  local K_AA32 = string.rep("\xaa", 32)
  local K_AA131 = string.rep("\xaa", 131)

  it("exports the crypto and jwt surfaces", function()
    assert.are.equal("table", type(security))
    assert.are.equal("table", type(crypto))
    assert.are.equal("table", type(jwt))
    for _, fn in ipairs({ "sign", "verify", "b64url_encode", "b64url_decode" }) do
      assert.are.equal("function", type(crypto[fn]), "crypto." .. fn)
    end
    for _, fn in ipairs({ "encode", "decode" }) do
      assert.are.equal("function", type(jwt[fn]), "jwt." .. fn)
    end
  end)

  describe("crypto.sign / crypto.verify (HMAC-SHA-256)", function()
    it("produces independent-implementation known answers for 32-byte keys", function()
      local k3 = "01234567890123456789012345678901"
      local data4 = {}
      for i = 0, 199 do data4[i + 1] = string.char(i % 251) end
      local vectors = {
        { key = K_0B32, data = "Hi There",
          want = "198a607eb44bfbc69903a0f1cf2bbdc5ba0aa3f3d9ae3c1c7a3b1696a0b68cf7" },
        { key = K_SEQ32, data = "",
          want = "d38b42096d80f45f826b44a9d5607de72496a415d3f4a1a8c88e3bb9da8dc1cb" },
        { key = k3, data = "lunet.security known-answer",
          want = "fac8f98c31a6f54a5849d943ad3abb32da62add25abdd7a36ae487b206e966b3" },
        { key = K_AA32, data = table.concat(data4),
          want = "d2430a1709c8d994e1e26bbfa7e90690df825310173c5168f765b1b3102f4d5c" },
      }
      for i, v in ipairs(vectors) do
        local tag = crypto.sign(v.data, v.key)
        assert.equals(32, #tag, "tag length, vector " .. i)
        assert.equals(v.want, hex(tag), "vector " .. i)
        assert.is_true(crypto.verify(v.data, v.key, tag), "verify, vector " .. i)
      end
    end)

    it("reproduces the RFC 4231 long-key vectors through the standard hash-the-key path", function()
      -- Keys longer than the HMAC block size are hashed first — RFC
      -- 2104's own reduction — so the published RFC 4231 tags for the
      -- 131-byte 0xaa key must come out exactly.
      local tag5 = crypto.sign("Test Using Larger Than Block-Size Key - Hash Key First", K_AA131)
      assert.equals("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
        hex(tag5), "RFC 4231 test case 5")
      local tag7 = crypto.sign("This is a test using a larger than block-size key and a " ..
        "larger than block-size data. The key needs to be hashed before being used by " ..
        "the HMAC algorithm.", K_AA131)
      assert.equals("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
        hex(tag7), "RFC 4231 test case 7")
    end)

    it("reproduces the RFC 4231 short-key vectors over the raw secret", function()
      -- RFC 4231 test cases 1 and 2 verbatim: keys far shorter than
      -- the block size, signed RAW (RFC 7518 HS256) — the retired
      -- derivation never produced these tags.
      local k20 = string.rep("\11", 20)
      local tag1 = crypto.sign("Hi There", k20)
      assert.equals("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        hex(tag1), "RFC 4231 test case 1")
      assert.is_true(crypto.verify("Hi There", k20, tag1))
      local tag2 = crypto.sign("what do ya want for nothing?", "Jefe")
      assert.equals("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        hex(tag2), "RFC 4231 test case 2")
      assert.is_true(crypto.verify("what do ya want for nothing?", "Jefe", tag2))
      -- A key between 32 and 64 bytes takes the same zero-pad-to-block
      -- path and stays plain HMAC-SHA-256 (independent implementation).
      local tag48 = crypto.sign("Hi There", string.rep("\11", 48))
      assert.equals("284c05df0b43f95169b6b67292c6c0511035ffbddc5ebeae4f6e90db86726f72",
        hex(tag48), "48-byte key")
    end)

    it("produces the exact external-implementation signature for a short secret", function()
      -- The message is a JWT signing input (canonical HS256 header,
      -- fixed claims); the expected tag was computed with Python's
      -- hmac module over the raw secret "secret" — the tag any
      -- standard HS256 library produces and expects.
      local message = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9"
      local tag = crypto.sign(message, "secret")
      assert.equals("7b59d00c745aded256634d8c51723cfb00e5d10e9ca6ac34269cc92ef24e5199",
        hex(tag), "external short-secret signature")
      assert.is_true(crypto.verify(message, "secret", tag))
    end)

    it("rejects the tags the retired subkey derivation produced", function()
      -- Regression pin: the old implementation reduced every secret to
      -- a 32-byte SHA-256 subkey before HMAC. Its tag over the same
      -- message and secret — reproduced here with an independent
      -- implementation — must FAIL to verify under the raw-secret
      -- policy, for both crypto.verify and jwt.decode.
      local message = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9"
      local old_tag = unhex("2b603854b5a9b8840d7666007b8580493918757724941f784db808cb6949d2c8")
      assert.equals(32, #old_tag, "old-tag length")
      assert.is_false(crypto.verify(message, "secret", old_tag))
      local old_token = message .. "." .. crypto.b64url_encode(old_tag)
      local claims, err = jwt.decode(old_token, "secret")
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: sig: signature verification failed", err)
    end)

    it("pads keys to the block size like plain HMAC", function()
      -- Raw-secret policy: the key octets go in as-is and HMAC's own
      -- zero-padding to the block does the rest, so a key and its
      -- zero-padded form are the SAME HMAC (equivalent keys, below and
      -- above 32 bytes), while genuinely different secrets never
      -- collide and the data still binds the tag.
      local secret = "correct horse battery staple"
      local t1 = crypto.sign("payload", secret)
      local t2 = crypto.sign("payload", secret)
      assert.equals(t1, t2)
      assert.equals(32, #t1)
      assert.equals(t1, crypto.sign("payload", secret .. string.rep("\0", 32)))
      assert.equals(crypto.sign("payload", "k"),
        crypto.sign("payload", "k" .. string.rep("\0", 31)))
      assert.not_equals(t1, crypto.sign("payload", secret .. "!"))
      assert.not_equals(t1, crypto.sign("payload2", secret))
    end)

    it("verifies true only for the exact data, key and tag", function()
      local tag = crypto.sign("payload", K_0B32)
      assert.is_true(crypto.verify("payload", K_0B32, tag))
      assert.is_false(crypto.verify("payloaD", K_0B32, tag))
      assert.is_false(crypto.verify("payload", K_AA32, tag))
      -- A flipped bit anywhere in the tag is rejected.
      for i = 1, 32 do
        local tampered = tag:sub(1, i - 1) .. string.char(bit.bxor(tag:byte(i), 0x01)) ..
          tag:sub(i + 1)
        assert.is_false(crypto.verify("payload", K_0B32, tampered), "flipped byte " .. i)
      end
    end)

    it("rejects a wrong-length signature without comparing it", function()
      local tag = crypto.sign("payload", K_0B32)
      assert.is_false(crypto.verify("payload", K_0B32, tag:sub(2)))
      assert.is_false(crypto.verify("payload", K_0B32, tag .. "x"))
      assert.is_false(crypto.verify("payload", K_0B32, ""))
    end)

    it("raises on malformed arguments, naming the argument", function()
      local cases = {
        { fn = crypto.sign, args = { 42, K_0B32 }, want = "string expected" },
        { fn = crypto.sign, args = { "data", 42 }, want = "string expected" },
        { fn = crypto.sign, args = { "data", "" }, want = "non%-empty" },
        { fn = crypto.sign, args = { "data", nil }, want = "string expected" },
        { fn = crypto.verify, args = { 42, K_0B32, K_0B32 }, want = "string expected" },
        { fn = crypto.verify, args = { "data", "", K_0B32 }, want = "non%-empty" },
        { fn = crypto.verify, args = { "data", K_0B32, 42 }, want = "string expected" },
      }
      for _, c in ipairs(cases) do
        local raised, err = pcall(c.fn, unpack(c.args))
        assert.is_false(raised, ("args %s must raise"):format(tostring(c.args[1])))
        assert.truthy(tostring(err):find(c.want),
          "message should match " .. c.want .. ", got: " .. tostring(err))
      end
    end)
  end)

  describe("crypto.b64url_encode / crypto.b64url_decode", function()
    -- RFC 4648 vectors, unpadded URL-safe profile.
    local vectors = {
      { raw = "", enc = "" },
      { raw = "f", enc = "Zg" },
      { raw = "fo", enc = "Zm8" },
      { raw = "foo", enc = "Zm9v" },
      { raw = "foob", enc = "Zm9vYg" },
      { raw = "fooba", enc = "Zm9vYmE" },
      { raw = "foobar", enc = "Zm9vYmFy" },
    }

    it("round-trips the RFC 4648 vectors unpadded", function()
      for _, v in ipairs(vectors) do
        assert.equals(v.enc, crypto.b64url_encode(v.raw), "encode " .. #v.raw .. " bytes")
        assert.equals(v.raw, crypto.b64url_decode(v.enc), "decode " .. v.enc)
      end
    end)

    it("uses the URL-safe alphabet and never pads", function()
      -- 0xFB 0xFF is "+/+" in the standard alphabet, "-_8" in the
      -- URL-safe one; no '=', '+' or '/' anywhere.
      assert.equals("-_8", crypto.b64url_encode("\251\255"))
      for _, raw in ipairs({ "f", "fo", "foob", "fooba" }) do
        assert.is_nil(crypto.b64url_encode(raw):find("=", 1, true), "no padding for " .. raw)
        assert.is_nil(crypto.b64url_encode(raw):find("+", 1, true), "no + for " .. raw)
        assert.is_nil(crypto.b64url_encode(raw):find("/", 1, true), "no / for " .. raw)
      end
    end)

    it("round-trips binary data", function()
      local blob = "\0\1\255\128caf\195\169"
      assert.equals(blob, crypto.b64url_decode(crypto.b64url_encode(blob)))
    end)

    it("raises on malformed input, naming the failure", function()
      for _, bad in ipairs({ "!!!!", "Zg==", "Zm9vYmFyX" }) do
        local raised, err = pcall(crypto.b64url_decode, bad)
        assert.is_false(raised, "malformed input " .. bad .. " must raise")
        assert.truthy(tostring(err):find("unparseable", 1, true) or
          tostring(err):find("malformed", 1, true),
          "message should name the failure, got: " .. tostring(err))
      end
      local raised, err = pcall(crypto.b64url_encode, 42)
      assert.is_false(raised)
      assert.truthy(tostring(err):find("string expected", 1, true))
    end)
  end)

  -- jwt needs jsonic's native decoder; probe it once, exactly like
  -- spec/jsonic_spec.lua does, and pend the jwt half when it is absent.
  local jok, jsonic = pcall(require, "lunet.jsonic")
  local native_jsonic = jok and pcall(jsonic.decode, "[1]")

  if not native_jsonic then
    pending("lunet.jsonic native decoder not built (xmake build-jsonic) — jwt half pends",
      function() end)
    return
  end

  describe("jwt.encode / jwt.decode (HS256)", function()
    local SECRET = K_0B32

    -- Segment helpers: the MAC covers the RAW base64url text
    -- (header_b64 .. "." .. payload_b64), so a valid signature for an
    -- arbitrary segment pair is computable even when the segments are
    -- deliberately bogus — that isolates each decode-side check.
    local function seg(text)
      return crypto.b64url_encode(text)
    end

    local function sig_for(h, p)
      return crypto.b64url_encode(crypto.sign(h .. "." .. p, SECRET))
    end

    local H = seg('{"alg":"HS256","typ":"JWT"}')  -- the canonical header

    it("round-trips a payload through encode and decode", function()
      local issued = os.time()
      local token = jwt.encode({ sub = "u1", name = "lunet", admin = false }, SECRET,
        { expires_in = 3600 })
      assert.equals("string", type(token))
      local claims, err = jwt.decode(token, SECRET)
      assert.is_nil(err)
      assert.are.equal("u1", claims.sub)
      assert.are.equal("lunet", claims.name)
      assert.is_false(claims.admin)
      -- expires_in injects exp on a COPY: the caller's table is not
      -- mutated, and exp lands inside the issued minute.
      assert.truthy(claims.exp >= issued + 3600 - 1)
      assert.truthy(claims.exp <= os.time() + 3600)
    end)

    it("verifies a standard-library token signed with a short raw secret", function()
      -- Fixed token bytes: the canonical HS256 header, {"sub":"u1"}
      -- claims, secret "secret", and the signature an external
      -- HMAC-SHA-256 (Python's hmac module) computes over the RAW
      -- secret — the token any standard HS256 library emits MUST
      -- decode here.
      local token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9." ..
        "e1nQDHRa3tJWY02MUXI8-wDl0Q6cpqw0JpzJLvJOUZk"
      local claims, err = jwt.decode(token, "secret")
      assert.is_nil(err)
      assert.are.equal("u1", claims.sub)
      -- And the module's own encode over the same secret emits a token
      -- whose signature segment is byte-identical.
      local issued = jwt.encode({ sub = "u1" }, "secret")
      local _, _, sig_b64 = issued:match("^([^.]+)%.([^.]+)%.([^.]+)$")
      assert.equals("e1nQDHRa3tJWY02MUXI8-wDl0Q6cpqw0JpzJLvJOUZk", sig_b64)
    end)

    it("never mutates the caller's payload table", function()
      local payload = { sub = "u1" }
      jwt.encode(payload, SECRET, { expires_in = 60 })
      assert.is_nil(payload.exp)
    end)

    it("emits the canonical HS256 header segment", function()
      local token = jwt.encode({ sub = "u1" }, SECRET, { expires_in = 60 })
      assert.truthy(token:find("^eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9%."))
    end)

    it("passes a caller-set exp through and never expires a token without one", function()
      local token = jwt.encode({ sub = "u1", exp = os.time() + 120 }, SECRET)
      local claims, err = jwt.decode(token, SECRET)
      assert.is_nil(err)
      assert.are.equal("u1", claims.sub)
      -- Reconciled design, stated: no exp claim means the token never
      -- expires — decode succeeds without an exp check.
      local immortal = jwt.encode({ sub = "u1" }, SECRET)
      claims, err = jwt.decode(immortal, SECRET)
      assert.is_nil(err)
      assert.are.equal("u1", claims.sub)
    end)

    it("enforces exp: past is an error, future is fine", function()
      local past = jwt.encode({ sub = "u1", exp = os.time() - 1 }, SECRET)
      local claims, err = jwt.decode(past, SECRET)
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: exp: token expired", err)

      local future = jwt.encode({ sub = "u1", exp = os.time() + 2 }, SECRET)
      claims, err = jwt.decode(future, SECRET)
      assert.is_nil(err)
      assert.are.equal("u1", claims.sub)
    end)

    it("rejects a non-numeric exp claim as malformed", function()
      local token = jwt.encode({ sub = "u1", exp = "soon" }, SECRET)
      local claims, err = jwt.decode(token, SECRET)
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: malformed: exp claim is not a number", err)
    end)

    it("rejects tampering with any segment", function()
      local token = jwt.encode({ sub = "u1" }, SECRET, { expires_in = 3600 })
      local header_b64, payload_b64, sig_b64 = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")

      -- Flip the FIRST payload character (a valid base64url char for a
      -- different byte): the MAC no longer covers the same message.
      local flip1 = function(s)
        local c = s:sub(1, 1)
        local other = (c == "A") and "B" or "A"
        return other .. s:sub(2)
      end
      local claims, err = jwt.decode(flip1(header_b64) .. "." .. payload_b64 .. "." .. sig_b64,
        SECRET)
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: sig: signature verification failed", err)

      claims, err = jwt.decode(header_b64 .. "." .. flip1(payload_b64) .. "." .. sig_b64, SECRET)
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: sig: signature verification failed", err)

      -- Flip the FIRST signature character: constant-time compare must
      -- reject the different tag bytes.
      claims, err = jwt.decode(header_b64 .. "." .. payload_b64 .. "." .. flip1(sig_b64), SECRET)
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: sig: signature verification failed", err)

      -- A different secret verifies nothing.
      claims, err = jwt.decode(token, K_AA32)
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: sig: signature verification failed", err)
    end)

    it("rejects an alg-confused header even under a valid signature", function()
      -- A token whose header declares alg=none (or any other
      -- algorithm) is malformed for this verifier even when the
      -- signature over it is genuinely valid — the alg check runs
      -- after the signature check and refuses anything but HS256.
      local none_header = seg('{"alg":"none","typ":"JWT"}')
      local payload_b64 = seg('{"sub":"u1"}')
      local token = none_header .. "." .. payload_b64 .. "." .. sig_for(none_header, payload_b64)
      local claims, err = jwt.decode(token, SECRET)
      assert.is_nil(claims)
      assert.equals("lunet.security.jwt: malformed: header alg is not HS256", err)
    end)

    it("reports every malformed shape as the named error", function()
      -- Signatures here are genuinely valid for the (bogus) segments,
      -- so each case isolates ONE decode-side check and every failure
      -- is reported as the named "malformed" kind.
      local shapes = {
        { "", "" },                          -- empty token
        { "not a token at all", "" },        -- no dots
        { H .. "." .. seg("{}"), "" },       -- two segments
        { H .. "." .. seg("{}") .. ".A.A", "" }, -- four segments
        { H .. "." .. seg("{}") .. ".", "" },    -- empty signature segment
        { "." .. seg("{}") .. "." .. sig_for("", seg("{}")), "" },   -- empty header segment
        { "!!!." .. seg("{}") .. "." .. sig_for("!!!", seg("{}")), "" }, -- header not base64url
        { H .. ".!!!." .. sig_for(H, "!!!"), "" },                       -- payload not base64url
        { H .. "." .. seg("{}") .. ".!!!", "" },                         -- signature not base64url
        { seg("not json") .. "." .. seg("{}") .. "." .. sig_for(seg("not json"), seg("{}")), "" },
      }
      for i, shape in ipairs(shapes) do
        local claims, err = jwt.decode(shape[1], SECRET)
        assert.is_nil(claims, "shape " .. i .. " must fail")
        assert.truthy(tostring(err):find("lunet%.security%.jwt: malformed:"),
          "shape " .. i .. " must report malformed, got: " .. tostring(err))
      end
      -- A JSON payload that is not an object still decodes to a Lua
      -- table (both folded references behaved this way): an array's
      -- claims are simply read by key and come up empty.
      local array_token = H .. "." .. seg("[1,2]") .. "." .. sig_for(H, seg("[1,2]"))
      local claims, err = jwt.decode(array_token, SECRET)
      assert.is_nil(err)
      assert.are.equal("table", type(claims))
      assert.is_nil(claims.sub)
    end)

    it("raises on malformed arguments, naming the argument", function()
      local token = jwt.encode({ sub = "u1" }, SECRET, { expires_in = 60 })
      local cases = {
        { fn = jwt.encode, args = { nil, SECRET }, want = "table expected" },
        { fn = jwt.encode, args = { "sub", SECRET }, want = "table expected" },
        { fn = jwt.encode, args = { { sub = "u1" }, "" }, want = "non%-empty" },
        { fn = jwt.encode, args = { { sub = "u1" }, 42 }, want = "string expected" },
        { fn = jwt.encode, args = { { sub = "u1" }, SECRET, "nope" }, want = "table expected" },
        { fn = jwt.encode, args = { { sub = "u1" }, SECRET, { expires_in = 0 } },
          want = "expires_in" },
        { fn = jwt.encode, args = { { sub = "u1" }, SECRET, { expires_in = -5 } },
          want = "expires_in" },
        { fn = jwt.encode, args = { { sub = "u1" }, SECRET, { expires_in = 1.5 } },
          want = "expires_in" },
        { fn = jwt.decode, args = { token, "" }, want = "non%-empty" },
        { fn = jwt.decode, args = { token, nil }, want = "string expected" },
      }
      for _, c in ipairs(cases) do
        local raised, err = pcall(c.fn, unpack(c.args))
        assert.is_false(raised, ("args %s must raise"):format(tostring(c.args[1])))
        assert.truthy(tostring(err):find(c.want),
          "message should match " .. c.want .. ", got: " .. tostring(err))
      end
    end)
  end)
end)

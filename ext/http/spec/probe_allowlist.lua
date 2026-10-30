-- By-design outcomes of the committed Http11Probe run, one entry per
-- test id whose verdict in probe-manifest.lua is not Pass.
--
-- verdict and status pin exactly what the manifest records; why names
-- the by-design family. Kept in step with each regenerated manifest,
-- because spec/http_probe_spec.lua requires: every manifest entry that
-- is not Pass appears here, and each entry here matches the manifest's
-- recorded verdict and status. The outcomes are pinned for the ext/http
-- tree the manifest's sha256 block covers; the raw responses of the run
-- stay in the sibling probe-results.json.
--
-- Regenerate the manifest after ext/http changes:
--
--     docker build -f ext/http/Dockerfile.http -t lunet-http-probe .
--     docker run --rm -v "$(pwd)/ext/http:/out" lunet-http-probe

local UNROUTED = 'echo target routes only GET / and POST /echo (405 with Allow)'
local CHUNK_SERVED405 = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)'
local NOTFOUND = 'unknown paths answer 404; nothing further breaks'
local HDR_CAP = 'rejection at the header cap (431 by design)'
local BODY_CAP = 'rejection at the body cap (413 by design)'
local VERSION = 'a version outside HTTP/1.1 is outside the framing subset (400)'
local ORIGIN_FORM = 'origin-form only; absolute-form is rejected (400)'
local OPTIONS_STAR = 'OPTIONS * is outside the framing subset (400)'
local DUP_HEADER = 'duplicate headers are rejected by the single-value rule (400)'
local VALUE_BYTES = 'header value bytes are passed to the router unparsed'
local HOST_COMMA = 'a comma-joined Host is one header value, not a duplicate-host rejection'
local CACHING = 'no caching validators; conditional requests answer 200'
local C_N = 'content negotiation is out of scope (200)'
local EXPECT = 'Expect is not honored (200)'
local GET_CL = 'GET with a Content-Length body is accepted (200)'
local METHOD_CASE = 'methods are case-sensitive; the probe\'s lowercase method routes (200)'
local BARE_LF = 'bare LF in a header line is not rejected (lenient)'
local RANGE = 'Range is out of scope (200)'
local WS = 'no WebSocket support; no 101 by design'
local PIPED = 'bytes left on the wire are served as the next request; the poison lands in its request line, answered 405 by the minimal target'

return {
  ['CAP-ETAG-304'] = { verdict = 'Warn', status = 200, why = 'no caching validators; conditional requests answer 200' },
  ['CAP-ETAG-IN-304'] = { verdict = 'Warn', status = 200, why = 'no caching validators; conditional requests answer 200' },
  ['CAP-ETAG-WEAK'] = { verdict = 'Warn', status = 200, why = 'no caching validators; conditional requests answer 200' },
  ['CAP-INM-PRECEDENCE'] = { verdict = 'Warn', status = 200, why = 'no caching validators; conditional requests answer 200' },
  ['CAP-INM-UNQUOTED'] = { verdict = 'Warn', status = 200, why = 'no caching validators; conditional requests answer 200' },
  ['CAP-INM-WILDCARD'] = { verdict = 'Warn', status = 200, why = 'no caching validators; conditional requests answer 200' },
  ['CAP-LAST-MODIFIED-304'] = { verdict = 'Warn', status = 200, why = 'no caching validators; conditional requests answer 200' },
  ['COMP-ABSOLUTE-FORM'] = { verdict = 'Warn', status = 400, why = 'origin-form only; absolute-form is rejected (400)' },
  ['COMP-ACCEPT-NONSENSE'] = { verdict = 'Warn', status = 200, why = 'content negotiation is out of scope (200)' },
  ['COMP-CHUNKED-BODY'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['COMP-CHUNKED-EMPTY'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['COMP-CHUNKED-EXTENSION'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['COMP-CHUNKED-HEX-UPPERCASE'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['COMP-CHUNKED-MULTI'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['COMP-CHUNKED-TRAILER-VALID'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['COMP-EXPECT-UNKNOWN'] = { verdict = 'Warn', status = 200, why = 'Expect is not honored (200)' },
  ['COMP-GET-WITH-CL-BODY'] = { verdict = 'Warn', status = 200, why = 'GET with a Content-Length body is accepted (200)' },
  ['COMP-HEAD-NO-BODY'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COMP-HTTP12-VERSION'] = { verdict = 'Fail', status = 400, why = 'a version outside HTTP/1.1 is outside the framing subset (400)' },
  ['COMP-METHOD-CASE'] = { verdict = 'Warn', status = 200, why = 'methods are case-sensitive; the probe\'s lowercase method routes (200)' },
  ['COMP-OPTIONS-STAR'] = { verdict = 'Fail', status = 400, why = 'OPTIONS * is outside the framing subset (400)' },
  ['COMP-POST-CL-BODY'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COMP-POST-CL-ZERO'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COMP-POST-NO-CL-NO-TE'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COMP-POST-UNSUPPORTED-CT'] = { verdict = 'Warn', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COMP-RANGE-POST'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COOK-CONTROL-CHARS'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COOK-ECHO'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COOK-EMPTY'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COOK-MALFORMED'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COOK-MANY-PAIRS'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COOK-MULTI-HEADER'] = { verdict = 'Warn', status = 400, why = 'duplicate headers are rejected by the single-value rule (400)' },
  ['COOK-NUL'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['COOK-PARSED-BASIC'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['COOK-PARSED-EMPTY-VAL'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['COOK-PARSED-MULTI'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['COOK-PARSED-SPECIAL'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['MAL-CHUNK-SIZE-OVERFLOW'] = { verdict = 'Fail', status = 413, why = 'rejection at the body cap (413 by design)' },
  ['MAL-CL-OVERFLOW'] = { verdict = 'Fail', status = 413, why = 'rejection at the body cap (413 by design)' },
  ['MAL-CL-TAB-BEFORE-VALUE'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['MAL-CONTROL-CHARS-HEADER'] = { verdict = 'Fail', status = 200, why = 'header value bytes are passed to the router unparsed' },
  ['MAL-LONG-METHOD'] = { verdict = 'Fail', status = 431, why = 'rejection at the header cap (431 by design)' },
  ['MAL-NON-ASCII-URL'] = { verdict = 'Fail', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['MAL-NUL-IN-HEADER-VALUE'] = { verdict = 'Fail', status = 200, why = 'header value bytes are passed to the router unparsed' },
  ['MAL-RANGE-OVERLAPPING'] = { verdict = 'Warn', status = 200, why = 'Range is out of scope (200)' },
  ['MAL-URL-BACKSLASH'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['MAL-URL-OVERLONG-UTF8'] = { verdict = 'Fail', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['MAL-URL-PERCENT-CRLF'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['MAL-URL-PERCENT-NULL'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['RFC9112-2.2-BARE-LF-HEADER'] = { verdict = 'Warn', status = 200, why = 'bare LF in a header line is not rejected (lenient)' },
  ['RFC9112-3.2-FRAGMENT-IN-TARGET'] = { verdict = 'Warn', status = 404, why = 'unknown paths answer 404; nothing further breaks' },
  ['SMUG-BARE-CR-HEADER-VALUE'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-CHUNK-BARE-SEMICOLON'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-CHUNK-EXT-CR'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-CHUNK-EXT-CTRL'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-CHUNK-EXT-INVALID-TOKEN'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-CHUNKED-WITH-PARAMS'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-CL-DOUBLE-ZERO'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-CL-EXTRA-LEADING-SP'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-CL-LEADING-ZEROS'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-CL-LEADING-ZEROS-OCTAL'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-CL-TRAILING-SPACE'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-CL0-BODY-POISON'] = { verdict = 'Fail', status = 405, why = 'bytes left on the wire are served as the next request; the poison lands in its request line, answered 405 by the minimal target' },
  ['SMUG-EXPECT-100-CL'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-EXPECT-100-CL-DESYNC'] = { verdict = 'Warn', status = 200, why = 'Expect is not honored (200)' },
  ['SMUG-HEAD-CL-BODY'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['SMUG-MULTIPLE-HOST-COMMA'] = { verdict = 'Fail', status = 200, why = 'a comma-joined Host is one header value, not a duplicate-host rejection' },
  ['SMUG-TE-DOUBLE-CHUNKED'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TE-EMPTY-VALUE'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TE-FORMFEED'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TE-LEADING-COMMA'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TE-NOT-FINAL-CHUNKED'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TE-NULL'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TE-TRAILING-COMMA'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TE-VTAB'] = { verdict = 'Fail', status = 501, why = 'framing subset rejects every Transfer-Encoding (501)' },
  ['SMUG-TRAILER-AUTH'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-TRAILER-CL'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-TRAILER-CONTENT-TYPE'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-TRAILER-HOST'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-TRAILER-TE'] = { verdict = 'Fail', status = 405, why = 'chunked requests are decoded and served; the minimal echo target answers 405 for POST / (with Allow)' },
  ['SMUG-TRANSFER_ENCODING'] = { verdict = 'Fail', status = 405, why = 'echo target routes only GET / and POST /echo (405 with Allow)' },
  ['WS-UPGRADE-INVALID-VER'] = { verdict = 'Warn', status = 200, why = 'no WebSocket support; no 101 by design' },
}

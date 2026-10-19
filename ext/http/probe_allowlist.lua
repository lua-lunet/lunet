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

local TE = "framing subset rejects every Transfer-Encoding (501)"
local UNROUTED = "echo target routes only GET / and POST /echo (405 with Allow)"
local NOTFOUND = "unknown paths answer 404; nothing further breaks"
local HDR_CAP = "rejection at the header cap (431 by design)"
local BODY_CAP = "rejection at the body cap (413 by design)"
local HTTP10 = "HTTP/1.0 is outside the framing subset (400)"
local VERSION = "a version outside HTTP/1.1 is outside the framing subset (400)"
local ORIGIN_FORM = "origin-form only; absolute-form is rejected (400)"
local OPTIONS_STAR = "OPTIONS * is outside the framing subset (400)"
local DUP_HEADER = "duplicate headers are rejected by the single-value rule (400)"
local VALUE_BYTES = "header value bytes are passed to the router unparsed"
local HOST_COMMA = "a comma-joined Host is one header value, not a duplicate-host rejection"
local CACHING = "no caching validators; conditional requests answer 200"
local C_N = "content negotiation is out of scope (200)"
local EXPECT = "Expect is not honored (200)"
local GET_CL = "GET with a Content-Length body is accepted (200)"
local METHOD_CASE = "methods are case-sensitive; the probe's lowercase method routes (200)"
local BARE_LF = "bare LF in a header line is not rejected (lenient)"
local RANGE = "Range is out of scope (200)"
local WS = "no WebSocket support; no 101 by design"
local COOKIE = "Cookie is passed through unparsed"

return {
  ['CAP-ETAG-304'] = { verdict = 'Warn', status = 200, why = CACHING },
  ['CAP-ETAG-IN-304'] = { verdict = 'Warn', status = 200, why = CACHING },
  ['CAP-ETAG-WEAK'] = { verdict = 'Warn', status = 200, why = CACHING },
  ['CAP-INM-PRECEDENCE'] = { verdict = 'Warn', status = 200, why = CACHING },
  ['CAP-INM-UNQUOTED'] = { verdict = 'Warn', status = 200, why = CACHING },
  ['CAP-INM-WILDCARD'] = { verdict = 'Warn', status = 200, why = CACHING },
  ['CAP-LAST-MODIFIED-304'] = { verdict = 'Warn', status = 200, why = CACHING },
  ['COMP-ABSOLUTE-FORM'] = { verdict = 'Warn', status = 400, why = ORIGIN_FORM },
  ['COMP-ACCEPT-NONSENSE'] = { verdict = 'Warn', status = 200, why = C_N },
  ['COMP-CHUNKED-BODY'] = { verdict = 'Fail', status = 501, why = TE },
  ['COMP-CHUNKED-EMPTY'] = { verdict = 'Fail', status = 501, why = TE },
  ['COMP-CHUNKED-EXTENSION'] = { verdict = 'Fail', status = 501, why = TE },
  ['COMP-CHUNKED-HEX-UPPERCASE'] = { verdict = 'Fail', status = 501, why = TE },
  ['COMP-CHUNKED-MULTI'] = { verdict = 'Fail', status = 501, why = TE },
  ['COMP-CHUNKED-NO-FINAL'] = { verdict = 'Fail', status = 501, why = TE },
  ['COMP-CHUNKED-TRAILER-VALID'] = { verdict = 'Fail', status = 501, why = TE },
  ['COMP-EXPECT-UNKNOWN'] = { verdict = 'Warn', status = 200, why = EXPECT },
  ['COMP-GET-WITH-CL-BODY'] = { verdict = 'Warn', status = 200, why = GET_CL },
  ['COMP-HEAD-NO-BODY'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COMP-HTTP10-DEFAULT-CLOSE'] = { verdict = 'Fail', status = 400, why = HTTP10 },
  ['COMP-HTTP12-VERSION'] = { verdict = 'Fail', status = 400, why = VERSION },
  ['COMP-METHOD-CASE'] = { verdict = 'Warn', status = 200, why = METHOD_CASE },
  ['COMP-OPTIONS-STAR'] = { verdict = 'Fail', status = 400, why = OPTIONS_STAR },
  ['COMP-POST-CL-BODY'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COMP-POST-CL-ZERO'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COMP-POST-NO-CL-NO-TE'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COMP-POST-UNSUPPORTED-CT'] = { verdict = 'Warn', status = 405, why = UNROUTED },
  ['COMP-RANGE-POST'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COOK-CONTROL-CHARS'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COOK-ECHO'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COOK-EMPTY'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COOK-MALFORMED'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COOK-MANY-PAIRS'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COOK-MULTI-HEADER'] = { verdict = 'Warn', status = 400, why = DUP_HEADER },
  ['COOK-NUL'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['COOK-PARSED-BASIC'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['COOK-PARSED-EMPTY-VAL'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['COOK-PARSED-MULTI'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['COOK-PARSED-SPECIAL'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['MAL-CHUNK-EXT-64K'] = { verdict = 'Fail', status = 501, why = TE },
  ['MAL-CHUNK-SIZE-OVERFLOW'] = { verdict = 'Fail', status = 501, why = TE },
  ['MAL-CL-OVERFLOW'] = { verdict = 'Fail', status = 413, why = BODY_CAP },
  ['MAL-CL-TAB-BEFORE-VALUE'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['MAL-CONTROL-CHARS-HEADER'] = { verdict = 'Fail', status = 200, why = VALUE_BYTES },
  ['MAL-LONG-METHOD'] = { verdict = 'Fail', status = 431, why = HDR_CAP },
  ['MAL-NON-ASCII-URL'] = { verdict = 'Fail', status = 404, why = NOTFOUND },
  ['MAL-NUL-IN-HEADER-VALUE'] = { verdict = 'Fail', status = 200, why = VALUE_BYTES },
  ['MAL-RANGE-OVERLAPPING'] = { verdict = 'Warn', status = 200, why = RANGE },
  ['MAL-URL-BACKSLASH'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['MAL-URL-OVERLONG-UTF8'] = { verdict = 'Fail', status = 404, why = NOTFOUND },
  ['MAL-URL-PERCENT-CRLF'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['MAL-URL-PERCENT-NULL'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['RFC9112-2.2-BARE-LF-HEADER'] = { verdict = 'Warn', status = 200, why = BARE_LF },
  ['RFC9112-3.2-FRAGMENT-IN-TARGET'] = { verdict = 'Warn', status = 404, why = NOTFOUND },
  ['SMUG-BARE-CR-HEADER-VALUE'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-CHUNK-BARE-CR-TERM'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-BARE-SEMICOLON'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-EXT-CR'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-EXT-CTRL'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-EXT-INVALID-TOKEN'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-EXT-LF'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-HEX-PREFIX'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-LEADING-SP'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-LF-TERM'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-LF-TRAILER'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-MISSING-TRAILING-CRLF'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-NEGATIVE'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-SIZE-PLUS'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-SIZE-TRAILING-OWS'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-SPILL'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNK-UNDERSCORE'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CHUNKED-WITH-PARAMS'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CL-DOUBLE-ZERO'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-CL-EXTRA-LEADING-SP'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-CL-LEADING-ZEROS'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-CL-LEADING-ZEROS-OCTAL'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-CL-TE-BOTH'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-CL-TRAILING-SPACE'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-EXPECT-100-CL'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-EXPECT-100-CL-DESYNC'] = { verdict = 'Warn', status = 200, why = EXPECT },
  ['SMUG-HEAD-CL-BODY'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['SMUG-MULTIPLE-HOST-COMMA'] = { verdict = 'Fail', status = 200, why = HOST_COMMA },
  ['SMUG-TE-CASE-MISMATCH'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-DOUBLE-CHUNKED'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-EMPTY-VALUE'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-FORMFEED'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-LEADING-COMMA'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-NOT-FINAL-CHUNKED'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-NULL'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-TAB-BEFORE-VALUE'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-TRAILING-COMMA'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TE-VTAB'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TRAILER-AUTH'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TRAILER-CL'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TRAILER-CONTENT-TYPE'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TRAILER-HOST'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TRAILER-TE'] = { verdict = 'Fail', status = 501, why = TE },
  ['SMUG-TRANSFER_ENCODING'] = { verdict = 'Fail', status = 405, why = UNROUTED },
  ['WS-UPGRADE-INVALID-VER'] = { verdict = 'Warn', status = 200, why = WS },
}
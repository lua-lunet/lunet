-- Parser caps for lunet.http, as one editable file.
--
-- Defaults are nginx's defaults: nginx was chosen as the baseline, not as
-- a mandate. If you front lunet with a different edge (Envoy, Traefik,
-- HAProxy, Caddy, a cloud load balancer or WAF), check your chosen edge
-- service's settings and align these caps to them: the edge must always
-- answer first, so lunet is never the strictest link in the chain.
--
-- Operators may need to raise header_max for very large security tokens
-- in headers: a SPNEGO auth header can reach ~12K for a single field,
-- JWTs run 10-20K, and the edge injects its own headers on top of the
-- client's.
--
-- Override paths: edit this file (pure Lua, ships beside http.lua, no
-- rebuild needed) or set the xmake build options
-- (--lunet_http_request_line_max / --lunet_http_header_max /
-- --lunet_http_body_max); unset options keep these defaults.

return {
    request_line_max = 8 * 1024,
    header_max = 32 * 1024,
    body_max = 1024 * 1024,
}

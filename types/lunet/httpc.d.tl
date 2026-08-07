global record httpc
    request: function(opts: {url: string, method: string, body: string, headers: {string: string}, timeout_ms: integer, max_body_bytes: integer}): {status: integer, body: string, headers: {{name: string, value: string}}, effective_url: string}, string
end

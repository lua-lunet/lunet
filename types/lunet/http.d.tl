global record HttpRequest
    method: string
    path: string
    version: string
    headers: {string: string}
    body: string
    raw: string
    chunked: boolean
    persistent_connection: boolean
    query_params: {string: string}
    query_string: string
end

global record HttpConnection
    next_request: function(self: HttpConnection): HttpRequest, string, integer
end

global record CorsConfig
    origin: string
    methods: string | {string}
    headers: string | {string}
    max_age: integer
    credentials: boolean
end

global record http
    MAX_HEADER_BYTES: integer
    MAX_BODY_BYTES: integer
    parse_query_string: function(query: string): {string: string}
    url_decode: function(str: string): string
    parse_request: function(raw: string): HttpRequest, string, integer
    read_request: function(read_chunk: function(): string, string): HttpRequest, string, integer
    new_connection: function(read_chunk: function(): string, string): HttpConnection
    response: function(status: integer, headers: {string: string}, body: string, cors: CorsConfig, persistent: boolean): string
    json_response: function(status: integer, data: any, cors: CorsConfig, persistent: boolean): string
    error_response: function(status: integer, data: any, cors: CorsConfig, persistent: boolean): string
    cors_headers: function(cors: CorsConfig): {string: string}
    is_preflight: function(request: HttpRequest): boolean
    preflight_response: function(cors: CorsConfig, persistent: boolean): string
end

global record HttpContext
    method: string
    path: string
    query: {string: string}
    headers: {string: string}
    body: string
    status: integer
    res_headers: {string: string}
    env_config: any
    write: function(text: string)
    log: function(level: string, ...: any)
    response_body: function(): string
end

global record http_context
    new: function(request: HttpRequest): HttpContext
end

global record http_router
    route: function(method: string, path: string, handler: function(any, HttpContext, {string: string}): any)
    use: function(fn: function(HttpContext): any)
    reset: function()
    match: function(method: string, path: string): any, {string: string}
    handle: function(ctx: HttpContext)
end

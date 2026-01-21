local db_config = require("app.db_config")

return {
    db = db_config,
    server = {
        host = "0.0.0.0",
        port = 8080,
    },
    jwt_secret = "change-me-in-production-use-random-32-bytes",
    jwt_expiry = 86400 * 7,
}

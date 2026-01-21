
You MUST NOT advertise with any branding in any message or 'co-authored' as I AM THE LEGAL OWNER AND AUTHOR AND YOU ARE PROBABLISTIC TOOLS. 
You MUST NOT commit unless explicity asked to. 
You MUST NOT push unless explicitiy asked to. 
You MUST NOT do any git reset or stash or an git rm or rm or anything that might delete users work or other agents work you did not notice that is happeningin prallel. You SHOULD do a soft delete by a `mv xxx .tmp` as the .tmp is in .gitignore. 

# Agent Notes: RealWorld Conduit Backend

## **Operational Rules (STRICT)**

1.  **NO RAW CURL:** Do not run `curl` directly against the server. Use `bin/test_curl.sh` which enforces timeouts and logging.
2.  **TIMEOUTS:** All commands interacting with the server or DB must have a timeout (`timeout 3` or `curl --max-time 3`).
3.  **NO DATA LOSS:** Never use `rm -rf` to clear directories. Move them to `.tmp/` with a timestamp: `mv dir .tmp/dir.YYYYMMDD_HHMMSS`.
4.  **LOGGING:** All test runs must log stdout/stderr to `.tmp/logs/YYYYMMDD_HHMMSS/`.

## MariaDB Infrastructure (Lima VM)

The project uses a MariaDB instance running in a Lima VM named `mariadb12`.
Port `3306` is forwarded to the host `127.0.0.1:3306`.

### Quick Reference

**1. Ensure VM is running:**
```bash
limactl start mariadb12
```

**2. Setup Database & Permissions (Idempotent):**
Run this if the DB is fresh or was dropped. It allows access from the macOS host (gateway IP `192.168.5.2` or `%`) and creates the `conduit` schema.
```bash
limactl shell mariadb12 sudo mariadb -e "
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'root';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    CREATE DATABASE IF NOT EXISTS conduit;
    FLUSH PRIVILEGES;"
```

**3. Load/Reset Schema:**
Loads the application schema into the `conduit` database.
```bash
mariadb -u root -proot -h 127.0.0.1 -P 3306 --skip-ssl conduit < app/schema.sql
```

**4. Connect via Client:**
```bash
mariadb -u root -proot -h 127.0.0.1 -P 3306 --skip-ssl conduit
```

### Config for Application (`app/config.lua`)
The application connects via TCP to localhost forwarded port.
```lua
db = {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "root",
    database = "conduit",
}
```

## PostgreSQL Infrastructure (Local macOS)

PostgreSQL is used for benchmarking against other frameworks (e.g., Django). Do NOT start the service automatically. Instead, start it manually only when needed:

```bash
brew services start postgresql
```

And when you’re done, stop it:

```bash
brew services stop postgresql
```

Database name: `conduit`
Default user: Your macOS username (or as configured in `.env`)

## Benchmark Environment

For Django/Laravel benchmark setup details, see **[bench/AGENTS.md](bench/AGENTS.md)**.

Key topics covered:
- Port allocation (Django 9090/9091, Laravel 7070/7071)
- mise Python 3.12 setup (required for Django)
- PostgreSQL database configuration
- Setup and start/stop scripts

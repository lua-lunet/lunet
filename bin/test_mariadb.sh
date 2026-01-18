#!/bin/sh
# Minimal POSIX script to verify MariaDB connection using config from app/db_config.lua

CONFIG_FILE="app/db_config.lua"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file $CONFIG_FILE not found"
    exit 1
fi

echo "Parsing $CONFIG_FILE..."

# Simple grep/awk extraction - assumes standard formatting
DB_HOST=$(grep 'host' "$CONFIG_FILE" | awk -F'"' '{print $2}')
DB_PORT=$(grep 'port' "$CONFIG_FILE" | grep -o '[0-9]*')
DB_USER=$(grep 'user' "$CONFIG_FILE" | awk -F'"' '{print $2}')
DB_PASS=$(grep 'password' "$CONFIG_FILE" | awk -F'"' '{print $2}')
DB_NAME=$(grep 'database' "$CONFIG_FILE" | awk -F'"' '{print $2}')

if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "ERROR: Failed to parse one or more config values."
    echo "Host: $DB_HOST"
    echo "Port: $DB_PORT"
    echo "User: $DB_USER"
    echo "Pass: [HIDDEN]"
    echo "Name: $DB_NAME"
    exit 1
fi

echo "Configuration:"
echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  User: $DB_USER"
echo "  DB:   $DB_NAME"

echo "---------------------------------------------------"
echo "Checking MariaDB Client..."
if ! command -v mariadb >/dev/null 2>&1; then
    echo "ERROR: 'mariadb' client not found in PATH"
    exit 1
fi

echo "Testing TCP Connection (Timeout 5s)..."
# Use Perl for timeout if available, else attempt connection directly
# Using 'mysqladmin ping' is usually cleaner for liveliness check
if command -v mysqladmin >/dev/null 2>&1; then
    echo "Using mysqladmin ping..."
    if ! mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --protocol=tcp --connect-timeout=5 --skip-ssl >/dev/null 2>&1; then
        echo "ERROR: Connection failed (mysqladmin ping refused)"
        exit 1
    fi
    echo "SUCCESS: Server is alive."
else
    # Fallback to query
    if ! mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --protocol=tcp --skip-ssl -e "SELECT 1" >/dev/null 2>&1; then
        echo "ERROR: Connection failed (SELECT 1 refused)"
        exit 1
    fi
    echo "SUCCESS: Server is alive (SELECT 1)."
fi

echo "Checking Database '$DB_NAME'..."
if ! mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --protocol=tcp --skip-ssl -e "USE $DB_NAME;" >/dev/null 2>&1; then
    echo "ERROR: Database '$DB_NAME' does not exist or access denied."
    exit 1
fi
echo "SUCCESS: Database '$DB_NAME' exists and is accessible."

echo "Checking Tables..."
TABLES=$(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --protocol=tcp --skip-ssl -D "$DB_NAME" -N -e "SHOW TABLES;")
if [ -z "$TABLES" ]; then
    echo "WARNING: Database is empty (no tables found)."
else
    echo "Tables found:"
    echo "$TABLES" | sed 's/^/  - /'
fi

echo "---------------------------------------------------"
echo "DB DIAGNOSTICS PASSED"
exit 0

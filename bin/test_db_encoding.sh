#!/bin/sh
# Verify database encoding by inserting and checking a value

DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER="root"
DB_PASS="root"
DB_NAME="conduit"

echo "Inserting test value 'test_utf8'..."
mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --protocol=tcp --skip-ssl "$DB_NAME" -e "INSERT INTO users (username, email, password_hash) VALUES ('test_utf8', 'test_utf8@example.com', 'pass');"

echo "Checking HEX value of 'test_utf8'..."
HEX_VAL=$(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --protocol=tcp --skip-ssl "$DB_NAME" -N -e "SELECT HEX(username) FROM users WHERE username='test_utf8';")

echo "HEX: $HEX_VAL"

# Expected: 746573745F75746638 (test_utf8)
# If it has 00 padding (e.g. 74006500...), it's wrong.

if echo "$HEX_VAL" | grep -q "00"; then
    echo "FAIL: Found null bytes in HEX output. Encoding is likely UCS-2/UTF-16."
    exit 1
else
    echo "SUCCESS: No null bytes found in ASCII string."
    exit 0
fi

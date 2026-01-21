#!/bin/bash
#
# Integration tests for Lunet Conduit API
# Usage: ./bin/test_api.sh
#
# Prerequisites: Server running on port 8080
#

set -e

API_URL="${API_URL:-http://localhost:8080/api}"
PASS=0
FAIL=0

log() { echo "[TEST] $*"; }
pass() { PASS=$((PASS + 1)); echo "[PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "[FAIL] $1: $2"; }

check_response() {
    local name="$1"
    local expected_status="$2"
    local actual_status="$3"
    local body="$4"
    local expected_content="$5"
    
    if [ "$actual_status" != "$expected_status" ]; then
        fail "$name" "Expected status $expected_status, got $actual_status"
        return 1
    fi
    
    if [ -n "$expected_content" ]; then
        if echo "$body" | grep -q "$expected_content"; then
            pass "$name"
            return 0
        else
            fail "$name" "Response missing '$expected_content'"
            return 1
        fi
    fi
    
    pass "$name"
    return 0
}

log "Testing $API_URL"
log "---"

# Check server is running
if ! curl -s "$API_URL/tags" > /dev/null 2>&1; then
    echo "ERROR: Server not responding at $API_URL"
    echo "Start with: make run"
    exit 1
fi

# --- GET /api/tags ---
log "GET /api/tags"
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/tags")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "GET /api/tags returns 200" "200" "$STATUS" "$BODY" "tags"

# --- GET /api/articles ---
log "GET /api/articles"
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/articles")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "GET /api/articles returns 200" "200" "$STATUS" "$BODY" "articlesCount"

# --- GET /api/articles with limit ---
log "GET /api/articles?limit=5"
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/articles?limit=5")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "GET /api/articles?limit=5 returns 200" "200" "$STATUS" "$BODY" "articles"

# --- POST /api/users (register) ---
log "POST /api/users (register new user)"
TEST_USER="apitest_$(date +%s)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/users" \
    -H "Content-Type: application/json" \
    -d "{\"user\":{\"username\":\"$TEST_USER\",\"email\":\"$TEST_USER@example.com\",\"password\":\"password123\"}}")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "POST /api/users returns 201" "201" "$STATUS" "$BODY" "token"

# Extract token
TOKEN=$(echo "$BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
if [ -z "$TOKEN" ]; then
    fail "Token extraction" "No token in response"
else
    pass "Token extraction"
fi

# --- GET /api/user (current user) ---
log "GET /api/user (with auth)"
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/user" \
    -H "Authorization: Token $TOKEN")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "GET /api/user returns 200" "200" "$STATUS" "$BODY" "$TEST_USER"

# --- POST /api/articles (create article) ---
log "POST /api/articles (create article)"
ARTICLE_TITLE="Test Article $(date +%s)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/articles" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token $TOKEN" \
    -d "{\"article\":{\"title\":\"$ARTICLE_TITLE\",\"description\":\"Test description\",\"body\":\"Test body content\",\"tagList\":[\"test\",\"api\"]}}")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "POST /api/articles returns 201" "201" "$STATUS" "$BODY" "slug"

# Extract slug
SLUG=$(echo "$BODY" | grep -o '"slug":"[^"]*"' | cut -d'"' -f4)
if [ -z "$SLUG" ]; then
    fail "Slug extraction" "No slug in response"
else
    pass "Slug extraction"
fi

# --- GET /api/articles/:slug ---
log "GET /api/articles/:slug"
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/articles/$SLUG")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "GET /api/articles/:slug returns 200" "200" "$STATUS" "$BODY" "$ARTICLE_TITLE"

# --- GET /api/articles/:slug/comments ---
log "GET /api/articles/:slug/comments"
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/articles/$SLUG/comments")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "GET /api/articles/:slug/comments returns 200" "200" "$STATUS" "$BODY" "comments"

# --- POST /api/articles/:slug/comments ---
log "POST /api/articles/:slug/comments"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/articles/$SLUG/comments" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token $TOKEN" \
    -d '{"comment":{"body":"Test comment from API test"}}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "POST /api/articles/:slug/comments returns 200" "200" "$STATUS" "$BODY" "comment"

# --- GET /api/profiles/:username ---
log "GET /api/profiles/:username"
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/profiles/$TEST_USER")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
check_response "GET /api/profiles/:username returns 200" "200" "$STATUS" "$BODY" "profile"

# --- Error cases ---
log "Testing error cases..."

# Unauthenticated article create
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/articles" \
    -H "Content-Type: application/json" \
    -d '{"article":{"title":"Should Fail","description":"No auth","body":"test"}}')
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "401" ]; then
    pass "POST /api/articles without auth returns 401"
else
    fail "POST /api/articles without auth" "Expected 401, got $STATUS"
fi

# Invalid article slug
RESP=$(curl -s -w "\n%{http_code}" "$API_URL/articles/nonexistent-slug-12345")
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "404" ]; then
    pass "GET /api/articles/nonexistent returns 404"
else
    fail "GET /api/articles/nonexistent" "Expected 404, got $STATUS"
fi

# Summary
echo ""
echo "==================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "==================================="

if [ $FAIL -gt 0 ]; then
    exit 1
fi

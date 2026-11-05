#!/usr/bin/env bash
# End-to-end smoke test against a running product-service.
# Uses a unique SKU per run and deletes it at the end, so it is safe to re-run.
#
#   Usage:  bash scripts/smoke.sh http://localhost:8080
set -u

URL="${1:-http://localhost:8080}"
URL="${URL%/}"
API="$URL/api/v1/products"
SKU="SMOKE-$(date +%s)-$$"
PASS=0; FAIL=0

check() {  # check "name" expected actual
  if [ "$2" = "$3" ]; then
    echo "  [PASS] $1"; PASS=$((PASS + 1))
  else
    echo "  [FAIL] $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1))
  fi
}

# req METHOD PATH [JSON]  -> sets $STATUS and $BODY
req() {
  local out
  if [ $# -ge 3 ]; then
    out="$(curl -s -m 10 -w '\n%{http_code}' -X "$1" "$2" -H 'Content-Type: application/json' -d "$3")"
  else
    out="$(curl -s -m 10 -w '\n%{http_code}' -X "$1" "$2")"
  fi
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

field() {  # field NAME -> value of a simple JSON field in $BODY
  printf '%s' "$BODY" | sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p"
}

echo "Smoke test against $URL (sku $SKU)"

if ! curl -s -m 5 -o /dev/null "$URL/health/live"; then
  echo "  cannot connect to $URL -- is port-forward running?"; exit 1
fi

req GET "$URL/health/live";  check "liveness probe returns 200" 200 "$STATUS"
req GET "$URL/health/ready"; check "readiness probe returns 200 (database reachable)" 200 "$STATUS"

rid="$(curl -s -m 10 -o /dev/null -D - -H 'X-Request-ID: smoke-123' "$URL/health/live" \
  | tr -d '\r' | awk -F': ' 'tolower($1) == "x-request-id" {print $2}')"
check "X-Request-ID is echoed back" smoke-123 "$rid"

req POST "$API" "{\"sku\":\"$SKU\",\"name\":\"Smoke Widget\",\"price\":\"5.00\",\"stock\":5}"
check "create product returns 201" 201 "$STATUS"
ID="$(field id)"

req POST "$API" "{\"sku\":\"$SKU\",\"name\":\"Duplicate\",\"price\":\"1.00\"}"
check "duplicate SKU returns 409" 409 "$STATUS"

req POST "$API" '{"sku":"bad sku!","name":"X","price":"-1"}'
check "invalid input returns 422" 422 "$STATUS"

req GET "$API/$ID"
check "get product by id returns 200" 200 "$STATUS"

req GET "$API/999999999"
check "missing product returns 404" 404 "$STATUS"

req GET "$API?q=$SKU"
check "search finds the product" 1 "$(field total)"

req PATCH "$API/$ID" '{"price":"7.50"}'
check "partial update changes the price" 7.50 "$(field price)"

req POST "$API/$ID/stock" '{"delta":-2}'
check "stock adjustment 5 - 2 = 3" 3 "$(field stock)"

req POST "$API/$ID/stock" '{"delta":-100}'
check "overselling is rejected with 409" 409 "$STATUS"

req DELETE "$API/$ID"
check "delete returns 204" 204 "$STATUS"

req GET "$API/$ID"
check "deleted product is gone (404)" 404 "$STATUS"

echo
echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]

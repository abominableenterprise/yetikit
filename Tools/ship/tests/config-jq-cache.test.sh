#!/usr/bin/env bash
# Pure-filter cache equivalence and invalidation; synthetic files only.
set -euo pipefail
tests="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/cache"
export SHIP_TEST_REAL_JQ="$(command -v jq)" SHIP_TEST_JQ_CACHE="$tmp/cache"
cp "$tests/lib/config-jq-cache.py" "$tmp/jq"; chmod +x "$tmp/jq"
# Avoid nesting an outer runner's cache wrapper in this direct equivalence test.
if [ -n "${SHIP_TEST_ORIGINAL_JQ:-}" ]; then SHIP_TEST_REAL_JQ="$SHIP_TEST_ORIGINAL_JQ"; fi
printf '.value\n' > "$tmp/lib/config-paths.jq"
printf '{"value":1}\n' > "$tmp/input.json"
query() { "$tmp/jq" -f "$tmp/lib/config-paths.jq" "$tmp/input.json"; }
[ "$(query)" = 1 ]; [ "$(query)" = 1 ]
echo 'ok   repeated pure config reads keep the result'
printf '{"value":2}\n' > "$tmp/input.json"
[ "$(query)" = 2 ]
echo 'ok   changed config bytes invalidate the cache'
printf '.value + 3\n' > "$tmp/lib/config-paths.jq"
[ "$(query)" = 5 ]
echo 'ok   changed filter bytes invalidate the cache'
printf '.value\n' > "$tmp/lib/config-values.jq"
[ "$(printf '{"value":4}\n' | "$tmp/jq" -j -f "$tmp/lib/config-values.jq")" = 4 ]
[ "$(printf '{"value":6}\n' | "$tmp/jq" -j -f "$tmp/lib/config-values.jq")" = 6 ]
echo 'ok   stdin config values participate in the cache key'
[ "$("$tmp/jq" -n --arg value uncached '$value')" = '"uncached"' ]
echo 'ok   arbitrary queries bypass the cache'
printf '{broken\n' > "$tmp/input.json"
if query > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
grep -q 'parse error' "$tmp/err"
echo 'ok   malformed JSON keeps the real diagnostic and exit code'
echo 'all passed'

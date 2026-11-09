#!/usr/bin/env bash
# Test collection shapes and malformed, streamed, empty or missing configuration.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

while IFS='|' read -r expression key; do
  invalid "$expression" "$key"
done <<'EOF'
.tests = []|tests
.tests.builderFixtures = []|tests.builderFixtures
.tests.builderFixtures = {"Assets/Editor/Builder.cs": [42]}|tests.builderFixtures
EOF
printf '{broken\n' > "$proj/yetikit.json"
run cache-key
check 'malformed JSON has a clear diagnostic' '[ "$rc" != 0 ] && grep -q "invalid JSON" "$tmp/err"'
printf '{}\n{}\n' > "$proj/yetikit.json"
run cache-key
check 'streamed JSON objects are rejected' '[ "$rc" != 0 ] && grep -q "one JSON object" "$tmp/err"'
: > "$proj/yetikit.json"
run cache-key
check 'empty config is rejected' '[ "$rc" != 0 ] && grep -q "one JSON object" "$tmp/err"'
rm "$proj/yetikit.json"
run cache-key
check 'missing root config names yetikit.json' '[ "$rc" != 0 ] && grep -q "missing config.*yetikit.json" "$tmp/err"'
config_finish

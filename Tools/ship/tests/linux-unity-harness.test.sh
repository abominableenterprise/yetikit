#!/usr/bin/env bash
# Focused harness prerequisites: standalone fixtures never escalate; CI uses GNU timeout.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$ship/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
. "$ship/tests/lib/fixture.sh"
mkdir -p "$tmp/host-bin"
# A sentinel stands in for real sudo: reaching it must fail without touching the host.
printf '#!/bin/sh\necho escaped > "%s/escaped"\nexit 99\n' "$tmp" > "$tmp/host-bin/sudo"
printf '#!/bin/sh\n[ "$FIXTURE_TOKEN" = synthetic ]\n' > "$tmp/host-bin/fixture-command"
chmod +x "$tmp/host-bin/"*
export PATH="$tmp/host-bin:$PATH" FIXTURE_TOKEN=synthetic
ship_fixture "$tmp/project"
check 'standalone fixture shadows host sudo and preserves command environment' \
  'sudo fixture-command && [ ! -e "$tmp/escaped" ] && [ "$(command -v sudo)" = "$tmp/project/.ship-test-bin/sudo" ]'
# Exercise the production non-root branch even when this regression runs as root.
eval "$(awk '/^as_root\(\)/ { print; exit }' "$ship/linux-unity.sh")"
id() { if [ "$1" = -u ]; then echo 1000; else command id "$@"; fi; }
check 'production non-root as_root stays inside standalone fixture wrappers' \
  'as_root fixture-command && [ ! -e "$tmp/escaped" ]'
unset -f id

fixture_clears_swap_state() (
  export APK_SWAPFILE="$tmp/inherited-swap"
  printf 'keep\n' > "$APK_SWAPFILE"
  tmp="$tmp/standalone"; proj="$tmp/project"; mkdir -p "$tmp"
  . "$ship/tests/lib/fake-unity.sh"
  [ "${APK_SWAPFILE-unset}" = unset ] && [ "$(<"$tmp/../inherited-swap")" = keep ]
)
check 'standalone fake fixture clears inherited swap cleanup ownership' 'fixture_clears_swap_state'

mkdir -p "$tmp/non-gnu"
cat > "$tmp/non-gnu/timeout" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then echo 'timeout (replacement implementation)'; exit 0; fi
echo 'unexpected fixture execution' >&2
exit 99
EOF
chmod +x "$tmp/non-gnu/timeout"
rc=0
PATH="$tmp/non-gnu:$PATH" bash "$ship/tests/run.sh" > "$tmp/output" 2>&1 || rc=$?
check 'suite rejects non-GNU timeout before launching any fixture' \
  '[ "$rc" = 1 ] && grep -qF "missing test dependency: GNU coreutils timeout" "$tmp/output" && ! grep -qF "=== " "$tmp/output"'
check 'CI pins the GNU-coreutils Ubuntu baseline and checks timeout identity' \
  'grep -qF "runs-on: ubuntu-24.04" "$repo/.github/workflows/ship.yml" && grep -qF "timeout --version | grep -F" "$repo/.github/workflows/ship.yml"'
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }

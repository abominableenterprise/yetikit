#!/usr/bin/env bash
# Focused harness prerequisites: standalone fixtures never escalate; CI uses GNU timeout.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
caller_path="$PATH"
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

fixture_isolates_setup() (
  caller="$tmp/setup-caller"
  mkdir -p "$caller"
  export HOME="$caller/home" ULF="$caller/licence" OUT_DIR="$tmp/setup-out"
  printf 'synthetic licence\n' > "$ULF"
  # Exercise the same standalone entry point as a developer. Its editor and
  # installer commands are already stubbed; the alleged caller licence is ours.
  bash "$ship/tests/linux-unity-setup.test.sh" > "$tmp/setup.log" 2>&1 &&
    [ ! -e "$caller/licence.idle" ] && [ ! -e "$caller/home" ]
)
check 'setup fixture overrides caller HOME and ULF before the idle lifecycle' 'fixture_isolates_setup'

fixture_protects_caller_state() (
  caller="$tmp/caller"
  mkdir -p "$caller/swap" "$caller/bin"
  export SEAT_STATE="$caller/seat" APK_SWAP_DIR="$caller/swap"
  printf 'keep seat\n' > "$SEAT_STATE"
  # A non-PID suffix is guaranteed stale. Guard real swap operations even on the unfixed fixture.
  printf 'keep swap\n' > "$APK_SWAP_DIR/linux-unity-apk.swap.stale"
  for tool in fallocate mkswap swapon swapoff; do
    printf '#!/bin/sh\ntouch "%s/swap-escaped"\nexit 99\n' "$caller" > "$caller/bin/$tool"
  done
  chmod +x "$caller/bin/"*
  export PATH="$caller/bin:$PATH"
  tmp="$tmp/standalone-state"; proj="$tmp/project"
  . "$ship/tests/lib/fake-unity.sh"
  bash -c '
    . "$1"
    printf "fixture seat\n" > "$SEAT_STATE"
    apk_swap_reclaim
  ' _ "$script" &&
    [ "$(< "$caller/seat")" = 'keep seat' ] &&
    [ "$(< "$caller/swap/linux-unity-apk.swap.stale")" = 'keep swap' ] &&
    [ ! -e "$caller/swap-escaped" ] &&
    [ "$(< "$OUT_DIR/unity-seat.held")" = 'fixture seat' ]
)
check 'standalone fake fixture writes its own seat marker and never reclaims caller swap' 'fixture_protects_caller_state'

# A controlled process view must exclude the host without hiding tracked failures.
cat > "$tmp/host-bin/readlink" <<'EOF'
#!/bin/sh
case "$1" in
  /proc/12345/exe) printf '/fixture/editor\n' ;;
  /proc/12346/exe) exit 1 ;;
  *) printf 'delegated:%s\n' "$1" ;;
esac
EOF
chmod +x "$tmp/host-bin/readlink"
export SHIP_FIXTURE_PIDS='12345 12346'
check 'opt-in process view excludes host processes but retains tracked inspection failures' '
  ship_fixture_process_view "$tmp/view-bin" &&
  [ "$(PATH="$tmp/view-bin:$PATH" readlink /proc/12345/exe)" = /fixture/editor ] &&
  ! PATH="$tmp/view-bin:$PATH" readlink /proc/12346/exe &&
  [ "$(PATH="$tmp/view-bin:$PATH" readlink /proc/1/exe)" = /fixture/host-process ] &&
  [ "$(PATH="$tmp/view-bin:$PATH" readlink ordinary-link)" = delegated:ordinary-link ]'
unset SHIP_FIXTURE_PIDS

apk_timeout_assertion_rejects_wrong_default() (
  # Break only the timeout contract in a disposable Ship copy. The APK test
  # still runs the synthetic editor and must report its failed assertion.
  cp -R "$ship" "$tmp/timeout-mutation"
  python3 - "$tmp/timeout-mutation/linux-unity.sh" <<'PY'
from pathlib import Path
import sys

runner = Path(sys.argv[1])
source = runner.read_text()
original = 'APK_TIMEOUT="${APK_TIMEOUT:-5400}"'
assert source.count(original) == 1
runner.write_text(source.replace(original, 'APK_TIMEOUT="${APK_TIMEOUT:-1800}"'))
PY
  unset APK_TIMEOUT
  rc=0
  PATH="$caller_path" bash "$tmp/timeout-mutation/tests/linux-unity-apk-swap-recovery.test.sh" > "$tmp/timeout.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -qF 'FAIL apk: the editor runs under APK_TIMEOUT' "$tmp/timeout.log" &&
    grep -qx '1 failed' "$tmp/timeout.log" || {
    cat "$tmp/timeout.log" >&2
    return 1
  }
)
check 'APK timeout assertion fails on the wrong default even after stub cleanup' 'apk_timeout_assertion_rejects_wrong_default'

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

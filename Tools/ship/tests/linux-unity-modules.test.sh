#!/usr/bin/env bash
# Guard the hub source-size ceiling and the sourced setup/licensing module boundary. Never runs Unity.
set -euo pipefail
ci="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

for file in linux-unity.sh linux-unity-setup.sh linux-unity-license.sh lib/android.sh lib/config.sh lib/linux-unity-idle.sh; do
  check "$file fits the hub source-size ceiling" \
    '[ -f "$ci/$file" ] && [ "$(wc -l < "$ci/$file")" -le 800 ] && [ "$(wc -c < "$ci/$file")" -le 51200 ]'
done

# Source from outside the checkout with nounset: relative module paths must use BASH_SOURCE, not pwd/$0.
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$tmp/project"
ci="$PROJECT/Tools/ship"
export OUT_DIR="$tmp/out" UNITY_ROOT="$tmp/unity" ULF="$tmp/licence"
export UNITY_USERNAME=module-user UNITY_PASSWORD=module-password
cd "$tmp"
shopt -s extdebug
. "$ci/linux-unity.sh"
check 'sourcing defines functions without creating command state' '[ ! -e "$OUT_DIR" ] && [ ! -e "$ULF" ]'
check 'sourcing does not change credentials' '[ "$UNITY_USERNAME" = module-user ] && [ "$UNITY_PASSWORD" = module-password ]'
for func in install_crane editor_version_ok install_editor install_libs setup_git pick_image has_android replace_base_editor cmd_setup; do
  check "$func is loaded from the setup module" \
    'definition="$(declare -F "$func")" && [ "${definition##* }" = "$ci/linux-unity-setup.sh" ]'
done
for func in mask creds_fallback need_creds ulf_problem set_aside_ulf cmd_activate cmd_return ensure_licence chain_exit_trap return_on_exit arm_return_on_exit; do
  check "$func is loaded from the licence module" \
    'definition="$(declare -F "$func")" && [ "${definition##* }" = "$ci/linux-unity-license.sh" ]'
done

for func in cmd_apk apk_swap_off apk_disk_check; do
  check "$func is loaded from the Android module" \
    'definition="$(declare -F "$func")" && [ "${definition##* }" = "$ci/lib/android.sh" ]'
done

echo "$fails failure(s)"
[ "$fails" = 0 ]

#!/usr/bin/env bash
# Shared real-timeout checks, invoked independently for each command's limit.
. "$(dirname "${BASH_SOURCE[0]}")/linux-unity-timeout-fixture.sh"
# Minimal APK prerequisites; never allocate swap, require host free space, or build anything real.
mkdir -p "$tmp/unity/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" \
  "$tmp/unity/Editor/Data/PlaybackEngines/AndroidPlayer/NDK" "$proj/Library" "$tmp/swap"
export APK_SWAP_GB=0 APK_SWAP_DIR="$tmp/swap" APK_MIN_FREE_GB=0 APK_MIN_FREE_GB_WARM=0
real_limits() {
for var in "$@"; do
  case "$var" in
    UNITY_TIMEOUT) args=(open); duration=1s; doubled=2 ;;
    UNITY_GFX_TIMEOUT) args=(test editmode -testCategory Gfx); duration=1.5s; doubled=3 ;;
    APK_TIMEOUT) args=(apk); duration=1s; doubled=2 ;;
  esac
  seconds="${duration%s}"
  run FAKE_EDITOR_GATE="$tmp/timeout-editor" "$var=$duration" bash "$script" "${args[@]}"
  check "$var=$duration: fake editor times out with a numeric rerun, no arithmetic error" \
    '[ "$rc" != 0 ] && grep -qF "killed at the $seconds s timeout; no results. Re-run with $var=$doubled" "$tmp/err" && ! grep -qE "integer expression|syntax error|invalid arithmetic" "$tmp/err"'
  run FAKE_UNITY_RC=137 "$var=0" bash "$script" "${args[@]}"
  check "$var=0: fake editor SIGKILL is external, not a disabled timeout firing" \
    '[ "$rc" != 0 ] && grep -qF "timeout disabled (out of memory? stop?); no results" "$tmp/err" && ! grep -qE "killed at the|Re-run with" "$tmp/err"'
done
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
}

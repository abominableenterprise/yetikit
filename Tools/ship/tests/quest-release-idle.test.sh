#!/usr/bin/env bash
# shellcheck disable=SC2016 # check takes single-quoted conditions, expanded by eval
# shellcheck disable=SC2034 # rc and out are read inside those conditions
# qr_idle_parse on fully synthetic AOSP-shaped dumpsys fixtures. No device or Unity.
# Run: bash Tools/ship/tests/quest-release-idle.test.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Tools/ship/quest-release/idle.sh
. "$here/../quest-release/idle.sh"
fx="$here/fixtures/quest-idle"
fails=0
check() { if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fails=$((fails+1)); fi; }
parse() { rc=0; out="$(qr_idle_parse "$@")" || rc=$?; }

parse < "$fx/home-multi-top-resumed.txt"
check 'several topResumedActivity lines with Home focused: idle' \
  '[ "$rc" = 0 ] && [ "$out" = "Home focused" ] && [ "$(grep -c topResumedActivity "$fx/home-multi-top-resumed.txt")" = 3 ]'
parse < "$fx/game-unmounted.txt"
check 'our game focused, headset unmounted (display still on): idle' '[ "$rc" = 0 ] && [[ "$out" == "not worn (HEADSET_UNMOUNTED)"* ]]'
parse < "$fx/game-mounted.txt"
check 'our game focused, headset mounted: busy' \
  '[ "$rc" = 1 ] && [ "$out" = "worn (HEADSET_MOUNTED), focused: com.example.consumer" ]'
parse < "$fx/other-app-mounted.txt"
check 'another app focused, headset mounted: busy' '[ "$rc" = 1 ] && [[ "$out" == *"focused: com.oculus.browser" ]]'

# CRLF from adb shell, and a resumed panel or topResumedActivity alone never decides the focus.
parse < <(sed 's/$/\r/' "$fx/game-mounted.txt")
check 'CRLF line ends parse the same' '[ "$rc" = 1 ] && [[ "$out" == *"focused: com.example.consumer" ]]'
parse < <(grep -E 'topResumedActivity|mResumedActivity|HEADSET' "$fx/game-mounted.txt")
check 'only topResumedActivity / mResumedActivity lines: unknown, never idle' '[ "$rc" = 2 ]'
parse < <(sed '/HEADSET_/d; s/state=ON/state=OFF/' "$fx/game-mounted.txt")
check 'no headset state: the display off counts as not worn' '[ "$rc" = 0 ] && [[ "$out" == "not worn (display off)"* ]]'
parse < <(sed '/HEADSET_/d; /Display Power/d' "$fx/game-mounted.txt")
check 'no headset state or display line: mWakefulness=Awake counts as worn' '[ "$rc" = 1 ] && [[ "$out" == "worn (awake)"* ]]'
parse < <(sed '/HEADSET_/d; /Display Power/d; /mWakefulness=/d' "$fx/game-mounted.txt")
check 'nothing says whether it is worn: unknown' '[ "$rc" = 2 ]'
parse < <(cat "$fx/game-mounted.txt"; sed -n '/mCurrentFocus/p' "$fx/home-multi-top-resumed.txt")
check 'Home in one focus source but the game in another: still busy when worn' '[ "$rc" = 1 ]'

# Only vrpowermanager's current State: line decides; its transition history never does.
parse < "$fx/game-standby-history.txt"
check 'game focused, State: STANDBY with a MOUNTED transition line and Asleep: idle' \
  '[ "$rc" = 0 ] && [ "$out" = "not worn (STANDBY), focused: com.example.consumer" ]'
parse < "$fx/game-unmounted-history.txt"
check 'game focused, State: HEADSET_UNMOUNTED with a MOUNTED transition line (display on): idle' \
  '[ "$rc" = 0 ] && [[ "$out" == "not worn (HEADSET_UNMOUNTED)"* ]]'
parse < "$fx/game-mounted-history.txt"
check 'game focused, State: HEADSET_MOUNTED with an UNMOUNTED transition line: busy' \
  '[ "$rc" = 1 ] && [ "$out" = "worn (HEADSET_MOUNTED), focused: com.example.consumer" ]'
parse < <(sed 's/^  State: .*/  State: BOOTING/' "$fx/game-mounted-history.txt")
check 'an unknown current state falls back to the display (on): busy, the history ignored' \
  '[ "$rc" = 1 ] && [[ "$out" == "worn (display on)"* ]]'
parse < <(sed '/^  State: /d' "$fx/game-standby-history.txt")
check 'history lines alone, display off: not worn (display off)' '[ "$rc" = 0 ] && [[ "$out" == "not worn (display off)"* ]]'
parse < <(sed '/^  State: /d; /Display Power/d; /mWakefulness=/d' "$fx/game-standby-history.txt")
check 'history lines alone and nothing else: unknown, never worn or idle' '[ "$rc" = 2 ]'

# getprop sys.hmt.mounted ($1) decides first when it is a clean 0 or 1; anything else falls back to the order above.
parse 0 < <(sed '/^  State: /d' "$fx/game-mounted-history.txt")
check 'no current state, display on, sys.hmt.mounted=0: idle' '[ "$rc" = 0 ] && [[ "$out" == "not worn (sys.hmt.mounted=0)"* ]]'
parse 1 < "$fx/game-standby-history.txt"
check 'sys.hmt.mounted=1 beats State: STANDBY (and Asleep): busy' \
  '[ "$rc" = 1 ] && [ "$out" = "worn (sys.hmt.mounted=1), focused: com.example.consumer" ]'
parse 0 < "$fx/game-mounted-history.txt"
check 'sys.hmt.mounted=0 beats State: HEADSET_MOUNTED: idle' \
  '[ "$rc" = 0 ] && [ "$out" = "not worn (sys.hmt.mounted=0), focused: com.example.consumer" ]'
parse 0 < "$fx/game-mounted.txt"
check 'sys.hmt.mounted=0 beats Headset state: HEADSET_MOUNTED: idle' '[ "$rc" = 0 ] && [[ "$out" == "not worn (sys.hmt.mounted=0)"* ]]'
parse 1 < "$fx/home-multi-top-resumed.txt"
check 'sys.hmt.mounted=1 with Home focused: still idle' '[ "$rc" = 0 ] && [ "$out" = "Home focused" ]'
parse 0 < <(sed '/^  State: /d; /Display Power/d; /mWakefulness=/d' "$fx/game-standby-history.txt")
check 'sys.hmt.mounted=0 alone is enough to say not worn' '[ "$rc" = 0 ]'
parse 1 < <(sed '/^  State: /d; /Display Power/d; /mWakefulness=/d' "$fx/game-standby-history.txt")
check 'sys.hmt.mounted=1 alone is enough to say worn' '[ "$rc" = 1 ] && [[ "$out" == "worn (sys.hmt.mounted=1)"* ]]'
for hmt in "" " " 2 01 "1 0" unknown; do
  parse "$hmt" < "$fx/game-standby-history.txt"
  check "sys.hmt.mounted '$hmt' (not a clean 0/1): the current State: STANDBY decides (idle)" \
    '[ "$rc" = 0 ] && [[ "$out" == "not worn (STANDBY)"* ]]'
  parse "$hmt" < "$fx/game-mounted-history.txt"
  check "sys.hmt.mounted '$hmt': the current State: HEADSET_MOUNTED decides (busy)" \
    '[ "$rc" = 1 ] && [[ "$out" == "worn (HEADSET_MOUNTED)"* ]]'
done
parse 2 < <(sed '/^  State: /d; /Display Power/d; /mWakefulness=/d' "$fx/game-standby-history.txt")
check 'an unclean sys.hmt.mounted and nothing else: unknown' '[ "$rc" = 2 ]'

if [ "$fails" != 0 ]; then printf '%s failed\n' "$fails"; exit 1; fi
printf 'all passed\n'

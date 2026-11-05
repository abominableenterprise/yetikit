#!/usr/bin/env bash
# test-all: serial
# The watchdog cleanup assertion scans the global process table for sleep 60/4321.
# shellcheck disable=SC2016 # check takes single-quoted conditions, expanded by eval
# shellcheck disable=SC2034 # rc, backup, serial and QR_SHORT are read inside those conditions
# Tests Tools/ship/quest-release.sh (Tools/ship/README.md) with stubbed unity/adb/df/python3/apksigner functions, a temp
# git repo and a fake headset: disk refusal, gate category filter and NUnit parsing, the device checks, the verified
# backup that never prints playtest.json, `all` skipping the install on a failed gate, rollback on a crash, cleanup,
# the read-only `doctor` and the single-run lock.
# Never runs Unity or adb. bash 3.2 compatible (stock macOS); like the real script it runs without set -e.
# Run: bash Tools/ship/tests/quest-release.test.sh
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/quest-release.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; [ -z "${QR_TEST_DEBUG:-}" ] || cat "$tmp/out"; fails=$((fails + 1)); fi; }

git() { # fetch is a no-op; everything else is real git on the temp repo
  if [ "$1" = -C ] && [ "$3" = fetch ]; then
    echo fetch >> "$tmp/git.log"
    printf 'prompt=%s ssh=%s\n' "${GIT_TERMINAL_PROMPT:-unset}" "${GIT_SSH_COMMAND:-unset}" >> "$tmp/fetch-env"
    return "${FAKE_FETCH_RC:-0}"
  fi
  if [ "${FAKE_STATUS_FAIL:-0}" = 1 ] && [ "$1" = -C ] && [ "$3" = status ]; then return 128; fi
  command git "$@"
}

# --- a temp repo with origin/main, a warm worktree with a Library ----------------------------------------------------------
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
repo="$tmp/repo"; mkdir -p "$repo/Tools/ship" "$repo/ProjectSettings" "$repo/Assets/Mats" "$repo/Assets/Scripts"
printf 'm_EditorVersion: 6000.6.6f1\n' > "$repo/ProjectSettings/ProjectVersion.txt"
printf "PURE_CATEGORIES='!Gfx;!MacOnly'\nGFX_CATEGORIES='Gfx'\n" > "$repo/Tools/ship/linux-unity.sh"
printf "/[Ll]ibrary/\n/[Bb]uilds/\n" > "$repo/.gitignore"
echo a > "$repo/Assets/Mats/A.mat"; echo b > "$repo/Assets/Mats/B.asset"; echo c > "$repo/Assets/Scripts/C.cs"
cp "$YETIKIT_CONFIG" "$repo/yetikit.json"
git -C "$repo" init -q -b main && git -C "$repo" add -A && git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
sha="$(git -C "$repo" rev-parse HEAD)"; short="${sha:0:9}"
root="$tmp/wt"; mkdir -p "$root/mac-pass/Library/Bee"; echo warm > "$root/mac-pass/Library/Bee/cache"
export QUEST_REPO="$repo" QUEST_WT_ROOT="$root" QUEST_BACKUP_ROOT="$tmp/home" QR_LAUNCH_WAIT=1 \
  ANDROID_SDK_ROOT="$tmp/sdk" HOME="$tmp/home"
mkdir -p "$HOME"
fake_jdk() { mkdir -p "$1/bin" && printf '#!/bin/sh\n' > "$1/bin/java" && chmod +x "$1/bin/java"; }
fake_jdk "$tmp/jdk"; export JAVA_HOME="$tmp/jdk"
serial=synthetic-device
cert="00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"

# shellcheck source=Tools/ship/quest-release.sh
. "$script"

# --- stubs (defined after sourcing, so they replace the script's unity/apksigner) -------------------------------------------
FAKE_FREE_GB=100
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3 999 0 %s 1%% /\n' "$((FAKE_FREE_GB * 1048576))"; }
qr_clone_dir() { echo "$1 -> $2" >> "$tmp/clone.log"; cp -R "$1" "$2"; } # /bin/cp -c is macOS-only

xml_pass='<?xml version="1.0"?><test-run id="2" total="3" passed="3" failed="0" skipped="0"><test-suite type="TestFixture" fullname="Ns.A" result="Passed"><test-case fullname="Ns.A.One" result="Passed"/></test-suite></test-run>'
xml_fail='<?xml version="1.0"?><test-run id="2" total="3" passed="1" failed="2" skipped="0">
<test-suite type="TestFixture" fullname="Synthetic.Props.Tests.PunchPlayModeTests" result="Failed" site="Child">
<test-case fullname="Synthetic.Props.Tests.PunchPlayModeTests.Haymaker" result="Failed"><failure><message><![CDATA[Expected knockdown
  but was <none>]]></message></failure></test-case>
<test-case fullname="Synthetic.Props.Tests.PunchPlayModeTests.Jab" result="Passed"/>
</test-suite>
<test-suite type="TestFixture" fullname="Synthetic.Park.Tests.CourtPlayModeTests" result="Failed" site="SetUp"><failure><message>scene did not load</message></failure>
<test-case fullname="Synthetic.Park.Tests.CourtPlayModeTests.Swish" result="Failed"><failure><message>OneTimeSetUp: scene did not load</message></failure></test-case>
</test-suite></test-run>'
FAKE_XML="$xml_pass"
unity() {
  local a prev="" proj="" res="" tests=0
  echo "$*" >> "$tmp/unity.log"
  echo "notes=${YETIKIT_WHATS_NEW:-} prev=${YETIKIT_PREV_SHA:-}" >> "$tmp/notes-env.log"
  echo "lock pid=$(cat "$root/release-logs/run.lock/pid" 2>/dev/null) run=$(cat "$root/release-logs/run.lock/run_dir" 2>/dev/null)" >> "$tmp/unity-lock.log"
  [ -z "${FAKE_UNITY_CRASH:-}" ] || return 139
  for a in "$@"; do
    case "$prev" in -projectPath) proj="$a" ;; -testResults) res="$a" ;; esac
    [ "$a" = -runTests ] && tests=1
    prev="$a"
  done
  if [ "$tests" = 1 ]; then
    case " $* " in *" -testFilter "*) [ -z "${FAKE_RETRY_XML:-}" ] || FAKE_XML="$FAKE_RETRY_XML" ;; esac
    printf '%s\n' "$FAKE_XML" > "$res"; [ "$FAKE_XML" = "$xml_pass" ] || return 2; return 0
  fi
  # What a child process (the editor, then Gradle) would inherit.
  echo "ANDROID_USER_HOME=$(printenv ANDROID_USER_HOME || echo unset) XDG_CONFIG_HOME=$(printenv XDG_CONFIG_HOME || echo unset)" >> "$tmp/unity-env.log"
  mkdir -p "$proj/Builds/Android"; echo "apk built in $proj" > "$proj/Builds/Android/consumer-dev.apk"
}
python3() { echo "$*" >> "$tmp/py.log"; return "${FAKE_LAUNCHER_RC:-0}"; }
FAKE_CERT="$cert"
apksigner() { echo "Signer #1 certificate DN: CN=Android Debug"; echo "Signer #1 certificate SHA-256 digest: $FAKE_CERT"; }
FAKE_KEYSTORE_CERT="$cert"
keytool() {
  local c="$FAKE_KEYSTORE_CERT"
  echo "$*" >> "$tmp/keytool.log"
  case "$*" in *"/xdg/"*) c="${FAKE_XDG_CERT:-$c}" ;; esac # $XDG_CONFIG_HOME/.android/debug.keystore
  printf 'Alias name: androiddebugkey\nEntry type: PrivateKeyEntry\nOwner: C=US, O=Android, CN=Android Debug\n'
  printf 'Certificate fingerprints:\n\t SHA1: 00:11:22\n\t SHA256: %s\nSignature algorithm name: SHA256withRSA\n' "$c"
}

# The fake headset: files under $tmp/device, state from FAKE_* variables. Logs every adb call.
mkdir -p "$tmp/device"
secret='{"uploadKey":"synthetic-private-value","player":"synthetic-player"}'
printf '%s\n' "$secret" > "$tmp/device/playtest.json"
printf 't,prop,speed\n1,Can,3.2\n' > "$tmp/device/throws.csv"
FAKE_MAKER=Oculus FAKE_ALIVE=1 FAKE_LOGCAT="" FAKE_CORRUPT=0
# dumpsys text comes from the idle fixtures (one section per dumpsys command); Home focused behind resumed panels by default.
fixtures="$(dirname "$0")/fixtures/quest-idle"
FAKE_FIXTURE=home-multi-top-resumed FAKE_ACTIVITY_MODE=normal FAKE_POWER_MODE=normal FAKE_VR=1 FAKE_HMT=""
fixture_section() { awk -v h="$1" '/^[A-Z][A-Z ]+ \(dumpsys /{ p = index($0, h) == 1 } p' "$fixtures/$FAKE_FIXTURE.txt"; }
fake_shell() {
  local f
  case "$1" in
    "getprop ro.product.manufacturer") echo "$FAKE_MAKER" ;;
    "getprop sys.hmt.mounted") printf '%s\r\n' "$FAKE_HMT"; return "${FAKE_HMT_RC:-0}" ;;
    "dumpsys activity activities")
      case "$FAKE_ACTIVITY_MODE" in
        fail) return 1 ;;
        empty) return 0 ;;
        ambiguous) echo 'topResumedActivity=unknown'; return 0 ;;
      esac
      fixture_section "ACTIVITY MANAGER" | sed 's/$/\r/' ;;
    "dumpsys window windows") fixture_section "WINDOW MANAGER" ;;
    "dumpsys vrpowermanager") [ "$FAKE_VR" = 1 ] || return 1; fixture_section "VR POWER MANAGER" ;;
    "dumpsys power")
      case "$FAKE_POWER_MODE" in
        fail) return 1 ;;
        empty) return 0 ;;
        ambiguous) echo 'Display Power: state=UNKNOWN'; return 0 ;;
        conflicting) printf 'Display Power: state=ON\nDisplay Power: state=OFF\n'; return 0 ;;
      esac
      fixture_section "POWER MANAGER" ;;
    "dumpsys package "*) echo "      android.permission.RECORD_AUDIO: granted=true, flags=[ USER_SET ]" ;;
    "pidof "*) [ "$FAKE_ALIVE" = 1 ] && echo 4242 ;;
    "am start "*) echo "Starting: Intent { $1 }" ;;
    *sha256sum*)
      f="${1#*sha256sum \'}"; f="${f%%\'*}"; f="$tmp/device/${f##*/}"
      if [ -f "$f" ]; then echo "$(qr_sha256 "$f")  /sdcard/x"; else echo missing; fi ;;
  esac
}
adb() {
  echo "$*" >> "$tmp/adb.log"
  { [ "${1:-}" = -s ] && [ -n "${2:-}" ]; } || { echo "$*" >> "$tmp/adb-no-serial"; return 1; }
  shift 2
  case "$1" in
    get-state) # $tmp/states: one state per get-state call (the last one repeats), else FAKE_STATE
      if [ -s "$tmp/states" ]; then head -n1 "$tmp/states"; [ "$(wc -l < "$tmp/states")" -le 1 ] || sed -i.bak 1d "$tmp/states"
      else echo "${FAKE_STATE:-device}"; fi ;;
    wait-for-device) [ "$(head -n1 "$tmp/states" 2>/dev/null)" = device ] || sleep 5 ;; # back, or never
    shell) shift; fake_shell "$*" ;;
    exec-out) cat "$tmp/device/${3##*/}"; [ "$FAKE_CORRUPT" = 0 ] || echo x ;;
    install) eval "echo \"\${$#}\"" >> "$tmp/installed"; echo "Performing Streamed Install"; echo Success ;;
    logcat) [ "$2" != -d ] || printf "%s\n" "$FAKE_LOGCAT" ;;
  esac
}

run() { rc=0; ( qr_main "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?; }
out_has() { grep -q -- "$1" "$tmp/out" "$tmp/err"; }
reset_logs() { rm -f "$tmp/states" "$tmp/unity.log" "$tmp/adb.log" "$tmp/installed" "$tmp/py.log" "$tmp/adb-no-serial" "$tmp/unity-env.log" "$tmp/notes-env.log" "$tmp/keytool.log" "$tmp/unity-lock.log"; }

# Keep the entry point and its sourced modules within the hub's source-size ceiling.
for file in "$(dirname "$script")/tests/quest-release.test.sh" "$(dirname "$script")"/tests/lib/quest-release-*.sh; do
  check "${file##*/} fits the hub source-size ceiling" \
    '[ "$(wc -l < "$file")" -le 800 ] && [ "$(wc -c < "$file")" -le 51200 ]'
done

# --- prepare -------------------------------------------------------------------------------------------------------------------
FAKE_FREE_GB=12 run prepare
check "prepare refuses under 25 GB free and creates no worktree" \
  '[ "$rc" != 0 ] && out_has "only 12 GB free" && [ ! -d "$root/rel-$short-test" ] && ! [ -f "$tmp/git.log" ]'
run prepare
check "prepare fetches and makes rel-<sha>-test and rel-<sha>-build at origin/main" \
  '[ "$rc" = 0 ] && [ -f "$tmp/git.log" ] && [ "$(git -C "$root/rel-$short-test" rev-parse HEAD)" = "$sha" ] && [ "$(git -C "$root/rel-$short-build" rev-parse HEAD)" = "$sha" ]'
check "each worktree has its own Library copy, never a symlink" \
  '[ -d "$root/rel-$short-build/Library" ] && [ ! -L "$root/rel-$short-build/Library" ] && [ ! -L "$root/rel-$short-test/Library" ] && [ -f "$root/rel-$short-test/Library/Bee/cache" ] && [ "$(wc -l < "$tmp/clone.log")" = 2 ]'
check "the warm worktree is untouched" '[ "$(cat "$root/mac-pass/Library/Bee/cache")" = warm ] && [ ! -d "$root/mac-pass/.git" ]'
check "the run folder holds a summary with the commit" 'grep -q "commit:      $short (origin/main)" "$root"/release-logs/"$short"-*/summary.txt'

check "fetch disables terminal and SSH prompts without changing the caller environment" \
  'grep -q "^prompt=0 ssh=" "$tmp/fetch-env" && grep -q -- "-o BatchMode=yes" "$tmp/fetch-env" && grep -q "; qr_ssh 1 ssh$" "$tmp/fetch-env" && [ "${GIT_TERMINAL_PROMPT-unset}" = unset ] && [ "${GIT_SSH_COMMAND-unset}" = unset ]'
for cmd in prepare all; do
  reset_logs
  FAKE_FETCH_RC=128 GIT_SSH_COMMAND='ssh -i /fake/key' run "$cmd"
  check "$cmd fetch failure fails fast with authentication guidance and no Unity or device calls" \
    '[ "$rc" != 0 ] && out_has "non-interactive.*authenticate.*ssh-agent.*retry prepare" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/adb.log" ] && grep -q "^prompt=0 ssh=" "$tmp/fetch-env" && grep -q -- "-o BatchMode=yes" "$tmp/fetch-env" && grep -q "; qr_ssh 1 ssh -i /fake/key$" "$tmp/fetch-env"'
done
run prepare

# A failed status inspection must never count as clean, either on reuse or cleanup.
FAKE_STATUS_FAIL=1 run prepare
check "prepare refuses a worktree when git status fails" '[ "$rc" != 0 ] && out_has "cannot inspect" && [ -d "$root/rel-$short-test" ]'
rc=0; ( qr_config; FAKE_STATUS_FAIL=1; qr_load_state; qr_cleanup_one "$root/rel-$short-test" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
check "cleanup preserves worktrees when git status fails" '[ "$rc" != 0 ] && [ -d "$root/rel-$short-test" ] && [ -d "$root/rel-$short-build" ] && out_has "inspection failed"'
run prepare
check "prepare recovers after status is readable" '[ "$rc" = 0 ]'
# A rejected dirty build worktree must not become a usable prepared release.
echo dirty >> "$root/rel-$short-build/Assets/Scripts/C.cs"
run prepare
check "failed dirty prepare does not publish current.env" \
  '[ "$rc" != 0 ] && out_has "local changes" && [ ! -f "$root/release-logs/current.env" ]'
reset_logs; run build
check "build after a failed prepare cannot consume the dirty worktree" \
  '[ "$rc" != 0 ] && out_has "no prepared release" && [ ! -f "$tmp/unity.log" ]'
git -C "$root/rel-$short-build" checkout -- Assets/Scripts/C.cs
run prepare

# --- gate ----------------------------------------------------------------------------------------------------------------------
check "the gate categories are MacOnly + Gfx (what the Linux pure pass excludes)" \
  '[ "$(qr_gate_categories "$repo")" = "Gfx;MacOnly" ] && [ "$(QUEST_GATE_CATEGORIES=MacOnly qr_gate_categories "$repo")" = MacOnly ]'
reset_logs; FAKE_XML="$xml_fail" run gate
check "a failed NUnit XML makes gate exit non-zero" '[ "$rc" != 0 ]'
check "gate runs EditMode with Metal graphics and -testCategory Gfx;MacOnly in the test worktree" \
  'grep -q -- "-force-metal -projectPath $root/rel-$short-test -runTests -testPlatform EditMode" "$tmp/unity.log" && grep -q -- "-testCategory Gfx;MacOnly" "$tmp/unity.log" && ! grep -q -- -nographics "$tmp/unity.log"'
check "gate prints the totals and each failure with its message (and a SetUp failure)" \
  'out_has "3 tests, 1 passed, 2 failed" && out_has "FAIL Synthetic.Props.Tests.PunchPlayModeTests.Haymaker: Expected knockdown but was <none>" && out_has "CourtPlayModeTests (SetUp): scene did not load"'
check "the summary lists the gate failures" 'grep -q "gate fails:  Synthetic.Props.Tests.PunchPlayModeTests.Haymaker" "$tmp/out"'
reset_logs; run gate
check "a passing XML: gate exits 0" '[ "$rc" = 0 ] && grep -q "gate:        Gfx;MacOnly: 3 tests, 3 passed, 0 failed" "$tmp/out"'
reset_logs; run gate --full
check "gate --full runs every test (no -testCategory)" '[ "$rc" = 0 ] && ! grep -q -- -testCategory "$tmp/unity.log"'
reset_logs; FAKE_UNITY_CRASH=1 run gate
check "a crash with no results XML fails the gate" '[ "$rc" != 0 ] && out_has "no results XML"'

# --- time box (no gtimeout on this PATH: the background watchdog) ---------------------------------------------------------------
check "the watchdog stops a run past its time box with 124" \
  '( PATH=/usr/bin:/bin; command -v gtimeout >/dev/null && exit 0; s=$(date +%s); qr_timebox 1 sleep 20; r=$?; [ "$r" = 124 ] && [ $(( $(date +%s) - s )) -lt 10 ] ) 2>/dev/null'
check "a run inside its time box keeps its exit code" '( PATH=/usr/bin:/bin; qr_timebox 5 sh -c "exit 3"; [ $? = 3 ] )'
check "the watchdog leaves no sleep behind (timed out or not)" \
  '( PATH=/usr/bin:/bin; qr_timebox 4321 true; qr_timebox 1 sleep 20 ) 2>/dev/null; sleep 1; ! pgrep -f "sleep (4321|60)$" >/dev/null'

# --- build and verify ------------------------------------------------------------------------------------------------------
apk="$root/mac-pass/Builds/Android/consumer-dev-$short.apk"
reset_logs; run build
check "build runs Synthetic.Editor.Build.DevelopmentApk for Android in the build worktree" \
  '[ "$rc" = 0 ] && grep -q -- "-projectPath $root/rel-$short-build -buildTarget Android -executeMethod Synthetic.Editor.Build.DevelopmentApk -quit -logFile" "$tmp/unity.log"'
check "build keeps the APK as consumer-dev-<sha>.apk in mac-pass/Builds/Android" \
  'grep -q "apk built in $root/rel-$short-build" "$apk" && grep -q "apk:         $apk" "$tmp/out"'
check "build with no --notes and no installed build in the logs leaves both notes variables unset" \
  'grep -q "^notes= prev=$" "$tmp/notes-env.log" && grep -q "notes:       merge titles since the last 8 merges" "$tmp/out"'
notes="$tmp/whats-new.txt"; printf -- '- Pick who is playing\nBuild number on the start panel\n' > "$notes"
logs="$root/release-logs"
mkdir -p "$logs/abc123456-20200101-000000/summary" "$logs/def987654-20200102-000000/summary"
echo "install ok (/x.apk)" > "$logs/abc123456-20200101-000000/summary/install"
echo "abc123456 (origin/main)" > "$logs/abc123456-20200101-000000/summary/commit"
echo "abc123456" > "$logs/abc123456-20200101-000000/summary/installed_commit"
echo "20200101-000000" > "$logs/abc123456-20200101-000000/summary/installed_at"
echo "install FAILED: no" > "$logs/def987654-20200102-000000/summary/install" # newer, but not installed
echo "def987654 (origin/main)" > "$logs/def987654-20200102-000000/summary/commit"
reset_logs; run build --notes "$notes"
check "build --notes exports YETIKIT_WHATS_NEW (absolute) and YETIKIT_PREV_SHA from the last successful install" \
  '[ "$rc" = 0 ] && grep -q "^notes=$notes prev=abc123456$" "$tmp/notes-env.log" && grep -q "notes:       $notes" "$tmp/out"'
reset_logs; run build --notes "$tmp/nope.txt"
check "build --notes with a missing file fails before Unity runs" '[ "$rc" != 0 ] && out_has "does not exist" && [ ! -f "$tmp/unity.log" ]'
rm -rf "$logs/abc123456-20200101-000000" "$logs/def987654-20200102-000000"

# --- the debug keystore Gradle signs with: ANDROID_USER_HOME, never $XDG_CONFIG_HOME/.android --------------------------------
export XDG_CONFIG_HOME="$HOME/.config" # what a fish login shell exports
reset_logs; run build
check "build: the editor sees ANDROID_USER_HOME=\$HOME/.android and no XDG_CONFIG_HOME the caller exported" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/unity-env.log")" = "ANDROID_USER_HOME=$HOME/.android XDG_CONFIG_HOME=unset" ]'
# shellcheck disable=SC2031 # qr_build sets ANDROID_USER_HOME only in its own subshell: that is the point
( qr_config; qr_load_state; qr_build >/dev/null 2>&1 && echo "${XDG_CONFIG_HOME-unset} ${ANDROID_USER_HOME-unset}" ) > "$tmp/caller-env.txt"
check "build leaves the caller's own environment alone" '[ "$(cat "$tmp/caller-env.txt")" = "$HOME/.config unset" ]'
unset XDG_CONFIG_HOME
# shellcheck disable=SC2031
export ANDROID_USER_HOME="$tmp/android-user"
reset_logs; run build
check "build respects a caller-set ANDROID_USER_HOME" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/unity-env.log")" = "ANDROID_USER_HOME=$tmp/android-user XDG_CONFIG_HOME=unset" ]'
unset ANDROID_USER_HOME
reset_logs; run build
check "no debug keystore yet: the preflight logs and the build runs" \
  '[ "$rc" = 0 ] && [ -f "$tmp/unity.log" ] && [ ! -f "$tmp/keytool.log" ] && out_has "no $HOME/.android/debug.keystore"'
mkdir -p "$HOME/.android"; echo not-a-real-keystore > "$HOME/.android/debug.keystore"
rc=0
# Hide keytool only after config has loaded, without hiding jq or filesystem tools.
( qr_config; unset -f keytool
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = keytool ]; then return 1; fi; builtin command "$@"; }
  qr_keystore_preflight
) > "$tmp/out" 2> "$tmp/err" || rc=$?
check "no keytool: the preflight logs and continues" '[ "$rc" = 0 ] && out_has "no keytool"'
reset_logs; FAKE_KEYSTORE_CERT="6F:0A:D4:16:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB" run build
check "a debug keystore with another certificate stops build before Unity runs, naming the keystore" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/unity.log" ] && out_has "$HOME/.android/debug.keystore" && out_has "6f0ad416" && grep -q "apk:         not built" "$tmp/out"'
check "the preflight reads the debug alias with storepass android and prints only the fingerprint" \
  'grep -q -- "-keystore $HOME/.android/debug.keystore -storepass android -alias androiddebugkey" "$tmp/keytool.log" && ! grep -q "PrivateKeyEntry\|Android Debug\|SHA1" "$tmp/out" "$tmp/err"'
reset_logs; run build
check "a debug keystore with the expected certificate: the build runs" \
  '[ "$rc" = 0 ] && [ -f "$tmp/unity.log" ] && [ -f "$tmp/keytool.log" ] && out_has "keystore preflight: .*matches"'

reset_logs; run verify "$apk"
check "verify runs android-launcher.py on the APK, checks the cert and prints the APK sha256" \
  '[ "$rc" = 0 ] && grep -q "Tools/ship/android-launcher.py --config $YETIKIT_CONFIG $apk" "$tmp/py.log" && out_has "apk sha256: $(qr_sha256 "$apk")" && grep -q "cert:        ok" "$tmp/out"'
FAKE_CERT="AA:BB" run verify "$apk"
check "verify fails on another signer certificate" '[ "$rc" != 0 ] && grep -q "cert:        MISMATCH" "$tmp/out"'
FAKE_LAUNCHER_RC=1 run verify "$apk"
check "verify fails when android-launcher.py rejects the APK" '[ "$rc" != 0 ] && out_has "android-launcher.py rejected"'
# Stub the Hub editor layout: SDK is beside Unity.app, not inside it.
editor="$tmp/hub/6000.6.6f1"
mkdir -p "$editor/PlaybackEngines/AndroidPlayer/SDK" "$editor/Unity.app/Contents/MacOS"
( unset ANDROID_SDK_ROOT; UNITY_HUB_EDITORS="$tmp/hub"; QR_SHORT="$short"; qr_config; qr_android_sdk 2>/dev/null; echo "$ANDROID_SDK_ROOT" ) > "$tmp/sdk.txt"
check "an unset ANDROID_SDK_ROOT points at the Hub editor's installed SDK" \
  '[ "$(cat "$tmp/sdk.txt")" = "$editor/PlaybackEngines/AndroidPlayer/SDK" ] && [ -d "$(cat "$tmp/sdk.txt")" ]'
( ANDROID_SDK_ROOT="$tmp/sdk"; UNITY_HUB_EDITORS="$tmp/hub"; qr_config; qr_android_sdk; echo "$ANDROID_SDK_ROOT" ) > "$tmp/sdk-override.txt"
check "an explicit ANDROID_SDK_ROOT is preserved" '[ "$(cat "$tmp/sdk-override.txt")" = "$tmp/sdk" ]'

# A stale "skipped: verify failed" from an earlier `all` clears once verify passes.
qr_config; qr_load_state; qr_set install "skipped: verify failed"
reset_logs; run verify "$apk"
check "a passing verify replaces an earlier 'install: skipped: verify failed'" \
  '[ "$rc" = 0 ] && ! grep -q "verify failed" "$tmp/out" && grep -q "install:     not run yet (verify ok)" "$tmp/out"'

# --- Java: apksigner and keytool need it; macOS's /usr/bin/java is only a stub.
hub="$tmp/jdk-hub"; fake_jdk "$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK"; fake_jdk "$hub/6000.0.1f1/PlaybackEngines/AndroidPlayer/OpenJDK"
# shellcheck disable=SC2031 # each case sets JAVA_HOME and PATH in its own subshell
java_env() { ( unset JAVA_HOME; [ -z "${1:-}" ] || JAVA_HOME="$1"; UNITY_HUB_EDITORS="${2:-$hub}"; qr_config; qr_java_setup && echo "$JAVA_HOME|${PATH%%:*}" ) 2>"$tmp/err"; }
check "no JAVA_HOME: the project's editor OpenJDK (ProjectVersion.txt), its bin first on PATH, logged" \
  '[ "$(java_env)" = "$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK|$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK/bin" ] && grep -q "java: JAVA_HOME=$hub/6000.6.6f1/.*Unity" "$tmp/err"'
check "a working JAVA_HOME is kept" '[ "$(java_env "$tmp/jdk")" = "$tmp/jdk|$tmp/jdk/bin" ]'
check "a broken JAVA_HOME falls back to Unity's OpenJDK" '[ "$(java_env "$tmp/nope")" = "$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK|$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK/bin" ]'
rm -rf "$hub/6000.6.6f1"
check "without the project's editor, any Hub editor's OpenJDK" '[ "$(java_env)" = "$hub/6000.0.1f1/PlaybackEngines/AndroidPlayer/OpenJDK|$hub/6000.0.1f1/PlaybackEngines/AndroidPlayer/OpenJDK/bin" ]'
for cmd in all build verify; do
  reset_logs; rm -f "$tmp/git.log"; rc=0; ( unset JAVA_HOME; UNITY_HUB_EDITORS="$tmp/no-hub"; qr_main "$cmd" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  check "$cmd with no Java anywhere fails at once, naming it, before prepare, Unity or verify" \
    '[ "$rc" != 0 ] && out_has "no Java runtime" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/py.log" ] && [ ! -f "$tmp/git.log" ]'
done

# --- install ---------------------------------------------------------------------------------------------------------------------
reset_logs; FAKE_MAKER=samsung run install "$apk"
check "install refuses a non-Oculus device and installs nothing" '[ "$rc" != 0 ] && out_has "not Oculus" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_FIXTURE=game-mounted run install "$apk"
check "install refuses when the game is focused and the headset is worn" '[ "$rc" != 0 ] && out_has "headset in use" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_FIXTURE=other-app-mounted run install "$apk"
check "install refuses when another app is focused and the headset is worn" '[ "$rc" != 0 ] && out_has "com.oculus.browser" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_FIXTURE=game-unmounted run install "$apk"
check "the game focused on an unmounted headset counts as idle" '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (not worn (HEADSET_UNMOUNTED)" "$tmp/out"'
reset_logs; FAKE_FIXTURE=game-standby-history run install "$apk"
check "State: STANDBY with an old HEADSET_MOUNTED transition line counts as idle" \
  '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (not worn (STANDBY)" "$tmp/out"'
reset_logs; FAKE_FIXTURE=game-mounted FAKE_VR=0 FAKE_HMT=0 run install "$apk"
check "no vrpowermanager, display on, getprop sys.hmt.mounted 0: idle" \
  '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (not worn (sys.hmt.mounted=0)" "$tmp/out" && grep -q "shell getprop sys.hmt.mounted" "$tmp/adb.log"'
reset_logs; FAKE_FIXTURE=game-mounted run install "$apk" --force
check "--force installs over a headset in use" '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && grep -q "idle check:  IN USE.*--force" "$tmp/out"'
reset_logs; run install "$apk"
check "Quest's several topResumedActivity lines with Home focused: idle" \
  '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (Home focused)" "$tmp/out"'
for mode in fail empty ambiguous; do
  reset_logs; FAKE_ACTIVITY_MODE="$mode" run install "$apk" --force
  check "install --force refuses $mode ACTIVITY dumpsys without backup or install" \
    '[ "$rc" != 0 ] && out_has "cannot determine" && [ ! -f "$tmp/installed" ] && ! grep -q "exec-out" "$tmp/adb.log"'
done
for mode in fail empty ambiguous conflicting; do
  reset_logs; FAKE_FIXTURE=game-mounted FAKE_VR=0 FAKE_POWER_MODE="$mode" run install "$apk" --force
  check "install --force refuses $mode POWER dumpsys (no headset state) without backup or install" \
    '[ "$rc" != 0 ] && out_has "cannot determine" && [ ! -f "$tmp/installed" ] && ! grep -q "exec-out" "$tmp/adb.log"'
done
reset_logs; FAKE_HMT=0 FAKE_HMT_RC=1 FAKE_FIXTURE=game-mounted run install "$apk"
check "failed mounted query printing zero cannot override a worn headset" \
  '[ "$rc" != 0 ] && out_has "headset in use" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_HMT=0 FAKE_HMT_RC=1 FAKE_FIXTURE=game-mounted FAKE_VR=0 FAKE_POWER_MODE=empty run install "$apk" --force
check "failed mounted query with unknown power fails safe even with --force" \
  '[ "$rc" != 0 ] && out_has "cannot determine" && [ ! -f "$tmp/installed" ]'
reset_logs; run install "$apk"
backup="$(find "$HOME" -maxdepth 1 -name 'Quest-playtest-backup-*' | sort | tail -n1)"
check "install: verifies before adb install -r, with -s on every adb call; no destructive command" \
  '[ -f "$tmp/py.log" ] && [ "$rc" = 0 ] && grep -q "^-s $serial install -r $apk$" "$tmp/adb.log" && [ ! -f "$tmp/adb-no-serial" ] && ! grep -qE "uninstall|pm clear|grant|revoke" "$tmp/adb.log"'
check "the backup has both files from exec-out cat, matching SHA256SUMS" \
  'grep -q "exec-out cat /sdcard/Android/data/com.example.consumer/files/playtest.json" "$tmp/adb.log" && cmp -s "$backup/playtest.json" "$tmp/device/playtest.json" && cmp -s "$backup/throws.csv" "$tmp/device/throws.csv" && [ "$(cat "$backup/SHA256SUMS")" = "$(qr_sha256 "$backup/playtest.json")  playtest.json
$(qr_sha256 "$backup/throws.csv")  throws.csv" ]'
check "playtest.json contents never reach stdout or stderr" '! grep -q "synthetic-private-value\|uploadKey" "$tmp/out" "$tmp/err" && ! grep -rq synthetic-private-value "$root/release-logs"'
check "the summary reports the backup, playtest.json unchanged and RECORD_AUDIO granted" \
  'grep -q "backup:      $backup (verified" "$tmp/out" && grep -q "data hash:   configured data files unchanged" "$tmp/out" && grep -q "mic:         RECORD_AUDIO granted=true" "$tmp/out"'
reset_logs; FAKE_CORRUPT=1 run install "$apk"
check "a backup copy that differs from the device stops the install" '[ "$rc" != 0 ] && out_has "does not match the device" && [ ! -f "$tmp/installed" ]'

# --- a Quest that drops off adb: wait-for-device, time-boxed by QR_ADB_WAIT.
reset_logs; printf 'offline\ndevice\n' > "$tmp/states"; run install "$apk"
check "install: a Quest that is back on the second get-state installs after one adb wait-for-device" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && [ "$(grep -c "^-s $serial wait-for-device$" "$tmp/adb.log")" = 1 ] && out_has "adb state .offline.: waiting up to 120s"'
reset_logs; printf 'unauthorized\n' > "$tmp/states"; s0=$(date +%s); QR_ADB_WAIT=1 run install "$apk"
check "install: a Quest that never comes back fails after the QUEST_ADB_WAIT time box, installing nothing" \
  '[ "$rc" != 0 ] && [ $(( $(date +%s) - s0 )) -lt 5 ] && grep -q "wait-for-device" "$tmp/adb.log" && out_has "not connected (adb state .unauthorized.)" && [ ! -f "$tmp/installed" ]'
reset_logs; run install "$apk"
check "install: a connected Quest never waits" '[ "$rc" = 0 ] && ! grep -q wait-for-device "$tmp/adb.log"'
reset_logs; printf 'offline\ndevice\n' > "$tmp/states"; FAKE_LOGCAT="" run launch
check "launch waits for a Quest that dropped off adb too" '[ "$rc" = 0 ] && grep -q "wait-for-device" "$tmp/adb.log" && grep -q "am start" "$tmp/adb.log"'

# --- launch ----------------------------------------------------------------------------------------------------------------------
FAKE_LOGCAT='10-31 12:00:01.000  4242  4260 I Unity   : synthetic diagnostic
10-31 12:00:30.000  4242  4260 I Unity   : [SyntheticPerf] fps=71.9 frame=13.9ms
10-31 12:00:31.000  4242  4260 W Unity   : [SyntheticFeature] voice model ready
10-31 12:00:32.000  4242  4260 E Unity   : NullReferenceException: boom
10-31 12:00:00.000  4100  4100 D AndroidRuntime: Calling main entry com.android.commands.am.Am'
reset_logs; run launch
check "launch: logcat -c, am start of the verified activity, one logcat -d, no polling" \
  '[ "$rc" = 0 ] && [ "$(grep -c "logcat -c" "$tmp/adb.log")" = 1 ] && [ "$(grep -c "logcat -d" "$tmp/adb.log")" = 1 ] && grep -q "am start -n com.example.consumer/com.unity3d.player.UnityPlayerGameActivity" "$tmp/adb.log"'
check "launch has no consumer-specific boot extras" \
  '! grep -q -- "--es" "$tmp/adb.log"'
check "launch reports configured fps and E/Unity lines and a live process" \
  'grep -q "launch:      fps 71.9.*E/Unity 1.*fatal 1.*alive yes" "$tmp/out" && out_has "NullReferenceException: boom"'
check "a healthy launch does not warn about the shell interstitial" '! out_has "WARN.*Quest shell"'
for broadcast in appLaunchFailureBroadcastReceived sendExtendedInterstitialBroadcast; do
  reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
11-01 12:00:30.000  1234  1234 I VrShell: $broadcast packageName=com.example.consumer resolution HEALTHY_INSTALLATION" run launch
  check "$broadcast for our package warns despite good fps and a live process (not a crash)" \
    '[ "$rc" = 0 ] && out_has "WARN: Quest shell" && out_has "$broadcast packageName" && grep -q "shell launch warnings 1" "$tmp/out" && ! grep -q "launch:      CRASH" "$tmp/out"'
  check "shell warning is saved in the launch report" \
    'grep -q "WARN: Quest shell" "$root"/release-logs/"$short"-*/launch-report.txt'
done
reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
11-01 12:00:30.000  1234  1234 I VrShell: appLaunchFailureBroadcastReceived packageName=com.example.other
11-01 12:00:31.000  1234  1234 I VrShell: sendExtendedInterstitialBroadcast packageName=com.example.consumer.other
11-01 12:00:32.000  1234  1234 I VrShell: appLaunchFailureBroadcastReceived packageName=comXexampleXconsumer
11-01 12:00:33.000  1234  1234 I VrShell: launching com.example.consumer" run launch
check "other packages, package prefixes and unrelated package lines do not warn" \
  '[ "$rc" = 0 ] && ! out_has "WARN.*Quest shell" && ! out_has "shell launch warnings"'
reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
11-01 12:00:30.000  1234  1234 I VrShell: sendExtendedInterstitialBroadcast packageName=com.example.consumer secondsSinceDetection=260
11-01 12:00:31.000  1234  1234 I VrShell: appLaunchFailureBroadcastReceived packageName=com.example.consumer resolution HEALTHY_INSTALLATION" run launch
check "both shell broadcasts are counted without converting them into a crash" \
  '[ "$rc" = 0 ] && out_has "shell launch warnings 2" && ! grep -q "launch:      CRASH" "$tmp/out"'

# Exercise the default 60 s path without waiting: the early snapshot can contain a broadcast which has rolled out
# by the final snapshot. Stub sleep only inside this subshell, leaving all other timebox tests real.
launch_timing() (
  local dumps=0
  sleep() {
    case "$1" in 0.*) command sleep "$1" ;; *) echo "$1" >> "$tmp/launch-sleeps" ;; esac
  }
  qr_adb() {
    if [ "${1:-}" = logcat ] && [ "${2:-}" = -d ]; then
      dumps=$((dumps + 1))
      echo "snapshot $dumps" >> "$tmp/launch-snapshots"
      if [ "$dumps" = 1 ] && [ "$QR_LAUNCH_WAIT" -gt 30 ]; then
        [ "${FAKE_EARLY_FAIL:-0}" = 0 ] || { echo 'adb unavailable'; return 1; }
        printf '%s\n' "$FAKE_LOGCAT"
        echo '11-01 12:00:30.000 I VrShell: appLaunchFailureBroadcastReceived packageName=com.example.consumer'
      else
        printf '%s\n' "$FAKE_LOGCAT"
      fi
    else
      adb -s "$serial" "$@"
    fi
  }
  qr_main launch
)
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=60 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "default wait checks at 30 s, then at 60 s, preserving early-only warnings" \
  '[ "$rc" = 0 ] && [ "$(paste -sd, "$tmp/launch-sleeps")" = 30,30 ] && [ "$(wc -l < "$tmp/launch-snapshots")" = 2 ] && out_has "30s check" && out_has "shell launch warnings 1"'
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=60 FAKE_EARLY_FAIL=1 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "early snapshot failure warns but preserves the final check and exit status" \
  '[ "$rc" = 0 ] && out_has "early adb logcat -d failed" && [ "$(wc -l < "$tmp/launch-snapshots")" = 2 ] && ! out_has "shell launch warnings"'
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=30 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "a 30 s wait uses one final snapshot without an additional delay" \
  '[ "$rc" = 0 ] && [ "$(paste -sd, "$tmp/launch-sleeps")" = 30 ] && [ "$(wc -l < "$tmp/launch-snapshots")" = 1 ]'
reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
10-31 12:00:40.000  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main" run launch
check "a FATAL line is a crash (exit 1)" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
for unrelated in \
  '10-31 12:00:40.000  9999  9999 E AndroidRuntime: FATAL EXCEPTION: main' \
  'E/AndroidRuntime( 9999): FATAL EXCEPTION: main' \
  '10-31 12:00:40.000  9999  9999 F libc: Fatal signal 11 in tid 9999' \
  "10-31 12:00:40.000  9999  9999 F DEBUG: pid: 8888, tid: 8888, name: other >>> $QR_PKG.other <<<"; do
  reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
$unrelated" run launch
  check "unrelated crash remains diagnostic, not a launch failure: $unrelated" \
    '[ "$rc" = 0 ] && ! grep -q "launch:      CRASH" "$tmp/out"'
done
reset_logs; FAKE_LOGCAT='E/AndroidRuntime( 4242): FATAL EXCEPTION: main' run launch
check "brief-format game crash is scoped by PID" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_LOGCAT="10-31 12:00:40.000  9999  9999 F DEBUG: pid: 4242, tid: 4242, name: UnityMain >>> $QR_PKG <<<" run launch
check "native tombstone for the exact game package fails launch" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_LOGCAT="10-31 12:00:40.000  9998  9998 E AndroidRuntime: FATAL EXCEPTION: main
10-31 12:00:40.001  9998  9998 E AndroidRuntime: Process: $QR_PKG, PID: 9998" run launch
check "package attribution catches a game process that restarted during observation" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_ALIVE=0 run launch
check "a dead process is a crash" '[ "$rc" != 0 ] && grep -q "alive no" "$tmp/out"'

# --- rollback ----------------------------------------------------------------------------------------------------------------------
old="$tmp/consumer-dev-old.apk"; echo old > "$old"
reset_logs; run rollback "$old"
check "rollback installs -r -d the previous APK (lower versionCode) with the same data checks" \
  '[ "$rc" = 0 ] && grep -q "^-s $serial install -r -d $old$" "$tmp/adb.log" && grep -q "data hash:   configured data files unchanged" "$tmp/out" && grep -q "install:     rollback ok" "$tmp/out"'

# --- cleanup -----------------------------------------------------------------------------------------------------------------------
echo noise >> "$root/rel-$short-test/Assets/Mats/A.mat"; echo noise >> "$root/rel-$short-test/Assets/Mats/B.asset"
echo real >> "$root/rel-$short-build/Assets/Scripts/C.cs"
run cleanup
check "cleanup removes a worktree with only .mat/.asset noise" '[ ! -d "$root/rel-$short-test" ]'
check "cleanup keeps a worktree with a changed .cs file and says why" \
  '[ "$rc" != 0 ] && [ -d "$root/rel-$short-build" ] && out_has "keeping $root/rel-$short-build: real changes: Assets/Scripts/C.cs"'
check "cleanup never touches the warm worktree" '[ -f "$root/mac-pass/Library/Bee/cache" ]'
git -C "$repo" worktree remove --force "$root/rel-$short-build"
# An index rename has two paths in porcelain -z: destination .asset is noise, source .cs is not.
run prepare
mkdir -p "$root/rel-$short-test/Assets/Scripts"
git -C "$root/rel-$short-test" mv Assets/Scripts/C.cs Assets/Scripts/C.asset
run cleanup
check "cleanup preserves staged source-to-asset renames" '[ "$rc" != 0 ] && [ -f "$root/rel-$short-test/Assets/Scripts/C.asset" ] && out_has "Assets/Scripts/C.cs"'
git -C "$repo" worktree remove --force "$root/rel-$short-test"
[ -d "$root/rel-$short-build" ] && git -C "$repo" worktree remove --force "$root/rel-$short-build"

# --- all -------------------------------------------------------------------------------------------------------------------------
reset_logs; FAKE_XML="$xml_fail" run all
check "all: a failed gate installs nothing, keeps the APK and reports" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/installed" ] && ! grep -q " install " "$tmp/adb.log" 2>/dev/null && [ -f "$apk" ] && grep -q "install:     skipped: gate failed" "$tmp/out"'
check "all: gate and build both ran, each with its own -logFile" \
  'grep -q "gate-unity.log" "$tmp/unity.log" && grep -q "build-unity.log" "$tmp/unity.log" && [ -d "$root/rel-$short-test" ]'
# A parameterised fixture failure reduces to Ns.F; one Passed case must not allow all to install.
xml_parameterized='<test-run total="2" passed="2" failed="0" skipped="0"><test-suite type="TestFixture" fullname="Ns.F(&quot;Cop&quot;)" result="Failed" site="TearDown"><test-case fullname="Ns.F(&quot;Cop&quot;).One" result="Passed"/><test-case fullname="Ns.F(&quot;Cop&quot;).Two" result="Passed"/></test-suite></test-run>'
xml_partial='<test-run total="1" passed="1" failed="0" skipped="0"><test-suite type="TestFixture" fullname="Ns.F(&quot;Cop&quot;)" result="Passed"><test-case fullname="Ns.F(&quot;Cop&quot;).One" result="Passed"/></test-suite></test-run>'
reset_logs; FAKE_XML="$xml_parameterized" FAKE_RETRY_XML="$xml_partial" run all
check "all refuses to install when a parameterised fixture retry returns just one Passed case" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/installed" ] && [ -f "$apk" ] && grep -q -- "-testFilter Ns.F " "$tmp/unity.log" && grep -q "install:     skipped: gate failed" "$tmp/out" && out_has "fixture retry omitted original test case"'
# One unlisted failure: its one rerun passes, so all installs.
xml_one='<?xml version="1.0"?><test-run id="2" total="3" passed="2" failed="1" skipped="0"><test-suite type="TestFixture" fullname="Ns.A" result="Failed" site="Child"><test-case fullname="Ns.A.One" result="Passed"/><test-case fullname="Ns.A.New" result="Failed"><failure><message>new flake</message></failure></test-case></test-suite></test-run>'
for k in test build; do [ -d "$root/rel-$short-$k" ] && git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
# The retry must actually pass the selected Ns.A.New case, not the unrelated Ns.A.One from the generic fixture.
reset_logs; FAKE_XML="$xml_one" FAKE_RETRY_XML="${xml_pass/Ns.A.One/Ns.A.New}" run all
check "all: one unlisted gate failure that passes on its rerun installs" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && grep -q -- "-testFilter Ns.A.New " "$tmp/unity.log" && grep -q "retried 1 unlisted failure: Ns.A.New, passed on rerun" "$tmp/out"'
reset_logs; FAKE_XML="$xml_fail" run all
# The operator's manual rerun in the same run folder: the summary shows each step's latest result.
reset_logs; run gate
check "after a failed all, a passing gate rerun clears 'install: skipped: gate failed'" \
  '[ "$rc" = 0 ] && ! grep -q "gate failed" "$tmp/out" && grep -q "install:     not run yet (gate ok)" "$tmp/out"'
reset_logs; run install; run launch
check "after a failed all, then gate, install, launch: the summary says install ok and the launch" \
  '[ "$rc" = 0 ] && grep -q "^install:     install ok ($apk)" "$tmp/out" && grep -q "^launch:      fps 71.9" "$tmp/out" && grep -q "^gate:        Gfx;MacOnly: 3 tests, 3 passed" "$tmp/out" && ! grep -q "^install: .*skipped\|gate failure" "$tmp/out"'
reset_logs; FAKE_MAKER=samsung run install "$apk"
check "a refused install replaces the stale 'not run yet' with its own result" \
  '[ "$rc" != 0 ] && grep -q "^install:     install stopped before adb install" "$tmp/out"'
for k in test build; do git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
reset_logs; run all --notes "$notes"
check "all --notes hands YETIKIT_WHATS_NEW to the build only" \
  '[ "$(grep -c "^notes=$notes " "$tmp/notes-env.log")" = 2 ] && grep -q "^-s $serial install -r $apk$" "$tmp/adb.log"'
check "all: the happy path verifies, installs, launches and cleans up" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && grep -q "logcat -d" "$tmp/adb.log" && [ ! -d "$root/rel-$short-test" ] && [ ! -d "$root/rel-$short-build" ]'
check "all: the keystore preflight runs once, not again in build" '[ "$(grep -c . "$tmp/keytool.log")" = 1 ]'
check "all: the summary block has every field" \
  'for f in commit: gate: "gate fails:" apk: "apk sha256:" cert: "idle check:" backup: install: "data hash:" mic: launch:; do grep -q "^$f" "$tmp/out" || exit 1; done'
reset_logs; FAKE_LOGCAT='10-31 12:00:40.000  9999  9999 E AndroidRuntime: FATAL EXCEPTION: main' run all --rollback "$old"
check "all does not roll back a healthy release for another app crash" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/installed")" = 1 ] && ! grep -q "install -r -d" "$tmp/adb.log"'
reset_logs; FAKE_ALIVE=0 run all --rollback "$old"
check "all --rollback: a crash at launch rolls back to the given APK" \
  '[ "$rc" != 0 ] && [ "$(sed -n 2p "$tmp/installed")" = "$old" ]'
for k in test build; do [ -d "$root/rel-$short-$k" ] && git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
reset_logs; FAKE_KEYSTORE_CERT="AA:BB" run all
check "all: a wrong debug keystore stops before the gate and build, installs nothing" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/installed" ] && out_has "$HOME/.android/debug.keystore" && grep -q "apk:         not built" "$tmp/out"'

# --- single-run lock: all, prepare, gate, build, verify, install, launch, rollback, cleanup (kill -0 on the recorded PID, never pgrep -f) -----------
lock="$root/release-logs/run.lock"
for k in test build; do [ -d "$root/rel-$short-$k" ] && git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
reset_logs; run prepare; reset_logs; run gate
check "gate holds the lock (its PID and run folder) while Unity runs and releases it on exit" \
  '[ "$rc" = 0 ] && grep -q "^lock pid=[0-9][0-9]* run=$root/release-logs/$short-" "$tmp/unity-lock.log" && [ ! -e "$lock" ]'
sleep 300 >/dev/null 2>&1 & live=$!
mkdir -p "$lock"; echo "$live" > "$lock/pid"; echo "$tmp/other-run" > "$lock/run_dir"
reset_logs; rm -f "$tmp/git.log"; run all
check "a second all refuses at once while a live run holds the lock, naming its PID and run folder" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active (pid $live, run folder $tmp/other-run)" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/git.log" ] && [ "$(cat "$lock/pid")" = "$live" ]'
for cmd in prepare gate build "install $apk" "rollback $old"; do
  # shellcheck disable=SC2086 # cmd is a step and its argument
  reset_logs; run $cmd
  check "${cmd%% *} refuses while the lock is live, touching neither Unity nor the device" \
    '[ "$rc" != 0 ] && out_has "another quest-release run is active" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/installed" ] && [ -d "$lock" ]'
done
reset_logs; run cleanup
check "cleanup refuses while the lock is live and keeps the live run's worktrees (nightly prepare && gate; cleanup)" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active" && [ -d "$root/rel-$short-test" ] && [ -d "$root/rel-$short-build" ] && [ -d "$lock" ]'
live_run="$(sed -n 's/^QR_RUN_DIR=//p' "$root/release-logs/current.env")"
echo live-apk > "$live_run/summary/apk"
reset_logs; run verify "$apk"
check "verify refuses while the lock is live and leaves the live run's apk fields alone" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active" && [ ! -f "$tmp/py.log" ] && [ "$(cat "$live_run/summary/apk")" = live-apk ] && [ "$(cat "$lock/pid")" = "$live" ]'
reset_logs; run launch
check "launch refuses while the lock is live: no logcat -c, no am start" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active" && ! grep -q "logcat\|am start" "$tmp/adb.log" 2>/dev/null && [ -d "$lock" ]'
reset_logs; run summary
check "summary takes no lock" '[ "$rc" = 0 ] && ! out_has "another quest-release run"'
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
reset_logs; run gate
check "a stale lock (PID gone) is removed with a log line and the run goes ahead" \
  '[ "$rc" = 0 ] && out_has "removing a stale lock $lock (pid $live is gone" && [ -f "$tmp/unity.log" ] && [ ! -e "$lock" ]'
check "the release scripts never search processes by command line (pgrep / pkill)" \
  '! grep -rnE "p(grep|kill)" "$script" "$(dirname "$script")/quest-release"'

# Read-only doctor regressions share this harness and run after the release-flow checks.
# shellcheck source=Tools/ship/tests/lib/quest-release-doctor.sh
. "$(dirname "$script")/tests/lib/quest-release-doctor.sh"

check "nothing ever ran adb without -s" '[ ! -f "$tmp/adb-no-serial" ]'

if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

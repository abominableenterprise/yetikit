#!/usr/bin/env bash
# shellcheck disable=SC2016 # check takes single-quoted conditions, expanded by eval
# shellcheck disable=SC2034 # rc, backup, serial and QR_SHORT are read inside those conditions
# Shared isolated harness for quest-release.test.sh and quest-release-flow-*.test.sh.
# Each suite creates only its own prerequisites, never replays another suite's checks.
# Never runs Unity or adb. bash 3.2 compatible (stock macOS); like the real script it runs without set -e.
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
# Each independent fixture has a distinct synthetic headset lock identity.
serial="synthetic-device-${tmp##*/}"
export QUEST_SERIAL="$serial"
cert="00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"

# shellcheck source=Tools/ship/quest-release.sh
. "$script"

# Reuse this fixture's validated immutable JSON; qr_config still evaluates
# environment overrides on every call. Config mutation has its own suite.
. "$(dirname "$0")/lib/quest-release-config-cache.sh"
qr_test_cache_config_reads || exit 1
# Conditions also use configured names outside qr_main's isolated subshell.
qr_config || exit 1

. "$(dirname "$0")/lib/quest-release-timebox.sh"

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
    "pidof "*) ( pidof() { [ "$FAKE_ALIVE" = 1 ] && echo 4242; }; eval "$1" ) ;;
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
    wait-for-device)
      if [ "$(head -n1 "$tmp/states" 2>/dev/null)" != device ]; then
        qr_test_block_until_term "$tmp/adb-wait"
      fi ;; # back immediately, or only the real timebox can end the wait
    shell) shift; fake_shell "$*" ;;
    exec-out) cat "$tmp/device/${3##*/}"; [ "$FAKE_CORRUPT" = 0 ] || echo x ;;
    install) eval "echo \"\${$#}\"" >> "$tmp/installed"; echo "Performing Streamed Install"; echo Success ;;
    logcat) [ "$2" != -d ] || printf "%s\n" "$FAKE_LOGCAT" ;;
  esac
}

# Repeated sourced calls share $$, unlike separate CLI invocations. Give each one
# a distinct synthetic second so three fast backups cannot collide on timestamp + $$.
QR_TEST_TICK=0
qr_timestamp() { printf '20990101-%06d\n' "$QR_TEST_TICK"; }
run() { QR_TEST_TICK=$((QR_TEST_TICK + 1)); rc=0; ( qr_main "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?; }
out_has() { grep -q -- "$1" "$tmp/out" "$tmp/err"; }
reset_logs() { rm -f "$tmp/adb-wait.started" "$tmp/adb-wait.terminated" "$tmp/states" "$tmp/unity.log" "$tmp/adb.log" "$tmp/installed" "$tmp/py.log" "$tmp/adb-no-serial" "$tmp/unity-env.log" "$tmp/notes-env.log" "$tmp/keytool.log" "$tmp/unity-lock.log"; }

# Fail setup explicitly: a prerequisite is not a test and must not hide failures.
qr_flow_require() {
  run "$@"
  if [ "$rc" != 0 ]; then
    printf 'fixture prerequisite failed: %s\n' "$*" >&2
    cat "$tmp/out" "$tmp/err" >&2
    exit 1
  fi
  reset_logs
}
qr_flow_prepare() { qr_flow_require prepare; }
qr_flow_build() { qr_flow_prepare; qr_flow_require build; }
qr_flow_keystore() {
  mkdir -p "$HOME/.android"
  echo not-a-real-keystore > "$HOME/.android/debug.keystore"
}
qr_flow_notes() {
  notes="$tmp/whats-new.txt"
  printf -- '- Pick who is playing\nBuild number on the start panel\n' > "$notes"
}
qr_flow_old_apk() { old="$tmp/consumer-dev-old.apk"; echo old > "$old"; }
qr_flow_healthy_log() {
FAKE_LOGCAT='10-31 12:00:01.000  4242  4260 I Unity   : synthetic diagnostic
10-31 12:00:30.000  4242  4260 I Unity   : [SyntheticPerf] fps=71.9 frame=13.9ms
10-31 12:00:31.000  4242  4260 W Unity   : [SyntheticFeature] voice model ready
10-31 12:00:32.000  4242  4260 E Unity   : NullReferenceException: boom
10-31 12:00:00.000  4100  4100 D AndroidRuntime: Calling main entry com.android.commands.am.Am'
}

apk="$root/mac-pass/Builds/Android/consumer-dev-$short.apk"
lock="$root/release-logs/run.lock"
qr_flow_finish() {
  check "nothing ever ran adb without -s" '[ ! -f "$tmp/adb-no-serial" ]'
  if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
  echo "all passed"
}

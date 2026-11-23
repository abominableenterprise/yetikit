#!/usr/bin/env bash
set -euo pipefail

ship="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
umask 077
mkdir "$work/bin" "$work/tmp"
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp" PROJECT="$work"
export calls="$work/calls" failure="$work/fake-failed" remote_files="$work/device"
export reverse_state="$work/reverse" real_python="$(command -v python3)"
export relay_pid_file="$work/relay.pid" nonce_file="$work/nonce"
export YETIKIT_TEST_ENROLL_TIMEOUT_SECONDS=3 YETIKIT_TEST_ENROLL_LAUNCH_SECONDS=1
mkdir "$remote_files"
export test_key='synthetic-key-not-for-output' test_code='synthetic code+&%?'
unset YETIKIT_CONFIG QUEST_SERIAL ANDROID_SERIAL
printf '%s\r\n' "$test_code" > "$work/private code"
printf '{"quest":{"package":"org.example.dev"}}\n' > "$work/yetikit.json"

cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'curl\n' >> "$calls"
check() { "$@" || { touch "$failure"; exit 96; }; }
check test "$1" = -q
check test "${*#*"$test_code"}" = "$*"
check test "$(< /dev/stdin)" = "$test_code"
check test "${*#*code@-}" != "$*"
check test "${!#}" = 'https://enroll.example.invalid/enroll'
while [[ "$1" != --output ]]; do shift; done
check test -f "$2"
check test "$(stat -c %a "$2")" = 600
printf '{"endpoint":"https://inbox.example.invalid","uploadKey":"%s"}' "$test_key" > "$2"
printf '%s\n%s\n' "$test_key" "$test_code" >&2
printf '%s' "${status:-200}"
EOF

cat > "$work/bin/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == */playtest-enroll-relay.py ]]; then
  printf '%s\n' "$$" > "$relay_pid_file"
fi
exec "$real_python" "$@"
EOF

cat > "$work/bin/adb" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'adb %s\n' "$*" >> "$calls"
check() { "$@" || { touch "$failure"; exit 96; }; }
if [[ "$*" == 'get-serialno' ]]; then printf 'synthetic-device\n'; exit; fi
check test "$1 $2" = '-s synthetic-device'; shift 2
expected_user="${active_user-0}"
remote="/storage/emulated/$expected_user/Android/data/org.example.dev/files/playtest"
# Also model the old direct write so the regressions fail on its effects.
legacy=/sdcard/Android/data/org.example.dev/files/playtest
staged_path() { [[ "${1%/*}" == "$remote" && "${1##*/}" == .playtest-enroll.* ]]; }
case "$*" in
  'shell am get-current-user')
    if compgen -G "$remote_files/.playtest-enroll.*" >/dev/null; then
      printf '%s\r\n' "${active_user_after_push-$expected_user}"
      exit "${user_rc_after_push:-0}"
    fi
    if [[ -e "$reverse_state" ]]; then
      printf '%s\r\n' "${active_user_after_reverse-$expected_user}"
      exit "${user_rc_after_reverse:-0}"
    fi
    printf '%s\r\n' "$expected_user"
    exit "${user_rc:-0}" ;;
  "shell cmd package path --user $expected_user org.example.dev")
    printf 'package:/data/app/base.apk\n' ;;
  'shell cmd package path --user 0 org.example.wrong') exit 0 ;; # no package, even with exit 0
  "shell mkdir -p $remote"|"shell mkdir -p $legacy")
    printf '%s\n' "$test_key" >&2
    if [[ $expected_user != 0 ]]; then exit 1; fi
    exit "${mkdir_rc:-0}" ;;
  'push '*)
    check test "$(stat -c %a "$2")" = 600
    if [[ "$3" != "$legacy/playtest.json" ]]; then check staged_path "$3"; fi
    check jq -e '. == {endpoint:"https://inbox.example.invalid", uploadKey:env.test_key, player:"fixture-player"}' "$2" >&2
    dest="$remote_files/${3##*/}"
    if [[ "${push_rc:-0}" == 0 ]]; then cp -- "$2" "$dest"; else printf 'partial' > "$dest"; fi
    printf '%s\n' "$test_key"
    printf '%s\n' "$test_key" >&2
    exit "${push_rc:-0}" ;;
  'shell mv -fT '*)
    check staged_path "$4"
    check test "$5" = "$remote/playtest.json"
    check test -f "$remote_files/${4##*/}"
    check grep -qx previous "$remote_files/playtest.json"
    printf '%s\n' "$test_key" >&2
    [[ "${rename_rc:-0}" == 0 ]] || exit "$rename_rc"
    mv -fT -- "$remote_files/${4##*/}" "$remote_files/playtest.json" ;;
  'shell rm -f '*)
    check staged_path "$4"
    rm -f -- "$remote_files/${4##*/}" ;;
  'reverse --no-rebind tcp:'*)
    check test "$3" = "$4"
    [[ ${reverse_rc:-0} == 0 ]] || exit "$reverse_rc"
    printf '%s\n' "${3#tcp:}" > "$reverse_state" ;;
  'reverse --remove tcp:'*)
    check test "${3#tcp:}" = "$(< "$reverse_state")"
    rm -f -- "$reverse_state" ;;
  "shell cmd package resolve-activity --brief --user $expected_user org.example.dev")
    printf 'priority=0 matched\r\n%s\r\n' "${component:-org.example.dev/.Launcher}" ;;
  "shell am start --user $expected_user -S "*)
    shift 6
    blocking=0
    if [[ "$1" == -W ]]; then blocking=1; shift; fi
    check test "$1 $2 $3 $4" = "-n 'org.example.dev/.Launcher' --ei yetikit_enroll_port"
    check test "$5" = "$(< "$reverse_state")"
    check test "$6 $7" = '--es yetikit_enroll_nonce'
    printf '%s\n' "$8" > "$nonce_file"
    [[ ${start_rc:-0} == 0 ]] || exit "$start_rc"
    if [[ ${launch_case:-} == stalled_start || ( ${launch_case:-} == blocked && $blocking == 1 ) ]]; then
      exec sleep 60
    fi
    if [[ -z ${launch_case:-} ]]; then
      check "$real_python" - "$5" "$8" <<'PY'
import json, os, re, socket, sys
port, nonce = int(sys.argv[1]), sys.argv[2]
assert re.fullmatch('[0-9a-f]{32}', nonce)

def request(value):
    with socket.create_connection(('127.0.0.1', port), timeout=2) as client:
        client.sendall(value.encode() + b'\n')
        with client.makefile('rb') as stream:
            return stream.read()

assert request('z' * 32) == b'', 'relay served a wrong nonce'
assert json.loads(request(nonce)) == dict(endpoint='https://inbox.example.invalid',
                                         uploadKey=os.environ['test_key'], player='fixture-player')
try:
    second = request(nonce)
except (ConnectionRefusedError, ConnectionResetError):
    pass
else:
    assert not second, 'relay served more than once'
PY
    fi
    if [[ $blocking == 1 ]]; then printf 'Status: ok\n'; else printf 'Starting: Intent\n'; fi ;;
  'shell date +%s.%N') printf '1700000000.321987654\n' ;;
  "shell am start --user $expected_user -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p org.example.dev")
    printf 'Status: ok\n' ;;
  'shell pidof -s org.example.dev') printf '123\n' ;; # unscoped PID lookup finds the primary user
  'shell ps -A -o UID,PID,NAME')
    printf 'UID PID NAME\n10123 123 org.example.dev\n'
    case "${launch_case:-}" in no_pid|blocked) ;; *) printf '1010123 456 org.example.dev\n' ;; esac ;;
  'logcat -d -T 1700000000.321 -v raw')
    if [[ ${launch_case:-} == blocked ]]; then
      printf 'Launch is blocked because: synthetic private detail %s %s\n' "$test_key" "$(< "$nonce_file")"
    fi ;;
  'logcat -d -T 1700000000.321 --pid=123 -v raw -s Unity:V'|'logcat -d -T 1700000000.321 --pid=456 -v raw -s Unity:V')
    if [[ "$expected_user" == 10 ]]; then check test "$5" = --pid=456; else check test "$5" = --pid=123; fi
    printf 'Playtest recorder on (%s)\n' "$test_key" ;;
  *) touch "$failure"; exit 96 ;;
esac
EOF
chmod +x "$work/bin/"*

run() {
  local expected="$1" rc=0
  shift
  : > "$calls"
  rm -f "$relay_pid_file" "$nonce_file"
  timeout --kill-after=1 6 bash -x "$ship/playtest-enroll.sh" --endpoint https://enroll.example.invalid/ \
    --code "$work/private code" --player fixture-player "$@" > "$work/out" 2> "$work/err" || rc=$?
  if grep -Fq -e "$test_key" -e "$test_code" "$work/out" "$work/err" "$calls"; then
    echo 'FAIL: credential printed' >&2
    exit 1
  fi
  if [[ -s "$nonce_file" ]] && grep -Fq -f "$nonce_file" "$work/out" "$work/err"; then
    echo 'FAIL: nonce printed' >&2
    exit 1
  fi
  [[ ! -e "$failure" ]] || { echo 'FAIL: unexpected fake command' >&2; exit 1; }
  [[ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]] || { echo 'FAIL: temp files left behind' >&2; exit 1; }
  [[ ! -e "$reverse_state" ]] || { echo 'FAIL: reverse left behind' >&2; exit 1; }
  if [[ -s "$relay_pid_file" ]] && kill -0 "$(< "$relay_pid_file")" 2>/dev/null; then
    echo 'FAIL: relay still running' >&2
    exit 1
  fi
  if [[ "$rc" != "$expected" ]]; then
    printf 'FAIL: %s: expected exit %s, got %s\n' "${launch_case:-foreground user ${active_user-0}}" "$expected" "$rc" >&2
    grep '^\[playtest-enroll\]' "$work/err" >&2 || true
    return 1
  fi
}

no_exchange() {
  if grep -Eq '^curl$|^adb .* (package path|mkdir|push|mv) ' "$calls"; then
    echo 'FAIL: enrollment proceeded without a supported Android user' >&2
    exit 1
  fi
}

assert_no_staging_file() {
  [[ -z "$(find "$remote_files" -mindepth 1 ! -name playtest.json -print)" ]] || {
    echo 'FAIL: staged device file left behind' >&2; exit 1;
  }
}

assert_installed_for_user() {
  local user="$1" dir="/storage/emulated/$1/Android/data/org.example.dev/files/playtest"
  grep -Fxq "adb -s synthetic-device shell cmd package path --user $user org.example.dev" "$calls"
  grep -Eq "^adb -s synthetic-device push .* $dir/\.playtest-enroll\." "$calls"
  grep -Fq " $dir/playtest.json" "$calls"
  jq -e '.uploadKey == env.test_key' "$remote_files/playtest.json" >/dev/null
  assert_no_staging_file
}

assert_in_app() {
  grep -Eq ' reverse --no-rebind tcp:[0-9]+ tcp:[0-9]+$' "$calls"
  grep -Eq ' reverse --remove tcp:[0-9]+$' "$calls"
  ! grep -Eq '^adb .* (mkdir|push|mv) ' "$calls" || exit 1
  grep -qx previous "$remote_files/playtest.json"
}

printf 'previous\n' > "$remote_files/playtest.json"
active_user=10 run 0
assert_in_app
grep -q 'delivered to the app' "$work/out"

active_user=10 run 0 --user 10 --launch
assert_in_app
grep -q 'recorder confirmed on' "$work/out"

run 0 --in-app
assert_in_app

active_user=10 start_rc=1 run 1
assert_in_app
grep -q 'could not launch' "$work/err"

failed=0
for fixture in no_pid blocked no_relay stalled_start; do
  case "$fixture" in
    no_pid) expected=3; message='app process did not appear for the selected Android user' ;;
    blocked) expected=2; message='the headset blocked the app launch (an OS dialog is showing or the headset is not worn): put the headset on, dismiss any system dialog, and retry.' ;;
    no_relay) expected=4; message='did not receive the configuration from the enrollment relay' ;;
    stalled_start) expected=1; message='in-app enrollment timed out waiting for adb' ;;
  esac
  active_user=10 launch_case="$fixture" run "$expected" || failed=1
  assert_in_app
  [[ -s "$relay_pid_file" ]]
  if ! grep -Fq "$message" "$work/err"; then
    printf 'FAIL: %s: missing fixed diagnostic\n' "$fixture" >&2
    failed=1
  fi
done
[[ "$failed" == 0 ]]

active_user=10 active_user_after_reverse=0 run 1
assert_in_app
grep -q 'foreground Android user changed' "$work/err"
! grep -q 'shell am start' "$calls" || exit 1

active_user=10 user_rc_after_reverse=1 run 1
assert_in_app
grep -q 'could not re-check the foreground Android user' "$work/err"
! grep -q 'shell am start' "$calls" || exit 1

active_user=10 component='other.package/.Launcher' run 1
assert_in_app
grep -q 'launcher activity' "$work/err"
! grep -q 'shell am start' "$calls" || exit 1

active_user=10 reverse_rc=1 run 1
grep -q 'could not set up adb reverse' "$work/err"
! grep -Eq 'shell am start|reverse --remove' "$calls" || exit 1

run 1 --user 10
no_exchange
grep -q 'must be the foreground Android user' "$work/err"

run 1 --user not-a-number
no_exchange
grep -q -- '--user must be a numeric Android user ID' "$work/err"

active_user=unknown run 1
no_exchange
grep -q 'current Android user' "$work/err"

user_rc=1 run 1
no_exchange
grep -q 'current Android user' "$work/err"

printf 'previous\n' > "$remote_files/playtest.json"
active_user_after_push=10 run 1
grep -q 'foreground Android user changed' "$work/err"
grep -qx previous "$remote_files/playtest.json"
! grep -q 'shell mv ' "$calls" || exit 1
grep -Fq 'shell rm -f /storage/emulated/0/' "$calls"
assert_no_staging_file

user_rc_after_push=1 run 1
grep -q 'could not re-check the foreground Android user' "$work/err"
grep -qx previous "$remote_files/playtest.json"
! grep -q 'shell mv ' "$calls" || exit 1
assert_no_staging_file

mkdir_rc=1 run 1
grep -q 'unlocked and in the foreground, or switch to the primary' "$work/err"
! grep -Eq '^adb .* (push|mv) ' "$calls" || exit 1

# A failed transfer may leave a partial file, but must not replace the live one.
push_rc=1 run 1
if ! grep -qx previous "$remote_files/playtest.json"; then
  echo 'FAIL: a failed transfer replaced the live configuration' >&2
  exit 1
fi
grep -q 'adb push failed.*unlocked and in the foreground, or switch to the primary' "$work/err"
! grep -q 'shell mv ' "$calls" || exit 1
assert_no_staging_file
first_stage="$(awk '/ push / {print $NF}' "$calls")"

rename_rc=1 run 1
grep -q 'could not replace' "$work/err"
grep -qx previous "$remote_files/playtest.json"
! grep -q 'configuration installed' "$work/out" || exit 1
assert_no_staging_file
second_stage="$(awk '/ push / {print $NF}' "$calls")"
[[ "$second_stage" != "$first_stage" ]]

run 0 --launch
grep -q 'recorder confirmed on' "$work/out"
grep -q 'wrangler secret delete ENROLL_CODE' "$work/out"
third_stage="$(awk '/ push / {print $NF}' "$calls")"
[[ "$third_stage" != "$first_stage" && "$third_stage" != "$second_stage" ]]
assert_installed_for_user 0

status=403 run 1
grep -q '403' "$work/err"
! grep -Eq '^adb .* (mkdir|push) ' "$calls" || exit 1

printf '{"quest":{"package":"org.example.wrong"}}\n' > "$work/yetikit.json"
run 1
grep -q 'applicationId.*not installed' "$work/err"
! grep -Eq '^curl$|^adb .* (mkdir|push) ' "$calls" || exit 1

printf 'playtest enrollment tests passed\n'

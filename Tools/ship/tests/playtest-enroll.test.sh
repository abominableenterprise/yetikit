#!/usr/bin/env bash
set -euo pipefail

ship="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
umask 077
mkdir "$work/bin" "$work/tmp"
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp" PROJECT="$work"
export calls="$work/calls" failure="$work/fake-failed" remote_files="$work/device"
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
    printf '%s\r\n' "$expected_user"
    exit "${user_rc:-0}" ;;
  "shell cmd package path --user $expected_user org.example.dev")
    printf 'package:/data/app/base.apk\n' ;;
  'shell cmd package path --user 0 org.example.wrong') exit 0 ;; # no package, even with exit 0
  "shell mkdir -p $remote"|"shell mkdir -p $legacy")
    printf '%s\n' "$test_key" >&2
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
  'shell date +%s.%N') printf '1700000000.321987654\n' ;;
  "shell am start --user $expected_user -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p org.example.dev")
    printf 'Status: ok\n' ;;
  'shell pidof -s org.example.dev') printf '123\n' ;; # unscoped PID lookup finds the primary user
  'shell ps -A -o UID,PID,NAME')
    printf 'UID PID NAME\n10123 123 org.example.dev\n1010123 456 org.example.dev\n' ;;
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
  bash -x "$ship/playtest-enroll.sh" --endpoint https://enroll.example.invalid/ \
    --code "$work/private code" --player fixture-player "$@" > "$work/out" 2> "$work/err" || rc=$?
  if grep -Fq -e "$test_key" -e "$test_code" "$work/out" "$work/err"; then
    echo 'FAIL: credential printed' >&2
    exit 1
  fi
  [[ ! -e "$failure" ]]
  if [[ "$rc" != "$expected" ]]; then
    printf 'FAIL: foreground user %s: expected exit %s, got %s\n' "${active_user-0}" "$expected" "$rc" >&2
    grep '^\[playtest-enroll\]' "$work/err" >&2 || true
    exit 1
  fi
  [[ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]] || { echo 'FAIL: temp files left behind' >&2; exit 1; }
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

printf 'previous\n' > "$remote_files/playtest.json"
active_user=10 run 0
assert_installed_for_user 10

printf 'previous\n' > "$remote_files/playtest.json"
active_user=10 run 0 --user 10 --launch
assert_installed_for_user 10
grep -q 'recorder confirmed on' "$work/out"

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
active_user=10 active_user_after_push=0 run 1
grep -q 'foreground Android user changed' "$work/err"
grep -qx previous "$remote_files/playtest.json"
! grep -q 'shell mv ' "$calls" || exit 1
grep -Fq 'shell rm -f /storage/emulated/10/' "$calls"
assert_no_staging_file

active_user=10 user_rc_after_push=1 run 1
grep -q 'could not re-check the foreground Android user' "$work/err"
grep -qx previous "$remote_files/playtest.json"
! grep -q 'shell mv ' "$calls" || exit 1
assert_no_staging_file

active_user=10 mkdir_rc=1 run 1
grep -q 'unlocked and in the foreground, or switch to the primary' "$work/err"
! grep -Eq '^adb .* (push|mv) ' "$calls" || exit 1

# A failed transfer may leave a partial file, but must not replace the live one.
active_user=10 push_rc=1 run 1
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

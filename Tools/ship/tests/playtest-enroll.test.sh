#!/usr/bin/env bash
set -euo pipefail

ship="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
umask 077
mkdir "$work/bin" "$work/tmp"
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp" PROJECT="$work"
export calls="$work/calls" failure="$work/fake-failed"
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
case "$*" in
  'shell cmd package path --user current org.example.dev') printf 'package:/data/app/base.apk\n' ;;
  'shell cmd package path --user current org.example.wrong') exit 0 ;; # no package, even with exit 0
  'shell mkdir -p /sdcard/Android/data/org.example.dev/files/playtest') ;;
  'push '*)
    check test "$(stat -c %a "$2")" = 600
    check test "$3" = /sdcard/Android/data/org.example.dev/files/playtest/playtest.json
    check jq -e '. == {endpoint:"https://inbox.example.invalid", uploadKey:env.test_key, player:"fixture-player"}' "$2" >&2
    printf '%s\n' "$test_key"
    printf '%s\n' "$test_key" >&2
    exit "${push_rc:-0}" ;;
  'shell date +%s.%N') printf '1700000000.321987654\n' ;;
  'shell am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p org.example.dev')
    printf 'Status: ok\n' ;;
  'shell pidof -s org.example.dev') printf '123\n' ;;
  'logcat -d -T 1700000000.321 --pid=123 -v raw -s Unity:V')
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
  [[ "$rc" == "$expected" ]] || { printf 'FAIL: expected exit %s, got %s\n' "$expected" "$rc" >&2; exit 1; }
  [[ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]] || { echo 'FAIL: temp files left behind' >&2; exit 1; }
}

run 0 --launch
grep -q 'recorder confirmed on' "$work/out"
grep -q 'wrangler secret delete ENROLL_CODE' "$work/out"

push_rc=1 run 1
grep -q 'adb push failed' "$work/err"

status=403 run 1
grep -q '403' "$work/err"
! grep -Eq '^adb .* (mkdir|push) ' "$calls" || exit 1

printf '{"quest":{"package":"org.example.wrong"}}\n' > "$work/yetikit.json"
run 1
grep -q 'applicationId.*not installed' "$work/err"
! grep -Eq '^curl$|^adb .* (mkdir|push) ' "$calls" || exit 1

printf 'playtest enrollment tests passed\n'

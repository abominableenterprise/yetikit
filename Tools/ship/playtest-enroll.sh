#!/usr/bin/env bash
# Disable tracing before reading either credential, even under bash -x.
set +x +v +a
set -euo pipefail

fail() { printf '[playtest-enroll] %s\n' "$1" >&2; exit 1; }
usage() {
  printf 'Usage: playtest-enroll.sh --endpoint <Worker HTTPS origin> --code <private file> [--player <tag>] [--user N] [--in-app] [--launch]\n'
  printf '%s\n' 'Targets the foreground Android user. In-app enrollment was verified on a real headset with a secondary user.'
  printf '%s\n' 'If enrollment fails, switch to the primary profile (user 0) and retry without --in-app.'
  printf '%s\n' 'To relaunch for a specific user: adb shell am start --user N -n <activity> (monkey rejects --user on the verified headset OS).'
  printf '%s\n' 'Check the YetiKitPlaytest: config line in Unity logcat to confirm which config loaded.'
}

endpoint='' code_file='' player=test-device launch=0 requested_user='' in_app=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint|--code|--player|--user)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a value"
      case "$1" in
        --endpoint) endpoint="$2" ;;
        --code) code_file="$2" ;;
        --player) player="$2" ;;
        --user)
          [[ "$2" =~ ^0*([0-9]+)$ ]] || fail '--user must be a numeric Android user ID'
          requested_user="${BASH_REMATCH[1]}" ;;
      esac
      shift ;;
    --in-app) in_app=1 ;;
    --launch) launch=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail 'unknown argument' ;;
  esac
  shift
done

export LC_ALL=C
origin='https://([A-Za-z0-9.-]+|\[[A-Fa-f0-9:]+\])(:[0-9]+)?/?'
[[ "$endpoint" =~ ^$origin$ ]] || fail '--endpoint must be an HTTPS origin without credentials, path, query or fragment'
[[ "$player" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,115}$ ]] || fail '--player must be a 1-116 character tag using letters, digits, dots, underscores or hyphens, starting with a letter or digit'
[[ -f "$code_file" && -r "$code_file" ]] || fail '--code must name a readable private file'
mode="$(stat -L -c %a -- "$code_file" 2>/dev/null || stat -L -f %Lp -- "$code_file" 2>/dev/null)" \
  || fail 'cannot check enrollment code file permissions'
[[ "$mode" =~ ^[0-7]+00$ ]] || fail 'the enrollment code file must not be accessible to group or others (chmod 600)'

ship_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${YETIKIT_CONFIG:-${PROJECT:-$ship_dir/../..}/yetikit.json}"
for tool in curl jq adb; do command -v "$tool" >/dev/null || fail "$tool is required"; done
package="$(jq -ers '
  select(length == 1) | .[0].quest.package
  | strings | select(test("\\A[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+\\z"))
' "$config" 2>/dev/null)" || fail 'yetikit.json must set quest.package to a valid Android applicationId'

# Pin one transport so package verification and push cannot pick different devices.
serial="${QUEST_SERIAL:-${ANDROID_SERIAL:-}}"
if [[ -z "$serial" ]]; then
  serial="$(adb get-serialno 2>/dev/null)" || fail 'cannot select an adb device; connect one or set QUEST_SERIAL'
fi
serial_pattern='^[][A-Za-z0-9_.:-]+$'
[[ "$serial" =~ $serial_pattern && "$serial" != unknown ]] || fail 'expected one adb device serial'
device=(adb -s "$serial")
foreground_user() {
  local current
  current="$("${device[@]}" shell am get-current-user 2>/dev/null)" || return 1
  current="${current%$'\r'}"
  [[ "$current" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$current"
}
user="$(foreground_user)" || fail 'could not determine the current Android user'
[[ -z "$requested_user" || "$requested_user" == "$user" ]] \
  || fail '--user must be the foreground Android user so its app storage is mounted; switch to that profile and unlock it, then retry'
if [[ "$user" != 0 ]]; then in_app=1; fi
if [[ "$in_app" == 1 ]]; then
  command -v python3 >/dev/null || fail 'python3 is required for in-app enrollment'
fi
installed="$("${device[@]}" shell cmd package path --user "$user" "$package" 2>/dev/null)" \
  || fail 'could not verify that the configured applicationId (quest.package) is installed on the selected device'
[[ "$installed" == package:/* ]] || fail 'configured applicationId (quest.package) is not installed on the selected device'

umask 077
tmp='' remote_stage='' app_helper_pid=''
cleanup() {
  if [[ -n "$app_helper_pid" ]]; then
    kill "$app_helper_pid" 2>/dev/null || true
    wait "$app_helper_pid" 2>/dev/null || true
  fi
  if [[ -n "$remote_stage" ]]; then
    "${device[@]}" shell rm -f "$remote_stage" >/dev/null 2>&1 \
      || printf '[playtest-enroll] could not remove the staged device file; reconnect the device and check the playtest directory\n' >&2
  fi
  if [[ -n "$tmp" ]]; then
    rm -rf -- "$tmp" || fail 'could not remove private enrollment files'
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
tmp="$(mktemp -d "${TMPDIR:-/tmp}/playtest-enroll.XXXXXXXX")"
: > "$tmp/response"

# Keep the code out of env/argv and the response out of shell variables. Never
# relay curl, jq, adb or logcat diagnostics that could contain the credentials.
unset code
code=''
IFS= read -r code < "$code_file" || [[ -n "$code" ]] || fail 'the enrollment code file is empty or unreadable'
code="${code%$'\r'}"
[[ -n "$code" ]] || fail 'the enrollment code file is empty'
printf 'After the enrollment window, run: wrangler secret delete ENROLL_CODE\n'
status="$(printf '%s' "$code" | curl -q --silent --globoff --proto '=https' --max-time 20 \
  --get --data-urlencode 'code@-' --output "$tmp/response" --write-out '%{http_code}' \
  "${endpoint%/}/enroll" 2>/dev/null)" || fail 'could not reach the enrollment endpoint over HTTPS'
unset code
case "$status" in
  200) ;;
  403) fail 'enrollment refused (HTTP 403); check the private code and Worker secrets' ;;
  429) fail 'enrollment rate limited (HTTP 429); wait before trying again' ;;
  *) fail 'unexpected status from the enrollment endpoint (expected HTTP 200)' ;;
esac
if ! jq -es --arg player "$player" --arg origin "\A$origin\z" '
  select(length == 1) | .[0] | objects
  | select((.endpoint | strings | test($origin)) and (.uploadKey | strings | length > 0))
  | {endpoint, uploadKey, player: $player}
' "$tmp/response" > "$tmp/playtest.json" 2>/dev/null; then
  fail 'invalid enrollment response; expected an HTTPS endpoint and nonempty uploadKey'
fi
rm -f -- "$tmp/response"

recheck_user() {
  local current
  current="$(foreground_user)" || fail 'could not re-check the foreground Android user; retry with the intended profile active'
  [[ "$current" == "$user" ]] || fail 'the foreground Android user changed during enrollment; switch back to the intended profile and retry'
}

read_device_clock() {
  since="$("${device[@]}" shell date +%s.%N 2>/dev/null)" || fail 'could not read the device clock'
  [[ "$since" =~ ^([0-9]+\.[0-9]{3})[0-9]*$ ]] || fail 'unexpected device clock format'
  since="${BASH_REMATCH[1]}"
}

install_in_app() {
  local result=0
  # Use an interruptible shell wait so EXIT cleanup can forward signals to the helper.
  python3 "$ship_dir/playtest-enroll-app.py" "$serial" "$user" "$package" "$tmp" "$launch" &
  app_helper_pid=$!
  wait "$app_helper_pid" || result=$?
  app_helper_pid=''
  return "$result"
}

install_by_push() {
  # Pin storage to the preflight user and verify it is still active before publishing.
  local remote="/storage/emulated/$user/Android/data/$package/files/playtest"
  local storage_hint='make sure the selected profile is unlocked and in the foreground, or switch to the primary profile (user 0) and retry'
  "${device[@]}" shell mkdir -p "$remote" >/dev/null 2>&1 || fail "adb could not create the playtest directory; $storage_hint"
  remote_stage="$remote/.${tmp##*/}"
  "${device[@]}" push "$tmp/playtest.json" "$remote_stage" >/dev/null 2>&1 || fail "adb push failed; check device connectivity and $storage_hint"
  recheck_user
  "${device[@]}" shell mv -fT "$remote_stage" "$remote/playtest.json" >/dev/null 2>&1 || fail 'adb could not replace the playtest configuration'
  remote_stage=''
  rm -f -- "$tmp/playtest.json"
  printf 'Playtest configuration installed on the selected device.\n'
}

if [[ "$in_app" == 1 ]]; then
  install_in_app
  exit 0
fi
install_by_push

if [[ "$launch" == 1 ]]; then
  # Use the device clock and the selected app PID; do not clear or print logcat.
  read_device_clock
  started="$("${device[@]}" shell am start --user "$user" -W -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER -p "$package" 2>/dev/null)" || fail 'could not launch the configured app'
  [[ "$started" == *'Status: ok'* ]] || fail 'Android did not confirm launch of the configured app'
  for ((attempt = 0; attempt < 10; attempt++)); do
    # Android encodes the user in the UID (PER_USER_RANGE = 100000).
    # pidof has no user filter and could find the same app in another profile.
    if pid="$("${device[@]}" shell ps -A -o UID,PID,NAME 2>/dev/null | awk -v user="$user" -v package="$package" '
      !found && $1 ~ /^[0-9]+$/ && int($1 / 100000) == user && $3 == package { print $2; found = 1 }
    ')" && [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      # Drain the snapshot rather than closing the pipe early under pipefail.
      if "${device[@]}" logcat -d -T "$since" "--pid=$pid" -v raw -s Unity:V 2>/dev/null \
        | grep -E '^Playtest recorder on([[:space:][:punct:]]|$)' >/dev/null; then
        printf 'Playtest recorder confirmed on.\n'
        exit 0
      fi
    fi
    [[ "$attempt" == 9 ]] || sleep 1
  done
  fail 'configuration installed, but no fresh Playtest recorder on line was found; check the development build and launch it from a stopped state'
fi

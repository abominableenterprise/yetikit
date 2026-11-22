#!/usr/bin/env bash
# Disable tracing before reading either credential, even under bash -x.
set +x +v +a
set -euo pipefail

fail() { printf '[playtest-enroll] %s\n' "$1" >&2; exit 1; }
usage() {
  printf 'Usage: playtest-enroll.sh --endpoint <Worker HTTPS origin> --code <private file> [--player <tag>] [--launch]\n'
}

endpoint='' code_file='' player=test-device launch=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint|--code|--player)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a value"
      case "$1" in
        --endpoint) endpoint="$2" ;;
        --code) code_file="$2" ;;
        --player) player="$2" ;;
      esac
      shift ;;
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
user="$("${device[@]}" shell am get-current-user 2>/dev/null)" || fail 'could not determine the current Android user'
user="${user%$'\r'}"
[[ "$user" =~ ^[0-9]+$ ]] || fail 'could not determine the current Android user'
[[ "$user" == 0 ]] || fail 'enrollment only supports the primary Android user (0); switch to it and retry'
installed="$("${device[@]}" shell cmd package path --user 0 "$package" 2>/dev/null)" \
  || fail 'could not verify that the configured applicationId (quest.package) is installed on the selected device'
[[ "$installed" == package:/* ]] || fail 'configured applicationId (quest.package) is not installed on the selected device'

umask 077
tmp='' remote_stage=''
cleanup() {
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

# Pin storage to user 0 too, even if the foreground user changes after preflight.
remote="/storage/emulated/0/Android/data/$package/files/playtest"
"${device[@]}" shell mkdir -p "$remote" >/dev/null 2>&1 || fail 'adb could not create the playtest directory'
remote_stage="$remote/.${tmp##*/}"
"${device[@]}" push "$tmp/playtest.json" "$remote_stage" >/dev/null 2>&1 || fail 'adb push failed; check device connectivity and app storage access'
"${device[@]}" shell mv -fT "$remote_stage" "$remote/playtest.json" >/dev/null 2>&1 || fail 'adb could not replace the playtest configuration'
remote_stage=''
rm -f -- "$tmp/playtest.json"
printf 'Playtest configuration installed on the selected device.\n'

if [[ "$launch" == 1 ]]; then
  # Use the device clock and the selected app PID; do not clear or print logcat.
  since="$("${device[@]}" shell date +%s.%N 2>/dev/null)" || fail 'could not read the device clock'
  [[ "$since" =~ ^([0-9]+\.[0-9]{3})[0-9]*$ ]] || fail 'unexpected device clock format'
  since="${BASH_REMATCH[1]}"
  started="$("${device[@]}" shell am start --user 0 -W -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER -p "$package" 2>/dev/null)" || fail 'could not launch the configured app'
  [[ "$started" == *'Status: ok'* ]] || fail 'Android did not confirm launch of the configured app'
  for ((attempt = 0; attempt < 10; attempt++)); do
    if pid="$("${device[@]}" shell pidof -s "$package" 2>/dev/null)" && [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
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

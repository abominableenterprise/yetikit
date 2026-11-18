#!/usr/bin/env bash
# Exercise both sides of the cross-UID /proc visibility boundary without real sudo.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/fixture.sh"
tmp="$(mktemp -d)"
finish() {
  if [ -n "${foreign:-}" ]; then kill "$foreign" 2>/dev/null || true; wait "$foreign" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap finish EXIT
ship_fixture "$tmp/project"
export UNITY_ROOT="$tmp/unity" SHM_DIR="$tmp/shm"
mkdir -p "$SHM_DIR" "$PROJECT/Temp"
. "$script"
/bin/sleep 300 & foreign=$!
export foreign UNITY_ROOT
partial="$tmp/partial/Editor"
mkdir -p "$partial/Data/Tools" "$partial/Data/Resources/Licensing/Client"
cp /usr/bin/sleep "$partial/Data/Resources/Licensing/Client/Unity.Licensing.Client"
export partial

# Host processes are outside the fixture's view. The synthetic foreign process
# is unreadable as UID 1001. Privileged inspection may or may not resolve it.
readlink() {
  case "$1" in
    "/proc/$foreign/exe")
      if [ "$view" != clear ]; then
        [ "${privileged:-0}" = 1 ] && [ "$view" != unknown ] || return 1
      fi
      case "$view" in
        editor) printf '%s/Editor/Unity\n' "$UNITY_ROOT" ;;
        deleted-helper) printf '/fixture/removed/Editor/Worker (deleted)\n' ;;
        partial-install) printf '%s/Data/Tools/Helper\n' "$partial" ;;
        *) printf '/fixture/system-daemon\n' ;;
      esac ;;
    *) printf '/fixture/host-process\n' ;;
  esac
}
export -f readlink
id() { [ "$1" = -u ] && printf '%s\n' "$runner_uid"; }
sudo() {
  # Never use real sudo. The mock rejects any attempt to prompt or to elevate deletion.
  [ "$1" = -n ] && [ "$2" = -- ] && [ "$view" != no-sudo ] || return 1
  shift 2
  [ "$1" = env ] || return 1
  privileged=1 "$@"
}
stat() {
  local path="${@: -1}"
  case "$path" in
    *-foreign|*/UnityLockfile)
      [ "$file_uid" != unknown ] && printf '%s\n' "$file_uid" ;;
    *) printf '%s\n' "$runner_uid" ;;
  esac
}

owned=("$SHM_DIR/udsMem-owned" "$SHM_DIR/sem.udsMem-owned")
other=("$SHM_DIR/udsMem-foreign" "$SHM_DIR/sem.udsMem-foreign")
lock="$PROJECT/Temp/UnityLockfile"
failures=0
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label" >&2; failures=$((failures + 1)); fi
}
run_wipe() {
  touch "${owned[@]}" "${other[@]}" "$lock"
  (trap - EXIT; lock_unity; wipe_unity_shared_files) 2>"$tmp/log"
}
all_retained() {
  local path
  for path in "${owned[@]}" "${other[@]}" "$lock"; do [ -f "$path" ] || return 1; done
}
owned_removed() { [ ! -e "${owned[0]}" ] && [ ! -e "${owned[1]}" ]; }
foreign_retained() { [ -f "${other[0]}" ] && [ -f "${other[1]}" ] && [ -f "$lock" ]; }
incomplete_warning() { grep -q 'inspection incomplete.*skipping shared-memory and UnityLockfile cleanup' "$tmp/log"; }
export view=daemon
runner_uid=1001; file_uid=1001
run_wipe
check 'unrelated unreadable daemon: runner-owned shared files are wiped' owned_removed
check 'unrelated unreadable daemon: runner-owned lockfile is wiped' test ! -e "$lock"
file_uid=2001
run_wipe
check 'mixed ownership: runner-owned shared files are still wiped' owned_removed
check 'mixed ownership: foreign shared memory, semaphore and lockfile survive' foreign_retained
view=clear
run_wipe
check 'complete non-root scan: resources owned by another UID survive' foreign_retained
check 'complete non-root scan: ownership warning explains retention' grep -q 'not verified as owned by UID 1001' "$tmp/log"
file_uid=unknown
run_wipe
check 'failed owner lookup: unverified resources survive' foreign_retained
check 'failed owner lookup: verified resources are still wiped' owned_removed
file_uid=1001
for view in unknown no-sudo editor deleted-helper partial-install; do
  run_wipe
  check "$view: all shared files survive" all_retained
  if [ "$view" = editor ] || [ "$view" = partial-install ]; then
    check "$view: foreign process is reported" grep -q 'Unity processes remain' "$tmp/log"
  else
    check "$view: incomplete inspection warns" incomplete_warning
  fi
done
view=daemon; runner_uid=0; file_uid=0
run_wipe
check 'root with unreadable executable: all shared files survive' all_retained
check 'root with unreadable executable: incomplete inspection warns' incomplete_warning
view=clear; file_uid=2001
run_wipe
check 'complete root scan: resources owned by another UID survive' foreign_retained
check 'complete root scan: root-owned resources are wiped' owned_removed
[ "$failures" = 0 ]

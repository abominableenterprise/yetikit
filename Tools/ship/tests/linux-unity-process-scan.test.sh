#!/usr/bin/env bash
# Strict replacement scans support older kernels without a Kthread status field.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/fixture.sh"
tmp="$(mktemp -d)"
pids=()
finish() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap finish EXIT
ship_fixture "$tmp/project"
export UNITY_ROOT="$tmp/unity"
. "$script"

# Keep real /proc directories but model a foreign unreadable exe and its kernel data.
sleep 300 & foreign=$!; pids+=("$foreign")
sleep 300 & readable=$!; pids+=("$readable")
matched=0; own_unreadable=0
readlink() {
  [ "$1" != "/proc/$foreign/exe" ] || return 1
  if [ "$own_unreadable" = 1 ]; then
    case "$1" in "/proc/$$/exe"|"/proc/$BASHPID/exe") return 1 ;; esac
  fi
  if [ "$matched" = 1 ] && [ "$1" = "/proc/$readable/exe" ]; then
    printf '%s/Editor/Unity\n' "$UNITY_ROOT"
  else
    printf '/usr/bin/sleep\n'
  fi
}
cat() {
  case "$1" in
    "/proc/$foreign/status") printf 'Name:\tsynthetic\nState:\t%s (synthetic)\n%s' "$state" "$kthread" ;;
    "/proc/$foreign/stat")
      [ "$fixture_stat_readable" = 1 ] || return 1
      # flags is field 9, after a comm containing spaces and a closing parenthesis.
      printf '%s (synthetic ) thread) %s 0 0 0 0 0 %s 0\n' "$foreign" "$state" "$fixture_flags" ;;
    *) command cat "$@" ;;
  esac
}
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
state=S; kthread=''; fixture_stat_readable=1
fixture_flags=2097216 # PF_KTHREAD plus another flag; status has no Kthread field before Linux 6.0.
check 'older-kernel thread without Kthread status is exempt' 'unity_pids strict > "$tmp/pids" && [ ! -s "$tmp/pids" ]'
fixture_flags=64
check 'unreadable live userspace exe still refuses replacement' '! unity_pids strict'
matched=1
check 'strict scan prints matched PIDs even when incomplete' '! unity_pids strict > "$tmp/pids" && grep -qw "$readable" "$tmp/pids"'
check 'non-strict scan still skips unreadable processes' 'unity_pids > "$tmp/pids" && grep -qw "$readable" "$tmp/pids"'
matched=0
fixture_flags=2097152; fixture_stat_readable=0
check 'unreadable stat cannot establish a kernel thread' '! unity_pids strict'
fixture_stat_readable=1; fixture_flags=invalid
check 'malformed flags cannot establish a kernel thread' '! unity_pids strict'
state=Z
check 'zombie without an executable is exempt' 'unity_pids strict > "$tmp/pids" && [ ! -s "$tmp/pids" ]'
state=S; fixture_flags=64; kthread=$'Kthread:\t1\n'
check 'newer-kernel Kthread status remains supported' 'unity_pids strict > "$tmp/pids" && [ ! -s "$tmp/pids" ]'
own_unreadable=1
check 'own shell and scan processes are ignored' 'unity_pids strict > "$tmp/pids" && [ ! -s "$tmp/pids" ]'
[ "$fails" = 0 ]

#!/usr/bin/env bash
# Strict replacement scans support older kernels without a Kthread status field.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/fixture.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ship_fixture "$tmp/project"
export UNITY_ROOT="$tmp/unity"
. "$script"

# Keep real /proc directories but model one unreadable exe and its kernel data.
# All other processes are readable and outside the installation, independent of host kernel.
readlink() {
  [ "$1" != "/proc/$$/exe" ] || return 1
  printf '/usr/bin/sleep\n'
}
cat() {
  case "$1" in
    "/proc/$$/status") printf 'Name:\tsynthetic\nState:\t%s (synthetic)\n%s' "$state" "$kthread" ;;
    "/proc/$$/stat")
      [ "$stat_readable" = 1 ] || return 1
      # flags is field 9, after a comm containing spaces and a closing parenthesis.
      printf '%s (synthetic ) thread) %s 0 0 0 0 0 %s 0\n' "$$" "$state" "$flags" ;;
    *) command cat "$@" ;;
  esac
}
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
state=S; kthread=''; stat_readable=1
flags=2097216 # PF_KTHREAD plus another flag; status has no Kthread field before Linux 6.0.
check 'older-kernel thread without Kthread status is exempt' 'unity_pids strict > "$tmp/pids" && [ ! -s "$tmp/pids" ]'
flags=64
check 'unreadable live userspace exe still refuses replacement' '! unity_pids strict'
flags=2097152; stat_readable=0
check 'unreadable stat cannot establish a kernel thread' '! unity_pids strict'
stat_readable=1; flags=invalid
check 'malformed flags cannot establish a kernel thread' '! unity_pids strict'
state=Z
check 'zombie without an executable is exempt' 'unity_pids strict > "$tmp/pids" && [ ! -s "$tmp/pids" ]'
state=S; flags=64; kthread=$'Kthread:\t1\n'
check 'newer-kernel Kthread status remains supported' 'unity_pids strict > "$tmp/pids" && [ ! -s "$tmp/pids" ]'
[ "$fails" = 0 ]

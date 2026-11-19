#!/usr/bin/env bash
# test-all: android.sh
# Synthetic swap ownership and liveness probes; no editor, sudo, or real swap operations.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/android.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
fails=0

log() { printf '%s\n' "$*" >&2; }
kill() {
  case "$*" in
    '-0 9101') return 0 ;;
    '-0 9102') echo 'kill: (9102) - Operation not permitted' >&2 ;;
    '-0 9103'|'-0 9105'|'-0 9106'|'-0 9107'|'-0 9108') echo "kill: ($2) - No such process" >&2 ;;
    *) echo 'kill: probe unavailable' >&2 ;;
  esac
  return 1
}
as_root() {
  local op="$1" path="${*: -1}" target
  if [ "$op" = dd ]; then path="${path#of=}"; fi
  target="$(realpath -m -- "$path")" || return 98
  case "$target" in "$tmp"/*) ;; *) return 98 ;; esac
  printf '%s %s\n' "$op" "$path" >> "$tmp/calls"
  case "$op" in
    fallocate) printf 'fake swap\n' > "$path" ;;
    swapoff) return "${fake_swapoff_rc:-0}" ;;
    mkswap|swapon) : ;;
    mktemp)
      local dir
      dir="$(command "$@")" || return
      if [ "${fake_collision:-0}" = 1 ]; then ln -s -- "$tmp/sentinel" "$dir/linux-unity-apk.swapfile" || return; fi
      if [ -n "${fake_dir_mode:-}" ]; then chmod -- "$fake_dir_mode" "$dir" || return; fi
      printf '%s\n' "$dir" ;;
    rm|rmdir|stat|dd) command "$@" ;;
    *) return 98 ;;
  esac
}
check() {
  local label="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$label"; else printf 'FAIL %s\n' "$label"; fails=$((fails + 1)); fi
}

liveness() (
  APK_SWAP_DIR="$tmp/liveness"
  mkdir -m 700 -- "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  local prefix="$APK_SWAP_DIR/linux-unity-apk.swap" pid
  for pid in 9101 9102 9103 9104; do
    (umask 077; : > "$prefix.$pid") || return
  done
  apk_swap_reclaim &&
    [ -f "$prefix.9101" ] && [ -f "$prefix.9102" ] && [ -f "$prefix.9104" ] &&
    [ ! -e "$prefix.9103" ] && grep -Fxq "swapoff $prefix.9103" "$tmp/calls" &&
    ! grep -Eq '\.910[124]$' "$tmp/calls"
)
check 'reclaim only an absent PID, not live, permission-denied, or unknown owners' liveness

creation_collision() (
  local kind="$1" sentinel="$tmp/$1-sentinel" path
  APK_SWAP_DIR="$tmp/create-$kind"; APK_SWAPFILE=""
  mkdir -m 700 -- "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  path="$APK_SWAP_DIR/linux-unity-apk.swap.$$"
  printf 'keep\n' > "$sentinel" || return
  case "$kind" in
    symlink) ln -s -- "$sentinel" "$path" ;;
    hardlink) ln -- "$sentinel" "$path" ;;
    regular) cp -- "$sentinel" "$path" ;;
  esac || return
  apk_swap_on 1 && apk_swap_off &&
    [ "$(<"$sentinel")" = keep ] && [ "$(<"$path")" = keep ] &&
    ! cut -d ' ' -f 2- "$tmp/calls" | grep -Fxq -- "$path"
)
for kind in symlink hardlink regular; do
  check "creation never modifies a pre-existing $kind at the old PID path" creation_collision "$kind"
done

reclaim_paths() (
  APK_SWAP_DIR="$tmp/reclaim"
  local sentinel="$tmp/reclaim-sentinel" prefix="$APK_SWAP_DIR/linux-unity-apk.swap"
  mkdir -m 700 -- "$APK_SWAP_DIR" && : > "$tmp/calls" && printf 'keep\n' > "$sentinel" &&
    ln -s -- "$sentinel" "$prefix.9105" && ln -- "$sentinel" "$prefix.9106" &&
    mkfifo -- "$prefix.9107" && mkdir -- "$prefix.9108" &&
    (umask 077; : > "$prefix.invalid") || return
  apk_swap_reclaim &&
    [ -L "$prefix.9105" ] && [ "$prefix.9106" -ef "$sentinel" ] &&
    [ -p "$prefix.9107" ] && [ -d "$prefix.9108" ] && [ -f "$prefix.invalid" ] &&
    [ "$(<"$sentinel")" = keep ] && [ ! -s "$tmp/calls" ]
)
check 'reclaim ignores symlinks, hard links, non-files, and malformed PIDs' reclaim_paths

symlink_directory() (
  local dir="$tmp/real-swap-dir"
  APK_SWAP_DIR="$tmp/linked-swap-dir"; APK_SWAPFILE=""
  mkdir -m 700 -- "$dir" && ln -s -- "$dir" "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  (umask 077; : > "$dir/linux-unity-apk.swap.9103") || return
  apk_swap_reclaim && apk_swap_on 1 && apk_swap_off &&
    [ -f "$dir/linux-unity-apk.swap.9103" ] && [ ! -s "$tmp/calls" ]
)
check 'neither creation nor reclaim follows a symlink swap directory' symlink_directory

writable_directory() (
  local parent="$tmp/writable-swap-dir"
  APK_SWAP_DIR="$parent/private"; APK_SWAPFILE=""
  mkdir -m 777 -- "$parent" && mkdir -m 700 -- "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  (umask 077; : > "$APK_SWAP_DIR/linux-unity-apk.swap.9103") || return
  apk_swap_reclaim && apk_swap_on 1 && apk_swap_off &&
    [ -f "$APK_SWAP_DIR/linux-unity-apk.swap.9103" ] && [ ! -s "$tmp/calls" ]
)
check 'a private leaf does not make a shared writable non-sticky ancestor safe' writable_directory

failed_swapoff() (
  APK_SWAP_DIR="$tmp/failed-swapoff"; fake_swapoff_rc=7
  mkdir -m 700 -- "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  local legacy="$APK_SWAP_DIR/linux-unity-apk.swap.9103" dir="$APK_SWAP_DIR/linux-unity-apk.swapdir.A1b2C3d4E5.9103" fresh rc=0
  fresh="$dir/linux-unity-apk.swapfile"
  APK_SWAPFILE="$APK_SWAP_DIR/linux-unity-apk.swapdir.F1g2H3j4K5.$$/linux-unity-apk.swapfile"
  mkdir -m 700 -- "$dir" "${APK_SWAPFILE%/*}" || return
  (umask 077; touch -- "$legacy" "$fresh" "$APK_SWAPFILE") || return
  # Fake the kernel table, not the inactive check. Use a synthetic active path and a distinct inactive file.
  cat() {
    [[ "$*" == /proc/swaps ]] || return 98
    printf 'Filename Type Size Used Priority\n%s file 100 0 -2\n%s file 100 0 -3\n' "$legacy" "$APK_SWAPFILE"
  }
  apk_swap_off || rc=$?
  [ "$rc" = 7 ] && apk_swap_reclaim &&
    [ -f "$legacy" ] && [ -f "$APK_SWAPFILE" ] && [ ! -e "$dir" ] &&
    grep -Fxq "swapoff $legacy" "$tmp/calls" && grep -Fxq "swapoff $fresh" "$tmp/calls" &&
    [ "$(grep '^rm ' "$tmp/calls")" = "rm $fresh" ]
)
check 'failed swapoff preserves active legacy and current files; inactive new-layout files are reclaimed' failed_swapoff

private_collision() (
  APK_SWAP_DIR="$tmp/private-collision"; APK_SWAPFILE=""; fake_collision=1
  mkdir -m 700 -- "$APK_SWAP_DIR" && : > "$tmp/calls" && printf 'keep\n' > "$tmp/sentinel" || return
  apk_swap_on 1 && [ -z "$APK_SWAPFILE" ] && [ "$(<"$tmp/sentinel")" = keep ] &&
    ! grep -Eq '^(fallocate|mkswap|swapon|rm) ' "$tmp/calls"
)
check 'exclusive file creation refuses a pre-existing path even within the private directory' private_collision

normal_swap() (
  APK_SWAP_DIR="$tmp/normal"; APK_SWAPFILE=""
  mkdir -m 1777 -- "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  apk_swap_on 1 &&
    [[ "$APK_SWAPFILE" == "$APK_SWAP_DIR/"* ]] && [ -f "$APK_SWAPFILE" ] &&
    [ "$(stat -c '%a:%h' -- "$APK_SWAPFILE")" = 600:1 ] &&
    [ "$(stat -c '%a' -- "${APK_SWAPFILE%/*}")" = 700 ] &&
    grep -Fxq "swapon $APK_SWAPFILE" "$tmp/calls" || return 1
  local path="$APK_SWAPFILE"
  apk_swap_off && [ ! -e "${path%/*}" ] && grep -Fxq "swapoff $path" "$tmp/calls"
)
check 'a sticky shared directory allows private swap creation and cleanup' normal_swap

setgid_swap() (
  APK_SWAP_DIR="$tmp/setgid"; APK_SWAPFILE=""
  local probe stale path mode
  mkdir -m 755 -- "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  if ! chmod g+s -- "$APK_SWAP_DIR"; then
    echo 'SKIP setgid swap: cannot set setgid on the swap parent'
    return 0
  fi
  probe="$(mktemp -d -- "$APK_SWAP_DIR/probe.XXXXXXXXXX")" || return
  mode="$(stat -c '%a' -- "$probe")" && rmdir -- "$probe" || return
  if [ "$mode" != 2700 ]; then
    printf 'SKIP setgid swap: mktemp inherited mode %s instead of 2700\n' "$mode"
    return 0
  fi
  apk_swap_on 1 && [ -n "$APK_SWAPFILE" ] && grep -Fxq "swapon $APK_SWAPFILE" "$tmp/calls" || return 1
  path="$APK_SWAPFILE"
  apk_swap_off && [ ! -e "${path%/*}" ] && grep -Fxq "swapoff $path" "$tmp/calls" || return 1

  stale="$APK_SWAP_DIR/linux-unity-apk.swapdir.S1t2A3l4E5.9103"
  mkdir -- "$stale" && chmod 2700 -- "$stale" && (umask 077; touch -- "$stale/linux-unity-apk.swapfile") || return
  apk_swap_reclaim && [ ! -e "$stale" ] && grep -Fxq "swapoff $stale/linux-unity-apk.swapfile" "$tmp/calls"
)
check 'a setgid parent allows private swap creation, cleanup, and reclamation' setgid_swap

insecure_allocation() (
  local fake_dir_mode="$1"
  APK_SWAP_DIR="$tmp/insecure-$fake_dir_mode"; APK_SWAPFILE=""
  mkdir -m 700 -- "$APK_SWAP_DIR" && : > "$tmp/calls" || return
  apk_swap_on 1 && [ -z "$APK_SWAPFILE" ] &&
    ! grep -Eq '^(dd|fallocate|mkswap|swapon) ' "$tmp/calls" &&
    [ -z "$(find "$APK_SWAP_DIR" -mindepth 1 -print -quit)" ]
)
for mode in 710 701; do
  check "a new swap directory with mode $mode is rejected and removed" insecure_allocation "$mode"
done

[ "$fails" = 0 ] || { printf '%s failed\n' "$fails"; exit 1; }

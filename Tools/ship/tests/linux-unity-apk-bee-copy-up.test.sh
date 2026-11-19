#!/usr/bin/env bash
# Run portably with a synthetic lower identity and real renames, or set
# BEE_OVERLAY_TEST=1 on a Linux VM with mount privileges to use overlayfs.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
. "$ship/lib/android.sh"
. "$ship/linux-unity-license.sh"
tmp="$(mktemp -d)"
upper="" lower=""
cleanup() {
  if [ -n "$upper" ]; then
    if mountpoint -q "$tmp/overlay"; then umount "$tmp/overlay" || return; fi
    rm -rf -- "$upper"
  fi
  if [ -n "$lower" ]; then rm -rf -- "$lower"; fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
if [ "${BEE_OVERLAY_TEST:-0}" = 1 ]; then
  # Distinct backing devices; /tmp itself may not support overlay upperdirs.
  upper="$(mktemp -d /dev/bee-overlay.XXXXXX)"
  lower="$(mktemp -d /dev/shm/bee-overlay.XXXXXX)"
  mkdir -- "$upper/upper" "$upper/work" "$tmp/overlay"
  [ "$(stat -c %d "$lower")" != "$(stat -c %d "$upper")" ]
fi

stat() {
  if [[ $# = 4 && "$1" = -c && "$2" = %d:%i && "$4" = "$bee" && -f "$PROJECT/lower" ]]; then
    printf '%s\n' '0:1'
  else
    command stat "$@"
  fi
}

touch() {
  command touch "$@" || return
  if [ "${@: -1}" = "$bee" ]; then rm -f -- "$PROJECT/lower"; fi
}

mv() {
  local from="${@: -2:1}"
  if [ "$from" = "$aside" ] && [ "$scenario" = occupied ] && [ ! -L "$bee" ]; then
    # Race the restore itself: a dangling symlink still counts as occupied.
    ln -s other-cache "$bee" || return
  fi
  command mv "$@" || return
  if [ "$from" = "$bee" ] && [ -L "$aside" ]; then
    rm -f -- "$PROJECT/lower"
    stat -c '%d:%i' -- "$aside" > "$PROJECT/moved-id"
    case "$scenario" in
      interrupted) kill -TERM "$BASHPID" ;;
      replaced-in-move) replace_aside ;;
    esac
  fi
}

replace_aside() {
  command mv -T -- "$aside" "$aside.original" || return
  if [ "$scenario" = replaced-dir ]; then mkdir "$aside"; else ln -s bee-cache "$aside"; fi
}

log() { printf '%s\n' "$*" >&2; }
cmd_cache() {
  # Relative to Temp the moved link dangles, but the entry must still exist.
  [ ! -e "$aside" ] && [ "$(readlink "$aside")" = bee-cache ] || return 1
  echo saved > "$PROJECT/saved"
  case "$scenario" in
    replaced-dir|replaced-link) replace_aside ;;
  esac
}

fails=0
scenarios=(normal interrupted replaced-dir replaced-link replaced-in-move occupied)
for scenario in "${scenarios[@]}"; do
  backing="$tmp/$scenario"
  if [ -n "$lower" ]; then backing="$lower/$scenario"; fi
  mkdir -p "$backing/Library/bee-cache" "$backing/Temp"
  ln -s bee-cache "$backing/Library/Bee"
  if [ -n "$lower" ]; then
    # An unindexed lower hardlink copies up as a new inode rather than
    # keeping the lower origin identity. Bee's target is still relative.
    ln -P "$backing/Library/Bee" "$backing/lower-peer"
  else
    : > "$backing/lower"
  fi
done
if [ -n "$lower" ]; then
  mount -t overlay overlay -o "lowerdir=$lower,upperdir=$upper/upper,workdir=$upper/work,xino=off,index=off" "$tmp/overlay"
  tmp_project="$tmp/overlay"
else
  tmp_project="$tmp"
fi
for scenario in "${scenarios[@]}"; do
  PROJECT="$tmp_project/$scenario"; bee="$PROJECT/Library/Bee"; aside="$PROJECT/Temp/apk-bee-aside"
  before="$(stat -c '%d:%i' -- "$bee")"
  rc=0
  (
    trap - EXIT
    APK_BEE_ID="" APK_CACHE_PID="" APK_CACHE_STARTING=0 APK_CACHE_SIGNAL=""
    chain_exit_trap apk_cache_cleanup
    trap 'apk_cache_interrupt 143' TERM
    apk_cache_save
  ) > "$PROJECT/log" 2>&1 || rc=$?
  verify() {
    local moved_id
    moved_id="$(< "$PROJECT/moved-id")" || return
    [ -n "$moved_id" ] && [ "$before" != "$moved_id" ] || return 1
    case "$scenario" in
      normal|interrupted)
        if [ "$scenario" = interrupted ]; then
          [ "$rc" = 143 ] && [ ! -e "$PROJECT/saved" ] || return 1
        else
          [ "$rc" = 0 ] && [ -f "$PROJECT/saved" ] || return 1
        fi
        [ -d "$bee" ] && [ "$(readlink "$bee")" = bee-cache ] &&
          [ "$(stat -c '%d:%i' -- "$bee")" = "$moved_id" ] && [ ! -L "$aside" ] && [ ! -e "$aside" ] ;;
      replaced-dir|replaced-link|replaced-in-move)
        [ "$rc" != 0 ] && grep -q 'refusing to restore an unexpected Bee aside' "$PROJECT/log" &&
          [ ! -L "$bee" ] && [ ! -e "$bee" ] &&
          [ "$(command stat -c '%d:%i' -- "$aside.original")" = "$moved_id" ] || return 1
        if [ "$scenario" = replaced-dir ]; then [ -d "$aside" ]; else [ "$(readlink "$aside")" = bee-cache ]; fi ;;
      occupied)
        [ "$rc" != 0 ] && [ "$(readlink "$bee")" = other-cache ] &&
          [ "$(stat -c '%d:%i' -- "$aside")" = "$moved_id" ] ;;
    esac
  }
  if verify; then
    echo "ok $scenario ($before -> $(< "$PROJECT/moved-id"))"
  else
    echo "FAIL $scenario (exit $rc; $before -> $(< "$PROJECT/moved-id"))" >&2
    cat "$PROJECT/log" >&2
    fails=$((fails + 1))
  fi
done
[ "$fails" = 0 ]

# shellcheck shell=bash
# Free space (whole GB) on the filesystem holding $1.
free_gb() { df -Pk -- "$1" | awk 'NR == 2 { print int($4 / 1048576) }'; }
# Total RAM and swap (whole GB, rounded down), from /proc/meminfo (MEMINFO overrides it in tests).
mem_gb() { awk -v k="$1" '$1 == k":" { print int($2 / 1048576) }' "${MEMINFO:-/proc/meminfo}"; }

# Require APK_MIN_FREE_GB free (APK_MIN_FREE_GB_WARM with Library/Bee/Android). Before restore, reserve
# space for the planned swapfile; after restore, df already accounts for it. Never start a build short on disk.
apk_disk_check() {
  local var=APK_MIN_FREE_GB need free stage="${2:-}"; free="$(free_gb "$PROJECT")"
  [ -d "$PROJECT/Library/Bee/Android" ] && var=APK_MIN_FREE_GB_WARM
  need=$((${!var} + ${1:-0}))
  [ "$free" -ge "$need" ] || die "apk: ${stage:+$stage: }only ${free} GB free on $(df -P "$PROJECT" | awk 'NR == 2 { print $6 }') (need ${need} GB: $var=${!var}${1:+ + ${1} GB swap}); free disk first (README.md: Android APK on Linux)"
  log "apk: ${stage:+$stage: }${free} GB free (need ${need} GB$([ "$var" = APK_MIN_FREE_GB ] || echo ", warm: Library/Bee/Android"))"
}

# The swapfile size apk adds (GB): APK_SWAP_GB on a VM with under APK_SWAP_BELOW_GB of RAM and no swap, else 0.
apk_swap_size() {
  [ "$APK_SWAP_GB" -gt 0 ] && [ "$(mem_gb MemTotal)" -lt "$APK_SWAP_BELOW_GB" ] && [ "$(mem_gb SwapTotal)" = 0 ] \
    && echo "$APK_SWAP_GB" || echo 0
}

# Trust only real directories owned by root or this user, with sticky protection
# wherever others can write (e.g. /var/tmp). Check ancestors too: a safe leaf can be replaced through its parent.
apk_swap_dir() {
  local dir="$APK_SWAP_DIR" path part meta owner mode
  [[ "/$dir/" != *'/../'* ]] || return 1
  dir="$(realpath -es -- "$dir")" || return 1
  local -a parts
  IFS=/ read -r -d '' -a parts < <(printf '%s\0' "$dir") || return 1
  path=""
  # Walk top-down so a checked component is already protected by its parent.
  for part in "${parts[@]}"; do
    path="${path%/}/$part"
    meta="$(stat -c '%u %f' -- "$path" 2>/dev/null)" || return 1
    read -r owner mode <<< "$meta"
    [[ "$owner" == 0 || "$owner" == "$EUID" ]] || return 1
    (( (16#$mode & 0170000) == 0040000 && (!(16#$mode & 0022) || (16#$mode & 01000)) )) || return 1
  done
  printf '%s\n' "$dir"
}

apk_swap_regular() {
  local meta owner links mode
  # lstat in one operation: never combine a path type check with metadata from a later entry.
  if [ "${2:-}" = private ]; then
    meta="$(as_root stat -c '%u %h %f' -- "$1" 2>/dev/null)" || return 1
  else
    meta="$(stat -c '%u %h %f' -- "$1" 2>/dev/null)" || return 1
  fi
  read -r owner links mode <<< "$meta"
  [[ "$links" == 1 && ( "$owner" == 0 || "$owner" == "$EUID" ) ]] || return 1
  (( (16#$mode & 0170000) == 0100000 && !(16#$mode & 0022) )) || return 1
  [ "${2:-}" != private ] || (( (16#$mode & 07777) == 0600 ))
}

apk_swap_private_dir() {
  local meta
  local owner mode
  meta="$(stat -c '%u %f' -- "$1" 2>/dev/null)" || return 1
  read -r owner mode <<< "$meta"
  [[ "$owner" == 0 || "$owner" == "$EUID" ]] && (( 16#$mode == (0040000 | 0700) ))
}

# Make both the private directory and its file exclusively. On some hosts the
# swap volume is root-owned, so allow sudo to allocate and inspect the file.
apk_swap_on() {
  local base dir f
  if ! base="$(apk_swap_dir)" ||
    ! dir="$(as_root mktemp -d --suffix=".$$" -- "${base%/}/linux-unity-apk.swapdir.XXXXXXXXXX")" ||
    ! apk_swap_private_dir "$dir"; then
    log "warning: could not create a safe swap directory in $APK_SWAP_DIR; building without swap"
    return 0
  fi
  f="$dir/linux-unity-apk.swapfile"
  if ! (umask 077; as_root dd if=/dev/null conv=excl status=none of="$f") ||
    ! apk_swap_regular "$f" private; then
    as_root rmdir -- "$dir" || :
    log "warning: could not create a safe swapfile in $dir; building without swap"
    return 0
  fi
  APK_SWAPFILE="$f"
  log "apk: adding a ${1} GB swapfile $f (removed on exit)"
  if ! as_root fallocate -l "${1}G" "$f"; then
    apk_swap_remove "$f" private && APK_SWAPFILE=""
    log "warning: could not create $f; building without swap"
    return 0
  fi
  as_root mkswap -q "$f" >/dev/null && as_root swapon "$f" \
    || log "warning: swapon $f failed; building without swap"
}

apk_swap_remove() {
  as_root rm -f -- "$1" || return "$?"
  [ "${2:-}" != private ] || as_root rmdir -- "${1%/*}"
}

# swapoff also fails for an inactive file. Unlink after a failure only if the
# kernel's swap table is readable and every entry can be ruled out, including aliases.
apk_swap_inactive() {
  local table active type size used priority rest
  table="$(cat /proc/swaps)" || return 1
  [[ "$table" == Filename[[:space:]]* ]] || return 1
  [[ "$table" == *$'\n'* ]] || return 0
  while read -r active type size used priority rest; do
    [[ "$active" == /* && -n "$priority" && -z "$rest" ]] || return 1
    printf -v active '%b' "${active//\\/\\0}" # /proc/swaps encodes path whitespace and backslashes as octal.
    [[ "$active" != "$1" && -e "$active" && ! "$active" -ef "$1" ]] || return 1
  done <<< "${table#*$'\n'}"
}

apk_swap_off() {
  [ -n "${APK_SWAPFILE:-}" ] || return 0
  local rc=0 rm_rc=0 layout=""
  if [[ "$APK_SWAPFILE" == */linux-unity-apk.swapfile ]]; then
    apk_swap_private_dir "${APK_SWAPFILE%/*}" || return 1
    layout=private
  fi
  if ! apk_swap_regular "$APK_SWAPFILE" "$layout"; then
    log "warning: refusing to clean an unexpected swap path $APK_SWAPFILE"
    return 1
  fi
  if as_root swapoff "$APK_SWAPFILE" 2>/dev/null; then :; else
    rc=$?
    if ! apk_swap_inactive "$APK_SWAPFILE"; then
      log "warning: swapoff $APK_SWAPFILE failed; keeping the swapfile"
      return "$rc"
    fi
  fi
  apk_swap_remove "$APK_SWAPFILE" "$layout" || rm_rc=$?
  if [ "$rm_rc" = 0 ]; then log "apk: removed swapfile $APK_SWAPFILE"; APK_SWAPFILE=""; fi
  [ "$rc" != 0 ] || rc=$rm_rc
  return "$rc"
}
# GNU mv -n can report success without moving anything. Check that the source
# disappeared, and never move into a destination directory or replace it.
apk_bee_move() {
  mv -nT -- "$1" "$2" || return "$?"
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

apk_bee_restore() {
  local aside="$PROJECT/Temp/apk-bee-aside" identity
  [ -n "$APK_BEE_ID" ] && [ -d "$aside" ] || return 0
  identity="$(stat -c '%d:%i' -- "$aside")" || return "$?"
  # If move-out failed and another aside appeared, it isn't ours to restore.
  [ "$identity" = "$APK_BEE_ID" ] || return 0
  apk_bee_move "$aside" "$PROJECT/Library/Bee" || {
    local rc=$?
    log "error: could not restore Library/Bee; recover it from $aside"
    return "$rc"
  }
  APK_BEE_ID=""
}

apk_cache_interrupt() {
  # Don't exit in the gap between starting the cache job and recording its PID.
  if [ "$APK_CACHE_STARTING" = 1 ]; then APK_CACHE_SIGNAL="$1"; else exit "$1"; fi
}

apk_cache_cleanup() {
  if [ -n "$APK_CACHE_PID" ]; then
    # The save (including its tar/upload children) runs in its own process
    # group. Stop it before putting Bee back into the tree it was reading.
    kill -KILL -- "-$APK_CACHE_PID" 2>/dev/null || :
    wait "$APK_CACHE_PID" 2>/dev/null || :
  fi
  apk_bee_restore
}

# Save the cache without ~7 GB of Bee intermediates. Keep it on the project
# filesystem so moving it aside and back doesn't copy those files.
apk_cache_save() {
  local bee="$PROJECT/Library/Bee" aside="$PROJECT/Temp/apk-bee-aside" save_rc=0 monitor=0 temp_device
  if [ -e "$aside" ] || [ -L "$aside" ]; then
    log "error: refusing to overwrite existing Bee aside $aside"
    return 1
  fi
  if [ -d "$bee" ]; then
    mkdir -p -- "$PROJECT/Temp" || return
    # Only an atomic rename preserves Bee's identity across cancellation.
    temp_device="$(stat -Lc '%d' -- "$PROJECT/Temp")" || return
    APK_BEE_ID="$(stat -c '%d:%i' -- "$bee")" || return
    if [ "${APK_BEE_ID%%:*}" != "$temp_device" ]; then
      log "error: Library/Bee and Temp are on different filesystems; not moving Bee"
      return 1
    fi
    apk_bee_move "$bee" "$aside" || {
      local rc=$?
      log "error: could not move Library/Bee aside to $aside"
      return "$rc"
    }
  fi
  APK_CACHE_STARTING=1
  if [[ $- != *m* ]]; then set -m; monitor=1; fi
  cmd_cache save android &
  APK_CACHE_PID=$!
  if [ "$monitor" = 1 ]; then set +m; fi
  APK_CACHE_STARTING=0
  [ -z "$APK_CACHE_SIGNAL" ] || exit "$APK_CACHE_SIGNAL"
  wait "$APK_CACHE_PID" || save_rc=$?
  APK_CACHE_PID=""
  apk_bee_restore || return
  # Provider failures are best-effort; losing track of Bee is not.
  [ "$save_rc" = 0 ] || log "warning: cache-save failed (exit $save_rc)"
}

# Only ESRCH establishes that the owner is gone. EPERM (a live owner under
# another UID) and unexpected probe failures both leave the file alone.
apk_swap_pid_gone() {
  local probe
  if probe="$(LC_ALL=C kill -0 "$1" 2>&1)"; then return 1; fi
  [[ "$probe" == *"($1) - No such process" ]]
}

# Reclaim both the legacy PID-only files and the new private allocations.
apk_swap_reclaim() (
  local dir entry f pid lock layout
  dir="$(apk_swap_dir)" || return 0
  # Without serialization a second reclaimer can validate a path just before the
  # first unlinks it, allowing someone in a sticky directory to plant a replacement.
  exec {lock}<"$dir" && flock -xn "$lock" || return 0
  for entry in "${dir%/}"/linux-unity-apk.swap.* "${dir%/}"/linux-unity-apk.swapdir.*; do
    layout=""
    if [[ "${entry##*/}" =~ ^linux-unity-apk\.swap\.([1-9][0-9]{0,9})$ ]]; then
      pid="${BASH_REMATCH[1]}"; f="$entry"
    elif [[ "${entry##*/}" =~ ^linux-unity-apk\.swapdir\.[[:alnum:]]{10}\.([1-9][0-9]{0,9})$ ]]; then
      pid="${BASH_REMATCH[1]}"; f="$entry/linux-unity-apk.swapfile"; layout=private
      apk_swap_private_dir "$entry" || continue
    else
      continue
    fi
    [[ "$pid" != "$$" ]] && (( pid <= 2147483647 )) && apk_swap_pid_gone "$pid" || continue
    if ! apk_swap_regular "$f" "$layout"; then
      # The owner might have died between creating the directory and its file.
      if [ "$layout" = private ]; then as_root rmdir -- "$entry" 2>/dev/null || :; fi
      continue
    fi
    if ! as_root swapoff "$f" 2>/dev/null && ! apk_swap_inactive "$f"; then
      log "warning: swapoff $f failed; keeping the stale swapfile"
    elif apk_swap_remove "$f" "$layout"; then
      log "apk: removed stale swapfile $f"
    fi
  done
)

# Build the configured APK for Android on Xvfb (never
# -nographics: the player build needs a graphics device for shaders). A cold build (no Library/) restores the Android
# Library cache first (falling back to the editor one) and saves it under the Android key after a successful build
# that had no Android entry. The old APK is removed first, so a failed build never
# reports a stale one.
cmd_apk() {
  local kind="${1:-dev}" method apk profile cold=0 rc=0 nrc=0 before size sum cache_source="existing Library"
  [ $# -le 1 ] || die "usage: apk [dev|release|contest]"
  case "$kind" in
    dev) method="$(ship_config_get '.build.devMethod')"; apk="$(ship_config_get '.build.apkPath')" ;;
    release|contest) method="$(ship_config_get '.build.releaseMethod')"; apk="$(ship_config_get '.build.releaseApkPath // .build.apkPath')" ;;
    *) die "usage: apk [dev|release|contest]" ;;
  esac
  profile="$(ship_config_get '.build.profile // empty')"
  [ -z "$profile" ] || method="profile $profile"
  has_android || die "no Android module in $UNITY_ROOT; run $SHIP_COMMAND setup --android"
  apk_swap_reclaim
  local swap; swap="$(apk_swap_size)"
  [ "$swap" != 0 ] || swap=""
  apk_disk_check "$swap"
  mkdir -p "$OUT_DIR"
  # The swapfile goes first, then the trap already set (licence return, pidfile). TERM/INT/HUP exit through it too
  # (bash runs no EXIT trap for an untrapped signal).
  # Cleanup owns only a file assigned by this invocation's apk_swap_on, never caller state.
  APK_SWAPFILE=""
  chain_exit_trap apk_swap_off; trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
  [ -z "$swap" ] || apk_swap_on "$swap"
  [ "$APK_JOBS" = 0 ] || log "apk: IL2CPP/bee capped at $APK_JOBS parallel jobs (APK_JOBS)"
  if [ ! -d "$PROJECT/Library" ]; then
    cmd_cache restore android
    if [ -d "$PROJECT/Library" ]; then
      cache_source="Android hit"
    else
      # No Android entry yet: the editor (base) Library still saves the shared imports; the build then re-imports
      # only what differs for Android, and saves the result under the Android key.
      cold=1; log "apk: no Android Library cache; trying the editor Library cache"; cmd_cache restore
      if [ -d "$PROJECT/Library" ]; then cache_source="editor fallback"; else cache_source="cold import"; fi
    fi
  fi
  log "apk: cache: $cache_source"
  # The restore (and any swapfile) has landed. Check actual remaining space before any editor work.
  apk_disk_check "" "post-restore"
  cleanup_unity
  rm -f "$PROJECT/$apk"
  before="$(run_noise_before)"; NOISE_SKIP=0; RUN_KEEP=()
  log "apk: $method (log: $OUT_DIR/apk.log)"
  # The editor passes IL2CPP_ADDITIONAL_ARGS to il2cpp (--jobs: conversion and C++ compile, bee jobs default to it);
  # BEE_BUILD_THREADS caps the bee backend that runs the player build graph (Gradle, linking).
  # Activate in the wrapper: no worker deferring signals or copying its EXIT chain.
  if [ "$APK_JOBS" != 0 ]; then
    local -x IL2CPP_ADDITIONAL_ARGS="${IL2CPP_ADDITIONAL_ARGS:+$IL2CPP_ADDITIONAL_ARGS }--jobs=$APK_JOBS"
    local -x BEE_BUILD_THREADS="$APK_JOBS"
  fi
  if [ -n "$profile" ]; then
    ensure_licence
    local cli; cli="$(ship_config_get '.build.cli // "unity"')"
    supervise xvfb-run -a -s "-screen 0 1280x1024x24" timeout -s KILL "$APK_TIMEOUT" \
      "$cli" build "$PROJECT" --profile "$profile" -e "$UNITY_BIN" --output-path "$PROJECT/$apk" \
      --android-export-type apk --allow-dirty-build --timeout "$APK_TIMEOUT" --no-tail \
      -l "$OUT_DIR/apk.log" >&2 || rc=$?
    activation_unlock
    cleanup_unity
  else
    UNITY_TIMEOUT="$APK_TIMEOUT" UNITY_TIMEOUT_VAR=APK_TIMEOUT UNITY_RUN_LABEL=apk unity -quit -buildTarget Android \
      -executeMethod "$method" -logFile "$OUT_DIR/apk.log" || rc=$?
  fi
  revert_run_noise_after "$before" || nrc=$?
  local build_class="${method%.*}"; build_class="${build_class##*.}"
  grep -hF "[$build_class]" "$OUT_DIR/apk.log" >&2 2>/dev/null || true
  if [ "$rc" != 0 ] || [ ! -s "$PROJECT/$apk" ]; then
    if [ "$nrc" != 0 ]; then noise_revert_failed "$nrc" "$before" "APK build failed" --run || :; fi
    [ "$rc" = 0 ] || die "$method failed (exit $rc; see $OUT_DIR/apk.log)"
    die "$method wrote no $apk (see $OUT_DIR/apk.log)"
  fi
  size="$(stat -c %s "$PROJECT/$apk")"; sum="$(sha256sum "$PROJECT/$apk" | cut -c1-64)"
  # Save recovery context before the best-effort cache upload or any subsequent interruption.
  if [ "$nrc" != 0 ]; then noise_revert_failed "$nrc" "$before" "APK built" --run || nrc=$?; fi
  # The Android Gradle build leaves its prefab scratch in the project root (not git-ignored before this).
  rm -rf "$PROJECT/.utmp"
  if [ "$cold" = 1 ]; then
    APK_BEE_ID="" APK_CACHE_PID="" APK_CACHE_STARTING=0 APK_CACHE_SIGNAL=""
    chain_exit_trap apk_cache_cleanup
    trap 'apk_cache_interrupt 143' TERM; trap 'apk_cache_interrupt 130' INT; trap 'apk_cache_interrupt 129' HUP
    apk_cache_save || return
  fi
  log "apk: $PROJECT/$apk"
  log "apk: size $size bytes ($((size / 1048576)) MB)"
  log "apk: sha256 $sum"
  return "$nrc"
}

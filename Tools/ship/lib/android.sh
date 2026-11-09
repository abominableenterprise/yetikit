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

# Add the build's swapfile (best effort: a filesystem that refuses swap only logs a warning). APK_SWAPFILE is set only
# once the file exists, so apk_swap_off removes exactly what this run created.
apk_swap_on() {
  local f; f="$APK_SWAP_DIR/linux-unity-apk.swap.$$"
  log "apk: adding a ${1} GB swapfile $f (removed on exit)"
  as_root fallocate -l "${1}G" "$f" || { as_root rm -f "$f"; log "warning: could not create $f; building without swap"; return 0; }
  APK_SWAPFILE="$f"
  as_root chmod 600 "$f" && as_root mkswap -q "$f" >/dev/null && as_root swapon "$f" \
    || log "warning: swapon $f failed; building without swap"
}
apk_swap_off() {
  [ -n "${APK_SWAPFILE:-}" ] || return 0
  local rc=0 rm_rc=0
  as_root swapoff "$APK_SWAPFILE" 2>/dev/null || rc=$?
  as_root rm -f "$APK_SWAPFILE" || rm_rc=$?
  if [ "$rm_rc" = 0 ]; then log "apk: removed swapfile $APK_SWAPFILE"; APK_SWAPFILE=""; fi
  [ "$rc" != 0 ] || rc=$rm_rc
  return "$rc"
}
# Save the Android Library cache without Library/Bee (~7 GB of IL2CPP/Gradle intermediates after a build: task-cache
# would tar it next to Library on a disk with ~8 GB left). Bee is set aside in Temp/ (same filesystem, git-ignored)
# and put back, so the next apk on this VM stays incremental.
apk_cache_save() {
  local aside="$PROJECT/Temp/apk-bee-aside" rc=0
  rm -rf "$aside"
  if [ -d "$PROJECT/Library/Bee" ]; then mkdir -p "$PROJECT/Temp"; mv "$PROJECT/Library/Bee" "$aside"; fi
  cmd_cache save android || rc=$?
  if [ -d "$aside" ]; then mv "$aside" "$PROJECT/Library/Bee"; fi
  return $rc
}

# Swapfiles of earlier apk runs that are gone (KILLed before their trap ran): swapoff and delete, so their space counts.
apk_swap_reclaim() {
  local f pid
  for f in "$APK_SWAP_DIR"/linux-unity-apk.swap.*; do
    [ -e "$f" ] || continue
    pid="${f##*.}"
    [ "$pid" != "$$" ] && ! kill -0 "$pid" 2>/dev/null || continue
    as_root swapoff "$f" 2>/dev/null || true
    as_root rm -f "$f"; log "apk: removed stale swapfile $f"
  done
}

# Build the configured APK for Android on Xvfb (never
# -nographics: the player build needs a graphics device for shaders). A cold build (no Library/) restores the Android
# Library cache first (falling back to the editor one) and saves it under the Android key after a successful build
# that had no Android entry. The old APK is removed first, so a failed build never
# reports a stale one.
cmd_apk() {
  local kind="${1:-dev}" method apk profile cold=0 rc=0 before size sum cache_source="existing Library"
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
    xvfb-run -a -s "-screen 0 1280x1024x24" timeout -s KILL "$APK_TIMEOUT" \
      "$cli" build "$PROJECT" --profile "$profile" -e "$UNITY_BIN" --output-path "$PROJECT/$apk" \
      --android-export-type apk --allow-dirty-build --timeout "$APK_TIMEOUT" --no-tail \
      -l "$OUT_DIR/apk.log" >&2 || rc=$?
    cleanup_unity
  else
    UNITY_TIMEOUT="$APK_TIMEOUT" UNITY_TIMEOUT_VAR=APK_TIMEOUT UNITY_RUN_LABEL=apk unity -quit -buildTarget Android \
      -executeMethod "$method" -logFile "$OUT_DIR/apk.log" || rc=$?
  fi
  revert_run_noise_after "$before"
  local build_class="${method%.*}"; build_class="${build_class##*.}"
  grep -hF "[$build_class]" "$OUT_DIR/apk.log" >&2 2>/dev/null || true
  [ "$rc" = 0 ] || die "$method failed (exit $rc; see $OUT_DIR/apk.log)"
  [ -s "$PROJECT/$apk" ] || die "$method wrote no $apk (see $OUT_DIR/apk.log)"
  size="$(stat -c %s "$PROJECT/$apk")"; sum="$(sha256sum "$PROJECT/$apk" | cut -c1-64)"
  # The Android Gradle build leaves its prefab scratch in the project root (not git-ignored before this).
  rm -rf "$PROJECT/.utmp"
  if [ "$cold" = 1 ]; then apk_cache_save || log "warning: cache-save failed"; fi
  log "apk: $PROJECT/$apk"
  log "apk: size $size bytes ($((size / 1048576)) MB)"
  log "apk: sha256 $sum"
}

#!/usr/bin/env bash
# Exercise sourced command orchestration only: never Unity, licensing, or the checkout's git index.
set -euo pipefail
ci="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$ci/tests/lib/fixture.sh"
ship_fixture "$tmp/project"
[ -z "${LINUX_UNITY_LIB:-}" ] || cp "$LINUX_UNITY_LIB" "$PROJECT/Tools/ship/linux-unity.sh"
export OUT_DIR="$tmp/out" UNITY_ROOT="$tmp/unity"
mkdir -p "$PROJECT/Library" "$OUT_DIR"
. "$script"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
cleanup_unity() { :; }
cmd_cache() { :; }
run_noise_before() { echo pre-dirty-font; }
noise_dirty_files() { echo pre-dirty-font; }
lightmap_meta_changes() { :; }
revert_bake_noise() { echo bake >> "$trace"; }
# Record each cleanup's actual snapshot and protection list. Do not stub cmd_* orchestration.
record_cleanup() { printf 'cleanup:%s' "$1" >> "$trace"; shift; printf '|%s' "$@" >> "$trace"; echo >> "$trace"; }
revert_run_noise_after() {
  [ "$NOISE_SKIP" != 1 ] || return 0
  record_cleanup "$1" ${RUN_KEEP[@]+"${RUN_KEEP[@]}"}
}
revert_editor_noise() { record_cleanup "$@"; }
has_android() { return 0; }
apk_swap_reclaim() { :; }
apk_swap_size() { echo 0; }
apk_disk_check() { :; }
chain_exit_trap() { :; }
# Keep the real test_passes selectors; the passes themselves stand in for editor work.
run_pass() { unity "$@"; }
run_gfx_pass() { unity "$@"; }
test_pr() { echo pr >> "$trace"; unity pr; }
unity() {
  calls=$((calls + 1)); echo "editor:$calls" >> "$trace"
  if [ "$calls" = "$fail_at" ]; then return 42; fi
  mkdir -p "$PROJECT/Builds/Android"
  printf apk > "$PROJECT/Builds/Android/GeneratedScene-dev.apk"
  return 0
}
export EDITMODE_GFX=0
for command in open editmode playmode pr scene area apk lab; do
  for fail_at in 0 1; do
    trace="$tmp/$command-$fail_at.trace"; : > "$trace"
    rc=0
    (
      calls=0
      case "$command" in
        open) cmd_open ;;
        editmode|playmode|pr) cmd_test "$command" ;;
        scene) cmd_scene ;;
        area) cmd_scene --area Court ;;
        apk) cmd_apk dev ;;
        lab) cmd_lab ;;
      esac
    ) > "$tmp/output" 2>&1 || rc=$?
    check "$command (editor failure=$fail_at) cleans last with the pre-run snapshot" \
      'tail -n 1 "$trace" | grep -q "^cleanup:pre-dirty-font"'
    if [ "$fail_at" = 0 ]; then
      check "$command succeeds after cleanup" '[ "$rc" = 0 ]'
    else
      check "$command retains editor failure after cleanup" '[ "$rc" != 0 ]'
    fi
  done
done
# Later scene failures must also clean up and stop the remaining editor stages.
for fail_at in 2 3; do
  trace="$tmp/scene-$fail_at.trace"; : > "$trace"; rc=0
  (calls=0; cmd_scene) > "$tmp/output" 2>&1 || rc=$?
  check "scene stage $fail_at failure still cleans and stops" \
    '[ "$rc" != 0 ] && grep -q "^cleanup:pre-dirty-font" "$trace" && [ "$(grep -c "^editor:" "$trace")" = "$fail_at" ]'
done
font='Assets/TextMesh Pro/Resources/Fonts & Materials/LiberationSans SDF.asset'
for command in open test scene lab; do
  trace="$tmp/$command-keep.trace"; : > "$trace"; fail_at=0; rc=0
  (cd "$PROJECT"; calls=0; "cmd_$command" $([ "$command" != test ] || echo editmode) --keep "$font") > "$tmp/output" 2>&1 || rc=$?
  check "$command passes the font --keep to cleanup" \
    '[ "$rc" = 0 ] && grep -qF "|$font" "$trace"'
done
trace="$tmp/lab-skip.trace"; : > "$trace"; fail_at=0; rc=0
(calls=0; cmd_lab --keep) > "$tmp/output" 2>&1 || rc=$?
check 'lab bare --keep skips cleanup' '[ "$rc" = 0 ] && ! grep -q "^cleanup:" "$trace"'
echo "$fails failure(s)"; [ "$fails" = 0 ]

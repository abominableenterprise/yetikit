#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Tests linux-unity.sh setup --android (image choice, base editor replaced), apk [dev|contest] (editor arguments, log,
# APK report, failures, Android Library cache) and cache-key android, with the fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk.test.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
mkdir -p "$proj/Packages" "$proj/ProjectSettings"
printf '{"dependencies":{}}\n' > "$proj/Packages/manifest.json"
printf '{"dependencies":{},"lock":1}\n' > "$proj/Packages/packages-lock.json"
printf 'm_EditorVersion: 6000.6.6f1\n' > "$proj/ProjectSettings/ProjectVersion.txt"
# shellcheck source=Tools/ship/tests/lib/fake-unity.sh
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
git_init
android="$tmp/unity/Editor/Data/PlaybackEngines/AndroidPlayer"
lu() { bash "$script" "$@" 2>"$tmp/err"; }
# The fake build: WorldBuild writes the APK named by the method (FAKE_APK_BYTES, default "apk"), unless FAKE_NO_APK=1.
build='m=$(tr " " "\n" < "$FAKE_TMP/last-args" | grep WorldBuild); case "$m" in *DevelopmentApk) f=GeneratedScene-dev.apk ;;
  *ContestApk) f=ExampleGame-contest.apk ;; esac; [ "${FAKE_NO_APK:-0}" = 1 ] || { mkdir -p Builds/Android; printf "%s" "${FAKE_APK_BYTES:-apk}" > Builds/Android/$f; }'
# The fake editor also records the job caps it was started with (env, in $tmp/jobs-env).
jobs='env | grep -E "^(IL2CPP_ADDITIONAL_ARGS|BEE_BUILD_THREADS)=" | sort > "$FAKE_TMP/jobs-env" || true'
export FAKE_MUTATE="tail -n1 \"\$FAKE_TMP/runs\" > \"\$FAKE_TMP/last-args\"; $jobs; $build"
# Fake disk and memory: df reports FAKE_FREE_GB (default 30) free; MEMINFO is a 16 GB VM without swap (no swapfile),
# unless a check points it at $tmp/meminfo-8g. fallocate/mkswap/swapon/swapoff only log (never a real swapfile).
cat > "$tmp/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
free=${FAKE_FREE_GB:-30}
[ -z "${FAKE_DISK_MARKER:-}" ] || [ ! -e "$FAKE_DISK_MARKER" ] || free=${FAKE_RESTORE_FREE_GB:-$free}
echo "none 41943040 1 $(( free * 1048576 + 1000 )) 50% /"
EOF
cat > "$tmp/bin/fallocate" <<EOF
#!/bin/sh
echo "fallocate \$*" >> "$tmp/swap-calls"; [ "\${FAKE_FALLOCATE_RC:-0}" = 0 ] || exit 1; : > "\$3"
EOF
for c in mkswap swapon swapoff; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/swap-calls"\n[ "%s" != swapon ] || exit "${FAKE_SWAPON_RC:-0}"\n' "$c" "$tmp" "$c" > "$tmp/bin/$c"
done
chmod +x "$tmp/bin/df" "$tmp/bin/fallocate" "$tmp/bin/mkswap" "$tmp/bin/swapon" "$tmp/bin/swapoff"
printf 'MemTotal:       16000000 kB\nSwapTotal:             0 kB\n' > "$tmp/meminfo-16g"
printf 'MemTotal:        8134656 kB\nSwapTotal:             0 kB\n' > "$tmp/meminfo-8g"
printf 'MemTotal:        8134656 kB\nSwapTotal:       4194300 kB\n' > "$tmp/meminfo-8g-swap"
mkdir -p "$tmp/swap"
export MEMINFO="$tmp/meminfo-16g" APK_SWAP_DIR="$tmp/swap"
unset APK_JOBS APK_SWAP_GB APK_MIN_FREE_GB APK_MIN_FREE_GB_WARM IL2CPP_ADDITIONAL_ARGS BEE_BUILD_THREADS

# --- apk -----------------------------------------------------------------------------------------------------------
check "apk without the Android module stops before the editor and names setup --android" \
  ': > "$tmp/runs"; ! lu apk && grep -q "setup --android" "$tmp/err" && [ ! -s "$tmp/runs" ]'
mkdir -p "$android/SDK" "$android/NDK"
mkdir -p "$proj/Library"
check "apk (default dev) succeeds" ': > "$tmp/runs"; lu apk'
check "apk dev: one editor run, Android target, DevelopmentApk, log in OUT_DIR/apk.log" \
  '[ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q -- "-batchmode -projectPath $proj -quit -buildTarget Android -executeMethod ExampleGame.World.Editor.WorldBuild.DevelopmentApk -logFile $OUT_DIR/apk.log" "$tmp/runs"'
check "apk dev: never -nographics (the player build needs a graphics device)" '! grep -q -- -nographics "$tmp/runs"'
check "apk dev: prints the APK path, size and sha256" \
  'grep -q "apk: $proj/Builds/Android/GeneratedScene-dev.apk" "$tmp/err" && grep -q "apk: size 3 bytes" "$tmp/err" && grep -q "apk: sha256 $(printf apk | sha256sum | cut -c1-64)" "$tmp/err"'
check "apk contest: ContestApk and ExampleGame-contest.apk" \
  ': > "$tmp/runs"; lu apk contest && grep -q "WorldBuild.ContestApk" "$tmp/runs" && grep -q "apk: $proj/Builds/Android/ExampleGame-contest.apk" "$tmp/err"'
check "apk release aliases the configured contest build" \
  ': > "$tmp/runs"; lu apk release && grep -q "WorldBuild.ContestApk" "$tmp/runs"'
check "apk with an unknown kind is a usage error, no editor run" ': > "$tmp/runs"; ! lu apk unknown && grep -q "usage: apk" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "apk with extra arguments is a usage error" '! lu apk dev extra && grep -q "usage: apk" "$tmp/err"'
check "apk: a failed editor run fails with the log path" \
  '! FAKE_UNITY_RC=1 lu apk && grep -q "DevelopmentApk failed (exit 1; see $OUT_DIR/apk.log)" "$tmp/err"'
check "apk: a build that writes no APK fails and never reports the old one" \
  '! FAKE_NO_APK=1 lu apk && grep -q "wrote no Builds/Android/GeneratedScene-dev.apk" "$tmp/err" && ! grep -q "apk: sha256" "$tmp/err"'
check "apk: the pidfile is gone afterwards" '[ ! -f "$OUT_DIR/linux-unity.pid" ]'

# --- parallelism cap -----------------------------------------------------------------------------------------------
check "apk: the editor gets il2cpp --jobs=2 and BEE_BUILD_THREADS=2 by default" \
  'lu apk && [ "$(cat "$tmp/jobs-env")" = "$(printf "BEE_BUILD_THREADS=2\nIL2CPP_ADDITIONAL_ARGS=--jobs=2")" ] && grep -q "capped at 2 parallel jobs" "$tmp/err"'
check "apk: APK_JOBS=3 sets both caps to 3" \
  'APK_JOBS=3 lu apk && grep -qx "BEE_BUILD_THREADS=3" "$tmp/jobs-env" && grep -qx "IL2CPP_ADDITIONAL_ARGS=--jobs=3" "$tmp/jobs-env"'
check "apk: an IL2CPP_ADDITIONAL_ARGS from the caller is kept, --jobs appended" \
  'IL2CPP_ADDITIONAL_ARGS=--foo lu apk && grep -qx "IL2CPP_ADDITIONAL_ARGS=--foo --jobs=2" "$tmp/jobs-env"'
check "apk: APK_JOBS=0 leaves the Unity defaults (no cap)" \
  'APK_JOBS=0 lu apk && [ ! -s "$tmp/jobs-env" ] && ! grep -q "capped at" "$tmp/err"'
check "apk: the caps reach only the apk editor run, not other commands (open)" \
  ': > "$tmp/jobs-env"; lu open && [ ! -s "$tmp/jobs-env" ]'

# --- disk check ------------------------------------------------------------------------------------------------------
check "apk with under 10 GB free fails before the editor and says how much is free and needed" \
  ': > "$tmp/runs"; ! FAKE_FREE_GB=9 lu apk && grep -q "apk: only 9 GB free on / (need 10 GB" "$tmp/err" && grep -q "free disk first" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "apk with exactly 10 GB free builds" 'FAKE_FREE_GB=10 lu apk && grep -q "apk: 10 GB free (need 10 GB)" "$tmp/err"'
check "a warm rebuild (Library/Bee/Android there) needs only 4 GB" \
  'mkdir -p "$proj/Library/Bee/Android" && FAKE_FREE_GB=4 lu apk && grep -q "need 4 GB, warm: Library/Bee/Android" "$tmp/err" && ! FAKE_FREE_GB=3 lu apk && grep -q "need 4 GB: APK_MIN_FREE_GB_WARM=4" "$tmp/err"'
check "APK_MIN_FREE_GB_WARM changes the warm limit" '! FAKE_FREE_GB=5 APK_MIN_FREE_GB_WARM=6 lu apk && grep -q "need 6 GB" "$tmp/err"; rc=$?; rm -rf "$proj/Library/Bee"; [ "$rc" = 0 ]'
check "APK_MIN_FREE_GB changes the limit" '! FAKE_FREE_GB=10 APK_MIN_FREE_GB=12 lu apk && grep -q "need 12 GB" "$tmp/err"'
check "apk on an 8 GB VM counts the swapfile into the disk it needs (13 GB with 3 GB swap)" \
  ': > "$tmp/swap-calls"; ! FAKE_FREE_GB=12 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "need 13 GB: APK_MIN_FREE_GB=10 + 3 GB swap" "$tmp/err" && [ ! -s "$tmp/swap-calls" ]'

# --- swapfile --------------------------------------------------------------------------------------------------------
swapfiles() { find "$tmp/swap" -name "linux-unity-apk.swap.*" | wc -l; }
: > "$tmp/swap-calls"
check "apk on a 16 GB VM adds no swapfile" 'lu apk && [ ! -s "$tmp/swap-calls" ]'
check "apk ignores inherited swap cleanup ownership and preserves the sentinel file" \
  'printf "keep\n" > "$tmp/inherited-swap"; APK_SWAPFILE="$tmp/inherited-swap" lu apk && [ -f "$tmp/inherited-swap" ] && [ "$(cat "$tmp/inherited-swap")" = keep ] && [ ! -s "$tmp/swap-calls" ]'
check "apk on an 8 GB VM that already has swap adds none" 'MEMINFO="$tmp/meminfo-8g-swap" lu apk && [ ! -s "$tmp/swap-calls" ]'
check "apk on an 8 GB VM without swap: a 3 GB swapfile is on during the build and removed afterwards" \
  ': > "$tmp/swap-calls"; MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "^fallocate -l 3G $tmp/swap/linux-unity-apk.swap." "$tmp/swap-calls" && grep -q "^swapon $tmp/swap/" "$tmp/swap-calls" && grep -q "^swapoff $tmp/swap/" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ] && grep -q "removed swapfile" "$tmp/err"'
check "swapon comes before the editor run, swapoff after it" \
  ': > "$tmp/swap-calls"; FAKE_MUTATE="echo editor >> \"$tmp/swap-calls\"" MEMINFO="$tmp/meminfo-8g" lu apk; [ "$(grep -oE "^(swapon|editor|swapoff)" "$tmp/swap-calls" | tr "\n" " ")" = "swapon editor swapoff " ]'
check "APK_SWAP_GB=4 makes a 4 GB swapfile; APK_SWAP_GB=0 none" \
  ': > "$tmp/swap-calls"; MEMINFO="$tmp/meminfo-8g" APK_SWAP_GB=4 lu apk && grep -q "^fallocate -l 4G" "$tmp/swap-calls" && : > "$tmp/swap-calls" && MEMINFO="$tmp/meminfo-8g" APK_SWAP_GB=0 lu apk && [ ! -s "$tmp/swap-calls" ]'
check "a failed build still removes the swapfile" \
  ': > "$tmp/swap-calls"; ! FAKE_UNITY_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "^swapoff" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ]'
check "a build that writes no APK still removes the swapfile" \
  '! FAKE_NO_APK=1 MEMINFO="$tmp/meminfo-8g" lu apk && [ "$(swapfiles)" = 0 ]'
: > "$tmp/swap-calls"
MEMINFO="$tmp/meminfo-8g" python3 - "$script" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ['FAKE_TMP'])
gate = root / 'apk-editor'
with (root / 'err').open('w') as log:
    runner = subprocess.Popen(['bash', sys.argv[1], 'apk'], stdout=log, stderr=log,
                              env=dict(os.environ, FAKE_EDITOR_GATE=str(gate)),
                              start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while not Path(str(gate) + '.ready').exists():
            assert runner.poll() is None, (root / 'err').read_text()
            assert time.monotonic() < deadline, 'APK editor never reached its gate'
            time.sleep(.02)
        assert any(line.startswith('swapon ') for line in (root / 'swap-calls').read_text().splitlines())
        runner.send_signal(signal.SIGTERM)
        # Bash may defer its handler until the foreground editor returns.
        Path(str(gate) + '.release').touch()
        assert runner.wait(timeout=60) == 143, (root / 'err').read_text()
    finally:
        Path(str(gate) + '.release').touch()
        if runner.poll() is None:
            os.killpg(runner.pid, signal.SIGKILL)
        runner.wait()
print('ok   APK wrapper receives TERM while the editor is gated and exits 143')
PY
check "apk TERMed mid-build removes the swapfile and its pidfile" \
  '[ "$(swapfiles)" = 0 ] && grep -q "^swapoff" "$tmp/swap-calls" && [ ! -f "$OUT_DIR/linux-unity.pid" ]'
check "a swapfile that could not be created: warning, build goes on, nothing to remove" \
  ': > "$tmp/swap-calls"; FAKE_FALLOCATE_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "could not create" "$tmp/err" && ! grep -q "^swapoff" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ]'
check "swapon refused (overlay root): warning, build goes on, the file is still removed" \
  ': > "$tmp/swap-calls"; FAKE_SWAPON_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "swapon .* failed" "$tmp/err" && [ "$(swapfiles)" = 0 ]'
# UNITY_RETURN_ON_EXIT=1: apk's swapfile trap chains onto the licence return trap (both run, the failure is kept).
lcdir="$tmp/unity/Editor/Data/Resources/Licensing/Client"; mkdir -p "$lcdir"
printf '#!/bin/sh\necho "$1" >> "%s/lc-calls"\n[ "$1" != --activate-ulf ] || cp "%s/ulf.good" "$ULF"\n' "$tmp" "$tmp" > "$lcdir/Unity.Licensing.Client"
chmod +x "$lcdir/Unity.Licensing.Client"; cp "$ULF" "$tmp/ulf.good"
check "apk with UNITY_RETURN_ON_EXIT=1 that activated: a failed build removes the swapfile and returns the licence" \
  ': > "$tmp/swap-calls"; : > "$tmp/lc-calls"; rm -f "$ULF"; ! UNITY_RETURN_ON_EXIT=1 UNITY_USERNAME=u UNITY_PASSWORD=p FAKE_UNITY_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "^swapoff" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ] && grep -q -- "^--return-ulf" "$tmp/lc-calls" && [ ! -f "$OUT_DIR/linux-unity.pid" ]'
cp "$tmp/ulf.good" "$ULF"
check "a stale swapfile of a KILLed run is swapped off and removed; one of a live run is kept" \
  'sleep 30 & live=$!; : > "$tmp/swap/linux-unity-apk.swap.999999"; : > "$tmp/swap/linux-unity-apk.swap.$live"; : > "$tmp/swap-calls"; lu apk; rc=$?; kill "$live"; [ "$rc" = 0 ] && [ ! -e "$tmp/swap/linux-unity-apk.swap.999999" ] && grep -q "^swapoff $tmp/swap/linux-unity-apk.swap.999999" "$tmp/swap-calls" && [ -e "$tmp/swap/linux-unity-apk.swap.$live" ] && rm -f "$tmp/swap/linux-unity-apk.swap.$live"'

check "apk: the editor runs under APK_TIMEOUT (default 5400 s), not UNITY_TIMEOUT" \
  'printf "#!/usr/bin/env bash\necho \"\$*\" > \"%s/timeout-args\"\nshift 3; exec \"\$@\"\n" "$tmp" > "$tmp/bin/timeout" && chmod +x "$tmp/bin/timeout" && lu apk && grep -q "^-s KILL 5400 " "$tmp/timeout-args" && APK_TIMEOUT=9 lu apk && grep -q "^-s KILL 9 " "$tmp/timeout-args"; rm -f "$tmp/bin/timeout"'

# --- Android Library cache ------------------------------------------------------------------------------------------
cat > "$tmp/bin/fake-cache" <<EOF
#!/bin/sh
echo "\$1 \$2" >> "$tmp/cache-calls"
case "\$1" in restore) if [ "\$2" = "\${FAKE_HIT:-}" ]; then mkdir -p Library/hit; [ "\${FAKE_WARM_RESTORE:-0}" = 0 ] || mkdir -p Library/Bee/Android; exit 0; fi
  if [ "\${FAKE_PARTIAL:-0}" = 1 ]; then mkdir -p Library .task-cache.partial; : > Library/partial; fi; exit 3 ;; esac
[ "\$1" = save ] && { [ -e Library/Bee ] || echo "\$1 \$2 nobee" >> "$tmp/cache-bee"; exit "\${FAKE_SAVE_RC:-0}"; }
EOF
chmod +x "$tmp/bin/fake-cache"
k="$(bash "$script" cache-key)"; ka="$(bash "$script" cache-key android)"
check "cache-key android is a different bare 64-hex key" '[[ "$ka" =~ ^[0-9a-f]{64}$ ]] && [ "$ka" != "$k" ]'
check "cache-key (no argument) is unchanged by the android variant" \
  '[ "$k" = "$({ cat "$proj/Packages/manifest.json" "$proj/Packages/packages-lock.json" "$proj/ProjectSettings/ProjectVersion.txt"; printf 6000.6.6f1; } | sha256sum | cut -c1-64)" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk with no Library/ and an Android cache hit restores it and saves nothing" \
  'TASK_CACHE=fake-cache FAKE_HIT="$ka" lu apk && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ] && grep -q "apk: cache: Android hit" "$tmp/err"'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"; : > "$tmp/runs"
check "apk: warm Android restore passes post-restore disk check and starts the editor" \
  'TASK_CACHE=fake-cache FAKE_HIT="$ka" FAKE_WARM_RESTORE=1 FAKE_FREE_GB=10 FAKE_DISK_MARKER="$proj/Library/hit" FAKE_RESTORE_FREE_GB=4 lu apk && grep -q "need 4 GB, warm: Library/Bee/Android" "$tmp/err" && [ "$(wc -l < "$tmp/runs")" = 1 ] && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"; : > "$tmp/runs"
check "apk: restored Library crosses cold threshold: fail post-restore before editor" \
  '! TASK_CACHE=fake-cache FAKE_HIT="$ka" FAKE_FREE_GB=10 FAKE_DISK_MARKER="$proj/Library/hit" FAKE_RESTORE_FREE_GB=9 lu apk && grep -q "post-restore.*only 9 GB free.*need 10 GB" "$tmp/err" && [ ! -s "$tmp/runs" ] && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ] && [ ! -e "$OUT_DIR/linux-unity.pid" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk with an Android miss falls back to the editor cache, then saves under the Android key" \
  'TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && [ "$(tr "\n" " " < "$tmp/cache-calls")" = "restore $ka restore $k save $ka " ] && grep -q "apk: cache: editor fallback" "$tmp/err"'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk: restore exit 3 cleans partial cache, imports cold, then saves Android cache" \
  'TASK_CACHE=fake-cache FAKE_PARTIAL=1 lu apk && grep -q "cache restore failed (exit 3); cold import" "$tmp/err" && grep -q "apk: cache: cold import" "$tmp/err" && [ ! -e "$proj/Library/partial" ] && [ ! -e "$proj/.task-cache.partial" ] && [ "$(tr "\n" " " < "$tmp/cache-calls")" = "restore $ka restore $k save $ka " ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "the cold save leaves Library/Bee out of the cache and puts it back afterwards" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p Library/Bee && echo x > Library/Bee/obj" TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && grep -qx "save $ka nobee" "$tmp/cache-bee" && [ -f "$proj/Library/Bee/obj" ] && [ ! -e "$proj/Temp/apk-bee-aside" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "a failed cold save still puts Library/Bee back" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p Library/Bee && echo x > Library/Bee/obj" FAKE_SAVE_RC=1 TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && grep -q "cache-save failed" "$tmp/err" && [ -f "$proj/Library/Bee/obj" ] && [ ! -e "$proj/Temp/apk-bee-aside" ]'
check "apk removes the Android build scratch .utmp/ from the project root" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p .utmp/Debug" lu apk && [ ! -e "$proj/.utmp" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "a failed cold build saves no cache" \
  '! TASK_CACHE=fake-cache FAKE_UNITY_RC=1 lu apk && ! grep -q "^save" "$tmp/cache-calls"'
: > "$tmp/cache-calls"
check "apk with a Library/ never touches the cache" 'mkdir -p "$proj/Library" && TASK_CACHE=fake-cache lu apk && [ ! -s "$tmp/cache-calls" ]'

# --- setup --android ------------------------------------------------------------------------------------------------
# Fake images: crane export <image> streams a tar of opt/unity; only the android one has AndroidPlayer/SDK and NDK.
img="$tmp/img"; lcrel="opt/unity/Editor/Data/Resources/Licensing/Client"
for i in base android; do
  mkdir -p "$img/$i/$lcrel"
  printf '#!/bin/sh\n# Unity 6000.6.6f1\n' > "$img/$i/opt/unity/Editor/Unity"; cp "$img/$i/opt/unity/Editor/Unity" "$img/$i/$lcrel/Unity.Licensing.Client"
  chmod +x "$img/$i/opt/unity/Editor/Unity" "$img/$i/$lcrel/Unity.Licensing.Client"
done
mkdir -p "$img/android/opt/unity/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" "$img/android/opt/unity/Editor/Data/PlaybackEngines/AndroidPlayer/NDK"
cat > "$tmp/bin/crane" <<EOF
#!/bin/sh
echo "\$*" >> "$tmp/crane-calls"
case "\$2" in *-android-3) tar -c -C "$img/android" opt/unity ;; *-base-3) tar -c -C "$img/base" opt/unity ;; *) exit 1 ;; esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/dpkg"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/ldd"
chmod +x "$tmp/bin/crane" "$tmp/bin/dpkg" "$tmp/bin/ldd"
setup() { : > "$tmp/crane-calls"; env -u UNITY_IMAGE UNITY_ROOT="$tmp/root/unity" BIN_DIR="$tmp/bin" "$@" bash "$script" setup ${SETUP_ARGS:-} >"$tmp/setup-out" 2>&1; }
check "setup (no flag) still installs the base image" \
  'setup env && grep -qx "export unityci/editor:ubuntu-6000.6.6f1-base-3 -" "$tmp/crane-calls" && [ ! -e "$tmp/root/unity/Editor/Data/PlaybackEngines/AndroidPlayer" ]'
check "setup again: editor already there, no pull" 'setup env && grep -q "editor already" "$tmp/setup-out" && [ ! -s "$tmp/crane-calls" ]'
check "setup --android over a base editor replaces it with the android image" \
  'SETUP_ARGS=--android setup env && grep -q "replacing the editor" "$tmp/setup-out" && grep -qx "export unityci/editor:ubuntu-6000.6.6f1-android-3 -" "$tmp/crane-calls" && [ -d "$tmp/root/unity/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" ] && [ -f "$tmp/root/unity/.install-complete" ] && grep -q "setup ok" "$tmp/setup-out"'
check "setup --android again: no pull" 'SETUP_ARGS=--android setup env && [ ! -s "$tmp/crane-calls" ] && grep -q "setup ok" "$tmp/setup-out"'
check "setup (no flag) keeps an android editor (it is a superset)" 'setup env && [ ! -s "$tmp/crane-calls" ] && [ -d "$tmp/root/unity/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" ]'
rm -rf "$tmp/root"
check "UNITY_MODULES=android is the same as --android" \
  'setup env UNITY_MODULES=android && grep -q "android-3" "$tmp/crane-calls" && [ -d "$tmp/root/unity/Editor/Data/PlaybackEngines/AndroidPlayer/NDK" ]'
rm -rf "$tmp/root"
check "UNITY_MODULES=webgl is refused before any pull" '! setup env UNITY_MODULES=webgl && grep -q "only android" "$tmp/setup-out" && [ ! -s "$tmp/crane-calls" ]'
check "setup --bogus is a usage error" '! SETUP_ARGS=--bogus setup env && grep -q "usage: setup \[--android\]" "$tmp/setup-out"'
check "setup --android with an image lacking the SDK fails" \
  '! SETUP_ARGS=--android setup env UNITY_IMAGE=unityci/editor:ubuntu-6000.6.6f1-base-3 && grep -q "no Android SDK/NDK" "$tmp/setup-out"'
rm -rf "$tmp/root"; mkdir -p "$tmp/root/unity/Editor"; printf '#!/bin/sh\n' > "$tmp/root/unity/Editor/Unity"; chmod +x "$tmp/root/unity/Editor/Unity"
check "setup --android never deletes an incomplete root (no completion marker)" \
  '! SETUP_ARGS=--android setup env && grep -q "incomplete" "$tmp/setup-out" && [ -x "$tmp/root/unity/Editor/Unity" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

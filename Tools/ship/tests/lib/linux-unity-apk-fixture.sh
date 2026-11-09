# Shared isolated fake-editor fixture for the topical APK tests; source before checks.
# Keep the Android module absent until apk_module is called, so the missing-module check stays meaningful.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
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
# APK contracts do not exercise installation-wide editor discovery; that scan
# has dedicated process-scan/setup/foreign-process suites. Keep cleanup itself
# real, but avoid inspecting unrelated worker processes in this fixture copy.
python3 - "$script" "$proj" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
assert path.resolve().is_relative_to(Path(sys.argv[2]).resolve())
source = path.read_text()
needle = 'unity_pids() {\n'
assert source.count(needle) == 1
path.write_text(source.replace(needle, needle + '  return 0 # synthetic APK fixture: no foreign installation\n'))
PY
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

apk_module() { mkdir -p "$android/SDK" "$android/NDK" "$proj/Library"; }

#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Android editor image setup, replacement and validation. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-setup.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"

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
ship_fixture_process_view "$tmp/process-view"
setup() { : > "$tmp/crane-calls"; env -u UNITY_IMAGE -u SHIP_FIXTURE_PIDS PATH="$tmp/process-view:$PATH" UNITY_ROOT="$tmp/root/unity" BIN_DIR="$tmp/bin" "$@" bash "$script" setup ${SETUP_ARGS:-} >"$tmp/setup-out" 2>&1; }
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

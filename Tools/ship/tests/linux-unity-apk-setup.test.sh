#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Android editor image setup, replacement and validation. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-setup.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"

# --- setup --android ------------------------------------------------------------------------------------------------
# Fake images expose config metadata and stream tiny editor archives. The wrong image
# deliberately has an unversioned tag so the test can't pass by inspecting its name.
img="$tmp/img"; lcrel="opt/unity/Editor/Data/Resources/Licensing/Client"
for i in base android wrong; do
  mkdir -p "$img/$i/$lcrel"
  version=6000.6.6f1; [ "$i" != wrong ] || version=6000.6.6f2
  printf '#!/bin/sh\n# Unity %s\n' "$version" > "$img/$i/opt/unity/Editor/Unity"
  cp "$img/$i/opt/unity/Editor/Unity" "$img/$i/$lcrel/Unity.Licensing.Client"
  chmod +x "$img/$i/opt/unity/Editor/Unity" "$img/$i/$lcrel/Unity.Licensing.Client"
  printf '{"history":[{"created_by":"RUN |2 version=%s module=android /bin/sh -c echo $version > \\"$UNITY_PATH/version\\" # buildkit"}]}\n' "$version" > "$img/$i/config.json"
done
for i in android wrong; do
  mkdir -p "$img/$i/opt/unity/Editor/Data/PlaybackEngines/AndroidPlayer/"{SDK,NDK}
done
android_digest="unityci/editor@sha256:$(printf '%064d' 1)"
wrong_digest="fixture@sha256:$(printf '%064d' 2)"
unknown_digest="fixture@sha256:$(printf '%064d' 3)"
cat > "$tmp/bin/crane" <<EOF
#!/bin/sh
echo "\$*" >> "$tmp/crane-calls"
case "\$*" in
  'digest --platform linux/amd64 --full-ref unityci/editor:ubuntu-6000.6.6f1-android-3') echo '$android_digest' ;;
  'digest --platform linux/amd64 --full-ref fixture:override') echo '$wrong_digest' ;;
  'digest --platform linux/amd64 --full-ref fixture:unknown') echo '$unknown_digest' ;;
  'config $android_digest') cat "$img/android/config.json" ;;
  'config $wrong_digest') cat "$img/wrong/config.json" ;;
  'config $unknown_digest') echo '{}' ;;
  'export $android_digest -'|export\ *-android-3\ -) tar -c -C "$img/android" opt/unity ;;
  'export fixture:override -') tar -c -C "$img/wrong" opt/unity ;;
  export\ *-base-3\ -) tar -c -C "$img/base" opt/unity ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\necho "install ok installed"\n' > "$tmp/bin/dpkg-query"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/ldd"
chmod +x "$tmp/bin/crane" "$tmp/bin/dpkg-query" "$tmp/bin/ldd"
ship_fixture_process_view "$tmp/process-view"
setup() { : > "$tmp/crane-calls"; env -u UNITY_IMAGE -u SHIP_FIXTURE_PIDS PATH="$tmp/process-view:$PATH" UNITY_ROOT="$tmp/root/unity" BIN_DIR="$tmp/bin" "$@" bash "$script" setup ${SETUP_ARGS:-} >"$tmp/setup-out" 2>&1; }
check "setup (no flag) still installs the base image" \
  'setup env && grep -qx "export unityci/editor:ubuntu-6000.6.6f1-base-3 -" "$tmp/crane-calls" && [ ! -e "$tmp/root/unity/Editor/Data/PlaybackEngines/AndroidPlayer" ]'
check "setup again: editor already there, no pull" 'setup env && grep -q "editor already" "$tmp/setup-out" && [ ! -s "$tmp/crane-calls" ]'
root="$tmp/root/unity"
printf 'original marker\n' > "$root/.install-complete"
check "setup --android rejects a wrong image version without replacing or downloading" \
  '! SETUP_ARGS=--android setup env UNITY_IMAGE=fixture:override && grep -qF "fixture:override is Unity 6000.6.6f2, expected 6000.6.6f1" "$tmp/setup-out" && ! grep -q "^export " "$tmp/crane-calls" && [ "$(< "$root/.install-complete")" = "original marker" ] && [ -x "$root/Editor/Unity" ] && cmp -s "$root/Editor/Unity" "$img/base/opt/unity/Editor/Unity" && [ ! -e "$root/Editor/Data/PlaybackEngines/AndroidPlayer" ]'
check "setup --android refuses an image with no editor version metadata before downloading" \
  '! SETUP_ARGS=--android setup env UNITY_IMAGE=fixture:unknown && grep -qF "cannot verify Unity 6000.6.6f1 in fixture:unknown" "$tmp/setup-out" && ! grep -q "^export " "$tmp/crane-calls" && [ "$(< "$root/.install-complete")" = "original marker" ] && cmp -s "$root/Editor/Unity" "$img/base/opt/unity/Editor/Unity"'
check "setup --android over a base editor installs the validated Android image digest" \
  'SETUP_ARGS=--android setup env && grep -q "replacing the editor" "$tmp/setup-out" && grep -qxF "export $android_digest -" "$tmp/crane-calls" && [ -d "$root/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" ] && [ -d "$root/Editor/Data/PlaybackEngines/AndroidPlayer/NDK" ] && [ -f "$root/.install-complete" ] && [ ! -s "$root/.install-complete" ] && grep -q "setup ok" "$tmp/setup-out"'
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

#!/usr/bin/env bash
# Reproduce GNU tar's stale directory status error with a synthetic image stream.
set -euo pipefail
. "$(dirname "$0")/lib/fixture.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
ship_fixture "$tmp"
ship_fixture_process_view "$tmp/process-view"
export PATH="$tmp/bin:$tmp/process-view:$PATH" HOME="$tmp/home" LC_ALL=C
unset TAR_OPTIONS UNITY_IMAGE UNITY_MODULES UNITY_USERNAME UNITY_PASSWORD USERNAME PASSWORD
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN UNITY_RETURN_ON_EXIT
mkdir -p "$HOME" "$tmp/bin" "$tmp/legacy"
export FIXTURE_ARCHIVE="$tmp/complete.tar"

editor='Editor/Unity'
client='Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client'
android='Editor/Data/PlaybackEngines/AndroidPlayer'
for layout in complete missing-editor missing-client missing-ndk mixed-error; do
  python3 - "$tmp/$layout.tar" "$layout" "$editor" "$client" "$android" <<'PY'
import io
import sys
import tarfile

path, layout, editor, client, android = sys.argv[1:]
with tarfile.open(path, 'w', format=tarfile.GNU_FORMAT) as archive:
    def member(path, kind=tarfile.DIRTYPE, data=b'', link=''):
        info = tarfile.TarInfo('opt/unity' + ('/' + path if path else ''))
        info.type, info.mode, info.size, info.linkname = kind, 0o755, len(data), link
        archive.addfile(info, io.BytesIO(data))

    # A GNU dumpdir entry keeps directory status pending across siblings. The
    # late symlink makes tar record the SDK inode for its post-link status pass.
    gnu_dumpdir = b'D'
    member('', gnu_dumpdir, b'\0')
    if layout != 'missing-editor':
        member(editor, tarfile.REGTYPE, b'#!/bin/sh\n# Unity 6000.6.6f1\n')
    if layout != 'missing-client':
        member(client, tarfile.REGTYPE, b'#!/bin/sh\n')
    member(android + '//SDK')
    link_dir = 'link-trigger' if layout == 'missing-ndk' else 'NDK'
    member(android + '/' + link_dir)
    member(android + '/' + link_dir + '/sdk-tool', tarfile.SYMTYPE, link='../SDK//tool')
    # The filesystem sees the same path, but tar tracks the directory entry
    # by its spelling and fails to discard its old inode when replacing it.
    member(android + '/SDK', tarfile.REGTYPE, b'temporary')
    # Keep the replacement file's inode live across SDK's re-creation. ext4
    # can otherwise cycle the same inode through directory, file, directory.
    member(android + '/temporary-link', tarfile.LNKTYPE, link='opt/unity/' + android + '/SDK')
    member(android + '//SDK')
    member(android + '/SDK/tool', tarfile.REGTYPE, b'restored SDK payload\n')
    if layout == 'mixed-error':
        member(android + '/blocked', tarfile.REGTYPE, b'not a directory')
        member(android + '/blocked/child', tarfile.REGTYPE, b'cannot extract')
PY
done

cat > "$tmp/bin/crane" <<'EOF'
#!/bin/sh
[ "$#" = 3 ] && [ "$1" = export ] && [ "$3" = - ] || exit 99
cat "$FIXTURE_ARCHIVE" || exit
exit "${FAKE_EXPORT_STATUS:-0}"
EOF
printf '#!/bin/sh\necho "install ok installed"\n' > "$tmp/bin/dpkg-query"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/ldd"
printf '#!/bin/sh\nexit 99\n' > "$tmp/bin/curl"
chmod +x "$tmp/bin/"*

renamed='Directory renamed before its status could be extracted'
status=0
tar -x -C "$tmp/legacy" opt/unity < "$FIXTURE_ARCHIVE" 2> "$tmp/legacy.err" || status=$?
if [ "$status" -ne 2 ] || ! grep -Fq "$renamed" "$tmp/legacy.err"; then
  printf 'fixture did not reproduce the GNU tar error (status %s)\n' "$status" >&2
  cat "$tmp/legacy.err" >&2
  exit 1
fi

export BIN_DIR="$tmp/bin" OUT_DIR="$tmp/logs" UNITY_ROOT="$tmp/root/unity"
if ! bash "$script" setup --no-creds --android > "$tmp/setup.log" 2>&1; then
  cat "$tmp/setup.log" >&2
  exit 1
fi
[ -x "$UNITY_ROOT/$editor" ] && [ -x "$UNITY_ROOT/$client" ] || exit 1
grep -Fq 'checking the staged Android editor' "$tmp/setup.log"
[ -f "$UNITY_ROOT/.install-complete" ]
[ "$(readlink "$UNITY_ROOT/$android/NDK/sdk-tool")" = '../SDK//tool' ]
grep -Fxq 'restored SDK payload' "$UNITY_ROOT/$android/NDK/sdk-tool"

reject() {
  local layout="$1" expected="$2" export_status="${3:-0}"
  local root="$tmp/rejected-$layout-$export_status/unity" output="$tmp/rejected.log"
  if FIXTURE_ARCHIVE="$tmp/$layout.tar" UNITY_ROOT="$root" FAKE_EXPORT_STATUS="$export_status" \
      bash "$script" setup --no-creds --android > "$output" 2>&1; then
    printf 'Android setup unexpectedly accepted %s (export status %s)\n' "$layout" "$export_status" >&2
    exit 1
  fi
  grep -Fq "$renamed" "$output" && grep -Fq "$expected" "$output" && [ ! -e "$root" ] || {
    cat "$output" >&2
    exit 1
  }
}
reject missing-editor 'editor or licensing client missing'
reject missing-client 'editor or licensing client missing'
reject missing-ndk 'no Android SDK/NDK'
reject mixed-error 'Not a directory'
reject complete "$renamed" 23

# Base mode keeps the legacy extraction behavior on the same input.
export UNITY_ROOT="$tmp/base/unity"
if bash "$script" setup --no-creds > "$tmp/base.log" 2>&1; then
  echo 'base setup unexpectedly accepted the Android fixture' >&2
  exit 1
fi
grep -Fq "$renamed" "$tmp/base.log"
[ ! -e "$UNITY_ROOT" ]
echo 'ok   Android setup accepts only the directory status error with a complete stage and successful export'

#!/usr/bin/env bash
# Offline crane bootstrap tests: synthetic archives and a fake curl.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export PROJECT="$tmp" YETIKIT_CONFIG="$tmp/yetikit.json" BIN_DIR="$tmp/install with spaces"
unset CRANE_VERSION
export FIXTURES="$tmp" REAL_SHA256SUM="$(command -v sha256sum)"
mkdir "$tmp/bin" "$tmp/payload"
export PATH="$tmp/bin:$PATH"
cp "$ship/tests/fixtures/scene/yetikit.json" "$tmp/base.json"

release=https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_x86_64.tar.gz
override=https://example.invalid/custom.tar.gz
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "${@: -1}" >> "$FIXTURES/requests"
exec cat -- "$FIXTURES/$ARCHIVE.tar.gz"
EOF
# Let only the known synthetic release stand in for the actual pinned bytes.
# All verification of override archives and mismatched content uses real SHA-256.
cat > "$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -eu
read -r actual suffix < <("$REAL_SHA256SUM" "$@")
if [ "$actual" = "${SYNTHETIC_RELEASE:-}" ]; then
  actual=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
fi
printf '%s  %s\n' "$actual" "$suffix"
EOF
cat > "$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -s) echo Linux ;;
  -m) echo "${ARCH:-x86_64}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/"*
for fixture in release custom; do
  printf '#!/bin/sh\necho %s\n' "$fixture" > "$tmp/payload/crane"
  chmod +x "$tmp/payload/crane"
  printf 'not crane\n' > "$tmp/payload/gcrane"
  tar -czf "$tmp/$fixture.tar.gz" -C "$tmp/payload" crane gcrane
done
read -r SYNTHETIC_RELEASE _ < <("$REAL_SHA256SUM" "$tmp/release.tar.gz")
export SYNTHETIC_RELEASE
read -r custom_sha _ < <("$REAL_SHA256SUM" "$tmp/custom.tar.gz")

run_install() {
  rm -f "$tmp/requests"
  bash -euo pipefail -c '
    . "$1/linux-unity.sh"
    # Ignore any crane installed on the test worker outside our fixture.
    command() {
      if [ "$*" = "-v crane" ]; then [ -x "$FIXTURES/bin/crane" ]; else builtin command "$@"; fi
    }
    install_crane
  ' _ "$ship" > "$tmp/output" 2>&1
}
fail() { printf 'FAIL: %s\n' "$*" >&2; if [ -f "$tmp/output" ]; then grep . "$tmp/output" >&2 || :; fi; exit 1; }
only_crane() { [ "$(find "$BIN_DIR" -mindepth 1 -printf '%f\n')" = crane ]; }
nothing_installed() { [ ! -d "$BIN_DIR" ] || [ -z "$(find "$BIN_DIR" -mindepth 1 -print -quit)" ]; }
config() { jq --argjson setup "$1" '.setup = $setup' "$tmp/base.json" > "$YETIKIT_CONFIG"; }

config '{}'
ARCHIVE=release run_install || fail 'pinned release should install'
[[ "$(< "$tmp/requests")" = "$release" && "$("$BIN_DIR/crane")" = release ]] && only_crane || fail 'install only the pinned crane'
echo 'ok: pinned archive verifies and installs only crane'

rm -rf -- "$BIN_DIR"
if ARCHIVE=custom run_install; then fail 'pinned release mismatch succeeded'; fi
[[ "$(< "$tmp/requests")" = "$release" ]] && grep -qi 'checksum mismatch' "$tmp/output" && nothing_installed || fail 'pin mismatch must leave nothing installed'
echo 'ok: mismatched pinned archive fails closed'

if ARCH=aarch64 ARCHIVE=release run_install; then fail 'unexpected pinned release on aarch64'; fi
[[ ! -e "$tmp/requests" ]] && grep -q 'aarch64' "$tmp/output" && grep -q 'setup.craneArchive' "$tmp/output" && nothing_installed || fail 'unsupported architecture must give guidance and not download'
if CRANE_VERSION=v0.0.0 ARCHIVE=release run_install; then fail 'unexpected unpinned release'; fi
[[ ! -e "$tmp/requests" ]] && grep -q 'v0.0.0' "$tmp/output" && nothing_installed || fail 'unsupported version must not download'
echo 'ok: unsupported default architecture or version makes no download'

config "{\"craneArchive\":\"$override\",\"craneSha256\":\"${custom_sha^^}\"}"
ARCH=aarch64 ARCHIVE=custom run_install || fail 'checksum-verified override should install'
[[ "$(< "$tmp/requests")" = "$override" && "$("$BIN_DIR/crane")" = custom ]] && only_crane || fail 'install only the override crane'
echo 'ok: custom archive and digest override the pin'

ARCH=aarch64 ARCHIVE=release run_install || fail 'preinstalled BIN_DIR crane should win'
[[ ! -e "$tmp/requests" && "$("$BIN_DIR/crane")" = custom ]] || fail 'preinstalled BIN_DIR crane was not preserved'
mv -- "$BIN_DIR/crane" "$tmp/bin/crane"
ARCH=aarch64 ARCHIVE=release run_install || fail 'preinstalled PATH crane should win'
[[ ! -e "$tmp/requests" ]] && nothing_installed || fail 'preinstalled PATH crane made a download'
rm -- "$tmp/bin/crane"
echo 'ok: preinstalled crane makes no download'

if ARCHIVE=release run_install; then fail 'override checksum mismatch succeeded'; fi
grep -qi 'checksum mismatch' "$tmp/output" && nothing_installed || fail 'override mismatch must leave nothing installed'
config "{\"craneArchive\":\"$override\"}"
ARCHIVE=custom run_install || fail 'archive-only override should still install'
[[ "$(< "$tmp/requests")" = "$override" && "$("$BIN_DIR/crane")" = custom ]] && only_crane || fail 'archive-only override must install only crane'
echo 'ok: override verifies a supplied digest and keeps archive-only compatibility'

for invalid in null 12 '""' '"xyz"' "\"$custom_sha\\n\""; do
  config "{\"craneArchive\":\"$override\",\"craneSha256\":$invalid}"
  if ARCHIVE=custom run_install; then fail "config accepted invalid digest: $invalid"; fi
  [[ ! -e "$tmp/requests" ]] && grep -q 'invalid.*setup.craneSha256' "$tmp/output" || fail 'invalid digest should fail validation'
done
echo 'ok: invalid digests fail config validation'

# Shared isolated setup for the topical creds regressions.
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"; mkdir -p "$proj/Assets"; echo x > "$proj/Assets/a.txt"
# shellcheck source=Tools/ship/tests/lib/fake-unity.sh
. "$(dirname "${BASH_SOURCE[0]}")/fake-unity.sh"
git_init
good_ulf="$(cat "$ULF")"
good_ulf_now() { printf '%s\n' "$good_ulf" > "$ULF"; }
# Fake Licensing Client: logs every call with its arguments to $tmp/lc-calls and echoes them (as the real one may echo
# the account), --activate-ulf writes a valid ULF, --return-ulf exits $FAKE_RETURN_RC.
lcdir="$tmp/unity/Editor/Data/Resources/Licensing/Client"; mkdir -p "$lcdir"
cat > "$lcdir/Unity.Licensing.Client" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/lc-calls"; echo "client called with \$*"
case "\$1" in
  --activate-ulf) printf '%s\n' '$good_ulf' > "\$ULF" ;;
  --return-ulf) exit "\${FAKE_RETURN_RC:-0}" ;;
esac
EOF
chmod +x "$lcdir/Unity.Licensing.Client"
unset UNITY_USERNAME UNITY_PASSWORD USERNAME PASSWORD UNITY_RETURN_ON_EXIT FAKE_RETURN_RC
# Run linux-unity.sh with only the given env (credentials, flags); all output in $tmp/out, exit code in $rc.
lu() { rc=0; : > "$tmp/lc-calls"; env "$@" bash "$script" "${args[@]}" > "$tmp/log" 2>&1 || rc=$?; }
leaks() { grep -qE 'hubuser@x\.io|hub-secret|unity-secret' "$tmp/log"; }
creds_error='[linux-unity] error: set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)'


creds_required_cases() {
# Credentials are required before licence reuse, preflight, setup/downloads, or editor work on every entry point.
for c in crane curl dpkg ldd apt-get; do
  printf '#!/bin/sh\necho "%s" >> "%s/work-calls"\nexit 99\n' "$c" "$tmp" > "$tmp/bin/$c"
  chmod +x "$tmp/bin/$c"
done
mkdir -p "$proj/Temp"
for licence in "$@"; do
  for cmd in activate open test scene lab apk all; do
    if [ "$licence" = present ]; then good_ulf_now; else rm -f "$ULF"; fi
    args=("$cmd"); [ "$cmd" != test ] || args+=(editmode)
    : > "$tmp/runs"; : > "$tmp/work-calls"; echo keep > "$proj/Temp/UnityLockfile"; echo keep > "$SHM_DIR/udsMem-creds"
    lu BIN_DIR="$tmp/bin"
    check "$cmd without credentials ($licence ULF): exact error before any work" \
      '[ "$rc" = 1 ] && grep -Fxq "$creds_error" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ ! -s "$tmp/runs" ] && [ ! -s "$tmp/work-calls" ] && [ "$(cat "$proj/Temp/UnityLockfile")" = keep ] && [ "$(cat "$SHM_DIR/udsMem-creds")" = keep ]'
    if [ "$licence" = present ]; then
      check "$cmd without credentials leaves the existing ULF untouched" '[ "$(cat "$ULF")" = "$good_ulf" ]'
    else
      check "$cmd without credentials does not create a ULF" '[ ! -e "$ULF" ]'
    fi
  done
done
rm -f "$proj/Temp/UnityLockfile" "$SHM_DIR/udsMem-creds"

}

#!/usr/bin/env bash
# Tests linux-unity.sh's USERNAME/PASSWORD credentials fallback (never printed, UNITY_* wins) and the opt-in
# UNITY_RETURN_ON_EXIT=1 licence return, with the fake editor and a fake Licensing Client; never runs Unity.
# Run: Tools/ship/test-all.sh
# shellcheck disable=SC2016,SC2034 # check() evals its single-quoted condition, which reads rc
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"; mkdir -p "$proj/Assets"; echo x > "$proj/Assets/a.txt"
# shellcheck source=Tools/ship/tests/lib/fake-unity.sh
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
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

# Credentials are required before licence reuse, preflight, setup/downloads, or editor work on every entry point.
for c in crane curl dpkg ldd apt-get; do
  printf '#!/bin/sh\necho "%s" >> "%s/work-calls"\nexit 99\n' "$c" "$tmp" > "$tmp/bin/$c"
  chmod +x "$tmp/bin/$c"
done
mkdir -p "$proj/Temp"
for licence in present absent; do
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

# --- credentials fallback ------------------------------------------------------------------------------------------
args=(activate); rm -f "$ULF"
lu USERNAME=hubuser@x.io PASSWORD=hub-secret
check "only USERNAME/PASSWORD: activate passes need_creds" '[ "$rc" = 0 ] && ! grep -q "set UNITY_USERNAME" "$tmp/log"'
check "only USERNAME/PASSWORD: the licensing client gets those values" \
  'grep -qx -- "--activate-ulf --username hubuser@x.io --password hub-secret" "$tmp/lc-calls"'
check "only USERNAME/PASSWORD: neither value is printed (the client's echo is masked)" \
  '! leaks && grep -q "<email>" "$tmp/log" && grep -q "<password>" "$tmp/log"'
args=(return)
lu USERNAME=hubuser@x.io PASSWORD=hub-secret
check "only USERNAME/PASSWORD: return passes and returns with them, printing neither" \
  '[ "$rc" = 0 ] && grep -qx -- "--return-ulf --username hubuser@x.io --password hub-secret" "$tmp/lc-calls" && ! leaks'
check "successful explicit return removes the ULF" '[ ! -e "$ULF" ]'
lu
check "return without a ULF skips credentials and the Licensing Client" \
  '[ "$rc" = 0 ] && grep -Fq "return: licence already returned" "$tmp/log" && [ ! -s "$tmp/lc-calls" ]'
good_ulf_now
lu UNITY_USERNAME=u@x.io UNITY_PASSWORD=unity-secret USERNAME=hubuser@x.io PASSWORD=hub-secret
check "UNITY_USERNAME/UNITY_PASSWORD win over USERNAME/PASSWORD" \
  '[ "$rc" = 0 ] && grep -qx -- "--return-ulf --username u@x.io --password unity-secret" "$tmp/lc-calls" && ! leaks'
good_ulf_now
lu UNITY_USERNAME= UNITY_PASSWORD= USERNAME=hubuser@x.io PASSWORD=hub-secret
check "empty UNITY_USERNAME/UNITY_PASSWORD fall back to USERNAME/PASSWORD" \
  '[ "$rc" = 0 ] && grep -q -- "--username hubuser@x.io" "$tmp/lc-calls"'
good_ulf_now
lu USERNAME=hubuser@x.io
check "USERNAME without PASSWORD: no fallback, the usual error" \
  '[ "$rc" != 0 ] && grep -Fxq "$creds_error" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ -f "$ULF" ] && ! leaks'

# --- UNITY_RETURN_ON_EXIT=1 ----------------------------------------------------------------------------------------
creds=(UNITY_USERNAME=u@x.io UNITY_PASSWORD=unity-secret)
returns() { grep -c -- "^--return-ulf" "$tmp/lc-calls" || true; }
args=(open); rm -f "$ULF"
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_UNITY_RC=1
check "UNITY_RETURN_ON_EXIT=1: a failed open that activated returns the licence and keeps its failure" \
  '[ "$rc" = 1 ] && grep -q -- "^--activate-ulf" "$tmp/lc-calls" && [ "$(returns)" = 1 ] && grep -q "returning the held licence" "$tmp/log" && [ ! -f "$ULF" ]'
check "UNITY_RETURN_ON_EXIT=1: the pidfile is gone afterwards" '[ ! -f "$OUT_DIR/linux-unity.pid" ]'
rm -f "$ULF"
lu USERNAME=hubuser@x.io PASSWORD=hub-secret UNITY_RETURN_ON_EXIT=1
check "UNITY_RETURN_ON_EXIT=1 with the USERNAME/PASSWORD fallback: an open that activated returns, printing neither" \
  '[ "$rc" = 0 ] && grep -qx -- "--return-ulf --username hubuser@x.io --password hub-secret" "$tmp/lc-calls" && ! leaks'
rm -f "$ULF"
lu "${creds[@]}" FAKE_UNITY_RC=1
check "without UNITY_RETURN_ON_EXIT: an open that activated keeps the licence" \
  '[ "$rc" = 1 ] && grep -q -- "^--activate-ulf" "$tmp/lc-calls" && [ "$(returns)" = 0 ]'
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1
check "UNITY_RETURN_ON_EXIT=1: a reused valid ULF is returned without activation" \
  '[ "$rc" = 0 ] && ! grep -q -- "^--activate-ulf" "$tmp/lc-calls" && [ "$(returns)" = 1 ] && [ ! -f "$ULF" ]'
rm -f "$ULF"
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_RETURN_RC=7
check "UNITY_RETURN_ON_EXIT=1: a failed return alone makes the run exit nonzero (its code)" \
  '[ "$rc" = 7 ] && grep -q "licence return failed (exit 7)" "$tmp/log" && [ -f "$ULF" ]'
args=(test editmode); rm -f "$ULF"
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_FAILS=X.Broken
check "UNITY_RETURN_ON_EXIT=1: a failing test run that activated returns the licence, keeps the test failure" \
  '[ "$rc" = 2 ] && [ "$(returns)" = 1 ]'
args=(all); rm -f "$ULF"; : > "$tmp/unity/.install-complete"
for c in crane dpkg ldd; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 BIN_DIR="$tmp/bin"
check "UNITY_RETURN_ON_EXIT=1 with all: one return, not two" '[ "$rc" = 0 ] && [ "$(returns)" = 1 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

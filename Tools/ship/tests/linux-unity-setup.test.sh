#!/usr/bin/env bash
# Tests that `linux-unity.sh setup` never trusts an interrupted editor extract.
# Stubs crane (fake image stream), dpkg and ldd; writes only under a temp dir.
# Run: bash Tools/ship/tests/linux-unity-setup.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; setup_pids=()
cleanup() {
  touch "$tmp/extract-release"
  for pid in "${setup_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$tmp"
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# Fake image contents: opt/unity with the editor binary and the licensing client.
img="$tmp/img"; lc="opt/unity/Editor/Data/Resources/Licensing/Client"
mkdir -p "$img/$lc" "$tmp/bin"
printf '#!/bin/sh\n# Unity 6000.6.6f1\n' > "$img/opt/unity/Editor/Unity"; cp "$img/opt/unity/Editor/Unity" "$img/$lc/Unity.Licensing.Client"
chmod +x "$img/opt/unity/Editor/Unity" "$img/$lc/Unity.Licensing.Client"
# FAKE_CUT=1 drops the stream; FAKE_EXTRACT_GATE synchronizes concurrent extracts.
cat > "$tmp/bin/crane" <<EOF
#!/bin/bash
echo crane >> "$tmp/download-calls"
if [ -n "\${FAKE_EXTRACT_GATE:-}" ]; then
  touch "\$FAKE_EXTRACT_GATE"
  deadline=\$((SECONDS + 90))
  while [ ! -e "$tmp/extract-release" ]; do
    [ "\$SECONDS" -lt "\$deadline" ] || exit 1
    /bin/sleep 0.02
  done
fi
if [ "\${FAKE_CUT:-0}" = 1 ]; then tar -c -C "$img" opt/unity/Editor/Unity; exit 1; fi
tar -c -C "$img" opt/unity
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/dpkg"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/ldd"
# Never download or start a detached idle watcher, even if setup regresses.
printf '#!/bin/sh\necho curl >> "%s/download-calls"\nexit 99\n' "$tmp" > "$tmp/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/nohup"
chmod +x "$tmp/bin/"*

unset UNITY_USERNAME UNITY_PASSWORD USERNAME PASSWORD THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN UNITY_RETURN_ON_EXIT
# Source only the installer module with a stubbed lookup: this must print a
# usable pinned command without invoking curl or any real installer.
missing_rc=0
bash -c '
  . "$1"
  command() { [ "$*" != "-v crane" ] && builtin command "$@"; }
  log() { :; }
  die() { printf "%s\n" "$*" >&2; exit 1; }
  ship_config_get() { :; }
  BIN_DIR="$2/install with spaces"; CRANE_VERSION=v0.22.1
  install_crane
' _ "$(dirname "$script")/linux-unity-setup.sh" "$tmp" > "$tmp/missing-crane" 2>&1 || missing_rc=$?
check 'missing crane gives a pinned one-line install command with a quoted destination' \
  '[ "$missing_rc" = 1 ] && grep -qF "go install github.com/google/go-containerregistry/cmd/crane@v0.22.1" "$tmp/missing-crane" && grep -qF "install\\ with\\ spaces" "$tmp/missing-crane" && [ ! -e "$tmp/download-calls" ]'
setup_args=()
run() { PATH="$tmp/bin:$PATH" PROJECT="$tmp" UNITY_ROOT="$tmp/root/unity" BIN_DIR="$tmp/bin" OUT_DIR="$tmp/logs" \
  UNITY_USERNAME=u UNITY_PASSWORD=p "$@" bash "$script" setup "${setup_args[@]}" >"$tmp/out" 2>&1; }

check "setup without credentials fails before crane or download" \
  '! run env UNITY_USERNAME= UNITY_PASSWORD= && grep -Fxq "[linux-unity] error: set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)" "$tmp/out" && [ ! -e "$tmp/download-calls" ] && [ ! -e "$tmp/root" ]'
setup_args=(--no-creds)
check "setup --no-creds succeeds without credentials" \
  'run env UNITY_USERNAME= UNITY_PASSWORD= UNITY_ROOT="$tmp/no-creds/unity" && grep -q "setup ok" "$tmp/out" && grep -qx crane "$tmp/download-calls" && [ -f "$tmp/no-creds/unity/.install-complete" ]'
setup_args=()

check "interrupted extract fails setup" '! run env FAKE_CUT=1'
check "interrupted extract leaves no UNITY_ROOT" '[ ! -e "$tmp/root/unity" ]'
check "interrupted extract leaves no staging dir (EXIT trap)" '! ls -d "$tmp/root/.unity-extract."* >/dev/null 2>&1'
check "re-run after interruption succeeds" 'run env'
check "re-run reports setup ok" 'grep -q "setup ok" "$tmp/out"'
check "editor installed" '[ -x "$tmp/root/unity/Editor/Unity" ]'
check "licensing client installed" '[ -x "$tmp/root/unity/Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client" ]'
check "staging dir removed" '! ls -d "$tmp/root/.unity-extract."* >/dev/null 2>&1'
check "completion marker written" '[ -f "$tmp/root/unity/.install-complete" ] && [ ! -e "$tmp/root/unity/.install-partial" ]'
check "second setup skips extract" 'run env && grep -q "editor already" "$tmp/out"'
rm "$tmp/root/unity/Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client"
check "incomplete existing root is not reported ok" '! run env && grep -q "incomplete" "$tmp/out"'


# #47: a custom UNITY_ROOT that already exists as an empty directory (a mount point) is filled in place: the editor
# ends up at $UNITY_ROOT/Editor, not $UNITY_ROOT/unity, and nothing touches the default /opt/unity. Wrappers log every
# mv/rm/mkdir/tar/find argument so the test can prove that.
real() { command -v "$1"; }
for c in mv rm mkdir tar find; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/ops"\nexec %s "$@"\n' "$c" "$tmp" "$(real "$c")" > "$tmp/bin/$c"
done
chmod +x "$tmp/bin/"*
mkdir -p "$tmp/srv/unity"; : > "$tmp/ops"
check "an empty custom UNITY_ROOT is filled" 'run env UNITY_ROOT="$tmp/srv/unity" && grep -q "setup ok" "$tmp/out"'
check "the editor is at UNITY_ROOT/Editor, not UNITY_ROOT/unity" \
  '[ -x "$tmp/srv/unity/Editor/Unity" ] && [ -x "$tmp/srv/unity/Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client" ] && [ ! -e "$tmp/srv/unity/unity" ]'
check "the stage sits beside UNITY_ROOT and is removed" \
  'grep -qE "$tmp/srv/\.unity-extract\.[A-Za-z0-9]{6}" "$tmp/ops" && ! ls -d "$tmp/srv/.unity-extract."* >/dev/null 2>&1'
check "nothing touches the default /opt/unity" '! grep -qE "(^| )/opt/unity" "$tmp/ops"'
check "a re-run trusts the filled root" 'run env UNITY_ROOT="$tmp/srv/unity" && grep -q "editor already at $tmp/srv/unity" "$tmp/out"'
mkdir -p "$tmp/srv/other"; echo x > "$tmp/srv/other/stray"
check "a non-empty incomplete custom UNITY_ROOT is refused, not merged into" \
  '! run env UNITY_ROOT="$tmp/srv/other" && grep -q "incomplete" "$tmp/out" && [ ! -e "$tmp/srv/other/Editor" ]'

# #145.1: emptiness is established with the install's privileges and the listing's exit status counts. Before, an
# unprivileged `ls -A` of a root-owned 0700 UNITY_ROOT failed with no output, so the directory looked empty and was
# merged into. FAKE_FIND_FAIL=<dir> makes the listing of that directory fail the same way (no output, nonzero exit).
cat > "$tmp/bin/find" <<EOF
#!/bin/sh
echo "find \$*" >> "$tmp/ops"
for a in "\$@"; do [ -n "\${FAKE_FIND_FAIL:-}" ] && [ "\$a" = "\$FAKE_FIND_FAIL" ] && exit 1; done
exec $(real find) "\$@"
EOF
chmod +x "$tmp/bin/find"
mkdir -p "$tmp/locked/unity"; echo keep > "$tmp/locked/unity/stray"
check "a UNITY_ROOT whose listing fails is refused untouched" \
  '! run env UNITY_ROOT="$tmp/locked/unity" FAKE_FIND_FAIL="$tmp/locked/unity" && grep -q "cannot tell whether $tmp/locked/unity is empty" "$tmp/out" && [ "$(ls -A "$tmp/locked/unity")" = stray ]'
check "nothing is extracted for a root of unknown emptiness" '! ls -d "$tmp/locked/.unity-extract."* >/dev/null 2>&1'

# #145.2: each run stages in its own mktemp dir, so concurrent setups of sibling roots never clobber each other, and
# another stage beside them (here the old shared .unity-extract.tmp) is left alone.
mkdir -p "$tmp/sib/.unity-extract.tmp"; echo theirs > "$tmp/sib/.unity-extract.tmp/f"
ra=0; rb=0
PATH="$tmp/bin:$PATH" PROJECT="$tmp" UNITY_ROOT="$tmp/sib/a" BIN_DIR="$tmp/bin" OUT_DIR="$tmp/logs-a" UNITY_USERNAME=u UNITY_PASSWORD=p FAKE_EXTRACT_GATE="$tmp/extract-a" timeout -k 5 120 bash "$script" setup >"$tmp/out-a" 2>&1 & pa=$!
setup_pids+=("$pa")
PATH="$tmp/bin:$PATH" PROJECT="$tmp" UNITY_ROOT="$tmp/sib/b" BIN_DIR="$tmp/bin" OUT_DIR="$tmp/logs-b" UNITY_USERNAME=u UNITY_PASSWORD=p FAKE_EXTRACT_GATE="$tmp/extract-b" timeout -k 5 120 bash "$script" setup >"$tmp/out-b" 2>&1 & pb=$!
setup_pids+=("$pb")
ship_wait_until test -e "$tmp/extract-a"
ship_wait_until test -e "$tmp/extract-b"
check "both extracts are gated with distinct staging directories" '[ "$(find "$tmp/sib" -maxdepth 1 -name ".unity-extract.*" ! -name ".unity-extract.tmp" | wc -l)" = 2 ] && kill -0 "$pa" && kill -0 "$pb"'
touch "$tmp/extract-release"
wait "$pa" || ra=$?; wait "$pb" || rb=$?
setup_pids=()
check "two concurrent setups of sibling roots both succeed" '[ "$ra" = 0 ] && [ "$rb" = 0 ]'
check "both sibling roots are complete" \
  '[ -x "$tmp/sib/a/Editor/Unity" ] && [ -f "$tmp/sib/a/.install-complete" ] && [ -x "$tmp/sib/b/Editor/Unity" ] && [ -f "$tmp/sib/b/.install-complete" ]'
check "each run removed only its own stage" \
  '[ "$(cat "$tmp/sib/.unity-extract.tmp/f")" = theirs ] && [ "$(ls -A "$tmp/sib" | tr "\n" " ")" = ".unity-extract.tmp a b " ]'

# #145.3: a move that fails part-way (here: every entry moved, then mv reports a failure, as a cross-filesystem copy
# can) leaves a tree that passes the executable checks. It has no completion marker, so a re-run refuses it.
cat > "$tmp/bin/mv" <<EOF
#!/bin/sh
echo "mv \$*" >> "$tmp/ops"
$(real mv) "\$@" || exit
[ "\${FAKE_MV_FAIL:-0}" = 1 ] && [ "\$1" = -t ] && exit 1
exit 0
EOF
chmod +x "$tmp/bin/mv"
check "a failed move fails setup" '! run env UNITY_ROOT="$tmp/xfs/unity" FAKE_MV_FAIL=1'
check "the failed move left a tree that passes the executable checks, unmarked" \
  '[ -x "$tmp/xfs/unity/Editor/Unity" ] && [ -x "$tmp/xfs/unity/Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client" ] && [ ! -e "$tmp/xfs/unity/.install-complete" ]'
check "a re-run refuses it as incomplete and says to clear it" \
  '! run env UNITY_ROOT="$tmp/xfs/unity" && grep -q "incomplete" "$tmp/out" && grep -q "clear it" "$tmp/out" && ! grep -q "setup ok" "$tmp/out"'
check "the refused tree is still not marked complete" '[ ! -e "$tmp/xfs/unity/.install-complete" ]'

# #145.3: an install from before the marker existed keeps working: the editor is the pinned version, so it is marked once.
mkdir -p "$tmp/old"; cp -a "$img/opt/unity" "$tmp/old/unity"
check "a pre-existing install of the pinned version is trusted and marked once" \
  'run env UNITY_ROOT="$tmp/old/unity" && grep -q "pre-existing install, marked complete" "$tmp/out" && [ -f "$tmp/old/unity/.install-complete" ]'
check "the next run sees the marker" 'run env UNITY_ROOT="$tmp/old/unity" && grep -q "editor already at $tmp/old/unity$" "$tmp/out"'
mkdir -p "$tmp/older"; cp -a "$img/opt/unity" "$tmp/older/unity"; printf '#!/bin/sh\n# Unity 2022.3.1f1\n' > "$tmp/older/unity/Editor/Unity"
check "a pre-existing install of another version is refused, not marked" \
  '! run env UNITY_ROOT="$tmp/older/unity" && grep -q "not Unity 6000.6.6f1" "$tmp/out" && [ ! -e "$tmp/older/unity/.install-complete" ]'

# A completion marker must not bypass a newly configured editor version.
touch "$tmp/older/unity/.install-complete"
check "a marked install with another version is refused" \
  '! run env UNITY_ROOT="$tmp/older/unity" && grep -q "not Unity 6000.6.6f1" "$tmp/out"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

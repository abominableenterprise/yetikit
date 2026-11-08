#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# Tests linux-unity.sh activate (ULF validation), open (preflight cleanup), test (RenderTool routing) and all (licence
# return failure on exit) with a fake editor, Licensing Client, xvfb-run and shared-memory dir; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-commands.test.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

proj="$tmp/proj"; root="$tmp/unity"; lcdir="$root/Editor/Data/Resources/Licensing/Client"
mkdir -p "$proj/Library" "$proj/Temp" "$proj/Assets/Tests/Park" "$lcdir" "$tmp/bin" "$tmp/shm"
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$proj"
export PIDFILE_FALLBACK="$tmp/fallback.pid"
good_ulf() { printf '<root><License id="Terms"><StopDate Value="%s" /></License><Signature>x</Signature></root>\n' "${1:-}"; }

# Fake editor: logs its arguments (one run per line) and, for open, what was still around at launch.
cat > "$root/Editor/Unity" <<EOF
#!/usr/bin/env bash
# Unity 6000.6.6f1
echo "\$*" >> "$tmp/runs"
[ -z "\${FAKE_EDITOR_SLEEP:-}" ] || { echo \$\$ > "$tmp/editor.pid"; sleep "\$FAKE_EDITOR_SLEEP"; }
{ ls "$tmp/shm"; [ -e "$proj/Temp/UnityLockfile" ] && echo lockfile
  [ -f "$tmp/stale.pid" ] && kill -0 "\$(cat "$tmp/stale.pid")" 2>/dev/null && echo datastore; } > "$tmp/at-launch" || true
exit "\${FAKE_UNITY_RC:-0}"
EOF
# Fake Licensing Client: --activate-ulf writes $FAKE_NEW_ULF (default a valid ULF); --return-ulf exits $FAKE_RETURN_RC.
cat > "$lcdir/Unity.Licensing.Client" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$tmp/lc-calls"
case "\$1" in
  --activate-ulf) if [ -n "\${FAKE_NEW_ULF:-}" ]; then printf '%s' "\$FAKE_NEW_ULF" > "\$ULF"
    else printf '<root><License id="Terms"><StopDate Value="" /></License><Signature>x</Signature></root>\n' > "\$ULF"; fi ;;
  --return-ulf) echo \$\$ > "$tmp/return.pid"; [ -z "\${FAKE_RETURN_SLEEP:-}" ] || sleep "\$FAKE_RETURN_SLEEP"
    echo "return"; exit "\${FAKE_RETURN_RC:-0}" ;;
esac
EOF
chmod +x "$root/Editor/Unity" "$lcdir/Unity.Licensing.Client"
: > "$root/.install-complete"   # a finished install, so `all`'s setup trusts it (#145)
printf '#!/usr/bin/env bash\n[ "$1" = -a ] && shift\n[ "$1" = -s ] && shift 2\nexec "$@"\n' > "$tmp/bin/xvfb-run"
for c in crane dpkg ldd nohup; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$c"; done
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" PROJECT="$proj" UNITY_ROOT="$root" ULF="$tmp/ulf/Unity_lic.ulf" OUT_DIR="$tmp/out" \
  SHM_DIR="$tmp/shm" TASK_CACHE=no-task-cache BIN_DIR="$tmp/bin"
mkdir -p "$tmp/ulf"
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN   # never reach the real hub
unset UNITY_USERNAME UNITY_PASSWORD USERNAME PASSWORD UNITY_RETURN_ON_EXIT
trap 'if [ -f "$tmp/stale.pid" ]; then kill "$(cat "$tmp/stale.pid")" 2>/dev/null || true; wait "$(cat "$tmp/stale.pid")" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
lu() { UNITY_USERNAME="${UNITY_USERNAME-u}" UNITY_PASSWORD="${UNITY_PASSWORD-p}" bash "$script" "$@" 2>"$tmp/err"; }
creds() { UNITY_USERNAME=u UNITY_PASSWORD=p "$@"; }

# --- #355: the missing-client error names the runnable setup command ---------------------------------------------
chmod -x "$lcdir/Unity.Licensing.Client"
check "activate: missing licensing client gives the full setup command" \
  '! creds lu activate && grep -Fxq "[linux-unity] error: licensing client not found; run \`Tools/ship/linux-unity.sh setup\` first" "$tmp/err"'
chmod +x "$lcdir/Unity.Licensing.Client"

# --- #47: activate validates an existing Unity_lic.ulf ------------------------------------------------------------
good_ulf > "$ULF"; : > "$tmp/lc-calls"
check "activate: a valid ULF is checked and kept (no re-activation)" \
  'creds lu activate && grep -q "already present.*(checked)" "$tmp/err" && ! grep -q -- --activate-ulf "$tmp/lc-calls"'
# #145: cut-sig is a valid ULF truncated inside <Signature (both opening tags present), cut-root one cut after
# </Signature> but before the closing root element: both are invalid and take the same recovery path.
for bad in corrupt empty expired cut-sig cut-root; do
  case "$bad" in corrupt) echo garbage > "$ULF" ;; empty) : > "$ULF" ;; expired) good_ulf 2001-01-01T00:00:00 > "$ULF" ;;
    cut-sig) good_ulf | head -c 70 > "$ULF" ;; cut-root) good_ulf | sed 's#</root>##' > "$ULF" ;; esac
  rm -f "$ULF".invalid-*; : > "$tmp/lc-calls"
  check "activate: ULF ($bad) is reported, set aside and re-activated" \
    'creds lu activate && grep -q "is invalid" "$tmp/err" && grep -q -- --activate-ulf "$tmp/lc-calls" && ls "$ULF".invalid-* >/dev/null 2>&1 && grep -q "<Signature" "$ULF"'
done
good_ulf | head -c 70 > "$ULF"
check "activate: the cut-sig fixture keeps both opening tags and is reported as truncated" \
  'grep -q "<License" "$ULF" && grep -q "<Signature" "$ULF" && ! grep -q "</Signature>" "$ULF" && creds lu activate && grep -q "is invalid: truncated" "$tmp/err"'
{ printf '<?xml version="1.0" encoding="UTF-8"?>\n'; good_ulf; } > "$ULF"; : > "$tmp/lc-calls"
check "activate: a ULF with an XML declaration and a trailing newline is valid" \
  'creds lu activate && grep -q "(checked)" "$tmp/err" && ! grep -q -- --activate-ulf "$tmp/lc-calls"'
good_ulf 2999-01-01T00:00:00 > "$ULF"; : > "$tmp/lc-calls"
check "activate: a ULF with a future StopDate is valid" 'creds lu activate && ! grep -q -- --activate-ulf "$tmp/lc-calls"'
echo garbage > "$ULF"
check "activate: an activation that writes a bad ULF fails with a recovery path" \
  '! creds env FAKE_NEW_ULF=junk bash "$script" activate 2>"$tmp/err" && grep -q "invalid" "$tmp/err" && grep -q "recover:.*return.*activate" "$tmp/err"'
echo garbage > "$ULF"
check "open: a corrupt ULF without credentials fails before licence validation or an editor run" \
  ': > "$tmp/runs"; ! UNITY_USERNAME= UNITY_PASSWORD= lu open && grep -Fxq "[linux-unity] error: set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)" "$tmp/err" && [ "$(cat "$ULF")" = garbage ] && [ ! -s "$tmp/runs" ]'
check "open: a corrupt ULF with credentials re-activates once, then opens" \
  'creds lu open && grep -q "re-activating once" "$tmp/err" && grep -q "<Signature" "$ULF"'
good_ulf | head -c 70 > "$ULF"
check "open: a truncated ULF without credentials fails before validation or the editor" \
  ': > "$tmp/runs"; ! UNITY_USERNAME= UNITY_PASSWORD= lu open && grep -Fxq "[linux-unity] error: set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "open (ensure_licence): a ULF truncated inside <Signature with credentials re-activates once, then opens" \
  'creds lu open && grep -q "is truncated.*re-activating once" "$tmp/err" && grep -q "</Signature>" "$ULF"'
good_ulf > "$ULF"

# Open preserves an unmarked helper and its files; a later open with no foreign helper wipes stale files.
cp /bin/sleep "$root/Editor/Data/Unity.DataStore"
env -u LINUX_UNITY_RUN "$root/Editor/Data/Unity.DataStore" 300 & stale=$!; echo "$stale" > "$tmp/stale.pid"
helper_ready() { [ "$(readlink "/proc/$stale/exe" 2>/dev/null)" = "$root/Editor/Data/Unity.DataStore" ]; }
ship_wait_until helper_ready
: > "$tmp/shm/udsMem1234"; : > "$tmp/shm/sem.udsMem1234"; : > "$proj/Temp/UnityLockfile"; : > "$tmp/shm/other"
check "open succeeds with a foreign helper" 'lu open'
check "open: foreign shared memory and the lockfile remain at editor launch" \
  'grep -q udsMem1234 "$tmp/at-launch" && grep -qx lockfile "$tmp/at-launch" && grep -qx other "$tmp/at-launch"'
check "open: an unmarked Unity.DataStore helper survives with a warning" \
  'kill -0 "$stale" && grep -qx datastore "$tmp/at-launch" && grep -q "PIDs:.*$stale.*skipping" "$tmp/err"'
kill "$stale"; wait "$stale" 2>/dev/null || true; rm -f "$tmp/stale.pid"
check "open succeeds without a foreign helper" 'lu open'
check "open: stale shared memory and the lockfile are gone before the editor starts" \
  '! grep -qE "udsMem|lockfile" "$tmp/at-launch" && grep -qx other "$tmp/at-launch"'

# --- #120: a filter-only run of a RenderTool class goes through the single Xvfb pass --------------------------------
printf 'namespace ExampleGame.Park.Tests {\n  [Category("RenderTool")]\n  public class CourtStripCapture {}\n}\n' > "$proj/Assets/Tests/Park/CourtStripCapture.cs"
printf 'namespace X {\n  [Category("Gfx")]\n  public class Other {}\n}\n' > "$proj/Assets/Tests/Park/Other.cs"
runs() { : > "$tmp/runs"; EDITMODE_GFX=1 lu test editmode "$@"; }
for f in ExampleGame.Park.Tests.CourtStripCapture CourtStripCapture ExampleGame.Park.Tests.CourtStripCapture.RenderTheDribbleStrips; do
  check "test -testFilter $f: one pass, on Xvfb, -testCategory RenderTool, no -nographics" \
    'runs -testFilter "$f" && [ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q -- "-testCategory RenderTool" "$tmp/runs" && ! grep -q -- -nographics "$tmp/runs" && grep -q "RenderTool class CourtStripCapture" "$tmp/err"'
done
check "test -testFilter <other class>: still the two category passes" \
  'runs -testFilter X.Other && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q -- "-nographics.*!Gfx;!MacOnly" "$tmp/runs" && ! grep -q RenderTool "$tmp/runs"'
check "test -testFilter CourtStripCaptureX (a longer name) is not a RenderTool run" \
  'runs -testFilter CourtStripCaptureX && [ "$(wc -l < "$tmp/runs")" = 2 ]'
check "test -testFilter mixing a RenderTool class with other tests is rejected before any editor run" \
  '! runs -testFilter "X.Other;ExampleGame.Park.Tests.CourtStripCapture" && grep -q "run the render tool on its own" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "test -testCategory RenderTool -testFilter ...: the documented command is unchanged (one pass)" \
  'runs -testCategory RenderTool -testFilter CourtStripCapture && [ "$(wc -l < "$tmp/runs")" = 1 ] && [ "$(grep -o -- -testCategory "$tmp/runs" | wc -l)" = 1 ]'

# --- #47: all exits nonzero when the licence return is the only failure, keeps an earlier failure's code -----------
all() { rc=0; creds env UNITY_RETURN_ON_EXIT=1 "$@" bash "$script" all >/dev/null 2>"$tmp/err" || rc=$?; }
all FAKE_RETURN_RC=0
check "all: everything ok exits 0" '[ "$rc" = 0 ]'
all FAKE_RETURN_RC=7
check "all: a failed return alone exits nonzero (its code)" \
  '[ "$rc" = 7 ] && grep -q "licence return failed (exit 7)" "$tmp/err"'
all FAKE_RETURN_RC=7 FAKE_UNITY_RC=3
check "all: an earlier failure keeps its exit code when the return also fails" '[ "$rc" = 1 ] && grep -q "licence return failed" "$tmp/err"'
check "all: the return still runs after an earlier failure" 'grep -q -- "--return-ulf" "$tmp/lc-calls"'
check "all: the pidfile is gone once all has exited" '[ ! -f "$OUT_DIR/linux-unity.pid" ]'
# #180 review: a hung licence return keeps the pidfile, so stop still finds the run.
rm -f "$tmp/return.pid"
UNITY_USERNAME=u UNITY_PASSWORD=p UNITY_RETURN_ON_EXIT=1 FAKE_RETURN_SLEEP=300 bash "$script" all >/dev/null 2>&1 & runner=$!
for i in $(seq 600); do [ -s "$tmp/return.pid" ] && break; sleep 0.1; done  # all runs setup..test first
check "all: the pidfile still names the run during the licence return" \
  '[ -s "$tmp/return.pid" ] && [ "$(cut -d" " -f1 "$OUT_DIR/linux-unity.pid")" = "$runner" ]'
bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
check "all: stop kills a hung licence return" \
  '! kill -0 "$runner" 2>/dev/null && ! kill -0 "$(cat "$tmp/return.pid")" 2>/dev/null && grep -q "stop: killing $runner" "$tmp/err"'
# #180 review: stop TERMs an all run mid-editor; its EXIT trap forks the licence return, which hangs (and would
# outlive the snapshot). It carries the run's LINUX_UNITY_RUN marker, so stop's final sweep still reaches it.
rm -f "$tmp/return.pid" "$tmp/editor.pid"
UNITY_USERNAME=u UNITY_PASSWORD=p UNITY_RETURN_ON_EXIT=1 FAKE_EDITOR_SLEEP=300 FAKE_RETURN_SLEEP=300 bash "$script" all >/dev/null 2>&1 & runner=$!
for i in $(seq 600); do [ -s "$tmp/editor.pid" ] && break; sleep 0.1; done
bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
ret="$(cat "$tmp/return.pid" 2>/dev/null || true)"
# A killed pid can stay a zombie for a moment until init reaps it: that counts as gone.
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
check "all: a licence return forked by TERM during stop's grace period is killed too" \
  '[ -n "$ret" ] && ! alive "$ret" && ! alive "$(cat "$tmp/editor.pid")"'
[ -z "$ret" ] || ! alive "$ret" || kill -9 "$ret"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

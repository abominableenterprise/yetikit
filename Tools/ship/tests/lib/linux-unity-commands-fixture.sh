# Shared isolated fake editor and Licensing Client for topical command regressions.
# Each caller gets its own project, installation, process view, pidfiles and shared-memory directory.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

proj="$tmp/proj"; root="$tmp/unity"; lcdir="$root/Editor/Data/Resources/Licensing/Client"
mkdir -p "$proj/Library" "$proj/Temp" "$proj/Assets/Tests/Park" "$lcdir" "$tmp/bin" "$tmp/shm"
# shellcheck source=Tools/ship/tests/lib/fixture.sh
. "$repo/Tools/ship/tests/lib/fixture.sh"
ship_fixture "$proj"
ship_fixture_process_view "$tmp/process-view"
export PATH="$tmp/process-view:$PATH" SHIP_FIXTURE_PIDS=''
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
# Successful test runs must produce evidence just like the shared fake editor.
while [ \$# -gt 0 ]; do
  if [ "\$1" = -testResults ]; then
    printf '<test-run total="1" passed="1" failed="0" skipped="0" />\\n' > "\$2"
    break
  fi
  shift
done
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
all() { rc=0; creds env UNITY_RETURN_ON_EXIT=1 "$@" bash "$script" all >/dev/null 2>"$tmp/err" || rc=$?; }

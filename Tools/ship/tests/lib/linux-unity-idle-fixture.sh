#!/usr/bin/env bash
# Deterministic licence lifecycle/idle tests; no Unity, real hub, or wall-clock waits.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; proj="$tmp/proj"; mkdir -p "$proj/Assets"
echo x > "$proj/Assets/a.txt"
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
git_init
good="$(cat "$ULF")"
idle_dir="$(readlink -m "$ULF").idle"
export UNITY_USERNAME=u UNITY_PASSWORD=p THEROBOTS_HUB_URL=hub-origin THEROBOTS_TASK_ID=5631 THEROBOTS_TASK_TOKEN=fake
export UNITY_IDLE_RETURN_MINUTES=1
unset UNITY_RETURN_ON_EXIT
lc="$UNITY_ROOT/Editor/Data/Resources/Licensing/Client"
mkdir -p "$lc"
cat > "$lc/Unity.Licensing.Client" <<EOF
#!/bin/bash
echo "\$1" >> "$tmp/lc-calls"
case "\$1" in
 --activate-ulf) printf '%s\n' '$good' > "\$ULF" ;;
 --return-ulf) if [ "\${FAKE_RETURN_HANG:-0}" != 0 ]; then
   [ "\$FAKE_RETURN_HANG" != 1 ] || trap '' TERM
   echo \$\$ > "$tmp/return.pid"
   bash -c 'trap "" TERM; exec /bin/sleep 300' & echo \$! > "$tmp/return-child.pid"; wait
 fi
 [ "\${FAKE_MISSING:-0}" = 0 ] || { echo 'Ulf license file not found (1404)'; exit 7; }; exit "\${FAKE_RETURN_RC:-0}" ;;
esac
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
cat >/dev/null
while [ $# -gt 0 ]; do
 case "$1" in -D) h="$2"; shift ;; -o) b="$2"; shift ;; -d) echo "$2" >> "$FAKE_TMP/hub-calls"; shift ;; esac
 shift
done
: > "$h"; echo '{"status":"acquired"}' > "$b"; printf 200
EOF
# Suppress launch for deterministic foreground watcher checks, but exercise the launch path below.
printf '#!/bin/bash\necho launch >> "$FAKE_TMP/launches"\n' > "$tmp/bin/nohup"
# Fast initial polls; defer retries beyond the outer deadline so this test
# observes exactly the first failed attempt even with slow config startup.
printf '#!/bin/bash\ncase "$1" in 5) ;; 10) exec /bin/sleep 30 ;; *) exec /bin/sleep "$@" ;; esac\n' > "$tmp/bin/sleep"
chmod +x "$lc/Unity.Licensing.Client" "$tmp/bin/"*
lu() { rc=0; bash "$script" "$@" > "$tmp/log" 2>&1 || rc=$?; }
count() { grep -c -- "$1" "$tmp/lc-calls" || true; }

# Shared synthetic seat lease fixture; each worker owns its temporary project and fake hub.
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"
# Concurrent commands run under timeout (including their children). Open gates on
# early exit too, then terminate/reap the bounded supervisors before removing files.
concurrent=()
cleanup() {
  touch "$tmp/lc-unblock" "$tmp/release-unblock"
  local pid
  for pid in "${concurrent[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${concurrent[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
proj="$tmp/proj"; mkdir -p "$proj/Assets"; echo x > "$proj/Assets/a.txt"
# shellcheck source=Tools/ship/tests/lib/fake-unity.sh
. "$(dirname "${BASH_SOURCE[0]}")/fake-unity.sh"
git_init
good_ulf="$(cat "$ULF")"
# Fake Licensing Client: logs its first argument; --activate-ulf writes a valid ULF unless FAKE_LC_FAIL=1 (then it
# fails without one); --return-ulf exits $FAKE_RETURN_RC.
lcdir="$tmp/unity/Editor/Data/Resources/Licensing/Client"; mkdir -p "$lcdir"
cat > "$lcdir/Unity.Licensing.Client" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$tmp/lc-calls"
case "\$1" in
  --activate-ulf) [ "\${FAKE_LC_FAIL:-0}" = 1 ] && { echo "activation failed"; exit 1; }
    if [ "\${FAKE_LC_BLOCK:-0}" = 1 ]; then
      echo started > "$tmp/lc-blocked"
      while [ ! -f "$tmp/lc-unblock" ]; do /bin/sleep 0.02; done
      [ "\${FAKE_LC_BLOCK_FAIL:-1}" = 0 ] || exit 1
    fi
    printf '%s\n' '$good_ulf' > "\$ULF" ;;
  --return-ulf) exit "\${FAKE_RETURN_RC:-0}" ;;
esac
EOF
# Fake curl: logs "<action> <url>" (and its arguments and stdin, for the token check) and answers with the next line
# of $tmp/answers ("<code> [retry-after]"; the last line repeats). 200 bodies say {"status":"acquired"}; an acquire
# answers with the body in $FAKE_ACQUIRE_BODY instead when that is set ("" for an empty body).
# FAKE_CONFLICT_BODY overrides only 409 bodies; FAKE_RELEASE_BODY overrides release bodies.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
hdr="" body="" data="" url=""
echo "args: $*" >> "$FAKE_TMP/curl-argv"; cat >> "$FAKE_TMP/curl-argv"
while [ $# -gt 0 ]; do
  case "$1" in -D) hdr="$2"; shift ;; -o) body="$2"; shift ;; -d) data="$2"; shift ;; -H|-X|-w|--max-time) shift ;;
    -*) ;; *) url="$1" ;; esac; shift
done
action="$(sed 's/.*"action":"\([a-z]*\)".*/\1/' <<< "$data")"
echo "$action $url" >> "$FAKE_TMP/curl-calls"
if [ "$action" = release ] && [ "${FAKE_RELEASE_BLOCK:-0}" = 1 ]; then
  touch "$FAKE_TMP/release-blocked"
  while [ ! -f "$FAKE_TMP/release-unblock" ]; do /bin/sleep 0.02; done
fi
if [ "$action" = acquire ] && [ -n "${FAKE_HTTP_SECONDS:-}" ]; then
  echo "$(($(cat "$FAKE_TMP/clock") + FAKE_HTTP_SECONDS))" > "$FAKE_TMP/clock"
fi
n="$(grep -c "^acquire " "$FAKE_TMP/curl-calls")"
if [ "$action" = acquire ]; then line="$(sed -n "${n}p" "$FAKE_TMP/answers")"; [ -n "$line" ] || line="$(tail -n1 "$FAKE_TMP/answers")"
else line="${FAKE_RELEASE_CODE:-200}"; fi
read -r code retry <<< "$line"
{ printf 'HTTP/1.1 %s X\r\n' "$code"; [ -z "${retry:-}" ] || printf 'Retry-After: %s\r\n' "$retry"; } > "$hdr"
if [ "$action" = release ] && [ -n "${FAKE_RELEASE_BODY+x}" ]; then printf '%s' "$FAKE_RELEASE_BODY"
elif [ "$action" = acquire ] && [ -n "${FAKE_ACQUIRE_BODY+x}" ]; then printf '%s' "$FAKE_ACQUIRE_BODY"
elif [ "$code" = 409 ] && [ -n "${FAKE_CONFLICT_BODY+x}" ]; then printf '%s' "$FAKE_CONFLICT_BODY"
else case "$code" in 200) echo '{"status":"acquired"}' ;; 202) echo '{"status":"waiting","resource":"Unity"}' ;; *) echo '{}' ;; esac; fi > "$body"
printf '%s' "$code"
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE_TMP/sleeps"
echo "$(($(cat "$FAKE_TMP/clock") + $1))" > "$FAKE_TMP/clock"
EOF
# Replace only the monotonic clock, not date (ULF validation still uses real dates).
cat > "$tmp/bin/awk" <<'EOF'
#!/bin/sh
if [ "$*" = '{print int($1)} /proc/uptime' ]; then cat "$FAKE_TMP/clock"
else exec /usr/bin/awk "$@"; fi
EOF
# Report actual contention, not merely that the second command was launched.
# Activity locks use fd 9; the activation lock uses a dynamically allocated fd.
cat > "$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_LOCK_WAIT:-}" ] && [ "${1:-}" = -x ] && [ "${2:-}" != 9 ]; then
  /usr/bin/flock -n "${!#}" && exit 0
  touch "$FAKE_LOCK_WAIT"
fi
exec /usr/bin/flock "$@"
EOF
for c in crane dpkg ldd; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$c"; done
: > "$tmp/unity/.install-complete"   # a finished install, so `all`'s setup trusts it
chmod +x "$lcdir/Unity.Licensing.Client" "$tmp/bin/"*
export BIN_DIR="$tmp/bin"
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN UNITY_RETURN_ON_EXIT UNITY_SEAT_WAIT_MINUTES SEAT_STATE \
  UNITY_USERNAME UNITY_PASSWORD USERNAME PASSWORD FAKE_ACQUIRE_BODY FAKE_CONFLICT_BODY FAKE_RELEASE_BODY
token="tok-SECRET-1234"
hub=(THEROBOTS_HUB_URL=hub-origin THEROBOTS_TASK_ID=5455 "THEROBOTS_TASK_TOKEN=$token")
state="$OUT_DIR/unity-seat.held"
# Run linux-unity.sh with the given env and arguments (after --); output in $tmp/log, exit code in $rc.
lu() {
  local env=(UNITY_USERNAME=u UNITY_PASSWORD=p); while [ "$1" != -- ]; do env+=("$1"); shift; done; shift
  rc=0; env "${env[@]}" bash "$script" "$@" > "$tmp/log" 2>&1 || rc=$?
}
reset() { echo 0 > "$tmp/clock"; : > "$tmp/curl-calls"; : > "$tmp/curl-argv"; : > "$tmp/lc-calls"; : > "$tmp/sleeps"; : > "$tmp/runs"; printf '%s\n' "$@" > "$tmp/answers"; }
calls() { grep -c "^$1 " "$tmp/curl-calls" || true; }
no_token() { ! grep -q "$token" "$tmp/log"; }

#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Duration parsing and exact boundaries, without wall-clock waits.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
# Load only the diagnostic helper, never the entry point. Arithmetic errors fail in a subshell.
eval "$(awk '/^report_killed\(\) \{/ { copy=1 } copy { print } copy && /^}/ { exit }' "$script")"
log() { printf '[linux-unity] %s\n' "$*" >&2; }
diagnose() {
  rc=0
  ( UNITY_TIMEOUT="$duration" UNITY_TIMEOUT_VAR="$var" UNITY_RUN_LABEL=fixture report_killed "$1" ) \
    2>"$tmp/err" || rc=$?
}
for var in UNITY_TIMEOUT UNITY_GFX_TIMEOUT APK_TIMEOUT; do
  while read -r duration seconds doubled earlier; do
    diagnose "$earlier"
    check "$var=$duration: an earlier SIGKILL is not a timeout" \
      '[ "$rc" = 0 ] && grep -qF "fixture: killed (SIGKILL) after $earlier s, before the $seconds s timeout" "$tmp/err" && ! grep -q "Re-run with" "$tmp/err"'
    for elapsed in "$seconds" "$doubled"; do
      diagnose "$elapsed"
      check "$var=$duration: SIGKILL at/after the limit ($elapsed s) doubles numeric seconds" \
        '[ "$rc" = 0 ] && grep -qxF "[linux-unity] fixture: killed at the $seconds s timeout; no results. Re-run with $var=$doubled" "$tmp/err"'
    done
  done <<'EOF'
1 1 2 0.9
1s 1 2 0.9
1.5s 1.5 3 1.49
2m 120 240 119.9
1h 3600 7200 3599.9
0.5 0.5 1 0.49
0.5m 30 60 29.9
1d 86400 172800 86399.9
EOF
  for duration in 0 0s 0.0m 0h; do
    diagnose 7200
    check "$var=$duration: zero disables the timeout even after a long run" \
      '[ "$rc" = 0 ] && grep -qF "killed (SIGKILL) after 7200 s, timeout disabled" "$tmp/err" && ! grep -qE "killed at the|Re-run with|before the" "$tmp/err"'
  done
done
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

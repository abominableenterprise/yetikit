#!/usr/bin/env bash
# test-all: slow
# Tests the editor time limits of `linux-unity.sh test`: the Gfx pass (test editmode's second pass, a -testCategory
# naming Gfx, test pr's Gfx pass) runs under UNITY_GFX_TIMEOUT (3600 s), the pure pass under UNITY_TIMEOUT (1800 s),
# a caller's UNITY_TIMEOUT sets both, and killed editors get duration-aware diagnostics (including APK_TIMEOUT).
# Fake editor and timeout only; helper checks cover long durations without minute/hour waits.
# Run: bash Tools/ship/tests/linux-unity-timeout.test.sh
# The checks are eval'd strings ($rc and $tmp expand when they run).
# shellcheck disable=SC2016,SC2034
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "$0")/lib/fake-unity.sh"

t="$proj/Assets/Tests/EditMode/Props"
mkdir -p "$t"
printf 'namespace X.Tests\n{\n    [Category("Gfx")]\n    public class SprayTests { }\n}\n' > "$t/SprayTests.cs"
git_init
git -C "$proj" checkout -q -b feature
echo '// touched' >> "$t/SprayTests.cs"; commit touch

# A logging timeout in front of the real one: "<seconds> <-testResults file>" per editor run, in $tmp/limits.
real_timeout="$(command -v timeout)"
cat > "$tmp/bin/timeout" <<EOF
#!/usr/bin/env bash
res=""; prev=""; for a in "\$@"; do [ "\$prev" = -testResults ] && res="\${a##*/}"; prev="\$a"; done
echo "\$3 \$res" >> "$tmp/limits"
exec "$real_timeout" "\$@"
EOF
chmod +x "$tmp/bin/timeout"

run() { : > "$tmp/limits"; : > "$tmp/runs"; rc=0; env "$@" 2>"$tmp/err" || rc=$?; }
limit() { sed -n "s/ $1\$//p" "$tmp/limits"; }

# --- defaults ------------------------------------------------------------------------------------------------------------
run bash "$script" test editmode
check "test editmode: the pure pass keeps 1800 s" '[ "$rc" = 0 ] && [ "$(limit editmode.xml)" = 1800 ]'
check "test editmode: the Gfx pass gets 3600 s by default" '[ "$(limit editmode-gfx.xml)" = 3600 ]'
check "test editmode: the Gfx pass logs its timeout" 'grep -q "editmode-gfx: Gfx pass, timeout 3600 s" "$tmp/err"'
run bash "$script" test editmode -testCategory Gfx
check "test editmode -testCategory Gfx: one pass at 3600 s" '[ "$(cat "$tmp/limits")" = "3600 editmode.xml" ]'
run bash "$script" test editmode -testCategory "Gfx;Other"
check "test editmode -testCategory Gfx;Other: still the Gfx timeout" '[ "$(limit editmode.xml)" = 3600 ]'
run bash "$script" test editmode -testCategory MacOnly
check "test editmode -testCategory MacOnly: the plain 1800 s" '[ "$(limit editmode.xml)" = 1800 ]'
run bash "$script" test editmode -testCategory "!Gfx"
check "test editmode -testCategory !Gfx: the plain 1800 s" '[ "$(limit editmode.xml)" = 1800 ]'
run bash "$script" test pr
check "test pr: pure pass 1800 s, Gfx pass 3600 s" \
  '[ "$rc" = 0 ] && [ "$(limit editmode.xml)" = 1800 ] && [ "$(limit editmode-gfx.xml)" = 3600 ]'

# --- the caller's settings win --------------------------------------------------------------------------------------------
run UNITY_TIMEOUT=5400 bash "$script" test editmode
check "an explicit UNITY_TIMEOUT sets both passes" '[ "$(limit editmode.xml)" = 5400 ] && [ "$(limit editmode-gfx.xml)" = 5400 ]'
run UNITY_TIMEOUT=900 bash "$script" test pr
check "an explicit UNITY_TIMEOUT (lower) also wins for test pr's Gfx pass" '[ "$(limit editmode-gfx.xml)" = 900 ]'
run UNITY_GFX_TIMEOUT=7200 bash "$script" test editmode
check "UNITY_GFX_TIMEOUT sets only the Gfx pass" '[ "$(limit editmode.xml)" = 1800 ] && [ "$(limit editmode-gfx.xml)" = 7200 ]'
run UNITY_TIMEOUT=600 UNITY_GFX_TIMEOUT=7200 bash "$script" test editmode
check "both set: each pass gets its own" '[ "$(limit editmode.xml)" = 600 ] && [ "$(limit editmode-gfx.xml)" = 7200 ]'
run bash "$script" open
check "open keeps UNITY_TIMEOUT's 1800 s" '[ "$(cat "$tmp/limits")" = "1800 " ]'

# --- an editor killed by the timeout ----------------------------------------------------------------------------------------
run FAKE_EDITOR_GATE="$tmp/timeout-editor" UNITY_GFX_TIMEOUT=1 bash "$script" test editmode -testCategory Gfx
check "a Gfx editor blocked at its gate past a 1 s timeout is killed: the run fails" '[ "$rc" != 0 ]'
check "it prints the killed line naming UNITY_GFX_TIMEOUT" \
  'grep -qF "[linux-unity] editmode: killed at the 1 s timeout; no results. Re-run with UNITY_GFX_TIMEOUT=2" "$tmp/err"'
check "and no results" 'grep -q "no results in .*editmode.xml" "$tmp/err"'
run FAKE_EDITOR_GATE="$tmp/timeout-editor" UNITY_TIMEOUT=1 EDITMODE_GFX=0 bash "$script" test editmode
check "a killed pure pass names UNITY_TIMEOUT" \
  '[ "$rc" != 0 ] && grep -qF "editmode: killed at the 1 s timeout; no results. Re-run with UNITY_TIMEOUT=2" "$tmp/err"'
run FAKE_UNITY_RC=137 bash "$script" open
check "a SIGKILL before the timeout is not reported as the timeout" \
  '[ "$rc" != 0 ] && grep -q "editor: killed (SIGKILL) after [0-9.]* s, before the 1800 s timeout" "$tmp/err" && ! grep -q "killed at the" "$tmp/err"'
run bash "$script" test editmode
check "a normal run prints no killed line" '[ "$rc" = 0 ] && ! grep -q killed "$tmp/err"'

# --- duration parsing and exact boundaries (no waiting) ---------------------------------------------------------------------
# Load only the diagnostic helper, never the entry point. Run in a subshell so even an arithmetic error is a test failure.
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

# --- real timeout + fake editor: duration strings reach the right per-command limit ----------------------------------------
# Minimal APK prerequisites; never allocate swap, require host free space, or build anything real.
mkdir -p "$tmp/unity/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" \
  "$tmp/unity/Editor/Data/PlaybackEngines/AndroidPlayer/NDK" "$proj/Library" "$tmp/swap"
export APK_SWAP_GB=0 APK_SWAP_DIR="$tmp/swap" APK_MIN_FREE_GB=0 APK_MIN_FREE_GB_WARM=0
for var in UNITY_TIMEOUT UNITY_GFX_TIMEOUT APK_TIMEOUT; do
  case "$var" in
    UNITY_TIMEOUT) args=(open); duration=1s; doubled=2 ;;
    UNITY_GFX_TIMEOUT) args=(test editmode -testCategory Gfx); duration=1.5s; doubled=3 ;;
    APK_TIMEOUT) args=(apk); duration=1s; doubled=2 ;;
  esac
  seconds="${duration%s}"
  run FAKE_EDITOR_GATE="$tmp/timeout-editor" "$var=$duration" bash "$script" "${args[@]}"
  check "$var=$duration: fake editor times out with a numeric rerun, no arithmetic error" \
    '[ "$rc" != 0 ] && grep -qF "killed at the $seconds s timeout; no results. Re-run with $var=$doubled" "$tmp/err" && ! grep -qE "integer expression|syntax error|invalid arithmetic" "$tmp/err"'
  run FAKE_UNITY_RC=137 "$var=0" bash "$script" "${args[@]}"
  check "$var=0: fake editor SIGKILL is external, not a disabled timeout firing" \
    '[ "$rc" != 0 ] && grep -qF "timeout disabled (out of memory? stop?); no results" "$tmp/err" && ! grep -qE "killed at the|Re-run with" "$tmp/err"'
done

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

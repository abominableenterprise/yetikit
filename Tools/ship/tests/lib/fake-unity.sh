# Fake Unity for the linux-unity.sh shell tests (sourced; never runs Unity). Sets up, under $tmp:
#   unity/Editor/Unity  the fake editor: logs its arguments (one run per line) to $tmp/runs, runs $FAKE_MUTATE (a bash
#                       snippet, in the project) and, for -runTests, writes canned NUnit result XML to -testResults:
#                       one passed test per -testFilter name (or ExampleGame.Fake.Tests.Ok), plus every name in
#                       $FAKE_FAILS (;-separated) as failed, and each $FAKE_SUITE_FAILS fixture as failed in its TearDown. A run whose results file ends in -retry.xml uses
#                       $FAKE_RETRY_FAILS instead. Exits 2 when a test failed (as Unity does), $FAKE_UNITY_RC otherwise.
#                       It writes a line to -logFile. FAKE_NO_XML=1 writes no XML and exits 1 (a crash). FAKE_SLEEP=n sleeps n seconds first.
#   bin/xvfb-run        drops its options and runs the command (FAKE_XVFB=1 also starts a fake Xvfb child)
#   bin/nohup           no-op: never launches a real detached idle-return watcher
# and exports PATH, UNITY_ROOT, ULF, OUT_DIR, SHM_DIR, TASK_CACHE, NOISE_BASE and fake credentials.
# Credential-specific tests explicitly unset these defaults. Needs $tmp and $proj.
. "$(dirname "${BASH_SOURCE[0]}")/fixture.sh"
ship_fixture "$proj"
mkdir -p "$tmp/unity/Editor" "$tmp/bin" "$tmp/shm" "$tmp/out"
cat > "$tmp/unity/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
# Unity 6000.6.6f1
echo "$*" >> "$FAKE_TMP/runs"
echo $$ > "$FAKE_TMP/unity.pid"
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
res="" filter="" tests=0 proj="" logf=""
while [ $# -gt 0 ]; do
  case "$1" in -testResults) res="$2"; shift ;; -logFile) logf="$2"; shift ;; -testFilter) filter="$2"; shift ;; -projectPath) proj="$2"; shift ;;
    -runTests) tests=1 ;; esac; shift
done
[ -z "$logf" ] || { mkdir -p "$(dirname "$logf")"; echo "fake editor log" > "$logf"; }
[ -z "${FAKE_MUTATE:-}" ] || (cd "$proj" && bash -c "$FAKE_MUTATE")
[ "$tests" = 1 ] || exit "${FAKE_UNITY_RC:-0}"
[ "${FAKE_NO_XML:-0}" = 1 ] && exit 1
fails="${FAKE_FAILS:-}"; [[ "$res" == *-retry.xml ]] && fails="${FAKE_RETRY_FAILS:-}"
case_xml() { local n="${1//&/&amp;}"; n="${n//\"/&quot;}"; printf '<test-case id="1" name="%s" fullname="%s" result="%s" />\n' "${n##*.}" "$n" "$2"; }
body="" passed=0 failed=0 IFS=';'
for n in ${filter:-ExampleGame.Fake.Tests.Ok}; do body="$body$(case_xml "$n" Passed)"$'\n'; passed=$((passed + 1)); done
for n in $fails; do body="$body$(case_xml "$n" Failed)"$'\n'; failed=$((failed + 1)); done
for n in ${FAKE_SUITE_FAILS:-}; do
  body="$body<test-suite type=\"TestFixture\" fullname=\"$n\" result=\"Failed\" site=\"TearDown\"></test-suite>"$'\n'; failed=$((failed + 1))
done
unset IFS
mkdir -p "$(dirname "$res")"
printf '<?xml version="1.0" encoding="utf-8"?>\n<test-run id="2" total="%d" passed="%d" failed="%d" skipped="0">\n%s</test-run>\n' \
  $((passed + failed)) "$passed" "$failed" "$body" > "$res"
[ "$failed" = 0 ] || exit 2
exit "${FAKE_UNITY_RC:-0}"
EOF
cat > "$tmp/bin/xvfb-run" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -a ] && shift
[ "$1" = -s ] && shift 2
if [ "${FAKE_XVFB:-0}" = 1 ]; then
  bash -c 'echo $$ > "$FAKE_TMP/xvfb.pid"; exec sleep 300' &
  x=$!
  rc=0; "$@" || rc=$?; kill "$x" 2>/dev/null; exit "$rc"
fi
exec "$@"
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/nohup"
chmod +x "$tmp/unity/Editor/Unity" "$tmp/bin/xvfb-run" "$tmp/bin/nohup"
printf '<root><License id="Terms"><StopDate Value="" /></License><Signature>x</Signature></root>\n' > "$tmp/ulf"
export FAKE_TMP="$tmp" PATH="$tmp/bin:$PATH" PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  PIDFILE_FALLBACK="$tmp/fallback.pid" SHM_DIR="$tmp/shm" TASK_CACHE=no-task-cache NOISE_BASE=HEAD UNITY_USERNAME=u UNITY_PASSWORD=p
# Never reach the real hub (a task VM exports these): the seat lease is tested with a fake curl.
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN
unset FAKE_FAILS FAKE_SUITE_FAILS FAKE_RETRY_FAILS FAKE_MUTATE FAKE_NO_XML FAKE_SLEEP FAKE_XVFB FAKE_UNITY_RC EDITMODE_GFX KNOWN_FLAKES PIDFILE APK_SWAPFILE

check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
# A temp git repo in $proj, everything committed on main (origin/main points at it).
git_init() {
  git -C "$proj" init -q -b main && git -C "$proj" add -A
  git -C "$proj" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$proj" update-ref refs/remotes/origin/main HEAD
}
commit() { git -C "$proj" add -A && git -C "$proj" -c user.name=t -c user.email=t@t commit -qm "$1"; }

#!/usr/bin/env bash
# shellcheck disable=SC2016 # check takes single-quoted conditions, expanded by eval
# shellcheck disable=SC2034 # rc is read inside those conditions
# Tests the known-flake retry of `quest-release.sh gate` (Tools/ship/README.md): when every failure is in
# known-flakes.txt, those tests rerun once with -testFilter and the same categories, and a green rerun passes the gate;
# a single failed test reruns once even when unlisted; two or more failures with an unlisted one fail at once. A retry
# must pass the selected tests, not merely return zero failures. Stubbed unity and git
# fetch; never runs Unity or adb. bash 3.2 compatible. Run: bash Tools/ship/tests/quest-release-flakes.test.sh
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/quest-release.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; [ -z "${QR_TEST_DEBUG:-}" ] || cat "$tmp/out" "$tmp/err"; fails=$((fails + 1)); fi; }

git() { if [ "$1" = -C ] && [ "$3" = fetch ]; then return 0; fi; command git "$@"; }

# --- a temp repo at origin/main with synthetic known flakes, a warm worktree with a Library ------------------------------
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
repo="$tmp/repo"; mkdir -p "$repo/Tools/ship" "$repo/ProjectSettings"
printf 'm_EditorVersion: 6000.6.6f1\n' > "$repo/ProjectSettings/ProjectVersion.txt"
printf "PURE_CATEGORIES='!Gfx;!MacOnly'\n" > "$repo/Tools/ship/linux-unity.sh"
printf '%s\n' '# Synthetic class flake' 'Synthetic.Props.Tests.ThrowConsistencyPlayModeTests' \
  '# Synthetic method flake' 'Synthetic.Props.Tests.ThrowPlayModeTests.AFlickSendsASodaCanTenMetresOrMore' \
  '# Synthetic method flake' 'Synthetic.Props.Tests.SprayPlayModeTests.SprayingAWallPaintsAContinuousStroke' > "$repo/Tools/ship/known-flakes.txt"
cp "$YETIKIT_CONFIG" "$repo/yetikit.json"
printf "/[Ll]ibrary/\n" > "$repo/.gitignore"
git -C "$repo" init -q -b main && git -C "$repo" add -A && git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
root="$tmp/wt"; mkdir -p "$root/mac-pass/Library"
export QUEST_REPO="$repo" QUEST_WT_ROOT="$root" HOME="$tmp/home"
mkdir -p "$HOME"
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3 999 0 %s 1%% /\n' "$((100 * 1048576))"; }

# shellcheck source=Tools/ship/quest-release.sh
. "$script"
qr_clone_dir() { cp -R "$1" "$2"; } # /bin/cp -c is macOS-only

# The fake editor: one run per line in $tmp/unity.log; NUnit XML with Ns.A.Ok plus the selected retry tests passing
# by default. FAKE_RETRY_PASSES overrides those names (including an empty selection); FAKE_RETRY_NONPASSES names
# selected cases with FAKE_RETRY_RESULT / FAKE_RETRY_LABEL. All name lists are ;-separated. Failures exit 2.
unity() {
  local a prev="" res="" filter="" names cases="" n failed=0 total=1 passed=1 skipped=0 inconclusive=0 log=""
  local passes="" nonpasses="" result label="" attrs
  echo "$*" >> "$tmp/unity.log"
  for a in "$@"; do
    case "$prev" in -testResults) res="$a" ;; -testFilter) filter="$a" ;; -logFile) log="$a" ;; esac
    prev="$a"
  done
  echo "editor log${filter:+ (filter $filter)}" > "$log"
  # Raw documents exercise parser failures and real fixture-shaped NUnit results.
  if [ -n "$filter" ] && [ -n "${FAKE_RETRY_XML:-}" ]; then
    printf '%s\n' "$FAKE_RETRY_XML" > "$res"; return "${FAKE_RETRY_EXIT:-2}"
  elif [ -z "$filter" ] && [ -n "${FAKE_INITIAL_XML:-}" ]; then
    printf '%s\n' "$FAKE_INITIAL_XML" > "$res"; return 2
  fi
  if [ -n "$filter" ]; then
    names="${FAKE_RETRY_FAILS:-}"; passes="${FAKE_RETRY_PASSES-$filter}"; nonpasses="${FAKE_RETRY_NONPASSES:-}"
    label="${FAKE_RETRY_LABEL:-}"
  else names="${FAKE_FAILS:-}"; fi
  for result in Passed Failed "${FAKE_RETRY_RESULT:-Skipped}"; do
    case "$result" in Passed) a="$passes" ;; Failed) a="$names" ;; *) a="$nonpasses" ;; esac
    [ -n "$a" ] || continue
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if [ "$result" = Passed ]; then
        case ";$names;$nonpasses;" in *";$n;"*) continue ;; esac
      fi
      attrs="fullname=\"$n\" result=\"$result\""
      case "$result" in
        Passed) passed=$((passed + 1)); cases="$cases<test-case $attrs/>" ;;
        Failed) failed=$((failed + 1)); cases="$cases<test-case $attrs><failure><message>flaky</message></failure></test-case>" ;;
        *)
          if [ "$result" = Inconclusive ]; then inconclusive=$((inconclusive + 1)); else skipped=$((skipped + 1)); fi
          cases="$cases<test-case $attrs${label:+ label=\"$label\"}/>" ;;
      esac
      total=$((total + 1))
    done <<EOF
$(printf '%s\n' "$a" | tr ';' '\n')
EOF
  done
  printf '<?xml version="1.0"?><test-run total="%s" passed="%s" failed="%s" skipped="%s" inconclusive="%s"><test-suite type="TestFixture" fullname="Ns.A" result="%s"><test-case fullname="Ns.A.Ok" result="Passed"/>%s</test-suite></test-run>\n' \
    "$total" "$passed" "$failed" "$skipped" "$inconclusive" "$([ "$failed" = 0 ] && echo Passed || echo Failed)" "$cases" > "$res"
  [ "$failed" = 0 ] || return 2
}

run() { rc=0; rm -f "$tmp/unity.log"; ( qr_main "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?; }
runs() { if [ -f "$tmp/unity.log" ]; then wc -l < "$tmp/unity.log" | tr -d ' '; else echo 0; fi; }
retry_line() { grep -- "-testFilter" "$tmp/unity.log"; }

spray=Synthetic.Props.Tests.SprayPlayModeTests.SprayingAWallPaintsAContinuousStroke
consistency=Synthetic.Props.Tests.ThrowConsistencyPlayModeTests.AnOverhandFlickLaunchesEveryPropAtOnePointFourTimesTheHand
flick='Synthetic.Props.Tests.ThrowPlayModeTests.AFlickSendsASodaCanTenMetresOrMore(True,25f)'
real=Synthetic.Props.Tests.SprayPlayModeTests.SomethingReallyBroken

run prepare
check "prepare makes the test worktree" '[ "$rc" = 0 ]'

# --- the list ----------------------------------------------------------------------------------------------------------------
list="$repo/Tools/ship/known-flakes.txt"
check "known-flakes.txt lists the class and two tests, each under a # comment" \
  'for n in ThrowConsistencyPlayModeTests ThrowPlayModeTests.AFlickSendsASodaCanTenMetresOrMore SprayPlayModeTests.SprayingAWallPaintsAContinuousStroke; do grep -B1 -E "^Synthetic\.[A-Za-z.]*\.$n\$" "$list" | head -n1 | grep -q "^#" || exit 1; done'
check "a class entry matches its tests, not a class whose name only starts the same" \
  '( KNOWN_FLAKES="$list"; is_known_flake "$consistency" && ! is_known_flake Synthetic.Props.Tests.ThrowConsistencyPlayModeTestsExtra.X )'

# --- only a listed flake failed, green rerun: the gate passes ---------------------------------------------------------------
FAKE_FAILS="$spray" run gate
check "a listed flake that passes on the rerun: gate exits 0" '[ "$rc" = 0 ]'
check "exactly one rerun, of only the failing test, with the same categories and its own results/log" \
  '[ "$(runs)" = 2 ] && retry_line | grep -q -- "-testCategory Gfx;MacOnly -testFilter $spray -testResults .*/gate-retry.xml -logFile .*/gate-retry-unity.log"'
check "the summary gate line names the retried flake and its result" \
  'grep -q "^gate:        Gfx;MacOnly: 2 tests, 1 passed, 1 failed, 0 skipped (Unity exit 2) (retried 1 known flake: $spray — passed)" "$tmp/out"'
check "the summary keeps the first run's failure for the record" 'grep -q "^gate fails:  none after the retry (first run: $spray: flaky)" "$tmp/out"'

FAKE_FAILS="$consistency;$flick" FAKE_RETRY_PASSES="$consistency;$flick" run gate
check "a test of a listed class plus a parameterised case of a listed test: one rerun, the case as its method" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && retry_line | grep -qF -- "-testFilter $consistency;${flick%%(*} " && grep -q "retried 2 known flakes: $consistency, ${flick%%(*} — passed" "$tmp/out"'

# --- retry results must actually pass every selected test/method -----------------------------------------------------------
flick_other="${flick%%(*}(False,25f)"
FAKE_FAILS="$flick;$flick_other" FAKE_RETRY_PASSES="$flick;$flick_other" run gate
check "all originally failed parameterised cases passing clears one deduplicated method filter" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && retry_line | grep -qF -- "-testFilter ${flick%%(*} -testResults"'
for partial in "$flick" "$flick_other" "${flick%%(*}"; do
  FAKE_FAILS="$flick;$flick_other" FAKE_RETRY_PASSES="$partial" run gate
  check "a partial method retry cannot clear every original failed case ($partial)" \
    '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && ! grep -q "flaky-passed:" "$tmp/err" && grep -q "method retry omitted original failed test case" "$tmp/out"'
done
FAKE_FAILS="$flick" FAKE_RETRY_PASSES="$flick_other" run gate
check "a different Passed case of the same method cannot clear the original failed case" \
  '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && ! grep -q "flaky-passed:" "$tmp/err"'
FAKE_FAILS="$consistency;$flick" FAKE_RETRY_PASSES="$consistency;$flick" run gate
check "a parameterised Passed case satisfies its selected method alongside another selected test" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ]'

for status in Skipped Ignored Inconclusive; do
  FAKE_FAILS="$spray" FAKE_RETRY_NONPASSES="$spray" FAKE_RETRY_RESULT="$status" run gate
  check "a selected test returning $status is not a passing retry despite an unrelated Passed case" \
    '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && ! grep -q "flaky-passed:" "$tmp/err"'
done
FAKE_FAILS="$spray" FAKE_RETRY_NONPASSES="$spray" FAKE_RETRY_LABEL=Ignored run gate
check "NUnit Skipped with label Ignored is not a passing retry" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'

FAKE_FAILS="$spray" FAKE_RETRY_PASSES="" run gate
check "only the unrelated Ns.A.Ok passing cannot clear the selected test" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'
FAKE_FAILS="$spray" FAKE_RETRY_PASSES="${spray}Extra" run gate
check "a Passed test sharing the selected test name prefix is not a match" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'
FAKE_FAILS="$flick" FAKE_RETRY_PASSES="${flick%%(*}Extra(True,25f)" run gate
check "a Passed parameterised case of a different method is not a match" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'
FAKE_FAILS="$spray;$consistency" FAKE_RETRY_PASSES="$spray" run gate
check "one selected test passing cannot hide a missing second selected test" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'
FAKE_FAILS="$spray;$consistency" FAKE_RETRY_NONPASSES="$consistency" run gate
check "one selected test passing cannot hide another selected test being skipped" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'
FAKE_FAILS="$real" FAKE_RETRY_NONPASSES="$real" FAKE_RETRY_RESULT=Inconclusive run gate
check "an unlisted selected test must also pass, not return Inconclusive" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'

# --- complete XML validation and standalone suite failures.
for broken in \
  '<test-run total="1" passed="0">' \
  "<test-run total=\"1\" passed=\"1\" failed=\"0\" skipped=\"0\"><test-case fullname=\"$spray\" result=\"Passed\"/>" \
  "<test-run total=\"1\" passed=\"1\" failed=\"0\" skipped=\"0\"><test-case fullname=\"$spray\" result=\"Passed\"/></wrong>" \
  "<test-run total=\"1\" passed=\"1\" failed=\"0\" skipped=\"0\"><test-case fullname=\"$spray\" result=\"Passed\"/></test-run><extra/>" \
  "<test-run total=\"1\" passed=\"1\" failed=\"0\" skipped=\"0\"><test-case fullname=\"$spray\" result=\"Passed\"/><output>&bogus;</output></test-run>" \
  "<test-run total=\"1\" passed=\"1\" failed=\"0\" skipped=\"0\"><test-case fullname=\"$spray\" result=\"Passed\"/></test-run><!-- unfinished" \
  "<results><test-case fullname=\"$spray\" result=\"Passed\"/></results>" \
  "<test-run><test-case fullname=\"$spray\" result=\"Passed\"/></test-run>"; do
  FAKE_FAILS="$spray" FAKE_RETRY_XML="$broken" run gate
  check "incomplete, malformed or non-NUnit retry XML fails closed: $broken" \
    '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && ! grep -q "flaky-passed:" "$tmp/err" && grep -q "invalid results XML" "$tmp/out"'
done
valid_retry="<?xml version='1.0'?><test-run total='1' passed='1' failed='0' skipped='0'><!-- <test-suite result=\"Failed\" fullname=\"Fake\"/> --><test-case fullname='$spray' result='Passed'/><output><![CDATA[<test-case result=\"Failed\" fullname=\"Fake.Case\"/>]]></output></test-run>"
FAKE_FAILS="$spray" FAKE_RETRY_XML="$valid_retry" FAKE_RETRY_EXIT=0 run gate
check "valid single-quoted XML, comments and CDATA are parsed rather than scanned as test results" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ]'
standalone="<test-run total=\"1\" passed=\"1\" failed=\"0\" skipped=\"0\"><test-case fullname=\"$spray\" result=\"Passed\"/><test-suite type=\"TestFixture\" fullname=\"Ns.Broken\" result=\"Failed\"><failure><message>teardown failed</message></failure></test-suite></test-run>"
FAKE_FAILS="$spray" FAKE_RETRY_XML="$standalone" run gate
check "shared failed_tests rejects a failed suite without site or failed children even with root failed=0 and exit 2" \
  '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && grep -q "Ns.Broken" "$tmp/out" && ! grep -q "flaky-passed:" "$tmp/err"'

# --- fixture selections from OneTimeSetUp / OneTimeTearDown.
fixture=Synthetic.Props.Tests.ThrowConsistencyPlayModeTests
fixture_cases="<test-case fullname=\"$fixture.One\" result=\"Passed\"/><test-case fullname=\"$fixture.Two(True)\" result=\"Passed\"/>"
fixture_xml() {
  printf '<test-run total="2" passed="2" failed="0" skipped="0"><test-suite type="TestFixture" fullname="%s" result="%s"%s>%s</test-suite></test-run>' \
    "$fixture" "$1" "${2:+ site=\"$2\"}" "$3"
}
fixture_pass="$(fixture_xml Passed '' "$fixture_cases")"
for site in SetUp TearDown; do
  fixture_initial="$(fixture_xml Failed "$site" "$fixture_cases")"
  FAKE_INITIAL_XML="$fixture_initial" FAKE_RETRY_XML="$fixture_pass" FAKE_RETRY_EXIT=0 run gate
  check "a successful full fixture retry clears a transient OneTime$site failure" \
    '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && retry_line | grep -qF -- "-testFilter $fixture " && grep -q "flaky-passed:" "$tmp/err"'
  for fixture_bad in \
    "$(fixture_xml Passed '' "<test-case fullname=\"$fixture.One\" result=\"Passed\"/>")" \
    "$(fixture_xml Passed '' '')" \
    "$(fixture_xml Passed '' "<test-case fullname=\"$fixture.One\" result=\"Passed\"/><test-case fullname=\"$fixture.Two(True)\" result=\"Skipped\"/>")" \
    "$(fixture_xml Passed '' "<test-case fullname=\"$fixture.One\" result=\"Passed\"/><test-case fullname=\"$fixture.Two(True)\" result=\"Inconclusive\"/>")" \
    "${fixture_pass//$fixture/${fixture}Extra}"; do
    FAKE_INITIAL_XML="$fixture_initial" FAKE_RETRY_XML="$fixture_bad" run gate
    check "fixture retry requires the matching fixture and every original case Passed ($site): $fixture_bad" \
      '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && ! grep -q "flaky-passed:" "$tmp/err"'
  done
done
fixture_setup="<test-run total=\"2\" passed=\"0\" failed=\"2\" skipped=\"0\"><test-suite type=\"TestFixture\" fullname=\"$fixture\" result=\"Failed\" site=\"SetUp\"><test-case fullname=\"$fixture.One\" result=\"Failed\"/><test-case fullname=\"$fixture.Two(True)\" result=\"Failed\"/></test-suite></test-run>"
FAKE_INITIAL_XML="$fixture_setup" FAKE_RETRY_XML="$fixture_pass" FAKE_RETRY_EXIT=0 run gate
check "OneTimeSetUp with failed children validates both the selected fixture and its selected methods" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ]'
FAKE_INITIAL_XML="$(fixture_xml Failed TearDown '')" FAKE_RETRY_XML="$fixture_pass" FAKE_RETRY_EXIT=0 run gate
check "a fixture failure with no original child results can recover with a full Passed fixture" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ]'
FAKE_FAILS="$spray" FAKE_RETRY_PASSES="$spray.Child" run gate
check "a method selection must not become a fixture selection just because a descendant name passes" \
  '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'
FAKE_FAILS="$flick" FAKE_RETRY_PASSES="$flick" FAKE_RETRY_NONPASSES="${flick%%(*}(False,25f)" run gate
check "a passing parameterised case cannot hide a skipped sibling of the selected method" \
  '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'

# --- parameterised fixtures keep fixture semantics after their arguments are stripped.
parameterized_suite() {
  printf '<test-suite type="TestFixture" fullname="%s(&quot;%s&quot;)" result="%s"%s>%s</test-suite>' \
    "$fixture" "$1" "$2" "${4:+ site=\"$4\"}" "$3"
}
cop_one="<test-case fullname=\"$fixture(&quot;Cop&quot;).One\" result=\"Passed\"/>"
cop_cases="$cop_one<test-case fullname=\"$fixture(&quot;Cop&quot;).Two(True)\" result=\"Passed\"/>"
mime_cases="<test-case fullname=\"$fixture(&quot;Mime&quot;).One\" result=\"Passed\"/>"
parameterized_initial="<test-run total=\"3\" passed=\"3\" failed=\"0\" skipped=\"0\">$(parameterized_suite Cop Failed "$cop_cases" TearDown)$(parameterized_suite Mime Passed "$mime_cases")</test-run>"
parameterized_pass="$(parameterized_suite Cop Passed "$cop_cases")$(parameterized_suite Mime Passed "$mime_cases")"
FAKE_INITIAL_XML="$parameterized_initial" FAKE_RETRY_XML="<test-run total=\"3\" passed=\"3\" failed=\"0\" skipped=\"0\">$parameterized_pass</test-run>" FAKE_RETRY_EXIT=0 run gate
check "a complete Passed retry of every parameterised fixture instance clears the gate" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && retry_line | grep -qF -- "-testFilter $fixture " && grep -q "flaky-passed:" "$tmp/err"'
for scenario in missing-case missing-instance missing-fixtures nonpassed-fixture; do
  case "$scenario" in
    missing-case)
      retry_suites="$(parameterized_suite Cop Passed "$cop_one")$(parameterized_suite Mime Passed "$mime_cases")"; total=2 ;;
    missing-instance)
      retry_suites="$(parameterized_suite Cop Passed "$cop_cases")"; total=2 ;;
    missing-fixtures)
      retry_suites="$cop_cases$mime_cases"; total=3 ;;
    nonpassed-fixture)
      retry_suites="$(parameterized_suite Cop Skipped "$cop_cases")$(parameterized_suite Mime Passed "$mime_cases")"; total=3 ;;
  esac
  FAKE_INITIAL_XML="$parameterized_initial" FAKE_RETRY_XML="<test-run total=\"$total\" passed=\"$total\" failed=\"0\" skipped=\"0\">$retry_suites</test-run>" FAKE_RETRY_EXIT=0 run gate
  check "parameterised fixture retry rejects $scenario despite Passed cases matching the filter prefix" \
    '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && ! grep -q "flaky-passed:" "$tmp/err" && grep -Eq "fixture retry omitted original test case|no matching Passed fixture|retry fixture did not pass" "$tmp/out"'
done

# --- the listed flake fails again: the gate fails, no third run --------------------------------------------------------------
FAKE_FAILS="$spray" FAKE_RETRY_FAILS="$spray" run gate
check "a listed flake that fails again: gate fails after one rerun only" '[ "$rc" != 0 ] && [ "$(runs)" = 2 ]'
check "the summary says the retried flake failed again" \
  'grep -q "(retried 1 known flake: $spray — failed again)" "$tmp/out" && grep -q "^gate fails:  $spray: flaky" "$tmp/out"'

# --- an unlisted failure next to a listed one: no rerun ----------------------------------------------------------------------
FAKE_FAILS="$spray;$real" run gate
check "an unlisted failure plus a listed flake: gate fails with no rerun, naming the unlisted test" \
  '[ "$rc" != 0 ] && [ "$(runs)" = 1 ] && ! grep -q -- -testFilter "$tmp/unity.log" && grep -q "not known flakes .*: $real; with more than one failure: no retry" "$tmp/err" && ! grep -q retried "$tmp/out"'
real2=Synthetic.Park.Tests.CourtPlayModeTests.AlsoBroken
FAKE_FAILS="$real;$real2" run gate
check "two unlisted failures: gate fails with no rerun" \
  '[ "$rc" != 0 ] && [ "$(runs)" = 1 ] && grep -q "$real, $real2; with more than one failure: no retry" "$tmp/err" && ! grep -q retried "$tmp/out"'

# --- exactly one failure, not listed: one rerun of just that test.
run_dir() { sed -n 's/^QR_RUN_DIR=//p' "$root/release-logs/current.env"; }
FAKE_FAILS="$real" run gate
check "one unlisted failure that passes on the rerun: gate exits 0 after one rerun of only that test" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && retry_line | grep -q -- "-testCategory Gfx;MacOnly -testFilter $real -testResults .*/gate-retry.xml -logFile .*/gate-retry-unity.log"'
check "the gate line says it retried 1 unlisted failure that passed on rerun" \
  'grep -qF "(retried 1 unlisted failure: $real, passed on rerun; consider adding it to known-flakes.txt or fixing it)" "$tmp/out"'
check "every attempt is kept: gate.xml (the failure), gate-retry.xml and gate-retry-unity.log" \
  'd="$(run_dir)"; grep -q "$real\" result=\"Failed" "$d/gate.xml" && grep -q "failed=\"0\"" "$d/gate-retry.xml" && grep -q "filter $real" "$d/gate-retry-unity.log" && grep -q "^editor log$" "$d/gate-unity.log"'
FAKE_FAILS="$real" FAKE_RETRY_FAILS="$real" run gate
check "one unlisted failure that fails again: gate fails after one rerun only" \
  '[ "$rc" != 0 ] && [ "$(runs)" = 2 ] && grep -q "(retried 1 unlisted failure: $real — failed again)" "$tmp/out" && grep -q "^gate fails:  $real: flaky" "$tmp/out"'

# --- the list is read from the commit under test; QUEST_KNOWN_FLAKES overrides ------------------------------------------------
worktrees=("$root"/rel-*-test)
wt="${worktrees[0]}"
# Commit a worktree-only list change: the main checkout must not supply these entries.
printf '%s\n' "$real" "$real2" >> "$wt/Tools/ship/known-flakes.txt"
git -C "$wt" add Tools/ship/known-flakes.txt && git -C "$wt" commit -qm 'Add synthetic release flakes'
check "the committed test list differs from the main checkout" \
  'git -C "$wt" show HEAD:Tools/ship/known-flakes.txt | grep -qF "$real" && ! grep -qF "$real" "$list"'
FAKE_FAILS="$real;$real2" run gate
check "the gate retries two known flakes committed only in the test worktree" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && grep -qF "retried 2 known flakes: $real, $real2 — passed" "$tmp/out"'

# A missing worktree list retains compatibility with the main checkout list.
git -C "$wt" rm -q Tools/ship/known-flakes.txt && git -C "$wt" commit -qm 'Omit synthetic release flakes'
FAKE_FAILS="$spray;$consistency" run gate
check "a worktree without a list falls back to the main checkout" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && grep -qF "retried 2 known flakes: $spray, $consistency — passed" "$tmp/out"'

rc=0
(
  qr_config || exit 1
  [ "$(qr_known_flakes_file "$wt")" = "$list" ] || exit 1
  QR_KNOWN_FLAKES="$tmp/missing-list.txt"
  [ -z "$(qr_known_flakes_file "$wt")" ]
) || rc=$?
check "no existing list in either checkout returns empty" '[ "$rc" = 0 ]'

# An existing empty worktree list is authoritative, not a reason to fall back.
: > "$wt/Tools/ship/known-flakes.txt"
FAKE_FAILS="$spray;$consistency" run gate
check "an empty worktree list does not use main-checkout entries" '[ "$rc" != 0 ] && [ "$(runs)" = 1 ]'

jq --arg path "$list" '.knownFlakes = $path' "$repo/yetikit.json" > "$YETIKIT_CONFIG"
FAKE_FAILS="$spray;$consistency" run gate
check "an absolute config path is used as-is despite an empty worktree list" \
  '[ "$rc" = 0 ] && [ "$(runs)" = 2 ] && grep -q "retried 2 known flakes" "$tmp/out"'
cp "$repo/yetikit.json" "$YETIKIT_CONFIG"
cp "$list" "$wt/Tools/ship/known-flakes.txt"

: > "$tmp/empty-flakes.txt"
rc=0; ( QUEST_KNOWN_FLAKES="$tmp/empty-flakes.txt"; FAKE_FAILS="$spray;$consistency"; rm -f "$tmp/unity.log"; qr_main gate ) > "$tmp/out" 2> "$tmp/err" || rc=$?
check "QUEST_KNOWN_FLAKES with nothing listed: two (now unlisted) failures get no rerun" '[ "$rc" != 0 ] && [ "$(runs)" = 1 ]'

if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

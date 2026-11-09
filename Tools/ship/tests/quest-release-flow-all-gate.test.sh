#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_keystore

# --- all -------------------------------------------------------------------------------------------------------------------------
reset_logs; FAKE_XML="$xml_fail" run all
check "all: a failed gate installs nothing, keeps the APK and reports" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/installed" ] && ! grep -q " install " "$tmp/adb.log" 2>/dev/null && [ -f "$apk" ] && grep -q "install:     skipped: gate failed" "$tmp/out"'
check "all: gate and build both ran, each with its own -logFile" \
  'grep -q "gate-unity.log" "$tmp/unity.log" && grep -q "build-unity.log" "$tmp/unity.log" && [ -d "$root/rel-$short-test" ]'
# A parameterised fixture failure reduces to Ns.F; one Passed case must not allow all to install.
xml_parameterized='<test-run total="2" passed="2" failed="0" skipped="0"><test-suite type="TestFixture" fullname="Ns.F(&quot;Cop&quot;)" result="Failed" site="TearDown"><test-case fullname="Ns.F(&quot;Cop&quot;).One" result="Passed"/><test-case fullname="Ns.F(&quot;Cop&quot;).Two" result="Passed"/></test-suite></test-run>'
xml_partial='<test-run total="1" passed="1" failed="0" skipped="0"><test-suite type="TestFixture" fullname="Ns.F(&quot;Cop&quot;)" result="Passed"><test-case fullname="Ns.F(&quot;Cop&quot;).One" result="Passed"/></test-suite></test-run>'
reset_logs; FAKE_XML="$xml_parameterized" FAKE_RETRY_XML="$xml_partial" run all
check "all refuses to install when a parameterised fixture retry returns just one Passed case" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/installed" ] && [ -f "$apk" ] && grep -q -- "-testFilter Ns.F " "$tmp/unity.log" && grep -q "install:     skipped: gate failed" "$tmp/out" && out_has "fixture retry omitted original test case"'

qr_flow_finish

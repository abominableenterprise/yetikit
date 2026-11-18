#!/usr/bin/env bash
# Synthetic editor evidence with differently encoded NUnit fullnames.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

cat > "$UNITY_ROOT/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TMP/runs"
while [ "$#" -gt 1 ]; do
  if [ "$1" = -testResults ]; then
    if [[ "$2" == *-retry.xml ]]; then cp "$FAKE_TMP/retry.xml" "$2"; exit; fi
    cp "$FAKE_TMP/original.xml" "$2"; exit 2
  fi
  shift
done
exit 1
EOF
cat > "$tmp/original.xml" <<'EOF'
<test-run total="2" passed="0" failed="2" skipped="0">
  <test-case fullname="X.Tests.Throw.AFlick(&#x22;A&#38;B&#10;C&amp;#65;&#34;)" result="Failed" />
  <test-case fullname="X.Tests.Throw.AFlick(&#x22;Next&#13;Line&#x22;)" result="Failed" />
</test-run>
EOF
retry_xml() {
  printf '%s\n' '<test-run total="2" passed="2" failed="0" skipped="0">' \
    "<test-case fullname='X.Tests.Throw.AFlick(\"A&amp;B$1C&amp;#65;\")' result='Passed' />" \
    '<test-case fullname="X.Tests.Throw.AFlick(&quot;Next&#xD;Line&quot;)" result="Passed" />' \
    '</test-run>' > "$tmp/retry.xml"
}
retry_xml '&#xA;'
EDITMODE_GFX=0 run editmode
check "retry matches exact decoded fullnames, including LF, CR and a literal reference" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && [ "$(retry_filter)" = X.Tests.Throw.AFlick ] && grep -q flaky-passed "$tmp/err"'
retry_xml ' '
EDITMODE_GFX=0 run editmode
check "a space in place of a referenced LF does not cover that failed case" \
  '[ "$rc" = 2 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && ! grep -q flaky-passed "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

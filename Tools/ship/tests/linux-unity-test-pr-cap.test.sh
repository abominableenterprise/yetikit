#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: bounded selection and deterministic recency ordering.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"


# --- bounded selection, deterministic newest-first fallback ------------------------------------------------------------
# Call the helper directly to assert stdout is ONLY fixture names and stderr contains the explanation. Controlled
# timestamps avoid sleeps; committed sources use commit time, dirty/untracked sources use mtime and rank first.
mkdir -p "$t/Cap" "$proj/Assets/Scripts/Cap"
echo 'class Cap {}' > "$proj/Assets/Scripts/Cap/Cap.cs"
for i in $(seq -w 1 14); do
  gfx "$t/Cap/Fixture$i.cs" ExampleGame.Cap.Tests "Fixture$i" Gfx
  printf '// Cap\n' >> "$t/Cap/Fixture$i.cs"
done
GIT_AUTHOR_DATE=2021-01-01T00:00:00Z GIT_COMMITTER_DATE=2021-01-01T00:00:00Z commit cap-fixtures
# Commit Fixture01 later than all others; leave it clean so an older-dated dirty fixture still ranks first.
echo '// newest committed' >> "$t/Cap/Fixture01.cs"
GIT_AUTHOR_DATE=2021-01-02T00:00:00Z GIT_COMMITTER_DATE=2021-01-02T00:00:00Z commit newest-fixture
# A newer Gfx fixture in the same folder is not a candidate unless its source mentions the changed class.
gfx "$t/Cap/UnrelatedTests.cs" ExampleGame.Other.Tests UnrelatedTests Gfx
GIT_AUTHOR_DATE=2021-01-03T00:00:00Z GIT_COMMITTER_DATE=2021-01-03T00:00:00Z commit unrelated-fixture
for i in $(seq -w 2 14); do
  echo '// dirty' >> "$t/Cap/Fixture$i.cs"
  touch -t "2020010100${i}.00" "$t/Cap/Fixture$i.cs"
done
echo '// changed runtime' >> "$proj/Assets/Scripts/Cap/Cap.cs"
pick
expected="$(for i in $(seq 14 -1 3); do printf 'ExampleGame.Cap.Tests.Fixture%02d\n' "$i"; done)"
check "default cap is 12; overflow chooses newest matching dirty fixtures in descending order" \
  '[ "$(wc -l < "$tmp/picked")" = 12 ] && [ "$(< "$tmp/picked")" = "$expected" ]'
check "overflow logs the fallback and cap on stderr, without contaminating stdout" \
  'grep -q "14 matching Gfx fixtures exceed TEST_PR_GFX_MAX=12; fallback" "$tmp/pick-err" && ! grep -qE "why:|selected|fallback" "$tmp/picked"'
TEST_PR_GFX_MAX=2 pick
check "custom cap also orders by recency, not class name" \
  '[ "$(< "$tmp/picked")" = "$(printf "ExampleGame.Cap.Tests.Fixture14\nExampleGame.Cap.Tests.Fixture13")" ]'
TEST_PR_GFX_MAX=14 pick
check "at the cap, no fallback: all matching classes in normal sorted order" \
  '[ "$(wc -l < "$tmp/picked")" = 14 ] && [ "$(head -n1 "$tmp/picked")" = ExampleGame.Cap.Tests.Fixture01 ] && ! grep -q fallback "$tmp/pick-err"'
# Equal mtimes have a stable class-name tie-break. A tracked dirty file and an untracked file share that policy.
git -C "$proj" checkout -q -- Assets/Tests/EditMode/Cap
printf '// dirty\n' >> "$t/Cap/Fixture02.cs"
gfx "$t/Cap/Fixture15.cs" ExampleGame.Cap.Tests Fixture15 Gfx
printf '// Cap\n' >> "$t/Cap/Fixture15.cs"
touch -t 202001010100.00 "$t/Cap/Fixture02.cs" "$t/Cap/Fixture15.cs"
TEST_PR_GFX_MAX=2 pick
check "dirty and untracked sources outrank clean committed sources; ties sort by class name" \
  '[ "$(< "$tmp/picked")" = "$(printf "ExampleGame.Cap.Tests.Fixture02\nExampleGame.Cap.Tests.Fixture15")" ]'
rm "$t/Cap/Fixture15.cs"
git -C "$proj" checkout -q -- Assets/Tests/EditMode/Cap
TEST_PR_GFX_MAX=1 pick
check "clean matching fixtures use commit recency, never a newer nonmatching fixture" '[ "$(< "$tmp/picked")" = ExampleGame.Cap.Tests.Fixture01 ]'
TEST_PR_GFX_MAX=0 pick
check "a zero cap selects no fixtures and explains the fallback" '[ ! -s "$tmp/picked" ] && grep -q TEST_PR_GFX_MAX=0 "$tmp/pick-err"'
TEST_PR_GFX_MAX=invalid pick
check "invalid cap falls back to the default" '[ "$(wc -l < "$tmp/picked")" = 12 ] && grep -q "invalid TEST_PR_GFX_MAX" "$tmp/pick-err"'
git -C "$proj" checkout -q -- Assets/Scripts/Cap/Cap.cs


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

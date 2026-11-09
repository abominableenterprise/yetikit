#!/usr/bin/env bash
# Offline integration tests: all repositories, identities and consumer data are synthetic.
set -euo pipefail
vendor=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in git jq sha256sum tar; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/yetikit vendor tests.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
source_repo="$tmp/source repo"
project="$tmp/consumer project"
prefix=com.abominable.yetikit.
url='https://github.com/abominableenterprise/yetikit.git?path=/Packages/'
fail() { echo "FAIL: $*" >&2; exit 1; }
equal() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"; }
expect_failure() {
  local status=0
  "$@" >"$tmp/failure.log" 2>&1 || status=$?
  [[ $status -ne 0 ]] || fail "unexpected success: $*"
  [[ -s "$tmp/failure.log" ]] || fail "failure has no diagnostic: $*"
  if [[ ${1:-} == check ]]; then equal "$status" 1 'checker failure exit code'; fi
}
bump() { bash "$vendor/kit-bump.sh" "$@" --project "$project" --source "$source_repo"; }
check() { YETIKIT_ALLOW_FILE=0 bash "$vendor/kit-check.sh" --project "$project"; }
manifest() { jq -e "$@" "$project/Packages/manifest.json" >/dev/null || fail 'manifest assertion'; }
version_value() { grep "^$1=" "$project/Tools/yetikit/VERSION" | cut -d= -f2-; }
snapshot() {
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - -C "$project" . | sha256sum
}
package() {
  mkdir -p "$source_repo/Packages/$prefix$1"
  jq -n --arg name "$prefix$1" --argjson dependencies "$2" \
    '{name:$name,version:"1.0.0",dependencies:$dependencies}' >"$source_repo/Packages/$prefix$1/package.json"
}
mkdir -p "$source_repo/Tools/ship/nested" "$project/Packages" "$project/Assets"
git init -q "$source_repo"
git -C "$source_repo" config user.name Fixture
git -C "$source_repo" config user.email fixture@example.invalid
git -C "$source_repo" config commit.gpgsign false
git -C "$source_repo" config tag.gpgsign false
package core '{}'
package hands '{"com.abominable.yetikit.core":"1.0.0","org.example.utility":"1.0.0"}'
package loop-a '{"com.abominable.yetikit.loop-b":"1.0.0"}'
package loop-b '{"com.abominable.yetikit.loop-a":"1.0.0"}'
printf '#!/bin/sh\nprintf "v1\\n"\n' >"$source_repo/Tools/ship/tool.sh"
chmod +x "$source_repo/Tools/ship/tool.sh"
printf 'remove in v2\n' >"$source_repo/Tools/ship/obsolete.txt"
printf 'nested VERSION is hashed\n' >"$source_repo/Tools/ship/nested/VERSION"
git -C "$source_repo" add .
git -C "$source_repo" commit -qm 'Add synthetic v1 fixture'
git -C "$source_repo" tag v1
v1_commit=$(git -C "$source_repo" rev-parse 'v1^{commit}')
rm "$source_repo/Tools/ship/obsolete.txt"
printf '#!/bin/sh\nprintf "v2\\n"\n' >"$source_repo/Tools/ship/tool.sh"
printf 'new in v2\n' >"$source_repo/Tools/ship/added file.txt"
git -C "$source_repo" add .
git -C "$source_repo" commit -qm 'Update synthetic v2 fixture'
git -C "$source_repo" tag -a v2 -m 'Synthetic annotated tag'
v2_commit=$(git -C "$source_repo" rev-parse 'v2^{commit}')
# Neither the current HEAD nor dirty/untracked source files may influence a tag bump.
git -C "$source_repo" checkout -q v1
printf 'dirty checkout\n' >"$source_repo/Tools/ship/tool.sh"
printf 'untracked\n' >"$source_repo/Tools/ship/untracked.txt"
printf '{}\n' >"$source_repo/Packages/${prefix}hands/package.json"
printf '{"registry":"synthetic","dependencies":{"org.example.utility":"1.2.3","org.example.other":"4.5.6"},"testables":[]}\n' >"$project/Packages/manifest.json"
printf 'consumer-owned\n' >"$project/Assets/keep.txt"
printf 'unrelated tool\n' >"$project/Tools-keep.txt"
cp "$project/Packages/manifest.json" "$tmp/initial.json"
echo 'Bump from nothing, add direct dependency closure, preserve consumer data'
bump v1 --modules hands,core
check
manifest --arg p "$prefix" --arg u "$url" '(.dependencies | keys | length) == 4 and .dependencies[$p+"hands"] == ($u+$p+"hands#v1") and .dependencies[$p+"core"] == ($u+$p+"core#v1")'
equal "$(jq -c 'del(.dependencies)' "$project/Packages/manifest.json")" "$(jq -c 'del(.dependencies)' "$tmp/initial.json")" 'other root keys'
equal "$(jq -c 'keys_unsorted' "$project/Packages/manifest.json")" '["registry","dependencies","testables"]' 'root key order'
equal "$(jq -c '.dependencies | to_entries[:2]' "$project/Packages/manifest.json")" "$(jq -c '.dependencies | to_entries' "$tmp/initial.json")" 'other entries and order'
equal "$(cat "$project/Assets/keep.txt")" consumer-owned 'unrelated asset'
equal "$(cat "$project/Tools-keep.txt")" 'unrelated tool' 'unrelated file'
equal "$(version_value tag)" v1 'initial tag'
equal "$(version_value commit)" "$v1_commit" 'initial commit'
v1_hash=$(version_value sha256)
[[ $v1_hash =~ ^[0-9a-f]{64}$ ]] || fail 'invalid digest format'
[[ -f "$project/Tools/yetikit/obsolete.txt" && ! -e "$project/Tools/yetikit/untracked.txt" ]] || fail 'incorrect v1 snapshot'
git -C "$source_repo" show v1:Tools/ship/tool.sh >"$tmp/expected-tool"
cmp "$tmp/expected-tool" "$project/Tools/yetikit/tool.sh" || fail 'dirty source leaked'
before=$(snapshot)
bump v1
equal "$(snapshot)" "$before" 'first adoption receipt remains canonical on repeat'
for invalid in '' '[]' $'{}\n{}'; do
  printf '%s' "$invalid" >"$project/Packages/manifest.json"
  invalid_before=$(snapshot)
  expect_failure bump v1
  equal "$(snapshot)" "$invalid_before" 'invalid manifest modified consumer'
  expect_failure check
done
# A stream of otherwise valid manifests must also be rejected.
cp "$tmp/initial.json" "$project/Packages/manifest.json"
cat "$tmp/initial.json" >>"$project/Packages/manifest.json"
expect_failure bump v1
cp "$tmp/initial.json" "$project/Packages/manifest.json"
bump v1 --modules hands,core
echo 'Upgrade rewrites all existing kit entries and terminates cyclic closure'
jq --arg p "$prefix" '.dependencies[$p+"loop-a"]="file:debug-only"' "$project/Packages/manifest.json" >"$tmp/upgrade.json"
cp "$tmp/upgrade.json" "$project/Packages/manifest.json"
bump v2
check
equal "$(version_value commit)" "$v2_commit" 'annotated tag peeled to commit'
equal "$(version_value tag)" v2 'upgrade tag'
[[ $(version_value sha256) != "$v1_hash" ]] || fail 'upgrade digest did not change'
[[ ! -e "$project/Tools/yetikit/obsolete.txt" && -f "$project/Tools/yetikit/added file.txt" ]] || fail 'upgrade did not replace tree'
[[ ! -e "$project/Tools/yetikit/untracked.txt" ]] || fail 'untracked source leaked'
git -C "$source_repo" show v2:Tools/ship/tool.sh >"$tmp/expected-tool"
cmp "$tmp/expected-tool" "$project/Tools/yetikit/tool.sh" || fail 'tag snapshot not honored'
manifest --arg p "$prefix" --arg u "$url" '(.dependencies | keys | length) == 6 and ([.dependencies | to_entries[] | select(.key | startswith($p)) | .value == ($u+.key+"#v2")] | all)'
equal "$(jq -c '.dependencies | keys_unsorted | map(select(. != "com.abominable.yetikit.loop-b"))' "$project/Packages/manifest.json")" "$(jq -c '.dependencies | keys_unsorted' "$tmp/upgrade.json")" 'existing dependency order'
version="$project/Tools/yetikit/VERSION"
equal "$(wc -l < "$version" | tr -d ' ')" 4 'VERSION line count'
equal "$(head -n 3 "$version")" "$(printf 'tag=v2\ncommit=%s\nsha256=%s' "$v2_commit" "$(version_value sha256)")" 'VERSION first three lines'
graph=$(version_value dependencies)
equal "$graph" "$(printf '%s' "$graph" | jq -c .)" 'compact dependency JSON'
printf '%s' "$graph" | jq -e '{"com.abominable.yetikit.core":[],"com.abominable.yetikit.hands":["com.abominable.yetikit.core"],"com.abominable.yetikit.loop-a":["com.abominable.yetikit.loop-b"],"com.abominable.yetikit.loop-b":["com.abominable.yetikit.loop-a"]} == .' >/dev/null || fail 'dependency graph'
cp "$version" "$tmp/version"
cp "$project/Packages/manifest.json" "$tmp/manifest"
echo 'Repeated bump is deterministic; invalid modules leave the entire consumer unchanged'
before=$(snapshot)
bump v2
equal "$(snapshot)" "$before" 'idempotent tree, modes and manifest'
# The checker must rely on VERSION, not a source checkout or network lookup.
mv "$source_repo" "$tmp/source unavailable"
check
mv "$tmp/source unavailable" "$source_repo"
for modules in absent 'hands,absent' '../outside'; do
  expect_failure bump v2 --modules "$modules"
  equal "$(snapshot)" "$before" 'failed bump modified consumer'
done
echo 'Offline checker rejects hand edits, nested VERSION edits and executable mode changes'
printf 'hand edit\n' >>"$project/Tools/yetikit/tool.sh"
expect_failure check
grep -Ei 'upstream|kit-bump' "$tmp/failure.log" >/dev/null || fail 'missing repair guidance'
cp "$tmp/expected-tool" "$project/Tools/yetikit/tool.sh"
printf 'tamper\n' >>"$project/Tools/yetikit/nested/VERSION"
expect_failure check
git -C "$source_repo" show v2:Tools/ship/nested/VERSION >"$project/Tools/yetikit/nested/VERSION"
if [[ -x "$source_repo/Tools/ship/tool.sh" ]]; then
  [[ -x "$project/Tools/yetikit/tool.sh" ]] || fail 'executable bit was not preserved during vendoring'
  chmod -x "$project/Tools/yetikit/tool.sh"
  if [[ ! -x "$project/Tools/yetikit/tool.sh" ]]; then expect_failure check; fi
  chmod +x "$project/Tools/yetikit/tool.sh"
fi
check
echo 'Tree hash detects added, removed and renamed paths'
printf 'extra file\n' >"$project/Tools/yetikit/extra.txt"
expect_failure check
rm "$project/Tools/yetikit/extra.txt"
mv "$project/Tools/yetikit/added file.txt" "$tmp/saved-file"
expect_failure check
mv "$tmp/saved-file" "$project/Tools/yetikit/renamed.txt"
expect_failure check
mv "$project/Tools/yetikit/renamed.txt" "$project/Tools/yetikit/added file.txt"
check
echo 'Debug override must not bypass closure, tag or tree integrity checks'
printf 'tamper\n' >>"$project/Tools/yetikit/tool.sh"
expect_failure env YETIKIT_ALLOW_FILE=1 bash "$vendor/kit-check.sh" --project "$project"
cp "$tmp/expected-tool" "$project/Tools/yetikit/tool.sh"
check
echo 'Reject mixed tags, missing dependencies, file references; permit explicit debug override'
jq --arg p "$prefix" '.dependencies[$p+"core"] |= sub("#v2$";"#v1")' "$tmp/manifest" >"$project/Packages/manifest.json"
expect_failure check
expect_failure env YETIKIT_ALLOW_FILE=1 bash "$vendor/kit-check.sh" --project "$project"
jq --arg p "$prefix" 'del(.dependencies[$p+"core"])' "$tmp/manifest" >"$project/Packages/manifest.json"
expect_failure check
expect_failure env YETIKIT_ALLOW_FILE=1 bash "$vendor/kit-check.sh" --project "$project"
jq --arg p "$prefix" 'del(.dependencies[$p+"loop-b"])' "$tmp/manifest" >"$project/Packages/manifest.json"
expect_failure check
jq --arg p "$prefix" '.dependencies[$p+"hands"]="file:../local hands"' "$tmp/manifest" >"$project/Packages/manifest.json"
expect_failure check
YETIKIT_ALLOW_FILE=1 bash "$vendor/kit-check.sh" --project "$project"
cp "$tmp/manifest" "$project/Packages/manifest.json"
echo 'Reject malformed VERSION metadata, including invalid offline dependency graphs'
for malformed in empty truncated tag commit digest graph invalid-json graph-value missing-graph duplicate; do
  case "$malformed" in
    empty) : >"$version" ;;
    truncated) printf 'tag=v2\n' >"$version" ;;
    tag) awk '{if (NR==1) print "tag="; else print}' "$tmp/version" >"$version" ;;
    commit) awk '{if (NR==2) print "commit=not-a-commit"; else print}' "$tmp/version" >"$version" ;;
    digest) awk '{if (NR==3) print "sha256=invalid"; else print}' "$tmp/version" >"$version" ;;
    graph) head -n 3 "$tmp/version" >"$version"; printf 'dependencies=[]\n' >>"$version" ;;
    invalid-json) head -n 3 "$tmp/version" >"$version"; printf 'dependencies={broken\n' >>"$version" ;;
    graph-value) head -n 3 "$tmp/version" >"$version"; printf 'dependencies={"com.abominable.yetikit.core":"invalid"}\n' >>"$version" ;;
    missing-graph) head -n 3 "$tmp/version" >"$version" ;;
    duplicate) cp "$tmp/version" "$version"; printf 'tag=v1\n' >>"$version" ;;
  esac
  expect_failure check
done
cp "$tmp/version" "$version"
check
echo 'A vendored symlink cannot redirect a subsequent bump outside the consumer'
printf 'external sentinel\n' >"$tmp/external"
rm "$project/Tools/yetikit/tool.sh"
ln -s "$tmp/external" "$project/Tools/yetikit/tool.sh"
if bump v2 >"$tmp/symlink.log" 2>&1; then check; fi
equal "$(cat "$tmp/external")" 'external sentinel' 'wrote through vendored symlink'
# Restore even if the implementation deliberately rejected the symlink.
rm -rf "$project/Tools/yetikit"
bump v2
check
echo 'Symlink destination cannot redirect writes outside the consumer'
mv "$project/Tools/yetikit" "$tmp/outside"
ln -s "$tmp/outside" "$project/Tools/yetikit"
cp "$tmp/outside/tool.sh" "$tmp/outside-tool"
# Rejection or safe replacement is acceptable; writing through the link is not.
if bump v1 >"$tmp/symlink.log" 2>&1; then check; fi
cmp "$tmp/version" "$tmp/outside/VERSION" || fail 'wrote through destination symlink'
cmp "$tmp/outside-tool" "$tmp/outside/tool.sh" || fail 'modified external target'
[[ -f "$tmp/outside/added file.txt" ]] || fail 'deleted external target file'
bash "$vendor/tests/ship-fixtures.sh"
echo 'PASS: offline vendoring regressions'

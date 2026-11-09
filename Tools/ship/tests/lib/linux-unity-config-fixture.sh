#!/usr/bin/env bash
# Shared synthetic consumer setup; no runner jq cache is required.
# Validation cases always exercise both command invocation and sourcing.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
proj="$tmp/project"; fails=0
. "$(dirname "${BASH_SOURCE[0]}")/fake-unity.sh"
cp "$proj/yetikit.json" "$tmp/scene.json"
run() { rc=0; bash "$script" "$@" >"$tmp/stdout" 2>"$tmp/err" || rc=$?; }
invalid() {
  local expression="$1" key="$2"
  jq "$expression" "$tmp/scene.json" > "$proj/yetikit.json"
  run cache-key
  check "invalid config names $key before command work" \
    '[ "$rc" != 0 ] && grep -Fq "$key" "$tmp/err" && [ ! -f "$tmp/runs" ]'
  rc=0
  bash -c '. "$1"' _ "$script" 2>"$tmp/source-err" || rc=$?
  check "source harness also rejects $key" '[ "$rc" != 0 ] && grep -Fq "$key" "$tmp/source-err"'
}
config_test_roots() {
  local key value
  for key in "$@"; do
    for value in '"/outside"' '"Assets/../outside"' '42' 'null' '""'; do
      invalid ".tests.$key = $value" "tests.$key"
    done
  done
}
config_no_scene_files() {
  mkdir -p "$proj/Packages" "$proj/ProjectSettings" "$proj/Library"
  printf '{}\n' > "$proj/Packages/manifest.json"
  printf '{}\n' > "$proj/Packages/packages-lock.json"
  printf 'm_EditorVersion: 6000.6.6f1\n' > "$proj/ProjectSettings/ProjectVersion.txt"
}
config_finish() {
  [ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
}

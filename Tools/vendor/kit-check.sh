#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
project=.
if (($#)); then
  [[ $# == 2 && $1 == --project && -n $2 ]] || fail 'kit-check.sh [--project <dir>]'
  project=$2
fi
open_project "$project"
bundle=$project/Tools/yetikit
check_tree "$bundle"
version=$bundle/VERSION
[[ -f $version ]] || fail 'missing VERSION; run kit-bump'
mapfile -t receipt < "$version"
[[ ${#receipt[@]} == 4 && ${receipt[0]} == tag=* && ${receipt[1]} == commit=* &&
   ${receipt[2]} == sha256=* && ${receipt[3]} == dependencies=* ]] || fail 'invalid VERSION; run kit-bump'
tag=${receipt[0]#tag=}; commit=${receipt[1]#commit=}
digest=${receipt[2]#sha256=}; graph=${receipt[3]#dependencies=}
valid_tag "$tag" && [[ $commit =~ ^[0-9a-f]{40}$ && $digest =~ ^[0-9a-f]{64}$ ]] ||
  fail 'invalid VERSION fields; run kit-bump'
jq -e --arg p "$KIT_PREFIX" 'type == "object" and all(to_entries[];
  (.key | startswith($p)) and (.value | type == "array" and all(.[]; type == "string")))' \
  <<< "$graph" >/dev/null || fail 'invalid VERSION dependencies; run kit-bump'
[[ $(tree_hash "$bundle") == "$digest" ]] || fail 'vendored Ship was edited: fix upstream, then kit-bump'
while IFS= read -r package; do
  valid_package "$package" || fail "invalid kit package: $package"
  pin=$(jq -r --arg name "$package" '.dependencies[$name]' "$manifest")
  if [[ $pin == file:* ]]; then
    [[ ${YETIKIT_ALLOW_FILE:-0} == 1 ]] || fail "file: kit package $package requires YETIKIT_ALLOW_FILE=1"
  else
    [[ $pin == "$(kit_url "$package" "$tag")" ]] || fail "$package must pin $tag; run kit-bump"
  fi
  jq -e --arg name "$package" 'has($name)' <<< "$graph" >/dev/null ||
    fail "$package has no dependency receipt; run kit-bump"
done < <(kit_entries)
while IFS= read -r package; do
  valid_package "$package" || fail "invalid VERSION package: $package"
  jq -e --arg name "$package" '.dependencies | has($name)' "$manifest" >/dev/null ||
    fail "missing kit package $package; run kit-bump"
  while IFS= read -r dependency; do
    jq -e --arg name "$dependency" 'has($name)' <<< "$graph" >/dev/null ||
      fail "incomplete dependency receipt for $package; run kit-bump"
    jq -e --arg name "$dependency" '.dependencies | has($name)' "$manifest" >/dev/null ||
      fail "$package is missing kit dependency $dependency; run kit-bump"
  done < <(jq -r --arg name "$package" '.[$name][]' <<< "$graph")
done < <(jq -r 'keys[]' <<< "$graph")
printf 'YetiKit: %s verified (Ship digest and package closure)\n' "$tag"

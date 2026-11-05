#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
usage='kit-bump.sh <tag> [--project <dir>] [--modules core,hands,...] [--source <local checkout>]'
[[ $# -gt 0 ]] || fail "$usage"
tag=$1; shift
valid_tag "$tag" || fail "invalid tag: $tag"
project=.; modules=; source_dir=
while (($#)); do
  [[ $# -ge 2 && -n $2 ]] || fail "$usage"
  case $1 in
    --project) project=$2 ;;
    --modules) modules=$2 ;;
    --source) source_dir=$2 ;;
    *) fail "$usage" ;;
  esac
  shift 2
done
open_project "$project"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
if [[ -z $source_dir ]]; then
  git clone --quiet --depth 1 --branch "$tag" -- "$KIT_REMOTE" "$work/repo"
  source_dir=$work/repo
fi
commit=$(git -C "$source_dir" rev-parse --verify "refs/tags/$tag^{commit}") ||
  fail "tag not found in source: $tag"
mkdir "$work/tree"
git -C "$source_dir" archive "$commit" Tools/ship Packages | tar -x -C "$work/tree"
ship=$work/tree/Tools/ship
check_tree "$ship"
[[ ! -e $ship/VERSION ]] || fail 'upstream Ship reserves VERSION for the consumer receipt'
# Resolve every existing pin, plus requested modules, using only the tagged tree.
mapfile -t queue < <(kit_entries)
if [[ -n $modules ]]; then
  [[ $modules != ,* && $modules != *, && $modules != *,,* ]] || fail 'invalid modules list'
  IFS=, read -r -a requested <<< "$modules"
  for module in "${requested[@]}"; do queue+=("$KIT_PREFIX$module"); done
fi
graph='{}'
declare -A seen=()
for ((i=0; i<${#queue[@]}; i++)); do
  package=${queue[i]}
  valid_package "$package" || fail "invalid kit package: $package"
  [[ ! ${seen[$package]+yes} ]] || continue
  seen[$package]=1
  metadata=$work/tree/Packages/$package/package.json
  [[ -f $metadata && ! -L $metadata ]] || fail "package not found at $tag: $package"
  deps=$(jq -ce --arg name "$package" --arg p "$KIT_PREFIX" '
    if .name != $name or ((.dependencies // {}) | type != "object") then
      error("invalid package metadata")
    else (.dependencies // {} | keys | map(select(startswith($p)))) end' "$metadata") ||
    fail "invalid package.json: $package"
  graph=$(jq -c --arg name "$package" --argjson deps "$deps" '. + {($name): $deps}' <<< "$graph")
  while IFS= read -r dependency; do queue+=("$dependency"); done < <(jq -r '.[]' <<< "$deps")
done
# Stable receipt bytes regardless of discovery order (requested vs existing pins).
graph=$(jq -cS . <<< "$graph")
jq --arg tag "$tag" --arg remote "$KIT_REMOTE" --argjson graph "$graph" '
  reduce ($graph | keys[]) as $name (. ;
    .dependencies[$name] = ($remote + "?path=/Packages/" + $name + "#" + $tag))
' "$manifest" > "$work/manifest.json"
old_tag=none
if [[ -f $project/Tools/yetikit/VERSION ]]; then
  old_tag=$(awk -F= '$1 == "tag" {print substr($0,5); exit}' "$project/Tools/yetikit/VERSION")
fi
digest=$(tree_hash "$ship")
printf 'tag=%s\ncommit=%s\nsha256=%s\ndependencies=%s\n' "$tag" "$commit" "$digest" "$graph" > "$ship/VERSION"
# Compare regular files including removals and executable-bit changes.
changed=0
old=$project/Tools/yetikit
if [[ -e $old ]]; then check_tree "$old"; fi
while IFS= read -r -d '' path; do
  if [[ ! -f $old/$path || ! -f $ship/$path ]] ||
    ! cmp -s -- "$old/$path" "$ship/$path" ||
    [[ -x $old/$path && ! -x $ship/$path || ! -x $old/$path && -x $ship/$path ]]; then
    changed=$((changed + 1))
  fi
done < <({ (cd "$ship" && find . -type f -print0)
  if [[ -d $old ]]; then (cd "$old" && find . -type f -print0); fi
} | LC_ALL=C sort -zu)
mkdir -p -- "$project/Tools"
rm -rf -- "$old"
mv -- "$ship" "$old"
# Preserve the manifest's filesystem permissions while replacing its JSON.
cat "$work/manifest.json" > "$manifest"
printf 'YetiKit: %s → %s; modules: %s; files changed: %s\n' "$old_tag" "$tag" \
  "$(jq -r 'keys | join(", ")' <<< "$graph")" "$changed"

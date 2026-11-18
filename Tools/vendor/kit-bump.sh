#!/usr/bin/env bash
set -euo pipefail
vendor=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$vendor/common.sh"
source "$vendor/tag-tree.sh"
source "$vendor/install.sh"
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
resolve_project "$project"
lock_project
read_manifest
prepare_install
if [[ -z $source_dir ]]; then
  source_dir=$work/repo
  git init --quiet --object-format=sha1 "$source_dir"
  tag_git fetch --quiet --no-tags --depth 1 -- "$KIT_REMOTE" "refs/tags/$tag:refs/tags/$tag"
fi
commit=$(tag_git rev-parse --verify "refs/tags/$tag^{commit}") ||
  fail "tag not found in source: $tag"
mkdir -- "$ship"
extract_ship
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
  read_package "$package" > "$work/package.json" || fail "package not found at $tag: $package"
  deps=$(jq -cse --arg name "$package" --arg p "$KIT_PREFIX" '
    if length != 1 or (.[0] | type != "object" or .name != $name) then
      error("invalid package metadata")
    else .[0] | (if has("dependencies") then .dependencies else {} end) |
      if type == "object" and all(.[]; type == "string") then
        keys | map(select(startswith($p)))
      else error("invalid dependencies") end
    end' "$work/package.json") || fail "invalid package.json: $package"
  graph=$(jq -c --arg name "$package" --argjson deps "$deps" '. + {($name): $deps}' <<< "$graph")
  while IFS= read -r dependency; do queue+=("$dependency"); done < <(jq -r '.[]' <<< "$deps")
done
# Stable receipt bytes regardless of discovery order (requested vs existing pins).
graph=$(jq -cS . <<< "$graph")
jq --arg tag "$tag" --arg remote "$KIT_REMOTE" --argjson graph "$graph" '
  reduce ($graph | keys[]) as $name (. ;
    .dependencies[$name] = ($remote + "?path=/Packages/" + $name + "#" + $tag))
' "$manifest" > "$staged_manifest"
chmod --reference="$manifest" -- "$staged_manifest"
old_tag=none
if [[ -e $old ]]; then
  check_tree "$old"
  if [[ -f $old/VERSION ]]; then
    old_tag=$(awk -F= '$1 == "tag" {print substr($0,5); exit}' "$old/VERSION")
  fi
fi
digest=$(tree_hash "$ship")
printf 'tag=%s\ncommit=%s\nsha256=%s\ndependencies=%s\n' "$tag" "$commit" "$digest" "$graph" > "$ship/VERSION"
# Compare regular files including removals and executable-bit changes.
(cd "$ship" && find . -type f -print0) > "$work/paths" || fail 'cannot list staged Ship'
if [[ -d $old ]]; then
  (cd "$old" && find . -type f -print0) >> "$work/paths" || fail 'cannot list existing Ship'
fi
LC_ALL=C sort -zu "$work/paths" > "$work/sorted-paths"
changed=0
while IFS= read -r -d '' path; do
  if [[ ! -f $old/$path || ! -f $ship/$path ]] ||
    ! cmp -s -- "$old/$path" "$ship/$path" ||
    [[ -x $old/$path && ! -x $ship/$path || ! -x $old/$path && -x $ship/$path ]]; then
    changed=$((changed + 1))
  fi
done < "$work/sorted-paths"
module_names=$(jq -r 'keys | join(", ")' <<< "$graph")
install_bundle
printf 'YetiKit: %s → %s; modules: %s; files changed: %s\n' "$old_tag" "$tag" "$module_names" "$changed"

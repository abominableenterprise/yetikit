#!/usr/bin/env bash
# Read original Git blob bytes without archive attributes or checkout filters.
tag_git() { git --no-replace-objects -C "$source_dir" "$@"; }
extract_ship() {
  local entry mode path oid
  tag_git ls-tree -rz --full-tree "$commit" -- Tools/ship/ > "$work/ship-entries" ||
    fail 'cannot list tagged Ship tree'
  [[ -s $work/ship-entries ]] || fail 'missing tagged Ship tree'
  while IFS= read -r -d '' entry; do
    mode=${entry%% *}; path=${entry#*$'\t'}; path=${path#Tools/ship/}
    oid=${entry%%$'\t'*}; oid=${oid##* }
    case $mode in
      100644|100755) ;;
      *) fail 'tagged Ship must contain only regular files and directories' ;;
    esac
    if [[ $path == */* ]]; then mkdir -p -- "$ship/${path%/*}"; fi
    tag_git cat-file blob "$oid" > "$ship/$path"
    if [[ $mode == 100755 ]]; then chmod +x -- "$ship/$path"; fi
  done < "$work/ship-entries"
}
read_package() {
  local path=Packages/$1/package.json entry
  entry=$(tag_git ls-tree --full-tree "$commit" -- "$path") || return 1
  [[ $entry == '100644 blob '* || $entry == '100755 blob '* ]] || return 1
  tag_git cat-file blob "$commit:$path"
}

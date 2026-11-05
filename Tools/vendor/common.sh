#!/usr/bin/env bash
# Shared implementation for the consumer vendoring commands (Bash 4+, GNU tools).
set -euo pipefail
KIT_PREFIX=com.abominable.yetikit.
KIT_REMOTE=https://github.com/abominableenterprise/yetikit.git
fail() { printf 'yetikit: %s\n' "$*" >&2; exit 1; }

valid_tag() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] &&
    git check-ref-format "refs/tags/$1" >/dev/null 2>&1
}
valid_package() { [[ $1 =~ ^com\.abominable\.yetikit\.[a-z0-9][a-z0-9.-]*$ ]]; }
kit_url() { printf '%s?path=/Packages/%s#%s' "$KIT_REMOTE" "$1" "$2"; }

# Refuse links/special files rather than following data outside the bundle.
check_tree() {
  [[ -d $1 && ! -L $1 ]] || fail "missing or linked Ship directory: $1"
  [[ -z $(find "$1" ! -type d ! -type f -print -quit) ]] ||
    fail 'Ship must contain only regular files and directories'
}
# Unambiguous records: path NUL executable-bit NUL byte-count NUL file-bytes.
# Only the root VERSION is excluded; nested VERSION files are ordinary payload.
tree_hash() {
  (
    check_tree "$1"
    cd "$1"
    while IFS= read -r -d '' path; do
      executable=0; [[ ! -x $path ]] || executable=1
      printf '%s\0%s\0%s\0' "${path#./}" "$executable" "$(stat -c %s -- "$path")"
      cat -- "$path"
    done < <(find . -type f ! -path ./VERSION -print0 | LC_ALL=C sort -z)
  ) | sha256sum | cut -d ' ' -f 1
}

open_project() {
  project=$(cd -- "$1" && pwd -P) || fail "project not found: $1"
  for path in Tools Tools/yetikit Packages Packages/manifest.json; do
    [[ ! -L $project/$path ]] || fail "linked project path is not supported: $path"
  done
  manifest=$project/Packages/manifest.json
  jq -se 'length == 1 and (.[0] | type == "object" and
    (.dependencies | type == "object") and
    (.dependencies | all(.[]; type == "string")))' "$manifest" >/dev/null ||
    fail 'manifest.json must have a dependencies object of strings'
}
kit_entries() {
  jq -r --arg p "$KIT_PREFIX" '.dependencies | keys[] | select(startswith($p))' "$manifest"
}

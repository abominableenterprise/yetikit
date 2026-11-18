#!/usr/bin/env bash
# Exercise the real Git path transport in disposable vendored checkouts.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null RUN_LOG="$tmp/runs"
failures=0

setup() {
  repo="$tmp/$1"
  tools="$repo/$2"
  mkdir -p "$tools/tests"
  git init -q "$repo"
  # Force the quoting behavior even when the caller has disabled it globally.
  git -C "$repo" config core.quotePath true
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config commit.gpgsign false
  cp "$ship/test-all.sh" "$tools/test-all.sh"
  printf 'echo quick >> "$RUN_LOG"\n' > "$tools/tests/quick.test.sh"
}

commit() {
  git -C "$repo" add -- .
  git -C "$repo" commit -qm 'Add synthetic fixture'
}

check() {
  local label=$1 expected=$2
  : > "$RUN_LOG"
  printf '%s' "$expected" > "$tmp/expected"
  if TEST_JOBS=1 bash "$tools/test-all.sh" --changed HEAD > "$tmp/out" 2>&1 &&
     cmp -s "$tmp/expected" "$RUN_LOG"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    cat "$tmp/out" >&2
    failures=$((failures + 1))
  fi
}

setup unicode 'Tools/vendor/café'
printf '# test-all: slow helper.sh\necho slow >> "$RUN_LOG"\n' > "$tools/tests/slow.test.sh"
touch "$tools/helper.sh"
commit
check 'clean non-ASCII vendored checkout selects nothing' ''
printf 'tracked edit\n' > "$tools/helper.sh"
check 'tracked helper in non-ASCII directory selects quick and opted-in slow tests' $'quick\nslow\n'
git -C "$repo" restore -- .
touch "$tools/new.txt"
check 'untracked file in non-ASCII directory selects only quick tests' $'quick\n'

setup unusual 'Tools/vendor/kit'
# Own-test selection must compare the literal path, not Git's escaped display
# name or a line fragment. Leave quick unchanged to detect over-selection.
filename=$'odd name\t"quote"\\backslash\nnext.test.sh'
printf '# test-all: slow\necho odd >> "$RUN_LOG"\n' > "$tools/tests/$filename"
commit
printf '# tracked edit\n' >> "$tools/tests/$filename"
check 'tracked test with whitespace, quotes and backslash selects only itself' $'odd\n'
git -C "$repo" restore -- .
printf '# test-all: slow\necho new >> "$RUN_LOG"\n' > "$tools/tests/new $filename"
check 'untracked test with whitespace, quotes and backslash selects only itself' $'new\n'

setup backslash 'Tools/vendor/kit'
helper='helper\t.sh'
printf '# test-all: slow %s\necho slow >> "$RUN_LOG"\n' "$helper" > "$tools/tests/slow.test.sh"
commit
touch "$tools/$helper"
check 'slow dependency basename keeps a literal backslash' $'quick\nslow\n'

((failures == 0))

#!/usr/bin/env bash
# Cleanup must never infer that edits are disposable from their paths.
# Synthetic worktrees and a fake Git keep this test local and independent of Unity.
set -euo pipefail
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/logs" "$tmp/repo"
export QR_REPO="$tmp/repo" QR_RUN_DIR="$tmp/logs" QR_SHA=fixture-commit
export FIXTURE_STATUS="$tmp/status" FIXTURE_CALLS="$tmp/calls"
cat > "$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -C ] || exit 90
wt="$2"
shift 2
case "$1" in
  status)
    [ "$*" = 'status --porcelain -z --untracked-files=all' ] || exit 91
    [ "${FIXTURE_INSPECTION_FAIL:-0}" = 0 ] || exit 92
    cat "$FIXTURE_STATUS"
    ;;
  ls-files)
    [ "$*" = 'ls-files -v -z' ] || exit 99
    printf 'H untouched.txt\0'
    [ "${FIXTURE_INDEX_FAIL:-0}" = 0 ] || exit 128
    ;;
  symbolic-ref)
    [ "$*" = 'symbolic-ref --quiet HEAD' ] || exit 95
    exit 1
    ;;
  rev-parse)
    case "$*" in
      'rev-parse --verify HEAD^{commit}')
        [ "${FIXTURE_HEAD_FAIL:-0}" = 0 ] || exit 128
        printf '%s\n' "$QR_SHA" ;;
      'rev-parse --path-format=absolute --git-path index') printf '%s\n' "$wt/index-fixture" ;;
      *) exit 96 ;;
    esac
    ;;
  update-ref)
    [ "$*" = 'update-ref --stdin' ] || exit 97
    IFS= read -r line && [ "$line" = start ] || exit 98
    printf 'start: ok\n'
    for expected in 'option no-deref' "verify HEAD $QR_SHA" prepare; do
      IFS= read -r line && [ "$line" = "$expected" ] || exit 98
    done
    printf 'prepare: ok\n'
    # Keep the synthetic transaction open until the operation closes stdin.
    ! IFS= read -r line
    ;;
  worktree)
    [ "$2" = remove ] || exit 93
    printf '%s\n' "$*" >> "$FIXTURE_CALLS"
    # Model the destructive effect of the old forced removal.
    if [ "$3" = --force ]; then shift; fi
    rm -rf "${3:?}"
    ;;
  *) exit 94 ;;
esac
SH
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"
source "$tool_dir/quest-release/prepare.sh"
source "$tool_dir/quest-release/cleanup-noise.sh"
# The real Git flow fixture verifies the registration and transaction behavior.
qr_registered_worktree() { return 0; }
qr_log() { printf '%s\n' "$*" >&2; }
failures=0
check() {
  if ("$@"); then
    printf 'PASS: %s\n' "$*"
  else
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
  fi
}

preserves_dirty() {
  local status="$1" path="$2" kind="$3" wt="$tmp/worktree" result
  rm -rf "$wt" "$tmp/expected"
  mkdir -p "$wt/$(dirname "$path")"
  : > "$FIXTURE_CALLS"
  printf '%s %s\0' "$status" "$path" > "$FIXTURE_STATUS"
  printf 'synthetic tracked content\n' > "$wt/untouched.txt"
  # The file and synthetic index stand for independent worktree/index versions.
  # Deleted paths stay absent; cleanup must preserve both contents and deletions.
  if [ "$kind" != deleted ]; then
    printf 'intentional authored change\n' > "$wt/$path"
  fi
  printf 'synthetic index: %s %s\n' "$status" "$path" > "$wt/index-fixture"
  cp -R "$wt" "$tmp/expected"
  if result="$(qr_cleanup_one "$wt")"; then
    return 1
  fi
  [ ! -s "$FIXTURE_CALLS" ] || return 1
  [ -d "$wt" ] || return 1
  diff -r "$tmp/expected" "$wt" || return 1
  [[ "$result" = kept* ]]
}

# Every old noise category can contain real edits, in either index column.
for path in Assets/authored.asset Assets/authored.mat ProjectSettings/ProjectSettings.asset; do
  check preserves_dirty ' M' "$path" modified
  check preserves_dirty 'M ' "$path" staged
  check preserves_dirty 'MM' "$path" staged-and-unstaged
  check preserves_dirty 'A ' "$path" added
  check preserves_dirty '??' "$path" untracked
  check preserves_dirty ' D' "$path" deleted
  check preserves_dirty 'D ' "$path" deleted
done
check preserves_dirty ' M' $'Assets/authored\nmaterial.mat' modified

removes_clean() {
  local wt="$tmp/clean" result
  mkdir -p "$wt"
  : > "$FIXTURE_STATUS"
  : > "$FIXTURE_CALLS"
  result="$(qr_cleanup_one "$wt")" || return 1
  [ "$result" = removed ] && [ ! -e "$wt" ] &&
    grep -Fxq "worktree remove $wt" "$FIXTURE_CALLS"
}
check removes_clean

preserves_uninspectable() {
  local wt="$tmp/uninspectable" result
  mkdir -p "$wt"
  : > "$FIXTURE_CALLS"
  if result="$(FIXTURE_INSPECTION_FAIL=1 qr_cleanup_one "$wt")"; then
    return 1
  fi
  [ -d "$wt" ] && [ ! -s "$FIXTURE_CALLS" ] && [ "$result" = 'kept (inspection failed)' ]
}
check preserves_uninspectable

preserves_unreadable_index() {
  local wt="$tmp/unreadable-index" result
  mkdir -p "$wt"
  : > "$FIXTURE_STATUS"
  : > "$FIXTURE_CALLS"
  if result="$(FIXTURE_INDEX_FAIL=1 qr_cleanup_one "$wt")"; then
    return 1
  fi
  [ -d "$wt" ] && [ ! -s "$FIXTURE_CALLS" ] && [ "$result" = 'kept (inspection failed)' ] &&
    [ ! -e "$wt/index-fixture.lock" ]
}
check preserves_unreadable_index

preserves_symlinked_index() {
  local wt target result
  wt="$(mktemp -d "$tmp/symlinked-index.XXXXXX")" || return 1
  target="$wt.target"
  printf 'synthetic tracked content\n' > "$wt/untouched.txt"
  printf 'synthetic index\n' > "$target"
  ln -s "$target" "$wt/index-fixture" || return 1
  : > "$FIXTURE_STATUS"
  : > "$FIXTURE_CALLS"
  qr_discard_noise() { printf 'discard noise\n' >> "$FIXTURE_CALLS"; }
  if result="$(qr_cleanup_one "$wt" "$@")"; then
    return 1
  fi
  [ "$result" = 'kept (symlinked index)' ] && [ ! -s "$FIXTURE_CALLS" ] &&
    [ -L "$wt/index-fixture" ] && [ "$(readlink "$wt/index-fixture")" = "$target" ] &&
    [ ! -e "$wt/index-fixture.lock" ] && [ ! -e "$target.lock" ] &&
    grep -Fxq 'synthetic tracked content' "$wt/untouched.txt" && grep -Fxq 'synthetic index' "$target"
}
check preserves_symlinked_index
check preserves_symlinked_index --discard-noise

preserves_existing_index_lock() {
  local wt="$tmp/busy-index" result
  mkdir -p "$wt"
  printf 'pending index write\n' > "$wt/index-fixture.lock"
  : > "$FIXTURE_STATUS"
  : > "$FIXTURE_CALLS"
  if result="$(qr_cleanup_one "$wt")"; then
    return 1
  fi
  [ ! -s "$FIXTURE_CALLS" ] && [ "$result" = 'kept (index lock unavailable)' ] &&
    grep -Fxq 'pending index write' "$wt/index-fixture.lock"
}
check preserves_existing_index_lock

preserves_unreadable_head() {
  local wt="$tmp/unreadable-head" result
  mkdir -p "$wt"
  : > "$FIXTURE_STATUS"
  : > "$FIXTURE_CALLS"
  if result="$(FIXTURE_HEAD_FAIL=1 qr_cleanup_one "$wt")"; then
    return 1
  fi
  [ -d "$wt" ] && [ ! -s "$FIXTURE_CALLS" ] && [ "$result" = 'kept or removal failed' ]
}
check preserves_unreadable_head
[ "$failures" = 0 ]

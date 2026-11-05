#!/usr/bin/env bash
# Cleanup must never infer that edits are disposable from their paths.
# Synthetic worktrees and a fake Git keep this test local and independent of Unity.
set -euo pipefail
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/logs" "$tmp/repo"
export QR_REPO="$tmp/repo" QR_RUN_DIR="$tmp/logs"
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
[ "$failures" = 0 ]

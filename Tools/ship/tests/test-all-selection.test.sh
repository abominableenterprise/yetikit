#!/usr/bin/env bash
# Selection-only runner regressions: fake tests and Git, no Unity or index writes.
set -euo pipefail
ci_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Tools/ship/tests" "$tmp/bin"
cp "$ci_dir/test-all.sh" "$tmp/Tools/ship/test-all.sh"
export RUN_LOG="$tmp/runs" CHANGED_PATHS="$tmp/changed" UNTRACKED_PATHS="$tmp/untracked"
export FAKE_REPO="$tmp"
runner="$tmp/Tools/ship/test-all.sh"
: > "$UNTRACKED_PATHS"
cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -C ] || exit 2
shift 2
case "$1" in
  rev-parse)
    [ "$2" = --show-toplevel ] || exit 2
    [ -z "${FAKE_REV_PARSE_FAIL:-}" ] || exit 1
    printf '%s\n' "$FAKE_REPO" ;;
  merge-base) echo fixture-base ;;
  diff|ls-files)
    command=$1
    while [ "$1" != -- ]; do shift; done
    shift
    [ "$1" = "${EXPECTED_PREFIX:-Tools/ship}/" ] || exit 2
    [ "$2" = .github/workflows/ship.yml ] || exit 2
    if [ "$command" = diff ]; then cat "$CHANGED_PATHS"; else cat "$UNTRACKED_PATHS"; fi ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
check() {
  local expected=$1
  shift
  : > "$RUN_LOG"
  TEST_JOBS=1 bash "$runner" "$@" > "$tmp/out" 2>&1 || {
    cat "$tmp/out"; fail "runner failed: $*"
  }
  printf '%s' "$expected" > "$tmp/expected"
  cmp -s "$tmp/expected" "$RUN_LOG" || {
    cat "$tmp/out"; fail "unexpected selection: $*"
  }
}
# Copy only the real tags; the fixture bodies merely record their selection.
for name in linux-unity-apk linux-unity-test-pr linux-unity-timeout; do
  grep '^# test-all: slow' "$ci_dir/tests/$name.test.sh" > "$tmp/Tools/ship/tests/$name.test.sh"
  printf '# incidental references: test-all.sh helper.sh\necho %s >> "$RUN_LOG"\n' "$name" >> "$tmp/Tools/ship/tests/$name.test.sh"
done
printf 'echo quick >> "$RUN_LOG"\n' > "$tmp/Tools/ship/tests/quick.test.sh"
printf '# test-all: slow\n# helper.sh\necho legacy >> "$RUN_LOG"\n' > "$tmp/Tools/ship/tests/legacy.test.sh"

printf 'Tools/ship/test-all.sh\nTools/ship/helper.sh\n' > "$CHANGED_PATHS"
check $'quick\n' --changed
check $'quick\n'
echo 'ok   default and explicit changed selection ignore incidental slow references'

printf 'Tools/ship/linux-unity.sh\n' > "$CHANGED_PATHS"
slow=$'linux-unity-apk\nlinux-unity-test-pr\nlinux-unity-timeout\n'
check "$slow"$'quick\n' --changed
check $'linux-unity-apk\n' --changed HEAD apk
check $'quick\n' --changed HEAD --fast
echo 'ok   changed tested script selects its slow fixtures; filters and --fast intersect'

printf 'Tools/ship/lib/android.sh\n' > "$CHANGED_PATHS"
check $'linux-unity-apk\nquick\n' --changed
check $'quick\n' --changed HEAD --fast
echo 'ok   APK tag names the extracted Android helper by basename'

# Quick tests retain broad tooling/workflow coverage, even without references.
for path in Tools/ship/not-linux-unity.sh Tools/ship/lib/not-android.sh \
            Tools/ship/lib/config.json .github/workflows/ship.yml; do
  printf '%s\n' "$path" > "$CHANGED_PATHS"
  check $'quick\n' --changed
done
echo 'ok   unrelated scripts, resources and workflow changes select only quick tests'

for name in linux-unity-apk linux-unity-test-pr linux-unity-timeout legacy; do
  printf 'Tools/ship/tests/%s.test.sh\n' "$name" > "$CHANGED_PATHS"
  check "$name"$'\n' --changed
  check '' --changed HEAD --fast
done
: > "$CHANGED_PATHS"
printf 'Tools/ship/tests/linux-unity-apk.test.sh\n' > "$UNTRACKED_PATHS"
check $'linux-unity-apk\n' --changed
printf 'Tools/ship/lib/android.sh\n' > "$UNTRACKED_PATHS"
check $'linux-unity-apk\nquick\n' --changed
: > "$UNTRACKED_PATHS"
check '' --changed
check ''
echo 'ok   own changes and untracked paths select fixtures; no changes select none'

check $'legacy\n'"$slow"$'quick\n' --all
check "$slow" --all linux-unity
check $'quick\n' --all --fast
check '' --all --fast linux-unity
echo 'ok   --all and filtered runs retain slow tests; --fast skips all slow tags'

# A consumer can vendor the same bytes at a different depth and directory name.
for prefix in Tools/yetikit Tools/vendor/yetikit; do
  export EXPECTED_PREFIX="$prefix"
  mkdir -p "$tmp/$prefix"
  cp -R "$tmp/Tools/ship/"* "$tmp/$prefix/"
  runner="$tmp/$prefix/test-all.sh"
  printf '%s/helper.sh\n' "$prefix" > "$CHANGED_PATHS"
  check $'quick\n' --changed
  printf '%s/tests/legacy.test.sh\n' "$prefix" > "$CHANGED_PATHS"
  check $'legacy\n' --changed
  : > "$CHANGED_PATHS"
  printf '%s/helper.sh\n' "$prefix" > "$UNTRACKED_PATHS"
  check $'quick\n' --changed
  : > "$UNTRACKED_PATHS"
  check '' --changed
  printf '.github/workflows/ship.yml\n' > "$CHANGED_PATHS"
  check $'quick\n' --changed
done
unset EXPECTED_PREFIX
echo 'ok   vendored runner selects tool and own-test changes at any depth'

ln -s "$tmp" "$tmp-linked"
# Keep the sibling link out of the temp tree to avoid recursive copies.
trap 'rm -f "$tmp-linked"; rm -rf "$tmp"' EXIT
runner="$tmp-linked/Tools/ship/test-all.sh"
printf 'Tools/ship/helper.sh\n' > "$CHANGED_PATHS"
check $'quick\n' --changed
: > "$CHANGED_PATHS"
check '' --changed
echo 'ok   symlinked checkout paths map to the physical repository root'

runner="$tmp/Tools/ship/test-all.sh"
printf 'Tools/ship/helper.sh\n' > "$CHANGED_PATHS"
export FAKE_REV_PARSE_FAIL=1
check $'quick\n' --changed
unset FAKE_REV_PARSE_FAIL
export FAKE_REPO="$tmp/outside"
if bash "$runner" --changed > "$tmp/out" 2>&1; then
  fail 'unmappable tool prefix must fail instead of selecting nothing'
fi
grep -q 'ERROR: cannot determine tool directory relative to repository' "$tmp/out" || {
  cat "$tmp/out"; fail 'missing prefix diagnostic'
}
check $'quick\n' --all --fast
echo 'ok   root lookup falls back; unmappable prefix fails only for changed selection'

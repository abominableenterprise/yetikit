#!/usr/bin/env bash
# Selection-only runner regressions: fake tests and Git, no Unity or index writes.
set -euo pipefail
ci_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Tools/ship/tests" "$tmp/bin"
cp "$ci_dir/test-all.sh" "$tmp/Tools/ship/test-all.sh"
export RUN_LOG="$tmp/runs" CHANGED_PATHS="$tmp/changed" UNTRACKED_PATHS="$tmp/untracked"
: > "$UNTRACKED_PATHS"
cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -C ] || exit 2
shift 2
case "$1" in
  merge-base) echo fixture-base ;;
  diff) cat "$CHANGED_PATHS" ;;
  ls-files) cat "$UNTRACKED_PATHS" ;;
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
  TEST_JOBS=1 bash "$tmp/Tools/ship/test-all.sh" "$@" > "$tmp/out" 2>&1 || {
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

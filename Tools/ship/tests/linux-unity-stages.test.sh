#!/usr/bin/env bash
# Tests linux-unity.sh test / test pr timing using only a fake editor.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"; mkdir -p "$proj"
. "$(dirname "$0")/lib/fake-unity.sh"
printf base > "$proj/README"
git_init
# Emit representative editor milestones; no Unity binary is used.
cat > "$UNITY_ROOT/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -logFile) logf="$2"; shift ;; -testResults) res="$2"; shift ;; esac
  shift
done
printf 'Importing assets\nScriptCompilation: starting\nCompleted reload\nRunning tests\n' > "$logf"
printf '<test-run total="1" passed="1" failed="0" skipped="0" />\n' > "$res"
EOF
chmod +x "$UNITY_ROOT/Editor/Unity"
# Expected order is actual shell execution order. Import and compile are nested
# within each pass; cache is explicitly a no-op in test (unlike open).
cat > "$tmp/expected" <<'EOF'
credentials-seat start
credentials-seat end
cache-restore start
cache-restore end
activate-reuse start
activate-reuse end
pure-pass start
editor-launch-import start
editor-launch-import end
compile start
compile end
pure-pass end
results start
results end
activate-reuse start
activate-reuse end
gfx-pass start
editor-launch-import start
editor-launch-import end
compile start
compile end
gfx-pass end
results start
results end
noise-revert start
noise-revert end
EOF
bash "$script" test editmode 2> "$tmp/err"
grep '^\[linux-unity\] stage ' "$tmp/err" > "$tmp/stages"
sed -E 's/^\[linux-unity\] stage //; s/ \+[0-9]+s$//' "$tmp/stages" > "$tmp/order"
check 'stubbed test prints ordered start/end stages' 'diff -u "$tmp/expected" "$tmp/order"'
check 'every stage has an elapsed whole-second timestamp' \
  '! grep -vE "^\[linux-unity\] stage [a-z-]+ (start|end) \+[0-9]+s$" "$tmp/stages"'
check 'the stage file exactly matches the printed stage lines' 'cmp "$tmp/stages" "$OUT_DIR/test-stages.log"'
# No changed fixtures: pure still runs and Gfx does not. The file resets per command.
bash "$script" test pr 2> "$tmp/err"
check 'test pr writes a fresh stage log and still runs pure when Gfx is empty' \
  '[ "$(grep -c "stage credentials-seat start" "$OUT_DIR/test-stages.log")" = 1 ] && grep -q "stage pure-pass end" "$OUT_DIR/test-stages.log" && ! grep -q "stage gfx-pass" "$OUT_DIR/test-stages.log"'
# Warm logs without compiler markers and failed editor exits must still close scopes.
printf '#!/bin/sh\nexit 7\n' > "$UNITY_ROOT/Editor/Unity"
rc=0; EDITMODE_GFX=0 bash "$script" test editmode 2> "$tmp/err" || rc=$?
check 'failed editor retains exit status and closes fallback timing scopes' \
  '[ "$rc" = 7 ] && grep -q "stage compile end" "$tmp/err" && grep -q "stage pure-pass end" "$tmp/err" && grep -q "stage noise-revert end" "$tmp/err"'
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }

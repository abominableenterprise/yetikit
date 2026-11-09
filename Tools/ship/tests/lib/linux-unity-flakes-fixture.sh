# Shared isolated setup for the topical flakes regressions.
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"; mkdir -p "$proj"
. "$(dirname "$0")/lib/fake-unity.sh"

flakes="$tmp/flakes.txt"
cat > "$flakes" <<'EOF'
# a comment line
X.Tests.Court.TheBallersKeepPlaying   # a trailing comment
  X.Tests.Throw.AFlick
X.Tests.Seam
EOF
export KNOWN_FLAKES="$flakes"
ballers=X.Tests.Court.TheBallersKeepPlaying
flick1='X.Tests.Throw.AFlick(False,25f)'; flick2='X.Tests.Throw.AFlick(True,25f)'
run() { : > "$tmp/runs"; rc=0; bash "$script" test "$@" 2>"$tmp/err" || rc=$?; }
retry_filter() { grep -- -retry.xml "$tmp/runs" | sed -n 's/.*-testFilter \([^ ]*\).*/\1/p'; }


#!/usr/bin/env bash
# Shared isolated fake-editor setup for timeout tests; no real Unity or hub.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "${BASH_SOURCE[0]}")/fake-unity.sh"

t="$proj/Assets/Tests/EditMode/Props"
mkdir -p "$t"
printf 'namespace X.Tests\n{\n    [Category("Gfx")]\n    public class SprayTests { }\n}\n' > "$t/SprayTests.cs"
git_init
git -C "$proj" checkout -q -b feature
echo '// touched' >> "$t/SprayTests.cs"; commit touch

# A logging timeout in front of the real one: "<seconds> <-testResults file>" per editor run, in $tmp/limits.
real_timeout="$(command -v timeout)"
cat > "$tmp/bin/timeout" <<EOF
#!/usr/bin/env bash
res=""; prev=""; for a in "\$@"; do [ "\$prev" = -testResults ] && res="\${a##*/}"; prev="\$a"; done
echo "\$3 \$res" >> "$tmp/limits"
exec "$real_timeout" "\$@"
EOF
chmod +x "$tmp/bin/timeout"

run() { : > "$tmp/limits"; : > "$tmp/runs"; rc=0; env "$@" 2>"$tmp/err" || rc=$?; }
limit() { sed -n "s/ $1\$//p" "$tmp/limits"; }

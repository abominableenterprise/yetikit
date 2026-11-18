#!/usr/bin/env bash
# Each case gets its own tagged checkout and consumer so baseline failures don't mask one another.
set -euo pipefail
vendor=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if (($# == 0)); then
  status=0
  for fixture in traversal listing collision attributes deps-false deps-null deps-value deps-stream \
      manifest-stage manifest-move first-install ship-move overlap sha256 receipt; do
    bash "$0" "$fixture" || status=1
  done
  exit "$status"
fi
fixture=$1
fail() { echo "FAIL: $fixture: $*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo=$tmp/source project=$tmp/project
prefix=com.abominable.yetikit.
export FIXTURE_ROOT=$tmp
mkdir -p "$repo/Tools/ship" "$repo/Packages/${prefix}core" "$project/Packages" "$tmp/bin"
format=sha1; [[ $fixture != sha256 ]] || format=sha256
git init -q --object-format="$format" --initial-branch=main "$repo"
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config commit.gpgsign false
git -C "$repo" config tag.gpgsign false
printf '{"dependencies":{}}\n' > "$project/Packages/manifest.json"
package=$repo/Packages/${prefix}core/package.json
case $fixture in
  deps-false) dependencies=false ;;
  deps-null) dependencies=null ;;
  deps-value) dependencies='{"org.example.utility":2}' ;;
  *) dependencies='{}' ;;
esac
printf '{"name":"%score","dependencies":%s}\n' "$prefix" "$dependencies" > "$package"
if [[ $fixture == deps-stream ]]; then cp "$package" "$tmp/package"; cat "$tmp/package" >> "$package"; fi
printf '#!/bin/sh\necho v1\n' > "$repo/Tools/ship/tool.sh"
chmod +x "$repo/Tools/ship/tool.sh"
if [[ $fixture == attributes ]]; then
  printf 'Tools/ship/tool.sh export-subst\nTools/ship/data.txt text eol=crlf\n' > "$repo/.gitattributes"
  printf '# %%s\n' '$Format:%H$' >> "$repo/Tools/ship/tool.sh"
  printf 'tagged LF\n' > "$repo/Tools/ship/data.txt"
fi
git -C "$repo" add .
git -C "$repo" commit -qm v1
git -C "$repo" tag -a v1 -m v1
printf '#!/bin/sh\necho v2\n' > "$repo/Tools/ship/tool.sh"
git -C "$repo" commit -qam v2
git -C "$repo" tag v2
bump() { bash "$vendor/kit-bump.sh" "$@" --project "$project" --source "$repo"; }
check() { bash "$vendor/kit-check.sh" --project "$project"; }
reject() { if "$@" > "$tmp/rejected" 2>&1; then fail "unexpected success: $*"; fi; }
snapshot() { tar --sort=name --mtime=@0 -cf - -C "$project" . | sha256sum; }
case $fixture in
  traversal|listing)
    bump v1
    # A scanner may emit nothing (validation) or all visible files (hashing), then fail.
    export REAL_FIND=$(command -v find) FIND_FIXTURE=$fixture
    cat > "$tmp/bin/find" <<'SH'
#!/usr/bin/env bash
if [[ $FIND_FIXTURE == traversal && $1 == */Tools/yetikit && ${2:-} == '!' ]] ||
   [[ $FIND_FIXTURE == listing && $1 == . && ${2:-} == -type ]]; then
  "$REAL_FIND" "$@"
  echo 'synthetic traversal failure' >&2
  exit 1
fi
exec "$REAL_FIND" "$@"
SH
    chmod +x "$tmp/bin/find"
    PATH="$tmp/bin:$PATH" reject check
    grep -q 'cannot inspect Ship' "$tmp/rejected" || fail 'missing traversal diagnostic'
    ;;
  collision)
    git -C "$repo" branch v1 HEAD
    # Rewrite the production URL to a local remote; forbid all network protocols.
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$repo.insteadOf"
    export GIT_CONFIG_VALUE_0=https://github.com/abominableenterprise/yetikit.git GIT_ALLOW_PROTOCOL=file
    bash "$vendor/kit-bump.sh" v1 --project "$project" --modules core || fail 'explicit tag acquisition failed'
    grep -qx "commit=$(git -C "$repo" rev-parse 'refs/tags/v1^{commit}')" "$project/Tools/yetikit/VERSION" || fail 'wrong commit'
    check
    ;;
  attributes)
    printf 'Tools/ship/data.txt export-ignore\n' > "$repo/.git/info/attributes"
    git -C "$repo" config core.autocrlf true
    bump v1 --modules core
    for name in tool.sh data.txt; do
      git -C "$repo" cat-file blob "refs/tags/v1:Tools/ship/$name" > "$tmp/expected"
      cmp "$tmp/expected" "$project/Tools/yetikit/$name" || fail "attribute changed $name"
    done
    check
    ;;
  deps-*)
    before=$(snapshot)
    reject bump v1 --modules core
    grep -q 'invalid package.json' "$tmp/rejected" || fail 'missing metadata diagnostic'
    [[ $(snapshot) == "$before" ]] || fail 'rejected metadata modified consumer'
    ;;
  manifest-stage|manifest-move|first-install|ship-move)
    if [[ $fixture != first-install ]]; then bump v1 --modules core; fi
    chmod 640 "$project/Packages/manifest.json"
    before=$(snapshot)
    export MOVE_FIXTURE=$fixture REAL_MV=$(command -v mv) REAL_JQ=$(command -v jq)
    cat > "$tmp/bin/mv" <<'SH'
#!/usr/bin/env bash
case "$MOVE_FIXTURE:${!#}" in
  manifest-move:*/Packages/manifest.json|first-install:*/Packages/manifest.json|ship-move:*/Tools/yetikit)
    # Fail only once so the same destination is available for rollback.
    if [[ ! -e $FIXTURE_ROOT/injected ]]; then
      touch "$FIXTURE_ROOT/injected"
      echo 'synthetic rename failure' >&2
      exit 1
    fi
    ;;
esac
exec "$REAL_MV" "$@"
SH
    cat > "$tmp/bin/jq" <<'SH'
#!/usr/bin/env bash
if [[ $MOVE_FIXTURE == manifest-stage && $* == *'reduce ($graph'* ]]; then
  printf '{partial'
  touch "$FIXTURE_ROOT/injected"
  echo 'synthetic manifest write failure' >&2
  exit 1
fi
exec "$REAL_JQ" "$@"
SH
    chmod +x "$tmp/bin/"{mv,jq}
    PATH="$tmp/bin:$PATH" reject bump v2
    [[ -e $tmp/injected ]] || fail 'fault was not exercised'
    [[ $(snapshot) == "$before" ]] || fail 'failed bump modified consumer'
    if [[ $fixture != first-install ]]; then check; fi
    bump v2 --modules core
    [[ $(stat -c %a "$project/Packages/manifest.json") == 640 ]] || fail 'manifest mode changed'
    check
    ;;
  overlap)
    bump v1 --modules core
    export REAL_JQ=$(command -v jq)
    mkfifo "$tmp/ready" "$tmp/resume"
    exec 8<> "$tmp/ready" 9<> "$tmp/resume"
    cat > "$tmp/bin/jq" <<'SH'
#!/usr/bin/env bash
if [[ $1 == -se && ${!#} == */Packages/manifest.json ]]; then
  echo ready >&8
  read -r -t 10 _ <&9 || exit 1
fi
exec "$REAL_JQ" "$@"
SH
    chmod +x "$tmp/bin/jq"
    PATH="$tmp/bin:$PATH" bump v2 > "$tmp/first.log" 2>&1 &
    first=$!
    read -r -t 10 _ <&8 || { wait "$first" || true; fail 'first bump did not reach manifest read'; }
    second_status=0
    timeout 5 bash "$vendor/kit-bump.sh" v1 --project "$project" --source "$repo" > "$tmp/second.log" 2>&1 || second_status=$?
    echo resume >&9
    wait "$first" || { cat "$tmp/first.log" >&2; fail 'first bump failed'; }
    [[ $second_status == 1 ]] && grep -q 'another kit-bump' "$tmp/second.log" || fail 'overlap was not rejected by the lock'
    grep -qx tag=v2 "$project/Tools/yetikit/VERSION" || fail 'first bump did not install v2'
    check
    ;;
  sha256)
    bump v1 --modules core
    grep -Exq 'commit=[0-9a-f]{64}' "$project/Tools/yetikit/VERSION" || fail 'missing SHA-256 commit'
    check || fail 'checker rejected SHA-256 commit'
    ;;
  receipt)
    bump v1
    awk 'NR == 4 { $0 = "dependencies={} {}" } 1' "$project/Tools/yetikit/VERSION" > "$tmp/receipt"
    cp "$tmp/receipt" "$project/Tools/yetikit/VERSION"
    reject check
    ;;
  *) fail 'unknown fixture' ;;
esac
printf 'PASS: %s\n' "$fixture"

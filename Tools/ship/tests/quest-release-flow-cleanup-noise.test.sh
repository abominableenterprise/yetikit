#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check evaluates conditions with fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

# This suite exercises the real config reads made by the noise classifier.
eval "$(declare -f qr_config_get | awk 'NR == 1 { sub(/^qr_config_get/, "cached_qr_config_get") } { print }')"
qr_config_get() {
  case "$1" in .noise.*) jq -r "$1" <<< "$QR_CONFIG_JSON" ;; *) cached_qr_config_get "$1" ;; esac
}

mat=Assets/Mats/A.mat
prefab='Assets/Mats/Test [1].prefab'
prefab_contents() {
  printf '%s\n' '--- !u!4 &1' 'Transform:' "  m_LocalPosition: {x: $1, y: -0, z: 1}" \
    '--- !u!114 &2' 'MonoBehaviour:' "  m_text: Version $2" "  m_custom: $3" \
    "  m_LocalPosition: {x: $4, y: 0, z: 1}" \
    '--- !u!224 &3' 'RectTransform:' "  m_LocalRotation: {x: 0, y: 0, z: -0, w: ${5:-1.0}}"
}
prefab_contents 0.100000001 1.10 1.10 1.10 > "$repo/$prefab"
printf '  m_Floats:\n  - _ZTest: 4\n' > "$repo/$mat"
git -C "$repo" add -- ":(literal)$mat" ":(literal)$prefab" && git -C "$repo" commit -qm 'Material fixture' || exit 1
git -C "$repo" update-ref refs/remotes/origin/main HEAD || exit 1
sha="$(git -C "$repo" rev-parse HEAD)"; short="${sha:0:9}"
qr_flow_prepare
test_wt="$root/rel-$short-test"; build_wt="$root/rel-$short-build"
material_noise() { printf '  m_Floats:\n  - _ZTest: 8\n' > "$1/$mat"; }
material_noise "$test_wt"; material_noise "$build_wt"
prefab_contents 0.1 1.10 1.10 1.10 1 > "$test_wt/$prefab"
run cleanup --discard-nois
check 'cleanup rejects a misspelled flag without touching either worktree' \
  '[ "$rc" = 2 ] && out_has "unknown option" && [ -d "$test_wt" ] && [ -d "$build_wt" ]'
run cleanup
check 'plain cleanup keeps even worktrees containing only editor noise' \
  '[ "$rc" != 0 ] && out_has "local changes" && [ -d "$test_wt" ] && [ -d "$build_wt" ]'

printf 'authored\n' >> "$build_wt/Assets/Scripts/C.cs"
run cleanup --discard-noise
check 'opt-in removes and unregisters the noise-only worktree' \
  '[ ! -e "$test_wt" ] && out_has "test removed" && ! git -C "$repo" worktree list --porcelain | grep -Fxq "worktree $test_wt"'
check 'opt-in preserves a mixed worktree intact and says why' \
  '[ "$rc" != 0 ] && out_has "real changes" && grep -q authored "$build_wt/Assets/Scripts/C.cs" && grep -q "_ZTest: 8" "$build_wt/$mat"'

git -C "$build_wt" restore -- Assets/Scripts/C.cs
keep_prefab_edit() {
  local description="$1"; shift
  prefab_contents "$@" > "$tmp/expected-prefab"
  cp "$tmp/expected-prefab" "$build_wt/$prefab"
  run cleanup --discard-noise
  check "$description" \
    '[ "$rc" != 0 ] && out_has "real changes" && cmp -s "$tmp/expected-prefab" "$build_wt/$prefab" && grep -q "_ZTest: 8" "$build_wt/$mat"'
  # Recreate the worktree if the regression removed it so each case is independent.
  if [ ! -d "$build_wt" ]; then
    git -C "$repo" worktree add -q --detach "$build_wt" "$sha" || exit 1
    material_noise "$build_wt"
  fi
}
keep_prefab_edit 'opt-in keeps a number-like change in prefab text' 0.1 1.1 1.10 1.10
keep_prefab_edit 'opt-in keeps an unrecognized prefab scalar edit' 0.1 1.10 1.1 1.10
keep_prefab_edit 'opt-in keeps a transform-like field edit in a script component' 0.1 1.10 1.10 1.1
keep_prefab_edit 'opt-in keeps a real transform edit below five significant digits' 0.100001 1.10 1.10 1.10
git -C "$build_wt" restore -- ":(literal)$prefab"

# A staged real edit can be hidden by a worktree edit relative to HEAD.
printf 'authored\n' > "$build_wt/$mat"
git -C "$build_wt" add -- "$mat"
material_noise "$build_wt"
run cleanup --discard-noise
check 'opt-in keeps staged work even when the file on disk looks like noise' \
  '[ "$rc" != 0 ] && out_has "staged" && [ "$(git -C "$build_wt" show ":$mat")" = authored ] && grep -q "_ZTest: 8" "$build_wt/$mat"'
git -C "$build_wt" restore --staged -- "$mat"

printf 'untracked\n' > "$build_wt/Assets/Mats/new.mat"
run cleanup --discard-noise
check 'opt-in preserves untracked content next to noise' \
  '[ "$rc" != 0 ] && out_has "untracked" && [ -f "$build_wt/Assets/Mats/new.mat" ] && grep -q "_ZTest: 8" "$build_wt/$mat"'
rm "$build_wt/Assets/Mats/new.mat"
printf '  m_Custom: 1\n' >> "$build_wt/$mat"
run cleanup --discard-noise
check 'opt-in keeps a material with both a noise line and a real property edit' \
  '[ "$rc" != 0 ] && out_has "real changes" && grep -q "m_Custom: 1" "$build_wt/$mat"'
material_noise "$build_wt"
chmod +x "$build_wt/$mat"
run cleanup --discard-noise
check 'opt-in preserves an executable-bit change next to noise in the same file' \
  '[ "$rc" != 0 ] && [ -x "$build_wt/$mat" ] && grep -q "_ZTest: 8" "$build_wt/$mat"'

chmod -x "$build_wt/$mat"
git -C "$build_wt" update-index --assume-unchanged Assets/Scripts/C.cs
printf 'hidden authored edit\n' >> "$build_wt/Assets/Scripts/C.cs"
run cleanup --discard-noise
check 'opt-in keeps work hidden by an index flag' \
  '[ "$rc" != 0 ] && out_has "hidden index entry" && grep -q "hidden authored edit" "$build_wt/Assets/Scripts/C.cs" && grep -q "_ZTest: 8" "$build_wt/$mat"'

git -C "$build_wt" update-index --no-assume-unchanged Assets/Scripts/C.cs
git -C "$build_wt" restore -- Assets/Scripts/C.cs
run cleanup --discard-noise
check 'opt-in succeeds when the only remaining worktree contains only noise' \
  '[ "$rc" = 0 ] && [ ! -e "$build_wt" ] && out_has "test absent; build removed"'

qr_flow_finish

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
printf '  scale: 1.000000\n' > "$repo/$prefab"
printf '  m_Floats:\n  - _ZTest: 4\n' > "$repo/$mat"
git -C "$repo" add -- ":(literal)$mat" ":(literal)$prefab" && git -C "$repo" commit -qm 'Material fixture' || exit 1
git -C "$repo" update-ref refs/remotes/origin/main HEAD || exit 1
sha="$(git -C "$repo" rev-parse HEAD)"; short="${sha:0:9}"
qr_flow_prepare
test_wt="$root/rel-$short-test"; build_wt="$root/rel-$short-build"
material_noise() { printf '  m_Floats:\n  - _ZTest: 8\n' > "$1/$mat"; }
material_noise "$test_wt"; material_noise "$build_wt"
printf '  scale: 1.0\n' > "$test_wt/$prefab"
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

# A staged real edit can be hidden by a worktree edit relative to HEAD.
git -C "$build_wt" restore -- Assets/Scripts/C.cs
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

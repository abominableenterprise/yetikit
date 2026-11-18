#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check evaluates conditions with fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

mat=Assets/Mats/A.mat
printf '  m_Floats:\n  - _ZTest: 4\n' > "$repo/$mat"
printf '/Assets/Scripts/Ignored.cs\n' >> "$repo/.gitignore"
git -C "$repo" add -A && git -C "$repo" commit -qm 'Integrity fixture' || exit 1
git -C "$repo" update-ref refs/remotes/origin/main HEAD || exit 1
sha="$(git -C "$repo" rev-parse HEAD)"; short="${sha:0:9}"
qr_flow_prepare
qr_flow_keystore

# Reuse one prepared run so a refused rerun has an earlier pass to replace.
run gate
run_dir="$(qr_wait_run_dir)"
check 'clean gate records passing results in the prepared run' \
  '[ "$rc" = 0 ] && [ -s "$tmp/unity.log" ] && [ -s "$run_dir/gate.xml" ] && [ "$(cat "$run_dir/summary/gate_result")" = passed ] && grep -q "^gate: .*3 passed" "$tmp/out" && grep -qx "gate fails:  none" "$tmp/out"'
QUEST_WAIT_GRACE=0 run wait 0
check 'wait accepts the clean gate' '[ "$rc" = 0 ]'

reset_logs
printf 'authored\n' >> "$root/rel-$short-test/Assets/Scripts/C.cs"
run gate
check 'dirty gate rerun still fails without starting the editor or retaining passing XML' \
  '[ "$rc" = 1 ] && out_has "has local changes" && [ ! -e "$tmp/unity.log" ] && [ ! -e "$run_dir/gate.xml" ] && [ "$(cat "$run_dir/summary/gate_result")" = failed ]'
check 'dirty gate rerun replaces both visible summary fields with the integrity refusal' \
  'grep -qx "gate:        FAILED: prepared worktree integrity check (see release.log)" "$tmp/out" && grep -qx "gate fails:  prepared worktree refused; Unity was not started" "$tmp/out" && cmp -s "$tmp/out" "$run_dir/summary.txt"'
QUEST_WAIT_GRACE=0 run wait 0
check 'wait rejects the dirty gate' '[ "$rc" = 1 ] && out_has "the run (gate, .* exited 1"'
git -C "$root/rel-$short-test" restore -- Assets/Scripts/C.cs || exit 1

refuse() {
  reset_logs
  run "$step"
  check "$step refuses $1 without starting the editor" '[ "$rc" != 0 ] && [ ! -e "$tmp/unity.log" ]'
}

for step in gate build; do
  case "$step" in gate) wt="$root/rel-$short-test" ;; build) wt="$root/rel-$short-build" ;; esac
  script_path=Assets/Scripts/C.cs
  git -C "$wt" checkout -q --detach HEAD^ || exit 1
  refuse 'a different HEAD'
  git -C "$wt" checkout -q --detach "$sha" || exit 1
  git -C "$wt" switch -qc "attached-$step" || exit 1
  refuse 'an attached HEAD even at the prepared commit'
  git -C "$wt" checkout -q --detach "$sha" || exit 1

  printf 'authored\n' >> "$wt/$script_path"
  refuse 'an unstaged tracked edit'
  git -C "$wt" add -- "$script_path" || exit 1
  refuse 'a staged edit'
  git -C "$wt" restore --source=HEAD --staged --worktree -- "$script_path" || exit 1
  printf 'untracked\n' > "$wt/Assets/Scripts/New.cs"
  refuse 'an untracked script'
  rm "$wt/Assets/Scripts/New.cs"
  printf 'ignored but not generated\n' > "$wt/Assets/Scripts/Ignored.cs"
  refuse 'an ignored script outside generated paths'
  rm "$wt/Assets/Scripts/Ignored.cs"

  git -C "$wt" update-index --assume-unchanged "$script_path" || exit 1
  printf 'hidden edit\n' >> "$wt/$script_path"
  refuse 'an edit hidden by an index flag'
  git -C "$wt" update-index --no-assume-unchanged "$script_path" || exit 1
  git -C "$wt" restore -- "$script_path" || exit 1

  printf '  m_Floats:\n  - _ZTest: 8\n  m_Custom: 1\n' > "$wt/$mat"
  refuse 'a material change mixed with generated noise'
  printf '  m_Floats:\n  - _ZTest: 8\n' > "$wt/$mat"
  chmod +x "$wt/$mat"
  refuse 'a mode change mixed with generated noise'
  chmod -x "$wt/$mat"
  reset_logs; run "$step"
  check "$step allows proven material noise and ignored Library state without editing either" \
    '[ "$rc" = 0 ] && [ -s "$tmp/unity.log" ] && grep -q "_ZTest: 8" "$wt/$mat" && [ -f "$wt/Library/Bee/cache" ]'
done

qr_flow_finish

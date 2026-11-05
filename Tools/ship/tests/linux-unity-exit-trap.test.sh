#!/usr/bin/env bash
# Exercise real cleanup functions under errexit with stubbed swapoff/rm and licence return; never runs Unity.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$tmp/project"
fixture_repo="$PROJECT"
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

for original in 0 42 143; do
  for failure in swapoff rm both; do
    run="$tmp/$original-$failure"; mkdir -p "$run"
    cp "$fixture_repo/yetikit.json" "$run/yetikit.json"
    rc=0
    PROJECT="$run" OUT_DIR="$run/out" bash -c '
      set -euo pipefail
      . "$1/Tools/ship/linux-unity.sh"
      run="$2"; original="$3"; failure="$4"
      log() { printf "%s\n" "$*" >&2; }
      as_root() {
        echo "$1" >> "$run/calls"
        case "$1:$failure" in
          swapoff:swapoff|swapoff:both) return 7 ;;
          rm:rm|rm:both) return 9 ;;
        esac
      }
      cmd_return() { echo return_on_exit >> "$run/calls"; }
      # An earlier failing handler must not prevent the final pidfile cleanup either.
      failing_cleanup() { echo failing_cleanup >> "$run/calls"; return 23; }
      PIDFILE="$run/pid"; PID_LINE="$$ test"; printf "%s\n" "$PID_LINE" > "$PIDFILE"
      APK_SWAPFILE="$run/swapfile"
      chain_exit_trap release_pidfile
      chain_exit_trap failing_cleanup
      UNITY_RETURN_ON_EXIT=1; arm_return_on_exit
      chain_exit_trap apk_swap_off
      exit "$original"
    ' _ "$fixture_repo" "$run" "$original" "$failure" >"$run/out.log" 2>"$run/err.log" || rc=$?
    check "$failure failure: original exit $original is preserved" '[ "$rc" = "$original" ]'
    check "$failure failure: swapoff, rm, licence return and later cleanup all run in order" \
      '[ "$(cat "$run/calls")" = "$(printf "swapoff\nrm\nreturn_on_exit\nfailing_cleanup\n")" ]'
    check "$failure failure: release_pidfile still removes this runs pidfile" '[ ! -e "$run/pid" ]'
    expected=7; [ "$failure" != rm ] || expected=9
    check "$failure failure: swap cleanup status and handler are reported on stderr" \
      'grep -q "exit cleanup failed (exit $expected): apk_swap_off" "$run/err.log"'
    check "$failure failure: subsequent cleanup failure is also reported on stderr" \
      'grep -q "exit cleanup failed (exit 23): failing_cleanup" "$run/err.log" && [ ! -s "$run/out.log" ]'
    if [ "$failure" != swapoff ]; then
      check "$failure failure: failed removal is not logged as successful" '! grep -q "removed swapfile" "$run/err.log"'
    fi
  done
done

# Closed stderr makes every diagnostic fail, independently of filesystem permissions (including as root).
# Only fake handlers run here: verify each diagnostic cannot abort the chain or mask the saved status.
for original in 0 42 143; do
  for return_rc in 0 17; do
    run="$tmp/closed-stderr-$original-$return_rc"; mkdir -p "$run"
    rc=0
    bash -c '
      set -euo pipefail
      . "$1/Tools/ship/linux-unity-license.sh"
      run="$2"; original="$3"; return_rc="$4"
      log() { printf "%s\n" "$*" >&2; }
      cmd_return() { echo return_on_exit >> "$run/calls"; return "$return_rc"; }
      idle_cleanup() { echo idle_cleanup >> "$run/calls"; }
      release_pidfile() { echo release_pidfile >> "$run/calls"; }
      failing_cleanup() { echo failing_cleanup >> "$run/calls"; return 23; }
      chain_exit_trap idle_cleanup
      chain_exit_trap release_pidfile
      UNITY_RETURN_ON_EXIT=1; arm_return_on_exit
      chain_exit_trap failing_cleanup
      exec 2>&-
      exit "$original"
    ' _ "$fixture_repo" "$run" "$original" "$return_rc" >"$run/out.log" 2>"$run/err.log" || rc=$?
    expected="$original"
    [ "$original" != 0 ] || expected="$return_rc"
    check "closed stderr: exit $original, return $return_rc preserves the intended status" '[ "$rc" = "$expected" ]'
    check "closed stderr: failed cleanup still reaches licence return, pidfile and idle cleanup" \
      '[ "$(cat "$run/calls")" = "$(printf "failing_cleanup\nreturn_on_exit\nrelease_pidfile\nidle_cleanup\n")" ]'
  done
done

# install_editor temporarily saves/restores the trap; preserve pre-existing handlers and quoted commands.
rc=0
bash -c '
  set -euo pipefail
  . "$1/Tools/ship/linux-unity-license.sh"
  trap '\''echo old >> "$2/calls"'\'' EXIT
  chain_exit_trap "printf '\''%s\\n'\'' '\''quoted handler'\'' >> $(printf %q "$2/calls")"
  saved="$(trap -p EXIT)"; trap - EXIT; eval "$saved"
  exit 19
' _ "$fixture_repo" "$tmp" >"$tmp/out.log" 2>"$tmp/err.log" || rc=$?
check 'saved/restored chains retain quoted commands, the old trap and the original failure' \
  '[ "$rc" = 19 ] && [ "$(cat "$tmp/calls")" = "$(printf "quoted handler\nold\n")" ] && [ ! -s "$tmp/err.log" ]'

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }

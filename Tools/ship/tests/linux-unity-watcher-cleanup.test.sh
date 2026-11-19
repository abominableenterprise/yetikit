#!/usr/bin/env bash
# Record watcher delays without sleeping in real time or calling the hub.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-seat-fixture.sh"
. "$script"
UNITY_IDLE_RETURN_MINUTES=0
UNITY_USERNAME=u UNITY_PASSWORD=p
THEROBOTS_TASK_ID=fixture THEROBOTS_TASK_TOKEN=fake THEROBOTS_HUB_URL=unused
export FAKE_RETURN_RC=0
mkdir -p "$IDLE_ACTIVE"
touch "$IDLE_ACTIVITY"

for scenario in marker guard retirement; do
  reset 200
  rm -rf "$ULF" "$ULF.returning" "$IDLE_DIR/retire.fixture"
  trace="$tmp/$scenario"
  printf '%s 1\n' "$THEROBOTS_TASK_ID" > "$SEAT_STATE"
  failed_path="$SEAT_STATE"
  expected=$'sleep 5\nfail\nsleep 10\nfail\nsleep 20\nclean'
  case "$scenario" in
    marker) printf '%s\n' "$good_ulf" > "$ULF" ;;
    guard)
      mkdir "$ULF.returning"
      failed_path="$ULF.returning/returned"
      expected=$'fail\nsleep 10\nfail\nsleep 20\nclean' ;;
    retirement)
      IDLE_WATCH_CONTEXT=fixture
      printf 'fixture\n' > "$IDLE_CONTEXT"
      printf '%s\n%s\n' "$(< "$SEAT_STATE")" "$SEAT_STATE" > "$IDLE_DIR/retire.fixture"
      failed_path="$IDLE_DIR/retire.fixture"
      expected=$'fail\nsleep 10\nfail\nsleep 20\nclean' ;;
  esac
  (
    sleep() {
      echo "sleep $1" >> "$trace"
      flock -n "$IDLE_ACTIVITY_LOCK" true || exit 91
    }
    rm() {
      if [ "${*: -1}" = "$failed_path" ]; then
        if [ "$(grep -c '^fail$' "$trace" 2>/dev/null || true)" != 2 ]; then
          echo fail >> "$trace"
          return 1
        fi
        echo clean >> "$trace"
      fi
      command rm "$@"
    }
    idle_watch
  )
  check "$scenario cleanup sleeps outside the lock between failed attempts without a ULF" \
    '[ "$(< "$trace")" = "$expected" ] && [ ! -e "$ULF" ] && [ ! -e "$failed_path" ] && [ "$(calls release)" = 1 ]'
done
[ "$fails" = 0 ]

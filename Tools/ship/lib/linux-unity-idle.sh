# shellcheck shell=bash
# Shared idle helpers; sourced by linux-unity-seat.sh after idle paths are set.

# Called only under the activity lock. Every terminal poll must retire its ad
# before unlocking; EXIT cleanup is too late for a concurrent reactivation.
idle_unadvertise() {
  [ "$(cut -d' ' -f1 "$IDLE_PID" 2>/dev/null)" != "$$" ] || rm -f "$IDLE_PID"
}

# Retain displaced run identities: /proc scans are not atomic across fork/exit.
idle_busy() {
  local f pid start p
  for f in "$IDLE_ACTIVE"/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; pid="${pid%%:*}"
    start="$(cat "$f")"
    if same_proc "$pid:$start"; then return 0; fi
    for p in $(marked "$pid:$start"); do
      if same_proc "$p" "$pid:$start"; then return 0; fi
    done
  done
  return 1
}

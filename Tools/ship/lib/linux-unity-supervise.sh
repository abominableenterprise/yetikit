# shellcheck shell=bash
# Keep state and EXIT cleanup in the wrapper. Bash dispatches signal traps
# during a wait builtin, but defers them while a foreground child is running.

# With no argument, report the caller's group only if it owns the terminal.
# Otherwise, set the terminal's foreground group even from a background job.
supervised_terminal_group() {
  perl -MPOSIX=tcgetpgrp,tcsetpgrp -e '
    open my $tty, "+<", "/dev/tty" or exit 1;
    if (@ARGV) {
      $SIG{TTOU} = "IGNORE";
      tcsetpgrp(fileno($tty), $ARGV[0]) or exit 1;
    } else {
      my $group = getpgrp();
      tcgetpgrp(fileno($tty)) == $group or exit 1;
      print $group;
    }
  ' "$@"
}

supervised_signal() {
  local status="$1" pid stat group i live
  local -A groups=()
  # Defer cancellation just until the async job's PID has been published.
  if [ -z "$child" ]; then pending="$status"; return; fi
  trap '' TERM INT HUP
  groups[$child]=1
  # GNU timeout (inside xvfb-run) may create its own group. Snapshot those
  # groups before TERM can orphan any descendants. No pipeline peers belong
  # to the background job's tree.
  for pid in $(descendants "$child"); do
    { read -r stat < "/proc/$pid/stat"; } 2>/dev/null || continue
    read -r _ _ group _ <<< "${stat##*) }"
    # Only groups led by a descendant can have been created by this job.
    [ "$group" != "$pid" ] || groups[$group]=1
  done
  for group in "${!groups[@]}"; do kill -TERM -- "-$group" 2>/dev/null || :; done
  for ((i=0; i<25; i++)); do
    live=0
    for group in "${!groups[@]}"; do
      if kill -0 -- "-$group" 2>/dev/null; then live=1; break; fi
    done
    [ "$live" = 1 ] || break
    /bin/sleep 0.02
  done
  for group in "${!groups[@]}"; do kill -KILL -- "-$group" 2>/dev/null || :; done
  wait "$child" 2>/dev/null || :
  if [ -n "$terminal_group" ]; then supervised_terminal_group "$terminal_group" || :; fi
  if [ -n "${supervised_cancel:-}" ]; then "$supervised_cancel" || :; fi
  exit "$status"
}

supervise() {
  local child='' pending='' saved rc=0 monitor=0 sig terminal_group=''
  if [ "${1:-}" = --foreground-terminal ]; then
    shift
    terminal_group="$(supervised_terminal_group)" || terminal_group=''
  fi
  saved="$(trap -p TERM INT HUP)"
  trap 'supervised_signal 143' TERM
  trap 'supervised_signal 130' INT
  trap 'supervised_signal 129' HUP
  # Job control makes $! the group leader. Turn it off again both here and
  # in the child, so its pipelines stay in that group and no job messages leak.
  if [[ $- != *m* ]]; then set -m; monitor=1; fi
  (
    set +m
    # Hand off before any sudo prompt, without changing pipeline stdin.
    if [ -n "$terminal_group" ]; then supervised_terminal_group "$BASHPID" || exit 1; fi
    "$@"
  ) <&0 &
  child=$!
  if [ "$monitor" = 1 ]; then set +m; fi
  [ -z "$pending" ] || supervised_signal "$pending"
  wait "$child" || rc=$?
  if [ -n "$terminal_group" ]; then supervised_terminal_group "$terminal_group" || :; fi
  # Replace installed handlers without an intermediate default disposition.
  eval "$saved"
  for sig in TERM INT HUP; do
    [[ "$saved" = *" SIG$sig"* ]] || trap - "$sig"
  done
  return "$rc"
}

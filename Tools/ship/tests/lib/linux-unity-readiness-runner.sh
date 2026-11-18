# A readiness wait can fail before any worker PID record exists. Tag only the
# synthetic run so cleanup can find workers in other process groups or sessions.
readiness_runner=""
readiness_workers() {
  grep -lzxF -- "SHIP_READINESS_RUN=$tmp" /proc/[0-9]*/environ 2>/dev/null || true
}
cleanup_readiness_runner() {
  [ -n "$readiness_runner" ] || return 0
  local pid file i
  # Give the wrapper its normal cancellation path first (notably seat release).
  if [[ $'\n'$(jobs -p)$'\n' = *$'\n'"$readiness_runner"$'\n'* ]]; then
    kill -TERM "$readiness_runner" 2>/dev/null || true
  fi
  for ((i=0; i<100; i++)); do
    [[ $'\n'$(jobs -p)$'\n' = *$'\n'"$readiness_runner"$'\n'* ]] || break
    /bin/sleep 0.03
  done
  # A wrapper blocked in a foreground command may not handle TERM. Kill the
  # job and then sweep its marked workers, including detached licensing clients.
  if [[ $'\n'$(jobs -p)$'\n' = *$'\n'"$readiness_runner"$'\n'* ]]; then
    kill -KILL "$readiness_runner" 2>/dev/null || true
  fi
  wait "$readiness_runner" 2>/dev/null || true
  for ((i=0; i<100; i++)); do
    local files=()
    mapfile -t files < <(readiness_workers)
    [ "${#files[@]}" -ne 0 ] || break
    for file in "${files[@]}"; do
      pid="${file#/proc/}"; pid="${pid%/environ}"
      grep -qzxF -- "SHIP_READINESS_RUN=$tmp" "$file" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    done
    /bin/sleep 0.02
  done
  readiness_runner=""
}

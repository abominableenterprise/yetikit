# shellcheck shell=bash
# Best-effort cgroup v2 diagnostics for the editor, which inherits our cgroup.
# Resolve both the mount point and its root (e.g. a mounted cgroup subtree).
unity_memory_events_file() {
  local proc="${UNITY_CGROUP_PROC:-/proc/self}" group path
  group="$(awk '/^0::\// { print substr($0, 4); exit }' "$proc/cgroup" 2>/dev/null)" || return 0
  [ -n "$group" ] || return 0
  while IFS= read -r -d '' path; do
    if [ -r "$path" ]; then printf '%s\n' "$path"; return 0; fi
  done < <(CGROUP_PATH="$group" awk '
    BEGIN { group = ENVIRON["CGROUP_PATH"] }
    # Decode mountinfo paths, not the unescaped path from /proc/self/cgroup.
    function decode(path) {
      gsub(/\\040/, " ", path); gsub(/\\011/, "\t", path)
      gsub(/\\012/, "\n", path); gsub(/\\134/, "\\", path)
      return path
    }
    {
      for (i = 7; i <= NF && $i != "-"; i++) {}
      if ($(i+1) != "cgroup2") next
      root = decode($4)
      if (root == "/") suffix = group
      else if (group == root) suffix = ""
      else if (index(group, root "/") == 1) suffix = substr(group, length(root) + 1)
      else next
      printf "%s%s/memory.events%c", decode($5), suffix, 0
    }' "$proc/mountinfo" 2>/dev/null)
}

unity_memory_events_read() {
  [ -r "$1" ] || return 0
  LC_ALL=C awk '$1 ~ /^(oom|oom_kill)$/ && $2 ~ /^[0-9]+$/ { print $1 "=" $2 }' "$1" 2>/dev/null || true
}

report_memory_events() {
  local after details
  after="$(unity_memory_events_read "$1")"
  if [ -z "$after" ]; then
    log "cgroup memory.events unavailable"
    return
  fi
  details="$(LC_ALL=C awk -F= -v before="$2" '
    BEGIN {
      n = split(before, rows, "\n")
      for (i = 1; i <= n; i++) { split(rows[i], field, "="); prior[field[1]] = field[2] }
    }
    {
      printf " %s", $0
      if ($1 in prior && $2+0 >= prior[$1]+0) printf " (+%.0f)", $2 - prior[$1]
    }' <<< "$after")"
  log "cgroup memory.events:$details (cgroup-wide counters, not proof this editor was OOM-killed)"
}

# SIGKILL (137) after $1 seconds: timeout if the limit was reached, else OOM/stop. GNU timeout accepts fractional
# s/m/h/d durations; zero disables it. Normalize only for diagnosis (timeout validates input). No results are written.
report_killed() {
  local label="${UNITY_RUN_LABEL:-editor}" var="${UNITY_TIMEOUT_VAR:-UNITY_TIMEOUT}"
  log "$label: $(LC_ALL=C awk -v duration="$UNITY_TIMEOUT" -v elapsed="$1" -v var="$var" '
    BEGIN {
      unit = substr(duration, length(duration))
      limit = (duration + 0) * (unit == "m" ? 60 : unit == "h" ? 3600 : unit == "d" ? 86400 : 1)
      if (limit == 0)
        printf "killed (SIGKILL) after %s s, timeout disabled (out of memory? stop?); no results", elapsed
      else if (elapsed >= limit)
        printf "killed at the %.12g s timeout; no results. Re-run with %s=%.12g", limit, var, limit * 2
      else
        printf "killed (SIGKILL) after %s s, before the %.12g s timeout (out of memory? stop?); no results", elapsed, limit
    }
  ')"
  report_memory_events "$2" "$3"
}

# shellcheck shell=bash
# Count exact tag fields in the final device-wide dump only. The early dump
# overlaps it; summing both would double-count entries. Never print messages here.
qr_launch_log_tag_counts() {
  [ -n "${QR_LAUNCH_LOG_TAGS:-}" ] || return 0
  # Pass literal data via the environment: awk -v interprets backslash escapes.
  QR_LAUNCH_LOG_TAGS="$QR_LAUNCH_LOG_TAGS" awk '
    BEGIN {
      n = split(ENVIRON["QR_LAUNCH_LOG_TAGS"], tags, "\n")
      for (i = 1; i <= n; i++) counts[tags[i]] = 0
    }
    match($0, /^[0-9][0-9]-[0-9][0-9][[:blank:]]+[0-9:.]+[[:blank:]]+[0-9]+[[:blank:]]+[0-9]+[[:blank:]]+[VDIWEFS][[:blank:]]+/) {
      $0 = substr($0, RLENGTH + 1)
      if (!sub(/[[:blank:]]*:([[:blank:]].*|$)/, "")) next
      if ($0 in counts) counts[$0]++
      next
    }
    /^[VDIWEFS]\// {
      sub(/^[VDIWEFS]\//, "")
      if (!sub(/[[:blank:]]*\([[:blank:]]*[0-9]+\):.*$/, "")) next
      if ($0 in counts) counts[$0]++
    }
    END {
      for (i = 1; i <= n; i++) printf "logcat tag [%s]: %d\n", tags[i], counts[tags[i]]
    }
  ' "$1"
}

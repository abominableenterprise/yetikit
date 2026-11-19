# shellcheck shell=bash
# Read-only post-install reporting for the foreground Android user on this Quest.
qr_permission_states() {
  local user dump=''
  [ -n "${QR_PERMISSIONS:-}" ] || { printf 'none configured\n'; return; }
  # Check adb's status before normalizing CRLF; a filter pipeline can hide a failed query.
  if user="$(qr_adb shell am get-current-user 2>/dev/null)" && [[ "${user%$'\r'}" =~ ^[0-9]+$ ]]; then
    user="${user%$'\r'}"
    dump="$(qr_adb shell dumpsys package "$QR_PKG" 2>/dev/null)" || dump=''
  else
    user=''
  fi
  # A package dump mixes package-wide sections and indented per-user sections.
  # Require the requested package and its installed user before reporting grants;
  # only an explicit requested-permissions section can establish absence.
  PERMISSIONS="$QR_PERMISSIONS" awk -v pkg="$QR_PKG" -v user="$user" '
    { sub(/\r$/, "") }
    /^[[:space:]]*\*\*\* SERVICE .* DUMP TIMEOUT/ { timed_out = 1 }
    /^[[:space:]]*$/ { next }
    {
      indent = match($0, /[^[:space:]]/) - 1
      if (indent == 0) packages = ($0 == "Packages:")
      if (in_package && indent <= package_indent) in_package = 0
      if (packages && $1 == "Package" && $2 == "[" pkg "]" && /:$/) {
        in_package = 1; package_indent = indent
        section = ""; runtime_indent = 0
        next
      }
      if (!in_package) next
      if (indent <= section_indent) { section = ""; runtime_indent = 0 }
      if (runtime_indent && indent <= runtime_indent) runtime_indent = 0
      if (section == "") {
        section_indent = indent
        if ($1 == "User" && $2 == user ":" && /[[:space:]]installed=true([[:space:]]|$)/) {
          installed = 1; section = "user"
        } else if ($1 == "install" && $2 == "permissions:") section = "install"
        else if ($1 == "requested" && $2 == "permissions:") {
          section = "requested"; saw_requested = 1
        } else section = "ignore"
      } else if (section == "user" && $1 == "runtime" && $2 == "permissions:") {
        runtime_indent = indent
      } else if (section == "requested" && (NF == 1 || $1 ~ /:$/)) {
        permission = $1
        sub(/:$/, "", permission)
        requested[permission] = 1
      } else if ($1 ~ /:$/ && $2 ~ /^granted=(true|false),?$/) {
        sub(/,$/, "", $2)
        if (runtime_indent) runtime[$1] = $2
        else if (section == "install") install[$1] = $2
      }
    }
    END {
      printf "user %s: ", (user == "" ? "unknown" : user)
      n = split(ENVIRON["PERMISSIONS"], names, "\n")
      for (i = 1; i <= n; i++) {
        key = names[i] ":"
        state = "unavailable"
        if (installed && !timed_out) {
          if (key in runtime) state = runtime[key]
          else if (key in install) state = install[key]
          else if (saw_requested && !(names[i] in requested)) state = "not requested"
        }
        printf "%s%s %s", (i == 1 ? "" : "; "), names[i], state
      }
      printf "\n"
    }
  ' <<< "$dump"
}

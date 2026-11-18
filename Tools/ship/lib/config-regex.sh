# shellcheck shell=bash
# Run after the schema check: noise keys and patterns cannot contain newlines.
# The pure-test fallback is a jq regex and is validated separately in config.jq.
ship_config_check_noise_regexes() {
  local patterns key regex rc
  patterns="$(jq -r '(.noise // {}) | to_entries[] | select(.key | endswith("Regex")) | .key, .value' <<< "$1")" || return 1
  [ -n "$patterns" ] || return 0
  while IFS= read -r key && IFS= read -r regex; do
    rc=0
    case "$key" in
      codeRegex) grep -qE -e "$regex" </dev/null 2>/dev/null || rc=$? ;;
      *) [[ '' =~ $regex ]] || rc=$? ;;
    esac
    # No match (1) is fine; only compilation errors should reject the config.
    if [ "$rc" -gt 1 ]; then
      printf 'invalid regular expression: noise.%s\n' "$key" >&2
      return 1
    fi
  done <<< "$patterns"
}

# shellcheck shell=bash
# Load one project-owned configuration before any editor, credential or seat work.
ship_config_get() {
  if [[ -v 'SHIP_CONFIG_VALUES[$1]' ]]; then
    [ -z "${SHIP_CONFIG_VALUES[$1]}" ] || printf '%s\n' "${SHIP_CONFIG_VALUES[$1]}"
  else jq -r "$1" <<< "$SHIP_CONFIG_JSON"; fi
}

ship_config_load() {
  command -v jq >/dev/null 2>&1 || { printf '[ship] error: jq is required to read yetikit.json\n' >&2; return 1; }
  SHIP_CONFIG_FILE="${YETIKIT_CONFIG:-$PROJECT/yetikit.json}"
  [ -f "$SHIP_CONFIG_FILE" ] || { printf '[ship] error: missing config %s\n' "$SHIP_CONFIG_FILE" >&2; return 1; }
  local error
  error="$(jq -sr -f "$(dirname "${BASH_SOURCE[0]}")/config.jq" "$SHIP_CONFIG_FILE")" || {
    printf '[ship] error: invalid JSON in %s\n' "$SHIP_CONFIG_FILE" >&2; return 1;
  }
  [ -z "$error" ] || { printf '[ship] error: %s: %s\n' "$SHIP_CONFIG_FILE" "$error" >&2; return 1; }
  SHIP_CONFIG_JSON="$(jq -f "$(dirname "${BASH_SOURCE[0]}")/config-paths.jq" "$SHIP_CONFIG_FILE")" || return 1
  # Batch fixed reads: dozens of jq subprocesses delay cancellation/lock tests
  # and every short command on resource-constrained workers.
  declare -gA SHIP_CONFIG_VALUES=()
  local key value values
  values="$(mktemp)" || return 1
  if ! jq -j -f "$(dirname "${BASH_SOURCE[0]}")/config-values.jq" <<< "$SHIP_CONFIG_JSON" > "$values"; then
    rm -f "$values"; return 1
  fi
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    SHIP_CONFIG_VALUES["$key"]="$value"
  done < "$values"
  rm -f "$values"
}

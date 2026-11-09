# shellcheck shell=bash
# Fixture-only reuse of immutable config. Validation/mutation has its own suite;
# qr_config's environment/path handling still executes on every invocation.
qr_test_cache_config_reads() {
  (
    # Collect the fixed scalar queries by running the real loader once with
    # placeholder values, then evaluate those queries in one jq process.
    qr_config_get() {
      printf '%s\n' "$1" >> "$tmp/config-expressions"
      case "$1" in 'has("quest")') echo true ;; *) echo synthetic ;; esac
    }
    qr_positive_seconds() { :; }
    qr_config >/dev/null 2>&1 || exit 1
    printf '%s\n' "$QR_CONFIG_JSON" > "$tmp/config-normalized.json"
    printf '. as $config |\n' > "$tmp/config-queries.jq"
    separator=''
    while IFS= read -r expression; do
      printf '%s($config | [(%s)] | map(if type == "string" then . else tostring end) | join("\\n")), "\\u0000"\n' "$separator" "$expression" >> "$tmp/config-queries.jq"
      separator=', '
    done < "$tmp/config-expressions"
    command jq -j -f "$tmp/config-queries.jq" "$tmp/config-normalized.json" > "$tmp/config-values" || exit 1
    printf 'qr_config_get() {\n  case "$1" in\n' > "$tmp/config-reads.sh"
    while IFS= read -r expression <&3; do
      value=''; IFS= read -r -d '' value || exit 1
      printf '    %q) printf "%%s\\n" %q ;;\n' "$expression" "$value" >> "$tmp/config-reads.sh"
    done 3< "$tmp/config-expressions" < "$tmp/config-values"
    printf '    *) echo "uncached config expression: $1" >&2; return 1 ;;\n  esac\n}\n' >> "$tmp/config-reads.sh"
  ) || return 1
  . "$tmp/config-reads.sh"
  jq() {
    case "$*" in
      "-sr --argjson questAbsoluteKnownFlakes true -f $QR_DIR/lib/config.jq $QR_CONFIG_FILE") return 0 ;;
      "-f $QR_DIR/lib/config-paths.jq $QR_CONFIG_FILE")
        while IFS= read -r line; do printf '%s\n' "$line"; done < "$tmp/config-normalized.json" ;;
      *) command jq "$@" ;;
    esac
  }
}

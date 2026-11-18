# shellcheck shell=bash
# Opt-in EditMode pure selection for `test pr`. Only the filter goes to stdout.
pr_pure_full() { test_stage_log "[linux-unity] test pr: full pure pass ($1)"; }

pr_pure_fixtures() {
  local max override="${TEST_PR_PURE_MAX:-}" regex enabled
  enabled="$(ship_config_get '(.tests // {}) | has("prPure")')" || return
  [ "$enabled" = true ] || return 0
  if [ "${TEST_PR_PURE_ALL:-}" = 1 ]; then pr_pure_full 'TEST_PR_PURE_ALL=1'; return; fi
  max="$(ship_config_get '.tests.prPure.max // 12')" || return
  if [ -n "$override" ]; then
    # Strip leading zeroes before checking length and doing decimal arithmetic.
    override="${override#"${override%%[!0]*}"}"
    override="${override:-0}"
    case "$override" in *[!0-9]*) pr_pure_full 'invalid TEST_PR_PURE_MAX'; return ;; esac
    if [ "${#override}" -gt 7 ]; then pr_pure_full 'invalid TEST_PR_PURE_MAX'; return; fi
    max="$override"
  fi
  if [ "$max" = 0 ]; then pr_pure_full 'max is 0'; return; fi
  regex="$(ship_config_get '.tests.prPure.fallbackRegex // empty')" || return
  # Keep both sides of renames for infrastructure checks and preserve literal paths.
  pr_changed_paths "$1" | pr_pure_select "$max" "$regex"
}

pr_pure_select() {
  local max="$1" regex="$2" tool_dir repo p area files blocked rows classes fixture reason count selected
  local edit_root scripts_root editor_root smoke paths=()
  smoke="$(ship_config_get '.tests.prPure.smokeFixtures[]?')" || return
  repo="$(pwd -P)" || return
  tool_dir="${SHIP_TOOL_DIR#"$repo"/}"
  edit_root="$(ship_config_get '.tests.editModeRoot // ((.tests.root // "Assets/Tests") + "/EditMode")')" || return
  scripts_root="$(ship_config_get '.tests.scriptsRoot // "Assets/Scripts"')" || return
  editor_root="$(ship_config_get '.tests.editorRoot // "Assets/Editor"')" || return
  while IFS= read -r -d '' p; do
    case "$p" in
      *$'\n'*|*$'\r'*|*$'\t'*) pr_pure_full 'changed path contains control whitespace'; return ;;
      "$tool_dir"|"$tool_dir/"*|Tools/yetikit|Tools/yetikit/*|yetikit.json|Packages/*|ProjectSettings/*|.github/*|*.asmdef|*.asmref|*.rsp|"$editor_root/"*.cs)
        pr_pure_full "infrastructure changed: $p"; return ;;
    esac
    paths+=("$p")
  done
  if [ -n "$regex" ] && [ "${#paths[@]}" -gt 0 ]; then
    p="$(printf '%s\n' "${paths[@]}" | jq -Rr --arg regex "$regex" 'select(test($regex))')" || return
    if [ -n "$p" ]; then pr_pure_full "fallbackRegex matched: ${p%%$'\n'*}"; return; fi
  fi
  # Pure includes untagged fixtures and fixtures with method-level categories.
  # Do not name classes excluded in their entirety, or explicitly invoke render tools.
  blocked="$(if [ -d "$edit_root" ]; then
    files="$(find "$edit_root" -name '*.cs')" || exit 1
    cs_classes '(Gfx|MacOnly|RenderTool)' class <<< "$files"
  fi)" || return
  rows=""
  for p in ${paths[@]+"${paths[@]}"}; do
    case "$p" in
      "$edit_root/"*.cs) files="$p"; reason="changed test $p" ;;
      "$scripts_root/"*/*.cs)
        area="${p#"$scripts_root/"}"; area="${area%%/*}"
        files="$(area_test_files "$area")" || return
        reason="tests for $area from $p" ;;
      *) continue ;;
    esac
    classes="$(cs_classes 0 <<< "$files")" || return
    # Smoke and other matches must not mask a changed test source we couldn't resolve.
    if [ -z "$classes" ]; then
      case "$p" in
        "$edit_root/"*.cs) pr_pure_full "no classes found in changed test $p"; return ;;
      esac
      continue
    fi
    while IFS= read -r fixture; do rows+="$fixture"$'\t'"$reason"$'\n'; done <<< "$classes"
  done
  while IFS= read -r fixture; do
    [ -z "$fixture" ] || rows+="$fixture"$'\tconfigured smoke fixture\n'
  done <<< "$smoke"
  rows="$(awk -F '\t' 'FILENAME == ARGV[1] { blocked[$1]=1; next } NF && !($1 in blocked)' \
    <(printf '%s\n' "$blocked") - <<< "$rows" | LC_ALL=C sort -u)" || return
  if [ -z "$rows" ]; then pr_pure_full 'no pure fixtures selected'; return; fi
  selected="$(cut -f1 <<< "$rows" | uniq)" || return
  count="$(wc -l <<< "$selected")" || return
  if [ "$count" -gt "$max" ]; then pr_pure_full "$count pure fixtures exceed max $max"; return; fi
  while IFS=$'\t' read -r fixture reason; do
    test_stage_log "[linux-unity] test pr: pure selected $fixture ($reason)"
  done <<< "$rows"
  paste -sd';' <<< "$selected"
}

run_pr_pure_pass() {
  local filter mb="$1"; shift
  local TEST_STAGES_LOG="${TEST_STAGES_LOG:-}"
  # Selection runs in the project; a relative OUT_DIR belongs to the caller.
  case "$TEST_STAGES_LOG" in ''|/*) ;; *) TEST_STAGES_LOG="$PWD/$TEST_STAGES_LOG" ;; esac
  if ! filter="$(cd "$PROJECT" && pr_pure_fixtures "$mb")"; then
    pr_pure_full 'could not determine pure selection'; filter=""
  fi
  if [ -n "$filter" ]; then set -- -testFilter "$filter" "$@"; fi
  run_pass editmode -nographics -runTests -testPlatform EditMode -testCategory "$PURE_CATEGORIES" "$@"
}

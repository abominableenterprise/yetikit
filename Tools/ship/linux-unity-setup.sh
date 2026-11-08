# shellcheck shell=bash
# Editor/image installation and setup command. Sourced by linux-unity.sh after its configuration and helpers.
# Uses the entry point's paths, as_root, log, die, need_creds, chain_exit_trap, cleanup_unity and unity_pids.

install_crane() {
  if command -v crane >/dev/null 2>&1 || [ -x "$BIN_DIR/crane" ]; then return; fi
  log "installing crane $CRANE_VERSION into $BIN_DIR"
  mkdir -p "$BIN_DIR"
  local archive; archive="$(ship_config_get '.setup.craneArchive // empty')"
  [ -n "$archive" ] || die "setup: crane is missing; with Go installed, run: GOBIN=$(printf %q "$BIN_DIR") go install github.com/google/go-containerregistry/cmd/crane@$CRANE_VERSION; then re-run setup (or set setup.craneArchive)"
  curl -fsSL "$archive" \
    | tar -xz -C "$BIN_DIR" crane
}

# Markers in UNITY_ROOT: PARTIAL is written before the editor is moved in, DONE replaces it once the whole transfer
# succeeded. A root with content but no DONE (a cross-filesystem move that failed part-way) is never trusted.
DONE_MARK=".install-complete"
PARTIAL_MARK=".install-partial"

# True when the editor binary is the pinned version (the version string is compiled into it; Unity is not run).
editor_version_ok() { as_root grep -aqF -- "$UNITY_VERSION" "$UNITY_BIN"; }

install_editor() {
  local done="$UNITY_ROOT/$DONE_MARK" partial="$UNITY_ROOT/$PARTIAL_MARK"
  local clear="clear it (sudo rm -rf $UNITY_ROOT) and re-run setup"
  if [ -x "$UNITY_BIN" ] && [ -x "$LC" ] && ! as_root test -e "$partial"; then
    if as_root test -e "$done"; then
      editor_version_ok || die "$UNITY_ROOT is not Unity $UNITY_VERSION; $clear"
      log "editor already at $UNITY_ROOT"; return
    fi
    # Installed before the marker existed: trust it once if the editor is the pinned version, and mark it.
    editor_version_ok || die "$UNITY_ROOT has an editor but no $DONE_MARK and it is not Unity $UNITY_VERSION; $clear"
    as_root touch "$done"; log "editor already at $UNITY_ROOT (pre-existing install, marked complete)"; return
  fi
  # An existing empty directory (a pre-created mount point, a custom UNITY_ROOT) is filled in place; anything else
  # that is there but incomplete is never trusted or overwritten. The listing runs with the install's privileges and
  # its exit status counts: an unprivileged `ls` of a root-owned 0700 directory prints nothing and looks empty.
  local first
  if [ -d "$UNITY_ROOT" ]; then
    first="$(as_root find -H "$UNITY_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" \
      || die "cannot tell whether $UNITY_ROOT is empty (listing it failed); check it, or $clear"
    [ -z "$first" ] || die "$UNITY_ROOT exists but is incomplete (editor, licensing client or $DONE_MARK missing); $clear"
  elif [ -e "$UNITY_ROOT" ]; then die "$UNITY_ROOT exists but is not a directory; $clear"; fi
  local crane stage parent prev_trap; crane="$(command -v crane || echo "$BIN_DIR/crane")"
  # A per-run stage next to UNITY_ROOT (never under the default /opt/unity unless that is UNITY_ROOT itself), so
  # concurrent setups of sibling roots never share one; the EXIT trap removes it on any failure.
  parent="$(dirname "$UNITY_ROOT")"; as_root mkdir -p "$parent"
  stage="$(as_root mktemp -d "$parent/.unity-extract.XXXXXX")"; as_root chmod 755 "$stage"
  prev_trap="$(trap -p EXIT)"
  # shellcheck disable=SC2064 # expand $stage now: the trap may run after this function returned
  chain_exit_trap "as_root rm -rf $(printf %q "$stage")"
  log "extracting $UNITY_IMAGE:/opt/unity (streamed, ~2-3 min, ~8.7 GB)"
  # Only opt/unity is written, into the stage, and moved into place once complete, so an interrupted extract never
  # leaves a half-installed $UNITY_ROOT that a re-run would trust.
  "$crane" export "$UNITY_IMAGE" - | as_root tar -x -C "$stage" opt/unity
  [ -x "$stage/opt/unity/$BIN_REL" ] && [ -x "$stage/opt/unity/$LC_REL" ] \
    || die "extract incomplete: editor or licensing client missing in $stage"
  [ -d "$UNITY_ROOT" ] || as_root mkdir "$UNITY_ROOT"
  as_root touch "$partial"
  # Move the contents, not the directory: `mv dir existing-dir` would make $UNITY_ROOT/unity.
  as_root find "$stage/opt/unity" -mindepth 1 -maxdepth 1 -exec mv -t "$UNITY_ROOT" -- {} +
  [ -x "$UNITY_BIN" ] && [ -x "$LC" ] || die "editor or licensing client missing in $UNITY_ROOT after install"
  as_root mv -f "$partial" "$done"
  as_root rm -rf "$stage"
  trap - EXIT; eval "$prev_trap"
}

install_libs() {
  # libGLU and xauth are dlopen'ed / used by xvfb-run, so ldd alone does not list them.
  local pkgs=(libgtk-3-0 libglu1-mesa libnss3 libasound2 libgbm1 libxss1 libxtst6 xvfb xauth libcap2 ca-certificates)
  local missing=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then
    log "apt-get install ${missing[*]}"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  fi
  if ldd "$UNITY_BIN" | grep -q 'not found'; then
    ldd "$UNITY_BIN" | grep 'not found' >&2
    die "editor still has missing libraries (see above)"
  fi
}

# merge=ours (.gitattributes, generated scene files) needs this driver once per clone.
setup_git() {
  git -C "$PROJECT" config merge.ours.driver true 2>/dev/null || log "warning: could not set merge.ours.driver"
}

# The image setup installs: UNITY_IMAGE when set, else the android image for UNITY_MODULES=android, else base.
pick_image() {
  case "$UNITY_MODULES" in
    ""|base) UNITY_IMAGE="${UNITY_IMAGE:-$UNITY_IMAGE_BASE}" ;;
    android) UNITY_IMAGE="${UNITY_IMAGE:-$UNITY_IMAGE_ANDROID}" ;;
    *) die "UNITY_MODULES=$UNITY_MODULES: only android is supported" ;;
  esac
}

has_android() { [ -d "$UNITY_ROOT/$ANDROID_REL/SDK" ] && [ -d "$UNITY_ROOT/$ANDROID_REL/NDK" ]; }

# setup --android over a complete editor without the Android module: remove it (the disk cannot hold both) so
# install_editor extracts the android image. An incomplete root is left for install_editor to refuse.
replace_base_editor() {
  [ "$UNITY_MODULES" = android ] && [ -x "$UNITY_BIN" ] && ! has_android || return 0
  as_root test -e "$UNITY_ROOT/$DONE_MARK" || return 0
  log "replacing the editor at $UNITY_ROOT (no Android module) with $UNITY_IMAGE"
  # Establish visibility with deletion's privileges before even wiping shared resources.
  local remaining
  remaining="$(as_root env UNITY_ROOT="$UNITY_ROOT" bash -c "$(declare -f unity_pids); unity_pids strict")" \
    || die "cannot inspect processes safely; refusing to replace $UNITY_ROOT"
  [ -z "$remaining" ] || die "cannot replace $UNITY_ROOT while Unity processes remain (PIDs:$remaining); close them and re-run setup"
  cleanup_unity
  as_root find "$UNITY_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

cmd_setup() {
  local no_creds=0
  while [ $# -gt 0 ]; do
    case "$1" in --android) UNITY_MODULES=android ;; --no-creds) no_creds=1 ;;
      *) die "usage: setup [--android] [--no-creds]" ;; esac
    shift
  done
  [ "$no_creds" = 1 ] || need_creds
  pick_image
  install_crane; replace_base_editor; install_editor; install_libs; setup_git
  if [ "$UNITY_MODULES" = android ]; then
    has_android || die "$UNITY_IMAGE gave no Android SDK/NDK under $UNITY_ROOT/$ANDROID_REL"
  fi
  log "setup ok"
}

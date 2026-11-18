#!/usr/bin/env bash
# Revert the editor's re-serialisation noise after a scene build.
# Sourced by linux-unity.sh `scene`; also runnable on its own after a scene build on any OS:
#   Tools/ship/scene-noise.sh [--run] [--before <file>] [--keep <path>]...
#
# Reverts (git checkout --) only tracked files that were clean before the build ($NOISE_DIRTY_BEFORE) and are not kept:
#   1. files under noise.artRoot (default Assets/Art) whose whole diff is `_ZTest` / `m_Floats` lines;
#   2. the configured noise.atlasPath and files matching noise.repackRegex (disabled when absent)
#      when no prop source (GLB/FBX/texture, or the configured generator code) changed against HEAD, the base branch or
#      as an untracked file: the atlas and the prefabs are then a re-pack of the same inputs. The prefabs and atlas
#      meshes are also kept whenever any code changed (Assets/Scripts/**, Assets/Editor/**, any .cs/.asmdef): their
#      generator's code inputs are not tracked one by one, so a code change always counts as a
#      real regeneration. The atlas PNG is still reverted then: it only depends on the prop textures.
#      With no merge-base between HEAD and $NOISE_BASE (default origin/main) the branch's committed changes are unknown,
#      so this step reverts nothing and says why.
#   3. ProjectSettings/TimeManager.asset only when solely Fixed Timestep formatting changed (absolute delta <= 1e-7),
#      including Unity's rational m_Count representation when noise.fixedTimestepCount is configured.
#   4. noise.specularMaterialPath, when configured, only _SPECULAR_COLOR keyword noise.
#   5. scene.lightmapDir/Lightmap-*.exr.meta only when solely platformSettings changed (bake noise).
#   6. noise.fontAssetPaths: opt-in static font serialization backstop (never deletion).
# Scene cleanup skips noise.protectedRegex (Assets/Scenes/ by default). Files dirty before the run and --keep
# paths are never touched. Additional configured prop, atlas, material and TimeManager paths are checked narrowly.
# --before <file>: the files dirty before the build (one per line, as linux-unity.sh writes to build/noise-before.txt
# when its own revert failed, including the pre-run lightmap dirty list); they are kept.
# --run: revert an editor command's noise instead (revert_run_noise), without scene bake cleanup.
# Every git call goes through noise_git: while another git command holds .git/index.lock it retries (NOISE_GIT_TRIES,
# default 10, NOISE_GIT_DELAY seconds apart, default 1.5), then fails with exit 75 ($NOISE_LOCK_RC). It never removes
# the lock. Prints every file it reverts or keeps. --keep paths are resolved from the caller's directory (./x,
# absolute, subdirectory-relative); a path outside the repository is an error.
#
# Needs bash >= 4. Stock macOS ships bash 3.2: `brew install bash`, then run it with that bash (the `#!/usr/bin/env
# bash` line picks it up once Homebrew's bin is first on PATH). NOISE_BASH_MAJOR overrides the detected major version
# (tests only).

if [ "${NOISE_BASH_MAJOR:-${BASH_VERSINFO[0]}}" -lt 4 ]; then
  printf '[scene-noise] error: needs bash >= 4, this is bash %s (macOS: brew install bash, then run it with that bash)\n' \
    "$BASH_VERSION" >&2
  return 2 2>/dev/null || exit 2
fi

# The runner loads configuration before sourcing this helper. Standalone recovery uses the same loader.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  PROJECT="${PROJECT:-$(git rev-parse --show-toplevel)}"
  die() { printf '[scene-noise] error: %s\n' "$*" >&2; exit 1; }
  source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
  ship_config_load
fi

NOISE_PROTECTED_RE="$(ship_config_get '.noise.protectedRegex // "^Assets/Scenes/"')"
NOISE_SOURCE_RE="$(ship_config_get '.noise.sourceRegex // "\\.(glb|fbx|jpg|jpeg|png|tga|psd)(\\.meta)?$"')"
NOISE_GENERATORS_RE="$(ship_config_get '.noise.generatorsRegex // "a^"')"
NOISE_CODE_RE="$(ship_config_get '.noise.codeRegex // "^Assets/(Scripts|Editor)/|\\.(cs|asmdef)$"')"
NOISE_ART_ROOT="$(ship_config_get '.noise.artRoot // "Assets/Art"')"
NOISE_ATLAS="$(ship_config_get '.noise.atlasPath // ""')"
# shellcheck source=Tools/ship/lib/run-noise.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/run-noise.sh"
noise_init_run_config ship_config_get || { return 1 2>/dev/null || exit 1; }
NOISE_PROPS_DIR="$(ship_config_get '.noise.propsDir // "Assets/Art/Props"')"
NOISE_PROPS_DIR="${NOISE_PROPS_DIR%/}"
NOISE_REPACK_RE="$(ship_config_get '.noise.repackRegex // "a^"')"
NOISE_LIGHTMAP_DIR="$(ship_config_get '.scene.lightmapDir // ""')"
NOISE_LIGHTMAP_DIR="${NOISE_LIGHTMAP_DIR%/}"

# Tracked files whose working tree or index differs from HEAD, plus untracked files (one path per line).
# Include staged edits even if the working file was restored to HEAD: cleanup validates against HEAD,
# but `git checkout -- <path>` restores from the index. Never reintroduce a staged setting as editor noise.
noise_dirty_files() {
  noise_git diff --name-only HEAD -- || return
  noise_git diff --cached --name-only HEAD -- || return
  noise_git ls-files --others --exclude-standard
}

# The merge-base of HEAD and the base branch ($NOISE_BASE, default origin/main); fails when there is none (no such
# ref, unrelated history, shallow clone).
noise_merge_base() { noise_git merge-base HEAD "${NOISE_BASE:-origin/main}" 2>/dev/null; }

# Every path changed on this branch: working tree and untracked vs HEAD, and HEAD vs the merge-base $1 (when given).
noise_changed_paths() {
  noise_dirty_files || return
  if [ -n "${1:-}" ]; then noise_git diff --name-only "$1" HEAD --; fi
}

# True when $1's diff against HEAD only adds `_ZTest` entries (and turns `m_Floats: []` into a `m_Floats:` list).
# A removed or changed `_ZTest` value is a real edit and is kept.
noise_only_ztest() {
  local lines
  lines="$(noise_git diff -U0 HEAD -- "$1")" || return 1
  lines="$(grep -E '^[+-]' <<< "$lines" | grep -vE '^(\+\+\+|---) ')" || return 1
  [ -n "$lines" ] || return 1
  # Here-strings, not `printf | grep -q`: grep -q exits at the first match, printf then dies of SIGPIPE and, under the
  # caller's pipefail, the pipeline's 141 would read as "no real line" (it reverted a real mesh diff once).
  ! grep -qvE '^\+[[:space:]]*(- )?_ZTest:|^[+-][[:space:]]*m_Floats:( \[\])?[[:space:]]*$' <<< "$lines"
}

# True when a prop source changed: a GLB/FBX/texture under noise.propsDir or the configured generator code. Any prop
# counts for every prefab and atlas mesh: one changed texture re-packs the shared atlas and so every prop's UVs.
# The atlas itself is an output, not a source. $1: changed paths.
noise_sources_changed() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$NOISE_ATLAS" ] && { [ "$f" = "$NOISE_ATLAS" ] || [ "$f" = "$NOISE_ATLAS.meta" ]; }; then continue; fi
    [[ "$f" =~ $NOISE_GENERATORS_RE ]] && return 0
    if [[ "$f" == "$NOISE_PROPS_DIR/"* && "$f" =~ $NOISE_SOURCE_RE ]]; then return 0; fi
  done <<< "$1"
  return 1
}

# True when any code changed: anything under Assets/Scripts/ or Assets/Editor/, or any .cs/.asmdef. $1: changed paths.
noise_code_changed() { grep -qE "$NOISE_CODE_RE" <<< "$1"; }

# Print the --keep path $2, as the caller typed it (relative to the current directory, ./x, absolute; file or
# directory, existing or not), relative to the repository root $1 ("." for the root itself). Fails when the path is
# outside the repository. Symlinks in the existing part of the path are resolved, then . and .. are dropped.
noise_keep_path() {
  local top p="$2" abs dir rest="" part res=""
  top="$(cd "$1" && pwd -P)" || return 1
  [ -n "$p" ] || return 1
  case "$p" in /*) abs="$p" ;; *) abs="$(pwd -P)/$p" ;; esac
  dir="$abs"
  while [ ! -d "$dir" ]; do rest="/${dir##*/}$rest"; dir="${dir%/*}"; [ -n "$dir" ] || dir=/; done
  abs="$(cd "$dir" && pwd -P)$rest"
  local IFS=/ parts
  read -ra parts <<< "$abs"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in ''|.) ;; ..) res="${res%/*}" ;; *) res="$res/$part" ;; esac
  done
  [ -n "$res" ] || res=/
  if [ "$res" = "$top" ]; then echo .
  elif [ "${res#"$top"/}" != "$res" ]; then echo "${res#"$top"/}"
  else return 1
  fi
}

noise_kept() {
  local f="$1" k
  for k in ${NOISE_KEEP[@]+"${NOISE_KEEP[@]}"}; do
    k="${k%/}"
    [ "$k" = . ] && return 0
    [ "$f" = "$k" ] || [ "${f#"$k"/}" != "$f" ] && return 0
  done
  return 1
}

# $1: dirty files before the build (noise_dirty_files output). Remaining args: paths to keep.
revert_editor_noise() { noise_lock_checked noise_revert_editor "$@"; }
noise_revert_editor() {
  local before="$1"; shift
  NOISE_KEEP=("$@")
  local changed all_changed f prop reason mb="" unknown=""
  local -a paths=(":(literal)$NOISE_ART_ROOT/" "$NOISE_TIME_MANAGER" "$NOISE_PROPS_DIR")
  [ -z "$NOISE_ATLAS" ] || paths+=("$NOISE_ATLAS")
  [ -z "$NOISE_SPECULAR_MATERIAL" ] || paths+=("$NOISE_SPECULAR_MATERIAL")
  for f in ${NOISE_FONT_PATHS[@]+"${NOISE_FONT_PATHS[@]}"}; do paths+=(":(literal)$f"); done
  changed="$(noise_git diff --name-only HEAD -- "${paths[@]}")" || return
  [ -n "$changed" ] || { noise_log "no changes under $NOISE_ART_ROOT or configured noise paths"; return 0; }
  if ! mb="$(noise_merge_base)"; then
    mb=""
    unknown="no merge-base with ${NOISE_BASE:-origin/main}, branch changes unknown"
    noise_log "warning: $unknown: keeping the atlas, atlas meshes and prefabs (fetch the base or set NOISE_BASE)"
  fi
  all_changed="$(noise_changed_paths "$mb")" || return
  all_changed="$(sort -u <<< "$all_changed")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    reason=""
    if [[ "$f" =~ $NOISE_PROTECTED_RE ]]; then continue
    elif noise_kept "$f"; then noise_log "keeping $f (--keep)"; continue
    elif grep -qxF -- "$f" <<< "$before"; then noise_log "keeping $f (changed before the build)"; continue
    elif noise_font_path "$f"; then
      [ -f "$f" ] || { noise_log "keeping $f (deleted)"; continue; }
      reason="static font serialization"
    elif [ "$f" = "$NOISE_TIME_MANAGER" ]; then
      if noise_fixed_timestep_only "$f"; then reason="only Fixed Timestep formatting"
      else noise_log "keeping $f (a real change)"; continue; fi
    elif noise_specular_only "$f"; then reason="only _SPECULAR_COLOR keyword"
    elif noise_only_ztest "$f"; then reason="only _ZTest/m_Floats lines"
    elif [ "$f" = "$NOISE_ATLAS" ]; then
      if [ -n "$unknown" ]; then noise_log "keeping $f ($unknown)"; continue; fi
      if noise_sources_changed "$all_changed"; then noise_log "keeping $f (a prop source changed)"; continue; fi
      reason="atlas re-encode, prop sources unchanged"
    elif [[ "$f" =~ $NOISE_REPACK_RE ]]; then
      prop="${BASH_REMATCH[1]:-$f}"
      if [ -n "$unknown" ]; then noise_log "keeping $f ($unknown)"; continue; fi
      if noise_sources_changed "$all_changed"; then noise_log "keeping $f (a prop source changed)"; continue; fi
      if noise_code_changed "$all_changed"; then noise_log "keeping $f (code changed)"; continue; fi
      reason="re-pack of $prop, prop sources unchanged"
    else continue
    fi
    noise_log "reverting $f ($reason)"
    noise_git checkout -q -- ":(literal)$f" || return
  done <<< "$changed"
}

# The editor noise of an `open` or `test` run, anywhere in the repository: tracked *.mat files whose diff only touches
# `_ZTest` lines, *.prefab files whose diff only re-formats floats, and the narrowly checked Fixed Timestep
# formatting in ProjectSettings/TimeManager.asset (including the configured rational form), plus
# _SPECULAR_COLOR-only keyword noise in noise.specularMaterialPath and static serialization in noise.fontAssetPaths
# (when configured, never deletion). $1: dirty files before the run
# (noise_dirty_files); remaining args: --keep paths. Files dirty before the run and kept paths are never touched.
revert_run_noise() { noise_lock_checked noise_revert_run "$@"; }
noise_revert_run() {
  local before="$1" f reason list; shift
  NOISE_KEEP=("$@")
  local -a paths=('*.mat' '*.prefab' "$NOISE_TIME_MANAGER")
  for f in ${NOISE_FONT_PATHS[@]+"${NOISE_FONT_PATHS[@]}"}; do paths+=(":(literal)$f"); done
  list="$(noise_git diff --name-only HEAD -- "${paths[@]}")" || return
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if noise_kept "$f"; then noise_log "keeping $f (--keep)"; continue
    elif grep -qxF -- "$f" <<< "$before"; then noise_log "keeping $f (changed before the run)"; continue
    elif ! reason="$(noise_run_reason "$f")"; then noise_log "keeping $f (a real change)"; continue
    fi
    noise_log "reverting $f ($reason)"
    noise_git checkout -q -- ":(literal)$f" || return
  done <<< "$list"
}

# Standalone scene recovery must finish both cleanups, even when the original scene's bake revert ran out of
# index-lock retries. Use the same pre-run snapshot and --keep protections as editor cleanup; only platformSettings
# may differ from HEAD. A changed lightmap importer setting, GUID, etc. is real bake output and must survive.
noise_revert_bake() {
  local before="$1" f list original head_path; shift
  NOISE_KEEP=("$@")
  [ -n "$NOISE_LIGHTMAP_DIR" ] || return 0
  list="$(noise_git diff --name-only HEAD -- "$NOISE_LIGHTMAP_DIR/Lightmap-*.exr.meta")" || return
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if noise_kept "$f"; then noise_log "keeping $f (--keep)"; continue
    elif grep -qxF -- "$f" <<< "$before"; then noise_log "keeping $f (edited before scene)"; continue; fi
    # ls-tree succeeds with empty output for a new staged meta, but still reports
    # repository/object errors. Do not mistake a failed show for a missing path.
    head_path="$(noise_git ls-tree --name-only HEAD -- ":(literal)$f")" || return
    if [ -z "$head_path" ]; then noise_log "keeping $f (absent from HEAD)"; continue; fi
    original="$(mktemp)"
    if noise_git show "HEAD:$f" > "$original"; then
      if [ -f "$f" ] && cmp -s <(noise_strip_platform_settings < "$original") <(noise_strip_platform_settings < "$f"); then
        rm -f "$original"
        noise_log "reverting bake-only $f"
        noise_git checkout -q -- "$f" || return
      else noise_log "keeping $f (changes outside platformSettings)"; fi
      rm -f "$original"
    else rm -f "$original"; return 1; fi
  done <<< "$list"
}

# A platformSettings block ends at the next importer key at the same indentation.
noise_strip_platform_settings() { awk '/^  platformSettings:/ { skip = 1; next } skip && /^  [^ -]/ { skip = 0 } !skip'; }

revert_scene_noise() {
  local brc=0 nrc=0
  noise_lock_checked noise_revert_bake "$@" || brc=$?
  revert_editor_noise "$@" || nrc=$?
  [ "$brc" = 0 ] || return "$brc"
  return "$nrc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  top="$PROJECT"
  keep=(); before=""; revert=revert_scene_noise
  while IFS= read -r k; do keep+=("$k"); done < <(ship_config_get '.scene.keepPaths[]?')
  usage="usage: $0 [--run] [--before <file>] [--keep <path>]..."
  # Resolve every --keep and --before from the caller's directory before the cd below.
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
        k="$(noise_keep_path "$top" "$2")" || { noise_log "error: --keep $2 is not inside $top"; exit 2; }
        keep+=("$k"); shift 2 ;;
      --before) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
        before="$(cat -- "$2")" || { noise_log "error: cannot read --before $2"; exit 2; }
        shift 2 ;;
      --run) revert=revert_run_noise; shift ;;
      *) echo "$usage" >&2; exit 2 ;;
    esac
  done
  cd "$top"
  "$revert" "$before" ${keep[@]+"${keep[@]}"}
fi

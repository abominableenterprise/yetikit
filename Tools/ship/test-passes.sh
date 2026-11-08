# Helpers for linux-unity.sh `test`: the Gfx fixtures a branch touches (`test pr`) and the
# known-flake retry. Sourced by linux-unity.sh; every function runs in the project root (the caller cd's there).

# Print every class the C# files named on stdin declare at namespace level, fully qualified (Ns.Class), one per line.
# With a category $1 (1 means Gfx), print only the classes carrying [Category("$1")], on the class or on one of its
# members (a method-level Gfx test runs in the render pass too, and -testFilter <class> reaches it). Nested classes
# count as their outer one.
cs_classes() {
  local f cat="${1:-0}"
  [ "$cat" = 1 ] && cat=Gfx
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    awk -v gfx="$([ "$cat" = 0 ] && echo 0 || echo 1)" -v cat="$cat" '
      BEGIN { tag = "\\[[^]]*Category\\(\"" cat "\"\\)" }
      function fq(c) { return ns == "" ? c : ns "." c }
      function braces(s,   o, c) { o = gsub(/\{/, "{", s); c = gsub(/\}/, "}", s); depth += o - c }
      /^[[:space:]]*\/\// { next }
      {
        line = $0
        if (match(line, /^[[:space:]]*namespace[[:space:]]+[A-Za-z0-9_.]+/)) {
          ns = substr(line, RSTART, RLENGTH); sub(/^[[:space:]]*namespace[[:space:]]+/, "", ns)
          nsdepth = line ~ /;[[:space:]]*$/ ? 0 : depth + 1
          braces(line); next
        }
        attr = line ~ /^[[:space:]]*\[/
        if (gfx && line ~ tag) pending = 1
        if (match(line, /(^|[^A-Za-z0-9_])class[[:space:]]+[A-Za-z0-9_]+/)) {
          c = substr(line, RSTART, RLENGTH); sub(/^.*class[[:space:]]+/, "", c)
          if (depth <= nsdepth) { top = c; if (!gfx) print fq(top) }
          if (pending && gfx) print fq(top)
          pending = 0
        } else if (pending && !attr && line ~ /[^[:space:]]/) {
          if (gfx && top != "") print fq(top)
          pending = 0
        }
        braces(line)
      }' "$f"
  done | sort -u
}

# Declared runtime type identifiers, including multiple/nested types and record
# class/struct forms. Ignore comments and literals rather than inventing types
# from documentation or embedded source text. Deleted files retain basename matching.
cs_declared_types() {
  [ -f "$1" ] || return 0
  perl -0777 -ne '
    s{/\*.*?\*/|//[^\n]*|@"(?:""|[^"])*"|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27}{ }gs;
    while (/\b(?:class|struct|enum|interface|record(?:\s+(?:class|struct))?)\s+@?([A-Za-z_][A-Za-z0-9_]*)/g) {
      print "$1\n";
    }' "$1" | sort -u
}

# Paths changed since the merge-base $1: committed and uncommitted (tracked) changes, plus untracked files.
pr_changed_paths() {
  git diff --name-only "$1" --
  git ls-files --others --exclude-standard
}

# The configured EditMode test folder for a scripts area, otherwise the folder
# holding *.<Area>.Tests.asmdef (only its own files, not tests in subdirectories).
area_test_files() {
  local area="$1" asm edit_root
  edit_root="$(ship_config_get '.tests.editModeRoot // ((.tests.root // "Assets/Tests") + "/EditMode")')" || return
  if [ -d "$edit_root/$area" ]; then find "$edit_root/$area" -name '*.cs'; return; fi
  asm="$(find "$edit_root" -name "*.$area.Tests.asmdef" 2>/dev/null | head -n1)"
  [ -n "$asm" ] && find "$(dirname "$asm")" -maxdepth 1 -name '*.cs'
  return 0
}

# Test files a change set (stdin, one path per line) touches: changed EditMode files,
# and every test file of a changed scripts area, using the configured roots.
pr_test_files() {
  local p areas="" edit_root scripts_root
  edit_root="$(ship_config_get '.tests.editModeRoot // ((.tests.root // "Assets/Tests") + "/EditMode")')" || return
  scripts_root="$(ship_config_get '.tests.scriptsRoot // "Assets/Scripts"')" || return
  while IFS= read -r p; do
    case "$p" in
      "$edit_root/"*.cs) echo "$p" ;;
      "$scripts_root/"*/*) areas="$areas ${p#"$scripts_root/"}" ;;
    esac
  done
  for p in $(printf '%s\n' $areas | sed 's#/.*##' | sort -u); do area_test_files "$p"; done
}

# Explicit builder-to-fixture dependencies, independent of scene-area membership. These fixtures exercise the
# builder's output but are not area tests; keep their real Gfx categories as the source of render-pass eligibility.
pr_builder_tests() {
  local p fixtures
  fixtures="$(ship_config_get '.tests.builderFixtures // {} | to_entries[] | .key as $path | .value[] | [$path, .] | @tsv')" || return
  while IFS= read -r p; do
    awk -F '\t' -v path="$p" '$1 == path { print $2 }' <<< "$fixtures"
  done | sort -u
}

# Gfx fixtures touched since $1 (stdout only); selection reasons go to stderr. Runtime types only search their
# area's test folder; editor builders search all tests for references to their filename's class. Neither builders
# nor scene assets expand to whole areas. Resolve Gfx tags globally so partial classes retain their eligibility.
pr_gfx_fixtures() {
  local tagged rows selected p name area files f fixture reason count max="${TEST_PR_GFX_MAX:-12}"
  local ranked stamp dirty newest latest_dirty source rest tests_root edit_root scripts_root editor_root
  tests_root="$(ship_config_get '.tests.root // "Assets/Tests"')" || return
  edit_root="$(ship_config_get '.tests.editModeRoot // ((.tests.root // "Assets/Tests") + "/EditMode")')" || return
  scripts_root="$(ship_config_get '.tests.scriptsRoot // "Assets/Scripts"')" || return
  editor_root="$(ship_config_get '.tests.editorRoot // "Assets/Editor"')" || return
  case "$max" in ''|*[!0-9]*) echo "test pr: invalid TEST_PR_GFX_MAX=$max; using 12" >&2; max=12 ;; esac
  # Normalise decimal values (including 0 and leading zeroes) without shell octal interpretation.
  max="$(awk -v n="$max" 'BEGIN { printf "%.0f", n }')"
  tagged="$(find "$tests_root" -name '*.cs' 2>/dev/null | sort | cs_classes 1)"
  [ -n "$tagged" ] || return 0
  rows="$( { while IFS= read -r p; do
    files=""; reason=""
    case "$p" in
      "$edit_root/"*.cs) files="$p"; reason="changed test $p" ;;
      "$scripts_root/"*/*.cs)
        area="${p#"$scripts_root/"}"; area="${area%%/*}"
        name="${p##*/}"; name="${name%.cs}"
        name="$( { printf '%s\n' "$name"; cs_declared_types "$p"; } | sort -u | paste -sd '|' -)"
        files="$(while IFS= read -r f; do grep -Elw -- "$name" "$f" || true; done < <(area_test_files "$area"))"
        reason="references $name from $p" ;;
      "$editor_root/"*.cs)
        name="${p##*/}"; name="${name%.cs}"
        files="$(grep -rlw --include='*.cs' -- "$name" "$tests_root" 2>/dev/null || true)"
        reason="references builder $name from $p" ;;
    esac
    [ -n "$files" ] || continue
    while IFS= read -r f; do
      while IFS= read -r fixture; do
        grep -Fxq -- "$fixture" <<< "$tagged" || continue
        printf '%s\t%s\t%s\n' "$fixture" "$f" "$reason"
      done < <(cs_classes 0 <<< "$f")
    done <<< "$files"
  done < <(pr_changed_paths "$1" | sort -u)
  # Explicit dependencies need not mention a builder identifier in test source.
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    grep -Fxq -- "$fixture" <<< "$tagged" || continue
    while IFS= read -r f; do
      cs_classes 0 <<< "$f" | grep -Fxq -- "$fixture" || continue
      printf '%s\t%s\t%s\n' "$fixture" "$f" 'configured builder dependency'
    done < <(find "$tests_root" -name '*.cs' 2>/dev/null | sort)
  done < <(pr_changed_paths "$1" | pr_builder_tests)
  } | sort -u)"
  [ -n "$rows" ] || return 0
  selected="$(cut -f1 <<< "$rows" | sort -u)"
  count="$(wc -l <<< "$selected")"
  if [ "$count" -gt "$max" ]; then
    echo "test pr: $count matching Gfx fixtures exceed TEST_PR_GFX_MAX=$max; fallback to the most recently changed matching fixtures" >&2
    # Dirty/untracked sources sort first by mtime, then committed sources by their latest commit time. For a
    # fixture declared in multiple matching sources use its newest source; equal times break by fixture name.
    ranked="$(while IFS= read -r fixture; do
      newest=0; latest_dirty=0
      while IFS=$'\t' read -r source rest; do
        dirty=0
        if [ -n "$(git status --porcelain -- "$source")" ]; then
          dirty=1; stamp="$(stat -c %Y "$source" 2>/dev/null || stat -f %m "$source")"
        else
          stamp="$(git log -1 --format=%ct -- "$source")"; stamp="${stamp:-0}"
        fi
        if [ "$dirty" -gt "$latest_dirty" ] || { [ "$dirty" = "$latest_dirty" ] && [ "$stamp" -gt "$newest" ]; }; then
          newest="$stamp"; latest_dirty="$dirty"
        fi
      done < <(awk -F '\t' -v f="$fixture" '$1 == f { print $2 "\t" $3 }' <<< "$rows")
      printf '%s\t%s\t%s\n' "$latest_dirty" "$newest" "$fixture"
    done <<< "$selected" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr -k3,3)"
    selected="$(awk -F '\t' -v max="$max" 'NR <= max { print $3 }' <<< "$ranked")"
  fi
  [ -n "$selected" ] || return 0
  while IFS= read -r fixture; do
    printf 'test pr: selected %s\n' "$fixture" >&2
    awk -F '\t' -v f="$fixture" '$1 == f { print "  why: " $3 " (" $2 ")" }' <<< "$rows" >&2
  done <<< "$selected"
  printf '%s\n' "$selected"
}

# PR #468: 46 fixtures took 3625 s in tests alone, plus editor startup.
# Estimate at 90 s/fixture; allow 120 s/fixture plus 1200 s startup/import
# headroom, with the old 3600 s floor. Explicit caller timeouts always win.
# test_pr dynamically scopes UNITY_GFX_TIMEOUT so other test modes are unchanged.
pr_gfx_budget() {
  local count=0 estimate budget
  [ -z "$1" ] || count="$(printf '%s\n' "$1" | wc -l | tr -d ' ')"
  estimate=$((count * 90))
  budget=$((1200 + count * 120))
  [ "$budget" -ge 3600 ] || budget=3600
  if [ -z "${TEST_PR_TIMEOUT_EXPLICIT:-}" ]; then UNITY_GFX_TIMEOUT="$budget"; fi
  log "test pr: selected $count Gfx fixtures; estimated tests ${estimate} s (90 s/fixture, rough; heavy fixtures can exceed this); editor-inclusive timeout $UNITY_GFX_TIMEOUT s"
}

# The scene areas a change set (stdin, one path per line) touches, one per line: a <Area>.prefab (or its .meta)
# under scene.areasDir, or a file the $SCENE_AREAS table (scene.areasFile) lists as that area's builder
# ("<Area> <path glob>..." per line, # comments). Both sources are optional.
pr_areas() {
  local p area globs g areas_dir
  areas_dir="$(ship_config_get '.scene.areasDir // ""')" || return
  areas_dir="${areas_dir%/}"
  local -a patterns
  while IFS= read -r p; do
    if [ -n "$areas_dir" ]; then
      case "$p" in
        "$areas_dir/"*.prefab|"$areas_dir/"*.prefab.meta)
          area="${p#"$areas_dir/"}"; echo "${area%%.*}" ;;
      esac
    fi
    [ -f "${SCENE_AREAS:-}" ] || continue
    while read -r area globs; do
      # Split words without pathname expansion: deleted builders must still match the original glob.
      read -r -a patterns <<< "$globs"
      for g in "${patterns[@]}"; do
        # shellcheck disable=SC2254 # $g is a glob from the table
        case "$p" in $g) echo "$area"; break ;; esac
      done
    done < <(sed -e 's/#.*//' "$SCENE_AREAS" | grep -v '^[[:space:]]*$')
  done | sort -u
}

# The test classes (Ns.Class, one per line) of the areas on stdin: classes tagged [Category("Area:<Area>")] (on the
# class or one of its tests) anywhere under the configured test root.
pr_area_tests() {
  local area files tests_root
  tests_root="$(ship_config_get '.tests.root // "Assets/Tests"')" || return
  files="$(find "$tests_root" -name '*.cs' 2>/dev/null | sort)"
  [ -n "$files" ] || return 0
  while IFS= read -r area; do
    [ -n "$area" ] && cs_classes "Area:$area" <<< "$files"
  done | sort -u
}

# Full names of the failures in an NUnit result XML ($1), one per line: failed test cases, and suites that failed on
# their own (a fixture's OneTimeSetUp/OneTimeTearDown: site other than "Child", or no site and no failed case inside),
# so a fixture failure whose cases all passed is never missed.
failed_tests() {
  [ -f "$1" ] || return 0
  perl -0777 -ne '
    sub name { my $n = $_[0] =~ /\bfullname="([^"]*)"/ ? $1 : "?";
      $n =~ s/&quot;/"/g; $n =~ s/&apos;/\x27/g; $n =~ s/&lt;/</g; $n =~ s/&gt;/>/g; $n =~ s/&amp;/&/g; $n }
    sub failed { $_[0] =~ /\bresult="Failed"/ }
    sub close_suite { my ($a, $inner) = @{pop @s};
      my $site = $a =~ /\bsite="([^"]*)"/ ? $1 : "";
      print name($a), "\n" if failed($a) && ($site ne "" ? $site ne "Child" : !$inner);
      $s[-1][1] ||= $inner if @s }
    @s = ();
    while (/<(\/?)(test-case|test-suite)\b([^>]*?)(\/?)>/g) {
      my ($end, $tag, $a, $self) = ($1, $2, $3, $4);
      if ($tag eq "test-case") { next if $end || !failed($a); print name($a), "\n"; $s[-1][1] = 1 if @s }
      elsif ($end) { close_suite() if @s }
      else { push @s, [$a, 0]; close_suite() if $self }
    }' "$1"
}

# The known-flakes list ($KNOWN_FLAKES): one fully qualified test (or fixture) name per line, # comments.
known_flakes() {
  [ -f "$KNOWN_FLAKES" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$KNOWN_FLAKES" | grep -v '^$' || true
}

# True when test $1 is listed: the same name, a parameterised case of it (Name(...)) or a test of a listed fixture.
is_known_flake() {
  local e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$1" = "$e" ] || [ "${1#"$e("}" != "$1" ] || [ "${1#"$e."}" != "$1" ] && return 0
  done <<< "$(known_flakes)"
  return 1
}

# The args $@ without any -testFilter <value> pair.
without_test_filter() {
  local skip=0 a
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [ "$a" = -testFilter ]; then skip=1; continue; fi
    printf '%s\0' "$a"
  done
}

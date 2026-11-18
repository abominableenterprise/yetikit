# shellcheck shell=bash
# Content predicates shared by editor-run reverts and release worktree cleanup.
# Call from the worktree root. Configuration is supplied by the calling tool.
noise_init_run_config() {
  local get="$1" fonts font
  NOISE_TIME_MANAGER="$("$get" '.noise.timeManagerPath // "ProjectSettings/TimeManager.asset"')" || return 1
  NOISE_TIMESTEP_COUNT="$("$get" '.noise.fixedTimestepCount // ""')" || return 1
  NOISE_SPECULAR_MATERIAL="$("$get" '.noise.specularMaterialPath // ""')" || return 1
  fonts="$("$get" '.noise.fontAssetPaths[]?')" || return 1
  NOISE_FONT_PATHS=()
  while IFS= read -r font; do
    [ -z "$font" ] || NOISE_FONT_PATHS+=("$font")
  done <<< "$fonts"
}

noise_font_path() {
  local font
  for font in ${NOISE_FONT_PATHS[@]+"${NOISE_FONT_PATHS[@]}"}; do
    [ "$1" != "$font" ] || return 0
  done
  return 1
}

noise_log() { printf '[scene-noise] %s\n' "$*" >&2; }

# Exit code of noise_git (and so of the reverts) when another git command kept .git/index.lock for every retry.
NOISE_LOCK_RC=75

# `git "$@"`, retried while another git process holds the index lock ("Unable to create '.../index.lock': File
# exists"). Output is buffered and printed once, from the try that ran to the end. The lock is never removed: a
# concurrent `git status` releases it within a second or two.
noise_git() {
  local tries="${NOISE_GIT_TRIES:-10}" delay="${NOISE_GIT_DELAY:-1.5}" try=1 rc out err
  out="$(mktemp)"; err="$(mktemp)"
  while :; do
    rc=0; git "$@" > "$out" 2> "$err" || rc=$?
    if [ "$rc" = 0 ] || ! grep -qF "index.lock': File exists" "$err"; then break; fi
    if [ "$try" -ge "$tries" ]; then
      noise_log "error: git $1 failed $tries times: .git/index.lock is held by a concurrent git command" \
        "(do not run git in this work tree while linux-unity.sh test/scene runs); the lock was left in place"
      rm -f "$out" "$err"
      # Also seen from a $(...) subshell or a predicate whose failure only means "keep the file" (noise_lock_checked).
      [ -z "${NOISE_LOCK_FLAG:-}" ] || : > "$NOISE_LOCK_FLAG"
      return "$NOISE_LOCK_RC"
    fi
    [ "$try" != 1 ] || noise_log "git $1: .git/index.lock exists (another git command is running); retrying up to $tries times"
    try=$((try + 1)); sleep "$delay"
  done
  cat "$out"; cat "$err" >&2
  rm -f "$out" "$err"
  return "$rc"
}

# Run "$@" and fail with $NOISE_LOCK_RC when any noise_git inside it ran out of retries, even where that failure was
# read as a plain "no" (a file then kept, not reverted): the revert is incomplete and must be rerun.
noise_lock_checked() {
  local flag rc=0
  flag="$(mktemp)"; rm -f "$flag"
  NOISE_LOCK_FLAG="$flag" "$@" || rc=$?
  if [ -e "$flag" ]; then rm -f "$flag"; return "$NOISE_LOCK_RC"; fi
  return "$rc"
}

# Only Fixed Timestep may differ, with the surrounding text and every other line byte-identical.
# Decimal float formatting is tolerated; rational counts are normalized only when explicitly configured.
# Other settings stay byte-identical.
noise_fixed_timestep_only() {
  noise_git show "HEAD:$1" | SHIP_TIMESTEP_COUNT="$NOISE_TIMESTEP_COUNT" perl -e '
    local $/; my $a = <STDIN>;
    open(my $h, "<", $ARGV[0]) or exit 1; my $b = <$h>;
    exit 1 unless defined $a && defined $b && $a ne $b;
    for ($a, $b) {
      exit 1 unless defined && (() = /^[ \t]*Fixed Timestep:/mg) == 1;
      my $count = $ENV{SHIP_TIMESTEP_COUNT};
      if ($count =~ /\A[1-9][0-9]*\z/) {
        my $seconds = $count / 141120000;
        s/^([ \t]*Fixed Timestep:)\r?\n[ ]{4}m_Count: \Q$count\E(\r?\n)/$1 $seconds$2/m;
      }
    }
    exit 0 if $a eq $b;
    my @a = split /(?<=\n)/, $a; my @b = split /(?<=\n)/, $b;
    exit 1 if @a != @b;
    my $num = qr/[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/;
    my $changed = 0;
    for my $i (0 .. $#a) {
      next if $a[$i] eq $b[$i];
      exit 1 unless $a[$i] =~ /\A([ \t]*Fixed Timestep: )($num)(\r?\n?)\z/;
      my ($prefix, $value, $suffix) = ($1, $2, $3);
      exit 1 unless $b[$i] =~ /\A\Q$prefix\E($num)\Q$suffix\E\z/;
      exit 1 unless abs($value - $1) <= 1e-7;
      $changed++;
    }
    exit($changed == 1 ? 0 : 1);' "$1"
}

# Only this known material may gain/lose/move _SPECULAR_COLOR in its keyword lists.
# Keep every other byte (including other keywords and their ordering); do not extend this to arbitrary materials.
noise_specular_only() {
  [ -n "$NOISE_SPECULAR_MATERIAL" ] && [ "$1" = "$NOISE_SPECULAR_MATERIAL" ] || return 1
  noise_git show "HEAD:$1" | perl -e '
    local $/; my $a = <STDIN>;
    open(my $h, "<", $ARGV[0]) or exit 1; my $b = <$h>;
    exit 1 unless defined $a && defined $b && $a ne $b;
    sub canonical {
      my ($text) = @_; my %seen;
      $text =~ s{(^  m_(Valid|Invalid)Keywords:)( \[\](\r?\n)|(\r?\n)((?:  - [A-Z0-9_]+\r?\n)*))}{
        my ($header, $kind, $body, $eol, $list_eol, $items) = ($1, $2, $3, $4, $5, $6);
        exit 1 if $seen{$kind}++;
        if (defined $items) {
          my $removed = ($items =~ s/^  - _SPECULAR_COLOR\r?\n//mg);
          exit 1 if $removed > 1;
          $body = length($items) ? "$list_eol$items" : " []$list_eol" if $removed;
        }
        "$header$body";
      }meg;
      exit 1 unless $seen{Valid} && $seen{Invalid};
      return $text;
    }
    exit(canonical($a) eq canonical($b) ? 0 : 1);' "$1"
}

# True when tracked $1's diff against HEAD only touches `_ZTest` lines (added, removed or changed; plus `m_Floats: []`
# turning into a list and back). Used after `open`/`test`, whose editor run never edits a material on purpose.
noise_ztest_lines_only() {
  local lines
  lines="$(noise_git diff --no-ext-diff --no-textconv --no-color -U0 HEAD -- ":(literal)$1")" || return 1
  lines="$(awk '/^@@ / { hunk=1 } hunk && /^[+-]/' <<< "$lines")" || return 1
  [ -n "$lines" ] || return 1
  ! grep -qvE '^[+-][[:space:]]*(- )?_ZTest:|^[+-][[:space:]]*m_Floats:( \[\])?[[:space:]]*$' <<< "$lines"
}

# True when tracked $1 differs from HEAD only in how floats are written: the same lines, and every changed number
# token is the same value to 5 significant digits (0 and -0 alike). Two integers (fileIDs, counts) must be equal, and
# any change outside a number is real.
noise_float_format_only() {
  noise_git cat-file -e "HEAD:$1" 2>/dev/null || return 1
  perl -e '
    my ($fa, $fb) = @ARGV;
    open(my $ha, "-|", "git", "show", "HEAD:$fa") or exit 1; my @a = <$ha>; close $ha or exit 1;
    open(my $hb, "<", $fb) or exit 1; my @b = <$hb>;
    exit 1 if @a != @b;
    my $num = qr/(?<![\w.])-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?(?![\w.])/;
    sub g { my $v = $_[0] + 0; $v = 0 if $v == 0; sprintf("%.5g", $v) }
    my $changed = 0;
    for my $i (0 .. $#a) {
      next if $a[$i] eq $b[$i];
      $changed = 1;
      my @x = split /($num)/, $a[$i]; my @y = split /($num)/, $b[$i];
      exit 1 if @x != @y;
      for my $j (0 .. $#x) {
        next if $x[$j] eq $y[$j];
        exit 1 if $j % 2 == 0;                                  # text outside a number changed
        if ($x[$j] !~ /[.eE]/ && $y[$j] !~ /[.eE]/) { exit 1 if $x[$j] != $y[$j]; next }  # integers: exact (-0 is 0)
        exit 1 if g($x[$j]) ne g($y[$j]);
      }
    }
    exit($changed ? 0 : 1);' "$1" "$1"
}

# Return the reason only when an existing run-noise rule recognizes the file.
noise_run_reason() {
  local f="$1"
  if noise_font_path "$f"; then
    [ -f "$f" ] || return 1
    echo "static font serialization"
  elif noise_specular_only "$f"; then echo "only _SPECULAR_COLOR keyword"
  elif [[ "$f" == *.mat ]] && noise_ztest_lines_only "$f"; then echo "only _ZTest lines"
  elif [[ "$f" == *.prefab ]] && noise_float_format_only "$f"; then echo "only float formatting"
  elif [ "$f" = "$NOISE_TIME_MANAGER" ] && noise_fixed_timestep_only "$f"; then echo "only Fixed Timestep formatting"
  else return 1; fi
}

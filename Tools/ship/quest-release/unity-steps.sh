# shellcheck shell=bash
# quest-release `gate [--full]` and `build`: the Mac-only EditMode tests in the test worktree and the development APK
# in the build worktree. Both can run at the same time (different projects, separate -logFile). Sourced by
# Tools/ship/quest-release.sh.

# The categories the gate runs: every category Linux's pure pass excludes (PURE_CATEGORIES '!Gfx;!MacOnly' in
# linux-unity.sh). Linux never runs MacOnly, and `test pr` runs Gfx only for the fixtures a branch touches, so the
# merged commit's other Gfx fixtures are unchecked until here. QUEST_GATE_CATEGORIES overrides.
qr_gate_categories() {
  if [ -n "${QUEST_GATE_CATEGORIES:-}" ]; then printf '%s\n' "$QUEST_GATE_CATEGORIES"; return 0; fi
  local pure cats="" c
  pure="$(sed -n "s/^PURE_CATEGORIES='\(.*\)'.*/\1/p" "$QR_SHIP_DIR/linux-unity.sh" 2>/dev/null | head -n1)"
  [ -n "$pure" ] || pure='!Gfx;!MacOnly'
  for c in $(printf '%s\n' "$pure" | tr ';' '\n' | sed -n 's/^!//p'); do
    case ";$cats;" in *";$c;"*) ;; *) cats="${cats:+$cats;}$c" ;; esac
  done
  case ";$cats;" in *";MacOnly;"*) ;; *) cats="MacOnly${cats:+;$cats}" ;; esac
  printf '%s\n' "$cats"
}

# Validate the ENTIRE document before extracting anything. /usr/bin/xmllint ships with macOS; Perl XML::Parser
# does not. Canonical XML also normalizes single-quoted attributes, numeric entities and CDATA for the shared
# failed_tests reader. No recovery, network access, DTDs or entity expansion from external resources.
qr_nunit_xml() {
  command -v xmllint >/dev/null 2>&1 || { qr_log "gate: xmllint is required to validate results XML"; return 1; }
  LC_ALL=C grep -q '<!DOCTYPE' "$1" && return 1
  local xml
  xml="$(xmllint --nonet --c14n "$1" 2>/dev/null)" || return 1
  perl -0777 -pe '
    s/<!--.*?-->|<\?.*?\?>//gs;
    # Canonical XML can retain literal > inside attributes; failed_tests uses > as its tag boundary.
    s{(<[A-Za-z][^\s/>]*\b(?:[^">]|"[^"]*")*>)}{
      my $tag = $1; $tag =~ s{"([^"]*)"}{my $a = $1; $a =~ s/>/&gt;/g; qq{"$a"}}ge; $tag
    }ge;
  ' <<< "$xml"
}

# NUnit result XML ($1): "total passed failed skipped", then shared failed_tests failures with their messages.
# A failed suite without site or failed children is a failure too, even when the root says failed=0.
qr_nunit_report() {
  local xml names parsed
  xml="$(qr_nunit_xml "$1")" || return 1
  parsed="$(mktemp)" || return 1
  printf '%s\n' "$xml" > "$parsed"
  names="$(failed_tests "$parsed")"
  rm -f "$parsed"
  perl -0777 -e '
    sub attr { my ($a, $k) = @_; return $a =~ /(?:^|\s)$k="([^"]*)"/ ? $1 : "" }
    sub unxml { my $s = shift; $s =~ s/&quot;/"/g; $s =~ s/&apos;/\x27/g; $s =~ s/&lt;/</g; $s =~ s/&gt;/>/g; $s =~ s/&amp;/&/g; $s }
    sub msg { my $b = shift // ""; return "" unless $b =~ /<message>(.*?)<\/message>/s;
      my $m = unxml($1); $m =~ s/\s+/ /g; $m =~ s/^ | $//g; return length($m) > 300 ? substr($m, 0, 300) . "..." : $m }
    my @names = split /\n/, shift @ARGV;
    my $xml = <>;
    $xml =~ s/<!--.*?-->|<\?.*?\?>//gs;
    my $attrs = qr/(?:[^">]|"[^"]*")*/;
    $xml =~ /\A\s*<test-run\b($attrs)>/ or exit 1;
    my $root = $1;
    my @counts = map { attr($root, $_) } qw(total passed failed skipped);
    for (@counts) { /\A[0-9]+\z/ or exit 1 }
    $counts[1] + $counts[2] + $counts[3] <= $counts[0] or exit 1;
    print join(" ", @counts), "\n";
    my %details;
    while ($xml =~ /<test-case\b($attrs)>(.*?)<\/test-case>/gs) {
      my ($a, $b) = ($1, $2); next unless attr($a, "result") eq "Failed";
      $details{unxml(attr($a, "fullname"))} = ": " . msg($b);
    }
    while ($xml =~ /<test-suite\b($attrs)>/g) {
      my $a = $1; next unless attr($a, "result") eq "Failed";
      my $site = attr($a, "site");
      my $own = substr($xml, pos($xml)); $own =~ s/<test-(?:suite|case)\b.*//s;
      $details{unxml(attr($a, "fullname"))} = ($site ne "" ? " ($site)" : "") . ": " . msg($own);
    }
    for my $name (@names) { print "FAIL $name", $details{$name} // ": failed", "\n" }
  ' "$names" <<< "$xml"
}

qr_gate() {
  local full=0 wt cats xml log rc=0 report totals failed total
  [ "${1:-}" = --full ] && full=1
  qr_need_commit
  wt="$(qr_wt test)"
  [ -d "$wt" ] || qr_die "no test worktree $wt: run prepare first"
  xml="$QR_RUN_DIR/gate.xml"; log="$QR_RUN_DIR/gate-unity.log"
  rm -f "$xml" "$QR_RUN_DIR/gate-retry.xml" "$QR_RUN_DIR/gate-retry-failures.txt"
  qr_set gate_result failed # until qr_gate_passed: what `wait` reads for a gate-only run
  set -- -batchmode -force-metal -projectPath "$wt" -runTests -testPlatform EditMode
  if [ "$full" = 1 ]; then
    cats="all (--full)"
  else
    cats="$(qr_gate_categories "$wt")"
    set -- "$@" -testCategory "$cats"
  fi
  qr_log "gate: EditMode in $wt, categories $cats (log $log)"
  QR_UNITY_TIMEOUT="$QR_GATE_TIMEOUT" unity "$@" -testResults "$xml" -logFile "$log" || rc=$?
  if [ ! -s "$xml" ]; then
    qr_set gate "FAILED: no results XML (Unity exit $rc; see gate-unity.log)"
    qr_die "gate: no results XML (Unity exit $rc); see $log"
  fi
  if ! report="$(qr_nunit_report "$xml")"; then
    qr_set gate "FAILED: invalid results XML (Unity exit $rc; see gate.xml)"
    qr_set gate_failures "invalid results XML"
    qr_log "gate: invalid results XML (see $xml)"
    return 1
  fi
  totals="$(printf '%s\n' "$report" | sed -n 1p)"
  # shellcheck disable=SC2086 # split "total passed failed skipped"
  set -- $totals
  total="$1"; failed="$3"
  qr_set gate "$cats: $1 tests, $2 passed, $3 failed, $4 skipped (Unity exit $rc)"
  printf '%s\n' "$report" | sed -n '2,$p' > "$QR_RUN_DIR/gate-failures.txt"
  qr_log "gate: $total tests, $2 passed, $failed failed, $4 skipped"
  if [ -s "$QR_RUN_DIR/gate-failures.txt" ]; then
    cat "$QR_RUN_DIR/gate-failures.txt" >&2
    qr_set gate_failures "$(sed 's/^FAIL //' "$QR_RUN_DIR/gate-failures.txt" | head -n 10 | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
  else
    qr_set gate_failures "none"
  fi
  [ "$total" != 0 ] || { qr_log "gate: no test matched $cats"; return 1; }
  case "$rc" in 0|2) ;; *) qr_log "gate: Unity exited $rc"; return 1 ;; esac
  if [ "$failed" != 0 ] || [ -s "$QR_RUN_DIR/gate-failures.txt" ]; then
    # Rebuild the first run's args (without its -testResults / -logFile) for the one known-flake rerun.
    set -- -batchmode -force-metal -projectPath "$wt" -runTests -testPlatform EditMode
    [ "$full" = 1 ] || set -- "$@" -testCategory "$cats"
    qr_gate_flake_retry "$wt" "$@" || return 1
  fi
  qr_gate_passed
}

# A passing gate replaces what an earlier failed `all` wrote for the steps it skipped (qr_step_ok).
qr_gate_passed() {
  qr_step_ok gate
  qr_set gate_result passed
  case "$(qr_get cleanup "")" in "kept for the gate failure"*) qr_set cleanup "kept (gate ok; run cleanup when done)" ;; esac
  return 0
}

# Identify the APK by its bytes, not the current prepared commit (a rollback or explicit install can use another
# run's APK, even after renaming it). Old build summaries already store its hash and source commit.
qr_apk_commit() {
  local hash d
  hash="$(qr_sha256 "$1")" || return 1
  for d in "$QR_LOGS"/*/summary; do
    if [ -f "$d/build_apk_sha256" ]; then
      [ "$(head -n1 "$d/build_apk_sha256")" = "$hash" ] || continue
      head -n1 "$d/build_commit"
      return
    fi
    # Generic apk_sha256 is also written by verify, even on prepared-only runs. It cannot prove that this
    # commit built those bytes. Ambiguous legacy records must not shadow a later immutable build record;
    # without one, return unknown and reset the notes baseline rather than inventing provenance.
  done
}

# The most recent actual adb install, including rollbacks and manual steps in the current run. An unidentifiable
# APK intentionally returns empty rather than borrowing the prepared commit or an older installed baseline.
qr_last_installed_sha() {
  local d ts sha apk
  for d in "$QR_LOGS"/*/ "$QR_LOGS"/*/devices/*/; do
    d="${d%/}"
    if [ -s "$d/summary/installed_at" ]; then
      ts="$(head -n1 "$d/summary/installed_at")"
      sha="$(head -n1 "$d/summary/installed_commit" 2>/dev/null)"
    else
      # Compatibility with logs predating installed_commit. Never treat a rollback's prepared commit as its APK.
      grep -qE '^(install|rollback) ok' "$d/summary/install" 2>/dev/null || continue
      ts="$(printf '%s\n' "${d##*/}" | sed -n 's/.*-\([0-9]\{8\}-[0-9]\{6\}\).*/\1/p')"
      sha=""
      apk="$(sed -n '1s/^[^(]*(\(.*\)), playtest\.json CHANGED$/\1/p; 1s/^[^(]*(\(.*\))$/\1/p' "$d/summary/install")"
      if [ -f "$apk" ]; then sha="$(qr_apk_commit "$apk")"; fi
      # A missing explicit APK cannot be tied to this run's prepared commit. Leave the baseline unknown
      # (last eight merges) unless installed_commit or byte-matched immutable build evidence identifies it.
    fi
    printf '%s %s\n' "${ts:-0}" "$sha"
  done | sort -r | sed -n '1s/^[^ ]* //p'
}

# --notes <file> for all/build: release notes passed through the configured environment variable.
qr_notes_option() {
  [ -n "${1:-}" ] || qr_die "--notes needs a file"
  [ -f "$1" ] || qr_die "--notes file $1 does not exist"
  export "$QR_WHATS_NEW_ENV=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

# Keep unity()/qr_timebox's timeout supervisor outside the editor's attempt-owned process group. The
# launcher publishes only that group's editor PID; no process-name/global kill searches or step-wide signals.
qr_build_attempt() (
  local log="$1" watch job pid="" size=0 current last="$SECONDS" stalled=0 rc=0
  shift
  watch="$(mktemp -d "$QR_RUN_DIR/build-watch.XXXXXXXX")" || return 1
  # Also drain on normal failure/timeout and cancellation, before removing the group's identity. A stopped
  # worker needs CONT to handle TERM; TERM-resistant compiler/Gradle children need bounded escalation.
  qr_build_drain() {
    local group
    [ -s "$watch/editor.pid" ] || return 0
    read -r group < "$watch/editor.pid"
    kill -TERM -- "-$group" 2>/dev/null || true
    kill -CONT -- "-$group" 2>/dev/null || true
    ps -axo pgid=,stat= | awk -v group="$group" '$1 == group && $2 !~ /^Z/ { alive=1 } END { exit !alive }' || return 0
    # Use a real two-second grace, not integer SECONDS rounding: the overall timeout keeps running here.
    sleep 2
    while ps -axo pgid=,stat= | awk -v group="$group" '$1 == group && $2 !~ /^Z/ { alive=1 } END { exit !alive }'; do
      kill -KILL -- "-$group" 2>/dev/null || true
      sleep 0.1
    done
  }
  trap 'qr_build_drain; rm -rf "$watch"' EXIT
  # Cancellation's outer step-group drain can KILL this shell after two seconds. Do not leave the
  # isolated editor group waiting on that same grace deadline; terminate it before exiting this trap.
  trap 'if [ -s "$watch/editor.pid" ]; then read -r pid < "$watch/editor.pid"; kill -KILL -- "-$pid" 2>/dev/null || true; fi; exit 143' HUP INT TERM
  # This override is scoped to this attempt and used only by the real unity wrapper (test stubs still work).
  qr_unity_bin() {
    local bin d
    d="$(qr_editor_dir "$1")" || return 1
    if [ -n "${UNITY_BIN:-}" ]; then bin="$UNITY_BIN"
    else bin="$d/Unity.app/Contents/MacOS/Unity"; fi
    [ -x "$bin" ] || { qr_log "no Unity editor at $bin"; return 1; }
    # Monitor mode creates a group for this editor only, not unity()/gtimeout or the parallel gate. Disable
    # it inside the editor job so all compiler/Gradle generations inherit that same group. The supervisor
    # stays alive to forward an overall timeout and reap the editor, preserving qr_timebox's exit 124.
    {
      printf '#!/bin/bash\nwatch=%q\n' "$watch"
      printf '%s\n' 'printf "%s\n" "$$" > "$watch/editor.pid" || exit 1' \
        'while [ ! -f "$watch/registered" ]; do [ -d "$watch" ] || exit 1; sleep 0.01; done'
      printf 'exec %q "$@"\n' "$bin"
    } > "$watch/editor-group"
    {
      printf '#!/bin/bash\nwatch=%q\n' "$watch"
      declare -f qr_build_drain
      printf '%s\n' 'set -m' 'pid=""; cancelled=0' \
        'trap '\''cancelled=1'\'' HUP INT TERM' \
        'cancel() { trap "" HUP INT TERM; kill -TERM -- "-$pid" 2>/dev/null; kill -CONT -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; qr_build_drain; exit 143; }'
      # Latch signals across fork/$! registration; the child cannot exec until registration succeeds.
      printf '(set +m; exec %q "$@") &\npid=$!\nset +m\n' "$watch/editor-group"
      printf '%s\n' 'trap cancel HUP INT TERM' '[ "$cancelled" = 0 ] || cancel' \
        ': > "$watch/registered" || cancel' 'rc=0; wait "$pid" || rc=$?' \
        'qr_build_drain' 'exit "$rc"'
    } > "$watch/editor"
    chmod +x "$watch/editor" "$watch/editor-group" || return 1
    printf '%s\n' "$watch/editor"
  }
  ANDROID_USER_HOME="$(qr_android_user_home)"; export ANDROID_USER_HOME; unset XDG_CONFIG_HOME
  QR_UNITY_TIMEOUT="$QR_BUILD_TIMEOUT" unity "$@" &
  job=$!
  while kill -0 "$job" 2>/dev/null; do
    if [ -z "$pid" ] && [ -s "$watch/editor.pid" ]; then
      read -r pid < "$watch/editor.pid"
      last="$SECONDS"
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      current=0
      [ ! -f "$log" ] || current="$(wc -c < "$log" | tr -d '[:space:]')"
      if [ "$current" != "$size" ]; then size="$current"; last="$SECONDS"; fi
      if [ "$((SECONDS - last))" -ge "$QR_BUILD_STALL_SECONDS" ]; then
        # Drain the entire attempt before a retry can start, even if the editor exits before its workers.
        if kill -0 "$pid" 2>/dev/null; then
          printf '%s\n' "$(tail -n 1 "$log" 2>/dev/null)" > "$watch/last-line"
          stalled=1
          qr_build_drain
        fi
        break
      fi
    fi
    sleep 1
  done
  wait "$job" || rc=$?
  if [ "$stalled" = 1 ] && [ "$rc" != 124 ]; then
    # An overall timeout can expire during stall grace. It wins: preserve 124 and never request a retry.
    # Otherwise a marker distinguishes a stall from an ordinary editor failure with any code.
    cp "$watch/last-line" "$log.stalled"
    rc=1
  fi
  return "$rc"
)

qr_build() {
  local wt out kept rc=0 log prev attempt=1
  local QR_BUILD_STALL_SECONDS="${QR_BUILD_STALL_SECONDS-300}"
  case "$QR_BUILD_STALL_SECONDS" in
    ''|*[!0-9]*|0*) qr_die "QR_BUILD_STALL_SECONDS must be a positive integer (seconds)" ;;
  esac
  # Bound shell arithmetic on both stock macOS Bash and Linux; accidental huge settings must not wrap.
  [ "${#QR_BUILD_STALL_SECONDS}" -le 9 ] || qr_die "QR_BUILD_STALL_SECONDS is too large"
  while [ $# -gt 0 ]; do
    case "$1" in
      --notes) qr_notes_option "${2:-}"; shift ;;
      *) qr_die "build: unknown option $1" ;;
    esac
    shift
  done
  qr_need_commit
  wt="$(qr_wt build)"
  [ -d "$wt" ] || qr_die "no build worktree $wt: run prepare first"
  out="$wt/$QR_APK_REL"
  kept="$QR_APK_DIR/${QR_APK_KEEP_NAME//\{sha\}/$QR_SHORT}"
  case "${kept#"$QR_APK_DIR"/}" in ''|*/*|.|..) qr_die "quest.apkKeepName must be a filename" ;; esac
  log="$QR_RUN_DIR/build-unity.log"
  [ "${QR_KEYSTORE_CHECKED:-}" = 1 ] || qr_keystore_preflight # `all` checked it before the gate
  rm -f "$out"
  # Release notes fall back to merges since the last installed build.
  if [ -z "${!QR_PREV_SHA_ENV:-}" ]; then
    prev="$(qr_last_installed_sha)"
    [ -z "$prev" ] || { export "$QR_PREV_SHA_ENV=$prev"; }
  fi
  qr_set notes "${!QR_WHATS_NEW_ENV:-merge titles since ${!QR_PREV_SHA_ENV:-the last 8 merges}}"
  qr_log "build: $QR_BUILD_METHOD in $wt (log $log, ANDROID_USER_HOME=$(qr_android_user_home)), notes: $(qr_get notes)"
  while :; do
    # Never let an earlier attempt's log, APK or stall marker count as progress/success for this attempt.
    rm -f "$out" "$log" "$log.stalled"
    rc=0
    qr_build_attempt "$log" -batchmode -projectPath "$wt" -buildTarget Android \
      -executeMethod "$QR_BUILD_METHOD" -quit -logFile "$log" || rc=$?
    [ -f "$log.stalled" ] || break
    if [ "$attempt" = 2 ]; then
      qr_log "build: no progress for $QR_BUILD_STALL_SECONDS s (last line: $(< "$log.stalled")); retry exhausted"
      rc=1; rm -f "$log.stalled"; break
    fi
    qr_log "build: no progress for $QR_BUILD_STALL_SECONDS s (last line: $(< "$log.stalled")); retrying once"
    rm -f "$log.stalled"
    mv -f "$log" "$QR_RUN_DIR/build-stalled-unity.log" 2>/dev/null || true
    attempt=2
  done
  if [ "$rc" != 0 ] || [ ! -s "$out" ]; then
    qr_set apk "build FAILED (Unity exit $rc; see build-unity.log)"
    qr_die "build failed (Unity exit $rc, apk $( [ -s "$out" ] && echo present || echo missing)); see $log"
  fi
  mkdir -p "$QR_APK_DIR"
  cp -p "$out" "$kept" || qr_die "cannot copy the APK to $kept"
  qr_set apk "$kept"
  qr_set apk_sha256 "$(qr_sha256 "$kept")"
  qr_set build_commit "$QR_SHA"
  qr_set build_apk_sha256 "$(qr_sha256 "$kept")"
  qr_step_ok build
  qr_log "build: $kept"
  printf '%s\n' "$kept"
}

# shellcheck shell=bash
# quest-release `gate`: the one retry. When every failure of the gate is in Tools/ship/known-flakes.txt, or exactly one test
# failed (listed or not), those tests rerun once (-testFilter, same categories; gate-retry.xml / gate-retry-unity.log)
# and a green rerun passes the gate. The list format and matching are linux-unity.sh's (known_flakes / is_known_flake / failed_tests in
# Tools/ship/test-passes.sh). Sourced by Tools/ship/quest-release.sh; bash 3.2 compatible.

# Config resolves an optional list to an absolute path; empty means no listed flakes.
qr_known_flakes_file() { printf '%s\n' "${QR_KNOWN_FLAKES:-}"; }

# Retry XML ($1), selected filters ($2), original XML ($3). Classify fixtures using the ORIGINAL NUnit suite
# metadata, not a dotted-name prefix. Methods require every originally failed case plus all returned matches Passed. A fixture
# must itself pass, contain Passed cases, and retain every original case (including parameterised siblings).
qr_gate_retry_coverage() {
  local original retry parsed rc=0
  original="$(qr_nunit_xml "$3")" || return 1
  retry="$(qr_nunit_xml "$1")" || return 1
  parsed="$(mktemp)" || return 1
  printf '%s\n' "$original" > "$parsed"
  perl -0777 -e '
    sub attr { my ($a, $k) = @_; return $a =~ /(?:^|\s)$k="([^"]*)"/ ? $1 : "" }
    sub unxml { my $s = shift; $s =~ s/&quot;/"/g; $s =~ s/&apos;/\x27/g; $s =~ s/&lt;/</g; $s =~ s/&gt;/>/g; $s =~ s/&amp;/&/g; $s }
    sub matches { $_[0] eq $_[1] || index($_[0], $_[1] . "(") == 0 }
    sub read_results {
      my $xml = shift;
      my (@stack, @suites, @cases);
      while ($xml =~ /<(\/?)(test-suite|test-case)\b((?:[^">]|"[^"]*")*)>/g) {
        my ($end, $tag, $a) = ($1, $2, $3);
        if ($tag eq "test-suite") {
          if ($end) { pop @stack; next }
          my $s = { name => unxml(attr($a, "fullname")), type => attr($a, "type"),
                    result => attr($a, "result"), cases => [] };
          push @suites, $s; push @stack, $s;
        } elsif (!$end) {
          my $c = { name => unxml(attr($a, "fullname")), result => attr($a, "result") };
          push @cases, $c; push @{$_->{cases}}, $c for @stack;
        }
      }
      return (\@suites, \@cases);
    }
    my @selected = split /;/, shift @ARGV;
    my $path = shift @ARGV;
    open my $fh, "<", $path or die "$path: $!";
    my ($old_suites, $old_cases) = read_results(do { local $/; <$fh> });
    my ($suites, $cases) = read_results(do { local $/; <STDIN> });
    for my $selection (@selected) {
      my @fixtures = grep { $_->{type} eq "TestFixture" && matches($_->{name}, $selection) } @$old_suites;
      # Original TestFixture metadata wins: parameterised fixture cases also match the filter prefix.
      if (!@fixtures) {
        my @matched = grep { matches($_->{name}, $selection) } @$cases;
        print "FAIL $selection: retry returned no matching Passed test case\n" unless @matched;
        for my $c (@matched) {
          print "FAIL $c->{name}: retry returned ", $c->{result} || "no result", ", expected Passed\n"
            unless $c->{result} eq "Passed";
        }
        for my $c (grep { $_->{result} eq "Failed" && matches($_->{name}, $selection) } @$old_cases) {
          print "FAIL $c->{name}: method retry omitted original failed test case\n"
            unless grep { $_->{name} eq $c->{name} && $_->{result} eq "Passed" } @matched;
        }
        next;
      }
      for my $old (@fixtures) {
        my @matched = grep { $_->{type} eq "TestFixture" && $_->{name} eq $old->{name} } @$suites;
        if (!@matched) { print "FAIL $old->{name}: retry returned no matching Passed fixture\n"; next }
        for my $suite (@matched) {
          print "FAIL $suite->{name}: retry fixture did not pass\n" unless $suite->{result} eq "Passed";
          my @children = @{$suite->{cases}};
          print "FAIL $suite->{name}: retry returned no matching Passed test case\n" unless @children;
          for my $c (@children) {
            print "FAIL $c->{name}: retry returned ", $c->{result} || "no result", ", expected Passed\n"
              unless $c->{result} eq "Passed";
          }
          for my $c (@{$old->{cases}}) {
            print "FAIL $c->{name}: fixture retry omitted original test case\n"
              unless grep { $_->{name} eq $c->{name} && $_->{result} eq "Passed" } @children;
          }
        }
      }
    }' "$2" "$parsed" <<< "$retry" || rc=$?
  rm -f "$parsed"
  return "$rc"
}

# After a failed gate run whose results are in $QR_RUN_DIR/gate.xml: $1 the test worktree, rest the Unity args of the
# first run without -testResults / -logFile. When every failure is a known flake those rerun once; otherwise only a
# single failed test (listed or not: tasks 5375, 5382) reruns once, and two or more failures with an unlisted one fail at
# once. Returns 0 when the rerun is green. The rerun writes gate-retry.xml / gate-retry-unity.log (gate.xml is kept);
# what was retried and the result go on the summary's gate line.
qr_gate_flake_retry() {
  local wt="$1" names f filter="" n=0 shown xml="$QR_RUN_DIR/gate.xml" rxml="$QR_RUN_DIR/gate-retry.xml"
  local rlog="$QR_RUN_DIR/gate-retry-unity.log" rrc=0 report totals result unlisted="" nu=0
  shift
  KNOWN_FLAKES="$(qr_known_flakes_file "$wt")"
  names="$(failed_tests "$xml")"
  [ -n "$names" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_known_flake "$f" || { unlisted="${unlisted:+$unlisted, }$f"; nu=$((nu + 1)); }
    # A parameterised case reruns as its method (-testFilter takes names, not argument lists).
    f="${f%%(*}"
    case ";$filter;" in *";$f;"*) ;; *) filter="${filter:+$filter;}$f"; n=$((n + 1)) ;; esac
  done <<EOF
$names
EOF
  shown="$(printf '%s\n' "$filter" | sed 's/;/, /g')"
  if [ "$nu" != 0 ] && [ "$(printf '%s\n' "$names" | grep -c .)" != 1 ]; then
    qr_log "gate: not known flakes ($KNOWN_FLAKES): $unlisted; with more than one failure: no retry"
    return 1
  fi
  if [ "$nu" != 0 ]; then qr_log "gate: one unlisted failure; rerunning it once: $filter (log $rlog)"
  else qr_log "gate: only known flakes failed; rerunning once: $filter (log $rlog)"; fi
  rm -f "$rxml"
  QR_UNITY_TIMEOUT="$QR_GATE_TIMEOUT" unity "$@" -testFilter "$filter" -testResults "$rxml" -logFile "$rlog" || rrc=$?
  if [ ! -s "$rxml" ]; then
    result="no results XML (Unity exit $rrc)"
  else
    if ! report="$(qr_nunit_report "$rxml")"; then
      report="0 0 1 0
FAIL retry: invalid results XML"
    fi
    totals="$(printf '%s\n' "$report" | sed -n 1p)"
    printf '%s\n' "$report" | sed -n '2,$p' > "$QR_RUN_DIR/gate-retry-failures.txt"
    qr_gate_retry_coverage "$rxml" "$filter" "$xml" >> "$QR_RUN_DIR/gate-retry-failures.txt" || \
      printf 'FAIL retry: could not verify selected test results\n' >> "$QR_RUN_DIR/gate-retry-failures.txt"
    # shellcheck disable=SC2086 # split "total passed failed skipped"
    set -- $totals
    qr_log "gate retry: $1 tests, $2 passed, $3 failed, $4 skipped (Unity exit $rrc)"
    if [ "$3" = 0 ] && [ "$1" != 0 ] && [ ! -s "$QR_RUN_DIR/gate-retry-failures.txt" ] \
      && { [ "$rrc" = 0 ] || [ "$rrc" = 2 ]; }; then
      result=passed
    else
      result="failed again"
      cat "$QR_RUN_DIR/gate-retry-failures.txt" >&2
    fi
  fi
  if [ "$nu" != 0 ] && [ "$result" = passed ]; then
    f="retried 1 unlisted failure: $shown, passed on rerun; consider adding it to known-flakes.txt or fixing it"
  elif [ "$nu" != 0 ]; then f="retried 1 unlisted failure: $shown — $result"
  elif [ "$n" = 1 ]; then f="retried 1 known flake: $shown — $result"
  else f="retried $n known flakes: $shown — $result"; fi
  qr_set gate "$(qr_get gate "") ($f)"
  if [ "$result" = passed ]; then
    qr_set gate_failures "none after the retry (first run: $(qr_get gate_failures ""))"
    qr_log "gate: flaky-passed: $shown"
    return 0
  fi
  [ -s "$QR_RUN_DIR/gate-retry-failures.txt" ] && \
    qr_set gate_failures "$(sed 's/^FAIL //' "$QR_RUN_DIR/gate-retry-failures.txt" | head -n 10 | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
  qr_log "gate: the rerun $result (see $rxml)"
  return 1
}

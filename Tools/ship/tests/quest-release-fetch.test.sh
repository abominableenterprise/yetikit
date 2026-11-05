#!/usr/bin/env bash
# Real Git + fake SSH: noninteractive prepare must preserve Git's transport precedence.
# No network, Unity, credentials or device operations. Compatible with Bash 3.2.
# shellcheck disable=SC2016 # eval assertions and the generated SSH script expand later.
set -u
ci_dir="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Tools/ship/quest-release/prepare.sh
. "$ci_dir/quest-release/prepare.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
QR_REPO="$tmp/repo" QR_WARM="$tmp/warm" QR_ROOT="$tmp/root" QR_LOGS="$tmp/logs"
mkdir -p "$QR_REPO" "$QR_WARM/Library" "$tmp/bin" "$tmp/with spaces"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_SSH_VARIANT=ssh
unset GIT_SSH_COMMAND GIT_SSH GIT_TERMINAL_PROMPT
command git -C "$QR_REPO" init -q
command git -C "$QR_REPO" remote add origin synthetic:fixture
export SSH_CAPTURE="$tmp/ssh-args"
printf '%s\n' '#!/bin/sh' 'printf "transport=%s prompt=%s\n" "$0" "$GIT_TERMINAL_PROMPT" >> "$SSH_CAPTURE"' 'printf "socket=<%s>\n" "${SSH_AUTH_SOCK-unset}" >> "$SSH_CAPTURE"' 'printf "<%s>\n" "$@" >> "$SSH_CAPTURE"' 'exit 128' > "$tmp/bin/ssh"
cp "$tmp/bin/ssh" "$tmp/with spaces/ssh-wrapper"
chmod +x "$tmp/bin/ssh" "$tmp/with spaces/ssh-wrapper"
export PATH="$tmp/bin:$PATH"
qr_state_file() { echo "$tmp/state"; }
qr_check_disk() { :; }
qr_die() { echo "$*" >&2; exit 1; }
run() { rm -f "$SSH_CAPTURE"; rc=0; ( qr_prepare origin/main ) > "$tmp/out" 2>&1 || rc=$?; }
fetch_failed_safely() {
  [ "$rc" != 0 ] && grep -q 'non-interactive.*authenticate' "$tmp/out" &&
    grep -q 'prompt=0$' "$SSH_CAPTURE" && grep -q '<BatchMode=yes>' "$SSH_CAPTURE"
}

run
check 'default SSH disables prompts' 'fetch_failed_safely && grep -q "transport=$tmp/bin/ssh " "$SSH_CAPTURE"'

command git -C "$QR_REPO" config core.sshCommand "ssh -i '$tmp/config key' -F '$tmp/ssh config'"
run
check 'core.sshCommand retains its identity and config options' \
  'fetch_failed_safely && grep -Fxq "<$tmp/config key>" "$SSH_CAPTURE" && grep -Fxq "<$tmp/ssh config>" "$SSH_CAPTURE"'

GIT_SSH="$tmp/with spaces/ssh-wrapper" run
check 'core.sshCommand takes precedence over GIT_SSH' \
  'fetch_failed_safely && grep -q "transport=$tmp/bin/ssh " "$SSH_CAPTURE" && grep -Fxq "<$tmp/config key>" "$SSH_CAPTURE"'

command git -C "$QR_REPO" config --unset core.sshCommand
GIT_SSH="$tmp/with spaces/ssh-wrapper" run
check 'GIT_SSH preserves the wrapper path including spaces' \
  'fetch_failed_safely && grep -q "transport=$tmp/with spaces/ssh-wrapper " "$SSH_CAPTURE"'

wrapper="$tmp/with spaces/ssh'wrapper"
cp "$tmp/bin/ssh" "$wrapper"
GIT_SSH="$wrapper" run
check 'GIT_SSH safely quotes apostrophes in executable paths' \
  'fetch_failed_safely && grep -Fq "transport=$wrapper " "$SSH_CAPTURE"'

command git -C "$QR_REPO" config core.sshCommand 'ssh -i /discarded/config-key'
GIT_SSH="$tmp/with spaces/ssh-wrapper" GIT_SSH_COMMAND="ssh -i '$tmp/command key'" run
check 'GIT_SSH_COMMAND takes precedence over both other transports' \
  'fetch_failed_safely && grep -q "transport=$tmp/bin/ssh " "$SSH_CAPTURE" && grep -Fxq "<$tmp/command key>" "$SSH_CAPTURE" && ! grep -q discarded "$SSH_CAPTURE"'

# OpenSSH uses the first value: merely finding BatchMode=yes in argv is insufficient.
batchmode_is_enforced_first() {
  [ "$(grep -i 'batchmode=' "$SSH_CAPTURE" | head -n1)" = '<BatchMode=yes>' ]
}
command git -C "$QR_REPO" config core.sshCommand "ssh -o BatchMode=no -i '$tmp/config key' -F '$tmp/ssh config'"
run
check 'enforced BatchMode precedes conflicting core.sshCommand options without losing them' \
  'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "<BatchMode=no>" "$SSH_CAPTURE" && grep -Fxq "<$tmp/config key>" "$SSH_CAPTURE" && grep -Fxq "<$tmp/ssh config>" "$SSH_CAPTURE"'
GIT_SSH_COMMAND="'$tmp/with spaces/ssh-wrapper' -oBatchMode=no -i '$tmp/command key' -p 2222" run
check 'enforced BatchMode precedes conflicting GIT_SSH_COMMAND options and retains the quoted wrapper' \
  'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "<-oBatchMode=no>" "$SSH_CAPTURE" && grep -Fq "transport=$tmp/with spaces/ssh-wrapper " "$SSH_CAPTURE" && grep -Fxq "<$tmp/command key>" "$SSH_CAPTURE" && grep -Fxq "<2222>" "$SSH_CAPTURE"'

# Prefix assignments belong to the transport environment, not to the injected wrapper's argv.
# Exercise both Git command sources, retaining spaces/apostrophes and conflicting caller options.
socket="$tmp/agent socket's.sock"
quoted_socket="'${socket//\'/\'\\\'\'}'"
for prefix in "env SSH_AUTH_SOCK=$quoted_socket" "SSH_AUTH_SOCK=$quoted_socket"; do
  command git -C "$QR_REPO" config core.sshCommand "$prefix '$tmp/with spaces/ssh-wrapper' -o BatchMode=no -i '$tmp/config key'"
  GIT_SSH="$tmp/unused-wrapper" run
  check "core.sshCommand preserves $prefix and enforces BatchMode first" \
    'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "socket=<$socket>" "$SSH_CAPTURE" && grep -Fq "transport=$tmp/with spaces/ssh-wrapper " "$SSH_CAPTURE" && grep -Fxq "<BatchMode=no>" "$SSH_CAPTURE" && grep -Fxq "<$tmp/config key>" "$SSH_CAPTURE"'

  command git -C "$QR_REPO" config core.sshCommand 'ssh -i /discarded/config-key'
  GIT_SSH="$tmp/unused-wrapper" GIT_SSH_COMMAND="$prefix '$tmp/with spaces/ssh-wrapper' -oBatchMode=no -i '$tmp/command key'" run
  check "GIT_SSH_COMMAND preserves $prefix and its precedence" \
    'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "socket=<$socket>" "$SSH_CAPTURE" && grep -Fq "transport=$tmp/with spaces/ssh-wrapper " "$SSH_CAPTURE" && grep -Fxq "<-oBatchMode=no>" "$SSH_CAPTURE" && grep -Fxq "<$tmp/command key>" "$SSH_CAPTURE" && ! grep -q discarded "$SSH_CAPTURE"'
done

# Assignment separators must not become shell command boundaries after wrapper injection.
for source in config command; do
  for separator in $'\n' $' \t\r\n\v\f '; do
    transport="SSH_AUTH_SOCK=$quoted_socket${separator}ssh -oBatchMode=no"
    if [ "$source" = config ]; then
      command git -C "$QR_REPO" config core.sshCommand "$transport"
      run
    else
      GIT_SSH_COMMAND="$transport" run
    fi
    check "$source consumes multiline assignment separators before wrapping SSH" \
      'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "socket=<$socket>" "$SSH_CAPTURE" && grep -Fxq "<-oBatchMode=no>" "$SSH_CAPTURE" && [ "$(grep -c "^transport=" "$SSH_CAPTURE")" = 1 ]'
  done
done

# env options and operands precede the executable, not SSH options. With -i, explicitly
# restore the fixture's capture path and Git's prompt guard into the empty environment.
for prefix in \
  "env -u SSH_ASKPASS SSH_AUTH_SOCK=$quoted_socket" \
  "env -i PATH='$PATH' SSH_CAPTURE='$SSH_CAPTURE' GIT_TERMINAL_PROMPT=0 SSH_AUTH_SOCK=$quoted_socket" \
  "env --unset=SSH_ASKPASS -- SSH_AUTH_SOCK=$quoted_socket"; do
  for source in config command; do
    transport="$prefix ssh -oBatchMode=no"
    if [ "$source" = config ]; then
      command git -C "$QR_REPO" config core.sshCommand "$transport"
      run
    else
      GIT_SSH_COMMAND="$transport" run
    fi
    check "$source consumes env options in $prefix" \
      'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "socket=<$socket>" "$SSH_CAPTURE" && grep -Fxq "<-oBatchMode=no>" "$SSH_CAPTURE"'
  done
done

for source in config command; do
  for assignment in 'SSH_AUTH_SOCK=~/.ssh/agent.sock' 'SSH_AUTH_SOCK="~/.ssh/agent.sock"'; do
    expected_socket="$HOME/.ssh/agent.sock"
    [ "$assignment" = 'SSH_AUTH_SOCK=~/.ssh/agent.sock' ] || expected_socket='~/.ssh/agent.sock'
    transport="$assignment ssh -oBatchMode=no"
    if [ "$source" = config ]; then
      command git -C "$QR_REPO" config core.sshCommand "$transport"
      run
    else
      GIT_SSH_COMMAND="$transport" run
    fi
    check "$source preserves assignment tilde semantics in $assignment" \
      'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "socket=<$expected_socket>" "$SSH_CAPTURE"'
  done
done

# Complex assignment expansions must either be parsed whole or rejected before SSH runs.
# These cases deliberately use rejection: no command text may silently become expansion data.
unset SSH_AUTH_SOCK
for source in config command; do
  for assignment in \
    'SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-/tmp/agent socket}' \
    'SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-${OTHER_SOCK:-"/tmp/nested agent socket"}}' \
    'SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-${OTHER_SOCK:-"/tmp/nested agent socket"}}"' \
    'SSH_AUTH_SOCK=$(printf "/tmp/agent socket")' \
    'SSH_AUTH_SOCK=`printf "/tmp/agent socket"`'; do
    transport="$assignment ssh -oBatchMode=no"
    if [ "$source" = config ]; then
      command git -C "$QR_REPO" config core.sshCommand "$transport"
      run
    else
      GIT_SSH_COMMAND="$transport" run
    fi
    check "$source rejects unsupported assignment expansion: $assignment" \
      '[ "$rc" != 0 ] && grep -q "unsupported SSH assignment syntax" "$tmp/out" && [ ! -e "$SSH_CAPTURE" ]'
  done
  # Literal quoted expansion text is supported and must not be evaluated by the scanner.
  expected_socket='${SSH_AUTH_SOCK:-/tmp/agent socket}'
  transport="SSH_AUTH_SOCK='$expected_socket' ssh -oBatchMode=no"
  if [ "$source" = config ]; then
    command git -C "$QR_REPO" config core.sshCommand "$transport"
    run
  else
    GIT_SSH_COMMAND="$transport" run
  fi
  check "$source keeps single-quoted expansion text literal" \
    'fetch_failed_safely && batchmode_is_enforced_first && grep -Fxq "socket=<$expected_socket>" "$SSH_CAPTURE"'
  # The transport has an absolute executable, so its restricted PATH need not contain env.
  transport="PATH='$tmp/with spaces' '$tmp/with spaces/ssh-wrapper' -oBatchMode=no"
  if [ "$source" = config ]; then
    command git -C "$QR_REPO" config core.sshCommand "$transport"
    run
  else
    GIT_SSH_COMMAND="$transport" run
  fi
  check "$source resolves env before applying a transport-specific PATH" \
    'fetch_failed_safely && batchmode_is_enforced_first && grep -Fq "transport=$tmp/with spaces/ssh-wrapper " "$SSH_CAPTURE"'
done

check 'transport overrides remain local to fetch' \
  '[ "${GIT_SSH_COMMAND-unset}" = unset ] && [ "${GIT_SSH-unset}" = unset ] && [ "${GIT_TERMINAL_PROMPT-unset}" = unset ]'
[ "$fails" = 0 ] || { echo "$fails failures"; exit 1; }

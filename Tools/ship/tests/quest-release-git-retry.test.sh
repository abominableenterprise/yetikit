#!/usr/bin/env bash
# Fake Git only: no network, credentials or worktrees.
set -eu
ship="$(cd "$(dirname "$0")/.." && pwd)"
. "$ship/quest-release.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export QR_REPO="$tmp/repo" TRACE="$tmp/trace"
mkdir -p "$QR_REPO" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TRACE"
if [[ "$SCENARIO" = recover || "$SCENARIO" = ssh-reset ]] && [ "$(wc -l < "$TRACE")" -eq 2 ]; then
  echo 'final stdout'
  exit 0
fi
case "$SCENARIO" in
  ssh-reset) echo 'kex_exchange_identification: read: Connection reset by peer' >&2 ;;
  ssh-denied) echo 'kex_exchange_identification: banner line 0: Permission denied' >&2 ;;
  auth) echo 'git@fixture.invalid: Permission denied (publickey).' >&2 ;;
  conflict) echo 'error: Pulling is not possible because you have unmerged files.' >&2 ;;
  no-ref) exit 2 ;; # ls-remote --exit-code found no matches
  *) echo "fatal: unable to access 'https://fixture.invalid/': Failed to connect to fixture.invalid: Connection timed out" >&2 ;;
esac
exit 128
GIT
chmod +x "$tmp/bin/git"
# Verify the requested backoff without wall-clock sleeps.
sleep() { printf '%s\n' "$1" >> "$tmp/sleeps"; }
run() {
  local scenario="$1"; shift
  : > "$TRACE"; : > "$tmp/sleeps"
  rc=0
  SCENARIO="$scenario" qr_git "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
}
for verb in fetch pull ls-remote; do
  run recover "$verb" origin
  [ "$rc" = 0 ] && [ "$(wc -l < "$TRACE")" -eq 2 ] && [ "$(cat "$tmp/out")" = 'final stdout' ] \
    && [ "$(cat "$tmp/sleeps")" = 1 ] && grep -q 'retrying' "$tmp/err" || exit 1
  run persist "$verb" origin
  [ "$rc" = 128 ] && [ "$(wc -l < "$TRACE")" -eq 3 ] && [ "$(cat "$tmp/sleeps")" = $'1\n2' ] \
    && grep -q '3 attempts' "$tmp/err" && grep -q 'Connection timed out' "$tmp/err" || exit 1
  echo "ok $verb recovers once and reports persistence after three attempts"
done
run ssh-reset fetch --quiet origin
[ "$rc" = 0 ] && [ "$(wc -l < "$TRACE")" -eq 2 ] && [ "$(cat "$tmp/out")" = 'final stdout' ] \
  && [ "$(cat "$tmp/sleeps")" = 1 ] && grep -q 'retrying' "$tmp/err" \
  || { echo 'FAIL SSH key-exchange reset did not retry'; exit 1; }
echo 'ok SSH key-exchange reset retries once'
for scenario in ssh-denied auth conflict no-ref; do
  case "$scenario" in
    auth|ssh-denied) run "$scenario" fetch origin; expected=128 ;;
    conflict) run conflict pull; expected=128 ;;
    no-ref) run no-ref ls-remote --exit-code origin refs/heads/absent; expected=2 ;;
  esac
  [ "$rc" = "$expected" ] && [ "$(wc -l < "$TRACE")" -eq 1 ] && [ ! -s "$tmp/sleeps" ] || exit 1
  echo "ok $scenario fails without retry"
done
run persist status
[ "$rc" = 128 ] && [ "$(wc -l < "$TRACE")" -eq 1 ] && [ ! -s "$tmp/sleeps" ]

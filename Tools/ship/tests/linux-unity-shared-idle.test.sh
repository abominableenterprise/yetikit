#!/usr/bin/env bash
# Shared-ULF regressions: stub clients and marked sleeping processes only, no real credentials/Unity.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="${SHARED_IDLE_TEST_SCRIPT:-$repo/Tools/ship/linux-unity.sh}"
tmp="$(mktemp -d)"; children=()
cleanup() {
  for p in "${children[@]}"; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  if [ -f "$tmp/launch-pids" ]; then
    while read -r p; do kill "$p" 2>/dev/null || true; done < "$tmp/launch-pids"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0; proj="$tmp/a"; mkdir -p "$proj" "$tmp/b" "$tmp/licence"
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
mv "$ULF" "$tmp/licence/real.ulf"
ln -s "$tmp/licence" "$tmp/licence-alias"
export ULF="$tmp/licence/real.ulf" OUT_DIR="$tmp/a/build"
. "$script"
IDLE_SCRIPT="$script"; UNITY_IDLE_RETURN_MINUTES=0
mkdir -p "$OUT_DIR"
# A publishes release-capable ownership. A fake launcher remains live, without running a watcher.
cat > "$tmp/bin/nohup" <<'EOF'
#!/bin/bash
echo $$ >> "$FAKE_TMP/launch-pids"
exec /bin/sleep 300
EOF
chmod +x "$tmp/bin/nohup"
UNITY_USERNAME=stub-user; UNITY_PASSWORD=stub-password
THEROBOTS_HUB_URL=hub-origin; THEROBOTS_TASK_ID=owner-a; THEROBOTS_TASK_TOKEN=stub-token-a
printf '%s %s\n' "$THEROBOTS_TASK_ID" "$$" > "$SEAT_STATE"
idle_begin; idle_finish
read -r launcher _ < "$IDLE_LAUNCH"; children+=("$launcher")
context_a="$(cat "$IDLE_CONTEXT")"
# A genuinely separate shell/OUT_DIR, using a canonical-path alias of the same ULF.
cat > "$tmp/command" <<'EOF'
#!/bin/bash
set -euo pipefail
. "$1"
idle_begin
if [ "$2" = begin ]; then
  printf '%s %s\n' "$IDLE_CONTEXT" "$IDLE_ACTIVE" > "$3"
  exec /bin/sleep 300
fi
idle_finish
EOF
ULF="$tmp/licence-alias/real.ulf" OUT_DIR="$tmp/b/build" \
  THEROBOTS_TASK_ID=owner-b THEROBOTS_TASK_TOKEN=stub-token-b \
  bash "$tmp/command" "$script" begin "$tmp/b-paths" & b=$!; children+=("$b")
# Separate shells validate/load config before publishing readiness.
for _ in {1..2000}; do [ -s "$tmp/b-paths" ] && break; /bin/sleep 0.01; done
read -r b_context b_active < "$tmp/b-paths"
check 'canonical ULF aliases and distinct checkouts share activity and context' \
  '[ "$b_active" = "$IDLE_ACTIVE" ] && [ "$b_context" = "$IDLE_CONTEXT" ]'
# A finishes its wrapper; only B is active. First poll must not return the global licence.
# Retire B on the second poll so even the old implementation terminates boundedly.
rm -f "$IDLE_ACTIVE/$$:$(proc_start "$$")"
(
  tick=0
  sleep() {
    tick=$((tick + 1)); [ "$tick" -le 3 ] || exit 90
    if [ "$tick" = 2 ]; then kill "$b"; wait "$b" 2>/dev/null || true; fi
  }
  cmd_return() { echo "$tick" > "$tmp/returned-at"; rm -f "$ULF"; }
  idle_watch
)
check 'A watcher cannot return while B command is alive' '[ "$(cat "$tmp/returned-at")" = 2 ]'
kill "$b" 2>/dev/null || true; wait "$b" 2>/dev/null || true

# B finishing a command must not orphan A's checkout-local persisted seat.
printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
printf '%s %s %s\n' "$launcher" "$(proc_start "$launcher")" "$context_a" > "$IDLE_LAUNCH"
ULF="$tmp/licence-alias/real.ulf" OUT_DIR="$tmp/b/build" \
  UNITY_USERNAME=stub-user UNITY_PASSWORD=stub-password \
  THEROBOTS_HUB_URL=hub-origin THEROBOTS_TASK_ID=owner-b THEROBOTS_TASK_TOKEN=stub-token-b \
  bash "$tmp/command" "$script" finish
check 'B preserves live A release context and original seat marker' \
  '[ "$(cat "$IDLE_CONTEXT")" = "$context_a" ] && seat_held'
# Shared watcher lock: B cannot run a second foreground watcher while A holds it.
# Allow config startup; a duplicate must still exit 0 without returning the ULF.
(
  exec 8> "${IDLE_PID%.pid}.lock"; flock -x 8
  rc=0
  OUT_DIR="$tmp/b/build" ULF="$tmp/licence-alias/real.ulf" DUPLICATE_RETURN="$tmp/duplicate-return" \
    timeout -k 1 20 bash -c '. "$1"; sleep() { :; }; cmd_return() { echo wrong > "$DUPLICATE_RETURN"; rm -f "$ULF"; }; idle_watch' \
    _ "$script" || rc=$?
  echo "$rc" > "$tmp/duplicate-status"
)
check 'watcher lock is shared across checkouts' \
  '[ ! -e "$tmp/duplicate-return" ] && [ "$(cat "$tmp/duplicate-status")" = 0 ]'
# Explicit foreign return must never release A with B's token. Once the ULF is
# gone, A's watcher still releases its own seat (including when it starts after removal).
(
  THEROBOTS_TASK_ID=owner-b; THEROBOTS_TASK_TOKEN=stub-token-b
  seat_post() { echo wrong > "$tmp/wrong-release"; }
  seat_release
)
check 'foreign task cannot release original seat' '[ ! -e "$tmp/wrong-release" ] && seat_held'
# Use the real return path with a stub licensing client, not only helper calls.
printf '#!/bin/bash\necho "$1" >> "$FAKE_TMP/shared-client-calls"\n' > "$tmp/shared-client"
chmod +x "$tmp/shared-client"
(
  THEROBOTS_TASK_ID=owner-b; THEROBOTS_TASK_TOKEN=stub-token-b
  SEAT_STATE="$tmp/b/build/unity-seat.held"; LC="$tmp/shared-client"
  seat_post() { echo wrong > "$tmp/wrong-release"; }
  cmd_return
)
check 'foreign explicit return uses stub client but never releases with wrong owner token' \
  '[ ! -f "$ULF" ] && [ ! -e "$tmp/wrong-release" ] && seat_held && [ "$(cat "$tmp/shared-client-calls")" = --return-ulf ]'
(
  IDLE_WATCH_CONTEXT="$context_a"
  seat_post() { echo "$THEROBOTS_TASK_ID $1" > "$tmp/released"; SEAT_CODE=200; }
  idle_watch
)
check 'owner watcher releases original seat even if another checkout removed ULF' \
  '[ "$(cat "$tmp/released" 2>/dev/null)" = "owner-a release" ] && [ ! -f "$SEAT_STATE" ]'
# A foreign explicit return requests retirement, then A re-acquires before its
# old watcher polls. That watcher must not release A's newer acquisition.
if declare -F idle_retire_owner >/dev/null; then
  printf '%s %s\n' owner-a 111 > "$SEAT_STATE"
  printf '%s\n' "$context_a" > "$IDLE_CONTEXT"
  printf '%s\n' owner-a > "$IDLE_OWNER"
  printf '%s\n' "$SEAT_STATE" > "$IDLE_SEAT"
  (THEROBOTS_TASK_ID=owner-b; idle_retire_owner)
  printf '%s %s\n' owner-a 222 > "$SEAT_STATE"
  printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
  (
    IDLE_WATCH_CONTEXT="$context_a"
    seat_post() { echo wrong > "$tmp/new-seat-released"; SEAT_CODE=200; }
    idle_watch
  )
  check 'late retirement cannot release a newer acquisition by the same task' \
    '[ ! -e "$tmp/new-seat-released" ] && [ "$(cat "$SEAT_STATE")" = "owner-a 222" ] && [ -f "$ULF" ]'
  # Same-task reactivation settles an outstanding old request before acquire;
  # acquisition identity is part of the context, so the old watcher retires.
  (THEROBOTS_TASK_ID=owner-b; idle_retire_owner)
  (
    activation_lock
    seat_post() { echo "$THEROBOTS_TASK_ID $1" >> "$tmp/settled"; SEAT_CODE=200; }
    idle_settle_own_retirement
    activation_unlock
  )
  printf '%s %s\n' owner-a 333 > "$SEAT_STATE"
  check 'same-task reactivation settles old seat and changes watcher context' \
    '[ "$(cat "$tmp/settled")" = "owner-a release" ] && [ "$(idle_context)" != "$context_a" ]'
fi
# A foreign waiter must not hold the activation lock while polling for A's
# retiring seat. Run the real curl parser; sleep drives A's watcher boundedly.
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
body='' headers='' action=''
while [ "$#" -gt 0 ]; do
  case "$1" in -o) body="$2"; shift ;; -D) headers="$2"; shift ;; -d) action="$2"; shift ;; esac
  shift
done
cat >/dev/null
printf 'Retry-After: 1\r\n' > "$headers"
if [[ "$action" = *release* ]]; then
  echo "$THEROBOTS_TASK_ID release" >> "$FAKE_TMP/waiter-releases"
  [ "$THEROBOTS_TASK_ID" != owner-a ] || touch "$FAKE_TMP/owner-released"
  printf '{}' > "$body"; printf 200
elif [ -f "$FAKE_TMP/owner-released" ]; then
  printf '{"status":"acquired"}' > "$body"; printf 200
else
  printf '{}' > "$body"; printf 202
fi
EOF
chmod +x "$tmp/bin/curl"
rm -f "$ULF"
printf '%s %s\n' owner-a 444 > "$SEAT_STATE"
printf '%s\n' "$context_a" > "$IDLE_CONTEXT"
printf '%s\n' owner-a > "$IDLE_OWNER"
printf '%s\n' "$SEAT_STATE" > "$IDLE_SEAT"
(THEROBOTS_TASK_ID=owner-b; idle_retire_owner)
waiter_rc=0
(
  trap - EXIT # cmd_activate chains EXIT; do not inherit the fixture's directory cleanup.
  owner_state="$SEAT_STATE"
  THEROBOTS_TASK_ID=owner-b; THEROBOTS_TASK_TOKEN=stub-token-b
  SEAT_STATE="$tmp/b/build/unity-seat.held"; LC="$tmp/shared-client"
  SEAT_OWNED=0; SEAT_PENDING=0; SEAT_PERSISTED=0; polls=0
  sleep() {
    polls=$((polls + 1)); [ "$polls" -le 3 ] || exit 90
    IDLE_WATCH_CONTEXT="$context_a" THEROBOTS_HUB_URL="$THEROBOTS_HUB_URL" \
      THEROBOTS_TASK_ID=owner-a THEROBOTS_TASK_TOKEN=stub-token-a \
      SEAT_STATE="$owner_state" timeout -k 1 20 bash -c '. "$1"; idle_watch' _ "$script" || exit "$?"
  }
  activate_client() {
    printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
  }
  cmd_activate
) > "$tmp/waiter.log" 2>&1 || waiter_rc=$?
check 'retired owner watcher releases its seat while a foreign activation polls' \
  '[ "$waiter_rc" = 0 ] && [ -f "$ULF" ] && [ "$(cat "$tmp/waiter-releases")" = "owner-a release" ] && [ ! -f "$SEAT_STATE" ] && [ "$(cut -d" " -f1 "$tmp/b/build/unity-seat.held")" = owner-b ]'
(
  trap - EXIT
  seat_acquire() { touch "$tmp/reuse-acquired"; }
  LC="$tmp/shared-client"
  cmd_activate
)
check 'valid shared ULF reuse never acquires a seat' '[ ! -f "$tmp/reuse-acquired" ]'
check 'shared metadata contains no plaintext credentials' \
  '! grep -rE "stub-user|stub-password|stub-token" "$(dirname "$IDLE_CONTEXT")"'
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }

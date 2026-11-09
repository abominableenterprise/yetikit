# shellcheck shell=bash
# quest-release `verify <apk>`: the launcher contract (Tools/ship/android-launcher.py), the signer certificate and the
# APK's SHA-256. Sourced by Tools/ship/quest-release.sh.

# Point ANDROID_SDK_ROOT at the editor's Android SDK when it is unset (android-launcher.py reads aapt from it).
qr_android_sdk() {
  if [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    local proj="$QR_REPO" d
    [ -n "${QR_SHORT:-}" ] && [ -d "$(qr_wt build)" ] && proj="$(qr_wt build)"
    d="$(qr_editor_dir "$proj")" || return 1
    ANDROID_SDK_ROOT="$(qr_unity_contents "$d")/PlaybackEngines/AndroidPlayer/SDK"
    export ANDROID_SDK_ROOT
    qr_log "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
  fi
}

# The apksigner of the SDK's newest build-tools; returns 1 when there is none.
qr_apksigner_path() {
  local bt
  bt="$(find "$ANDROID_SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
  [ -n "$bt" ] && [ -x "$ANDROID_SDK_ROOT/build-tools/$bt/apksigner" ] || return 1
  printf '%s\n' "$ANDROID_SDK_ROOT/build-tools/$bt/apksigner"
}

# apksigner from the SDK's newest build-tools (tests replace this function).
apksigner() {
  local bin
  bin="$(qr_apksigner_path)" || { qr_log "no apksigner under $ANDROID_SDK_ROOT/build-tools"; return 127; }
  "$bin" "$@"
}

# Lowercase hex without colons or spaces.
qr_norm_hex() { printf '%s\n' "$1" | tr -d ':[:space:]' | tr 'A-F' 'a-f'; }

# The folder Gradle/AGP takes debug.keystore from. The build passes it explicitly (and drops XDG_CONFIG_HOME), since
# with ANDROID_USER_HOME unset AGP prefers $XDG_CONFIG_HOME/.android, a different key from a fish login shell.
qr_android_user_home() { printf '%s\n' "${ANDROID_USER_HOME:-$HOME/.android}"; }

qr_require_certificate() {
  local cert
  cert="$(qr_norm_hex "${QUEST_CERT_SHA256:-}")"
  [[ "$cert" =~ ^[0-9a-f]{64}$ ]] || qr_die "QUEST_CERT_SHA256 must supply the expected signer SHA-256 (64 hex digits)"
  QR_CERT_SHA256="$cert"
}

# Before the long gate/build: check the signing certificate the resulting APK must use.
# Debug-only discovery failures retain the historical warning behavior; custom signing fails closed.
qr_keystore_preflight() {
  local ks want got rc=0
  qr_require_certificate
  qr_signing_resolve || qr_die "keystore preflight: $QR_SIGNING_ERROR"
  ks="$QR_KEYSTORE_LABEL"
  want="$(qr_norm_hex "$QR_CERT_SHA256")"
  got="$(qr_keystore_check "$QR_KEYSTORE_PATH" "$QR_KEYSTORE_ALIAS" "$QR_KEYSTORE_PASS_ENV")" || rc=$?
  if [ -n "${QR_SIGNING_PATH_ENV:-}" ] && [ "$rc" != 0 ]; then
    qr_set apk "not built: $ks failed certificate check"
    case "$rc" in
      1) qr_die "keystore preflight: $ks has certificate SHA-256 $got, not the expected $want (QUEST_CERT_SHA256)" ;;
      2) qr_die "keystore preflight: file named by $QR_SIGNING_PATH_ENV is missing" ;;
      3) qr_die "keystore preflight: $ks not checked: no keytool on PATH" ;;
      *) qr_die "keystore preflight: keytool could not read $ks (check $QR_SIGNING_PASS_ENV and $QR_SIGNING_ALIAS_ENV)" ;;
    esac
  fi
  case "$rc" in
    2) qr_log "keystore preflight: no $ks yet (Gradle creates it); verify checks the APK signer"; return 0 ;;
    3) qr_log "keystore preflight: no keytool on PATH; skipped (verify checks the APK signer)"; return 0 ;;
    4) qr_log "keystore preflight: keytool could not read $ks; skipped (verify checks the APK signer)"; return 0 ;;
  esac
  if [ "$rc" != 0 ]; then
    qr_set apk "not built: $ks has certificate ${got:0:16}..., expected ${want:0:16}..."
    qr_die "keystore preflight: $ks has certificate SHA-256 $got, not the expected $want (QUEST_CERT_SHA256); an APK signed with it cannot install over the headset's app without an uninstall. Set ANDROID_USER_HOME to the folder with the right debug.keystore"
  fi
  qr_log "keystore preflight: $ks matches the expected certificate (${got:0:16}...)"
}

qr_verify() {
  local apk="${1:-}" want got sha rc=0
  qr_require_certificate
  [ -n "$apk" ] || apk="$(qr_get apk "")"
  [ -f "$apk" ] || qr_die "verify: no APK at '${apk}'"
  qr_android_sdk || qr_die "verify: cannot find the Android SDK; set ANDROID_SDK_ROOT"
  if ! python3 "$QR_SHIP_DIR/android-launcher.py" --config "$QR_CONFIG_FILE" "$apk" > "$QR_RUN_DIR/verify-launcher.log" 2>&1; then
    cat "$QR_RUN_DIR/verify-launcher.log" >&2
    qr_set cert "not checked (launcher check FAILED)"
    qr_die "verify: android-launcher.py rejected $apk"
  fi
  qr_log "verify: launcher contract ok"
  want="$(qr_norm_hex "$QR_CERT_SHA256")"
  apksigner verify --print-certs "$apk" > "$QR_RUN_DIR/verify-apksigner.log" 2>&1 || rc=$?
  got="$(sed -n 's/^Signer #1 certificate SHA-256 digest:[[:space:]]*//p' "$QR_RUN_DIR/verify-apksigner.log" | head -n1)"
  got="$(qr_norm_hex "$got")"
  sha="$(qr_sha256 "$apk")"
  qr_set apk "$apk"
  qr_set apk_sha256 "$sha"
  printf 'apk sha256: %s\n' "$sha"
  if [ "$rc" != 0 ] || [ -z "$got" ]; then
    qr_set cert "FAILED (apksigner exit $rc; see verify-apksigner.log)"
    qr_die "verify: apksigner could not verify $apk"
  fi
  if [ "$got" != "$want" ]; then
    qr_set cert "MISMATCH: signer $got, expected $want"
    qr_die "verify: signer certificate $got is not the expected $want (QUEST_CERT_SHA256)"
  fi
  qr_set cert "ok (launcher contract + signer ${got:0:16}...)"
  qr_step_ok verify
  qr_log "verify: signer certificate ok"
}

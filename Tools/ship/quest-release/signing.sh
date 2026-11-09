# shellcheck shell=bash
# Resolve signing inputs only for build/doctor, never for a prebuilt APK. Config contains variable names only.
# Errors name the source variable, never its value (including keystore paths and aliases).
qr_signing_resolve() {
  local name
  if [ -z "${QR_SIGNING_PATH_ENV:-}" ]; then
    QR_KEYSTORE_PATH="$(qr_android_user_home)/debug.keystore"
    QR_KEYSTORE_ALIAS=androiddebugkey
    QR_KEYSTORE_PASS_ENV=QR_DEBUG_STORE_PASS
    QR_KEYSTORE_LABEL="$QR_KEYSTORE_PATH"
    return 0
  fi
  for name in "$QR_SIGNING_PATH_ENV" "$QR_SIGNING_PASS_ENV" "$QR_SIGNING_ALIAS_ENV" "${QR_SIGNING_KEY_PASS_ENV:-}"; do
    [ -n "$name" ] || continue
    if [ -z "${!name:-}" ]; then
      QR_SIGNING_ERROR="signing environment variable $name is unset or empty"
      return 1
    fi
  done
  if [ ! -f "${!QR_SIGNING_PATH_ENV}" ]; then
    QR_SIGNING_ERROR="keystore file named by $QR_SIGNING_PATH_ENV is missing"
    return 1
  fi
  QR_KEYSTORE_PATH="${!QR_SIGNING_PATH_ENV}"
  QR_KEYSTORE_ALIAS="${!QR_SIGNING_ALIAS_ENV}"
  QR_KEYSTORE_PASS_ENV="$QR_SIGNING_PASS_ENV"
  QR_KEYSTORE_LABEL="keystore from $QR_SIGNING_PATH_ENV"
}

# $1 path, $2 alias, $3 password environment-variable name. Keytool auto-detects PKCS12 and JKS.
# Print only the SHA-256, never keytool diagnostics (which can include sensitive input).
# Returns 0 match, 1 another certificate, 2 missing file, 3 missing keytool, 4 unreadable.
qr_keystore_check() {
  local got
  # Scope the public debug password to keytool, not the consumer editor's environment.
  if [ -z "${QR_SIGNING_PATH_ENV:-}" ]; then
    local QR_DEBUG_STORE_PASS=android
    export QR_DEBUG_STORE_PASS
  fi
  qr_require_certificate
  [ -f "$1" ] || return 2
  command -v keytool >/dev/null 2>&1 || return 3
  got="$(keytool -list -v -keystore "$1" -storepass:env "$3" -alias "$2" < /dev/null 2>/dev/null)" || return 4
  got="$(printf '%s\n' "$got" | sed -n 's/^[[:space:]]*SHA-\{0,1\}256:[[:space:]]*//p' | head -n1)"
  got="$(qr_norm_hex "$got")"
  [ -n "$got" ] || return 4
  printf '%s\n' "$got"
  [ "$got" = "$(qr_norm_hex "$QR_CERT_SHA256")" ] || return 1
}

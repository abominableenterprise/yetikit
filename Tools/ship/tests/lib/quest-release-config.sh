# shellcheck shell=bash
# Synthetic consumer configuration. Call after creating the suite's temp directory.
qr_test_config() {
  local directory="$1"
  mkdir -p "$directory"
  export YETIKIT_CONFIG="$directory/yetikit.json"
  unset PROJECT
  export QUEST_SERIAL=synthetic-device
  # Deliberately synthetic fingerprint, never a shipped signing identity.
  export QUEST_CERT_SHA256='00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF'
  printf '%s\n' '{
  "schema": 1,
  "unityVersion": "6000.6.6f1",
  "build": {
    "devMethod": "Synthetic.Editor.Build.DevelopmentApk",
    "releaseMethod": "Synthetic.Editor.Build.ReleaseApk",
    "apkPath": "Builds/Android/consumer-dev.apk"
  },
  "knownFlakes": "Tools/ship/known-flakes.txt",
  "quest": {
    "package": "com.example.consumer",
    "apkKeepName": "consumer-dev-{sha}.apk",
    "perfLogTag": "[SyntheticPerf]",
    "launcherChecks": {"permissions": [], "assets": []}
  }
}' > "$YETIKIT_CONFIG"
}

# Direct module tests bypass qr_config; supply the same public inputs explicitly.
qr_test_build_config() {
  QR_UNITY_VERSION=6000.6.6f1
  QR_BUILD_METHOD=Synthetic.Editor.Build.DevelopmentApk
  QR_APK_KEEP_NAME='consumer-dev-{sha}.apk'
  QR_WHATS_NEW_ENV=YETIKIT_WHATS_NEW
  QR_PREV_SHA_ENV=YETIKIT_PREV_SHA
}

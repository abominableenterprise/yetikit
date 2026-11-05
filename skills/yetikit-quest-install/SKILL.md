---
name: yetikit-quest-install
description: Safely install and verify a development APK on a Quest attached to a Mac; use before device install, launch or log collection.
---
# Quest development install

Ship is planned here. Use the consumer's tagged `Tools/yetikit/quest-release.sh`
and its help/configuration; do not invent a transport or bypass device locking.

1. Reserve the headset through the task hub using its current device entry.
   Check for an identical queued/running task: **one pending install at a time**.
   Touch only the game's configured package. Keep the Mac awake and on power.
2. Run `Tools/yetikit/quest-release.sh doctor` **first**, before a build. Check
   Java, signing tools/key, editor version, disk, device authorization and lock.
   Prefer USB-C. If absent/offline, stop with one combined human-action request;
   no reconnection loops. Never run adb outside the reserved device task.
3. Confirm it is a Quest and select it explicitly; never use bare adb with
   multiple devices. Read the mounted state: clean `sys.hmt.mounted=0` means
   not worn, `1` means worn. Otherwise inspect only the current `State:` in
   `dumpsys vrpowermanager`, not transition history. **Do not install while worn**;
   unknown state blocks installation until a manual not-worn check. Do not
   override a known worn state or rely on a stale focus result.
4. Retain the **last good APK** for rollback. Verify candidate APK SHA-256,
   expected versionCode and signer with the release verifier; compare its signer
   SHA-256 to the installed app before replacement. Mac/Linux debug keys may
   differ. Use one securely managed game signing key across build machines.
   A signer mismatch is a stop, never a reason to uninstall.
5. Back up game data privately with hashes; do not print upload configuration
   or keys. Save any existing playtest logcat **before** a launcher clears it.
   Use only `adb -s <reserved-device> install -r <apk>` through the approved
   release procedure. **Never uninstall, `pm clear`, or clear app data**. Do not
   change runtime permissions to make an install pass.
6. For a background release, start `Tools/yetikit/quest-release.sh all` with a
   log and the installed runner's rollback option. Make **ONE** blocking call
   `Tools/yetikit/quest-release.sh wait 28` (or less), timeout longer than its
   wait. No sleep-poll loops. Exit 124 means still pending: report the run and
   hand off monitoring; do not stack a second install or another wait call.
7. After installation, verify the **installed** versionCode and signer match
   the candidate, and data hashes/permissions remain intact. APK verification
   alone does not prove installed identity. Match runtime build/kit stamps too.
8. Launch through the configured release launcher. Save logcat immediately to
   a private file, inspect Unity/FATAL/AndroidRuntime errors and check process
   liveness. Report XR shell warnings; a live process alone is not proof of
   presentation. Keep performance claims limited to the device actually tested.
9. If rollback is needed, recheck idle state and signer; preserve data with a
   supported same-signer update. Use `install -r -d` only where downgrade is
   supported; otherwise build the previous code with a higher versionCode.
   Never uninstall as a workaround. Report commit/build, APK digest, signer
   prefix, idle verdict, installed identity, backup location and launch findings.

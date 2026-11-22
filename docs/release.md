# Kit release checklist

Include the following gates in the release PR brief and record their results in
that PR before tagging:

- [ ] Resolve core-only, playtest-only and full-XR manifests from an empty cache.
- [ ] Run `Tools/ci/release-consumer-check.sh` from the candidate checkout on
  Linux and record the candidate SHA, result and APK SHA-256 printed by Ship.
  Use [Ship](../Tools/ship/README.md) to set up Android support and activate the
  Unity seat first:

  ```sh
  PROJECT="$PWD/Host" Tools/ship/linux-unity.sh setup --android
  PROJECT="$PWD/Host" Tools/ship/linux-unity.sh activate
  Tools/ci/release-consumer-check.sh
  ```

  The gate uses the [advertised modules](../README.md#modules) and their
  declared dependencies, not the Host or starter package list. Unity resolves
  them and attempts one Android development APK build with `YETIKIT_DEV`.
  A compilation error or missing APK blocks the release. Inspect `build/apk.log`
  under the printed temporary project path. Delete the temporary project after
  collecting evidence and return the Unity seat after the final verification:

  ```sh
  PROJECT="$PWD/Host" Tools/ship/linux-unity.sh return
  ```

The [lexical dependency check](../Tools/ci/check-package-closure.py) still runs
in regular CI. The Android build runs for release candidates only; a single
combined build does not prove that each package also builds in isolation.

# Quality

Editor-only, opt-in validators. Reference `YetiKit.Quality.Editor` from the
consumer's Editor/test asmdefs; it is not auto-referenced and has no runtime or
core dependency. Add this package to the project's `testables` to run its own
synthetic regression tests. No game catalog, scene edits or asset repairs occur.

## Asset and placement API

- `MissingScriptScan.Find(IEnumerable<string> assetPaths)` returns tuples
  `(assetPath, gameObjectPath, componentIndex)`. Prefabs/models and scenes are
  supported, including inactive descendants. An explicit prefab/model path that
  cannot be loaded throws an actionable error rather than silently passing.
  Component indices include Transform.
  Scenes open in isolated preview scenes and close in `finally`; loaded scenes
  are not replaced or saved. `FindInFolders(params string[] folders)` searches
  existing AssetDatabase folders. Pass explicit folders, not an empty array.
- `GuidCollisionCheck.Find(params string[] roots)` reads all `.meta` text files
  recursively without importing. Returns `(guid, paths[])` with normalized,
  absolute paths; overlapping roots do not double-count files. GUID comparison
  is case-insensitive. Include both consumer assets and the kit checkout to catch
  migration copies. Missing directories throw rather than silently pass.
- `PlacementCheck.Check(GameObject prefabOrModel, PlacementSpec spec)` returns
  `lowestPerQuadrant`, `maxGap`, `forwardErrorDegrees`, `Pass` and `Reason`.
  Zero/default `forward` means +Z, zero/default `tolerance` means 0.02 metres;
  negative or non-finite specs fail. Positive tolerance overrides the default.
  Lowest points in all four XZ quadrants must meet the root pivot's y=0 plane.
  Child transforms and inactive meshes count; root placement/scale is ignored.
  Work in metre-authored model space, not world-space terrain grounding.

**Facing contract:** each mesh transform's +Z is its authored forward axis, and
must match `spec.forward` in root-local space within one degree. A mesh child
rotated 180 degrees fails a +Z declaration. Geometry alone cannot identify a
semantic front; backwards geometry baked into unchanged axes is not detectable.
Use consistently oriented mesh nodes or validate a dedicated model subtree.

With `trunkRim = true`, the highest of 12 angular-sector minima must meet the
plane; lower roots may penetrate it. Every sector needs vertices. This generic
API does not infer a trunk radius or separate foliage from roots: pass a
base-only model if overhangs pollute the measurement. `lowestPerQuadrant` still
reports ordinary quadrant minima; `maxGap` uses the rim metric in this mode.
Skinned meshes use undeformed shared geometry, not an animated pose.

## Three consumer EditMode tests

Replace the example folders and prefab list with the consumer's own inventory.
Use a test asmdef referencing `YetiKit.Quality.Editor` and the Unity test runners.

```csharp
using NUnit.Framework;
using UnityEditor;
using YetiKit.Quality.Editor;

public class ContentQualityTests
{
    [Test] public void ScriptsArePresent() =>
        Assert.IsEmpty(MissingScriptScan.FindInFolders("Assets/Prefabs", "Assets/Scenes"));

    [Test] public void GuidsAreUnique() =>
        Assert.IsEmpty(GuidCollisionCheck.Find("Assets", "Packages"));

    [Test] public void PropsMeetTheirPlacementContract()
    {
        foreach (var path in new[] { "Assets/Prefabs/Bench.prefab" })
        {
            var model = AssetDatabase.LoadAssetAtPath<UnityEngine.GameObject>(path);
            var result = PlacementCheck.Check(model, default);
            Assert.IsTrue(result.Pass, path + ": " + result.Reason);
        }
    }
}
```

Registry/git packages may live in `Library/PackageCache`; pass their resolved
physical directories to the GUID check too when validating an installed closure.
Never refresh/import intentionally colliding metadata fixtures.

## Release build audit

`BuildAudit.Check(BuildReport, BuildAuditRules)` returns violation strings.
An overload accepts assembly names and permission strings for cheap tests.
Defaults reject any assembly with an exact `Dev` dot-separated name segment
(case-insensitive), names starting with `YetiKit.Playtest` or `YetiKit.Lab`, and
**all permissions not explicitly allowed**. For example, `Consumer.Dev.Tools`
and `Consumer.Dev` are rejected; `Unity.Services.Core.Device` and
`Consumer.Devices` are not. `forbiddenAssemblyPrefixes` adds/replaces prefix
rules; the exact `Dev` segment guard remains. `forbiddenPermissions` defaults to
`{"*"}`; replace it with exact permission names for a narrower deny list. Exact
`allowedPermissions` wins.

Opt in immediately before `BuildPipeline.BuildPlayer`, not through a runtime
component. The hook checks selected assemblies before stripping/IL2CPP, then
checks the report and final APK manifest after a release build. Development
builds bypass both checks; disabled is the default. Use the hook rather than
only the report adapter when auditing IL2CPP, whose final output omits DLLs.
Always disable in `finally` to avoid policy leaking into subsequent builds:

```csharp
BuildAuditHook.Enable(new BuildAuditRules
{
    allowedPermissions = new[] { "android.permission.RECORD_AUDIO" }
});
try
{
    // BuildPipeline.BuildPlayer(options); // consumer-owned release options
}
finally { BuildAuditHook.Disable(); }
```

Android checks inspect the **packaged merged** manifest via SDK `aapt2 dump
permissions`, not just a source manifest. SDK lookup: `ANDROID_SDK_ROOT`,
`ANDROID_HOME`, then the editor's bundled SDK. Missing tools, failed inspection,
AABs and exported Gradle projects produce violations (fail closed); APKs are the
supported Android output. No real player build is needed for the kit tests.
Non-Android reports audit assemblies only. Inspect direct `Check` results in
custom release pipelines; the enabled hook throws `BuildFailedException`.

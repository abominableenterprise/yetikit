# YetiKit design

Everything here is **planned**, not an implemented API. The kit extracts proven,
small components from a consumer game without importing its gameplay or identity.
The first slice is Ship, core and basic quality; hands, interaction, capture,
lab and a playable template follow. Later locomotion/body features need a second
consumer's concrete request. No Unity project or game code is part of this skeleton.

## Modules and dependency graph

```text
core            UnityEngine only; build identity, notes, counters, utilities
hands        -> core, Input System, XRI, XR Hands
interaction  -> hands, core, XRI
playtest     -> core                              [YETIKIT_DEV]
playtest.XR  -> playtest, hands, interaction       [YETIKIT_DEV; optional bridge]
lab          -> hands, core, playtest             [YETIKIT_DEV]
quality         editor/tests only
Game.Runtime -> core, hands, interaction
Game.Dev     -> Game.Runtime, playtest, lab       [YETIKIT_DEV]
```

Core stays non-XR. The optional capture bridge has its own constrained asmdef
and a version define for hands; it must not force XR into base playtest.
Package manifests declare real dependencies; no kit assembly references a game.
One asmdef per module, all `autoReferenced: false`. App modules are non-XR
services; XR menus are a renderer, not a dependency of their shared model.
Performance tools that depend on recording stay in playtest, not core.

Ship provides Linux editor setup/licensing/seat handling, tests, APK builds,
doctor, locking, signer checks, safe install, verify and launch. It calls the
game's configured build method rather than adding a new editor build API.
Games vendor tagged Ship into `Tools/yetikit/`; `VERSION` records tag and SHA-256.
CI compares its digest and manifest tag. Game configuration belongs in
`yetikit.json` (scenes, build method, bundle ID and signer fingerprint).
Every Git UPM dependency in the closure is pinned at one repository tag;
`kit-bump.sh` updates those pins and re-vendors Ship together. Before tagging,
resolve core-only, playtest-only and full-XR manifests from an empty cache.

## Four game seams (proposed signatures)

```csharp
// 1. The game supplies aim candidates; null means an unassisted physical throw.
public interface IThrowTargetSource { IReadOnlyList<ThrowTarget> Targets(); }

// 2. The kit samples impact; only the game sink decides window.Accept.
public readonly struct ImpactSample {
    public readonly Collider Other;
    public readonly Vector3 RelativeVelocity, Incoming, Point;
    public readonly float Speed, Now;
}
public interface IThrownHitSink {
    bool OnThrownImpact(GrabbableProp prop, in ImpactSample hit, PropHitFilter window);
}

// 3. Capture has small verbs, not a game-world model.
public interface ISnapContextSource { void Write(SnapContext ctx); }
public interface IObjectSnapshotSource { void Snapshot(ObjectFrameWriter w); }
public static class Capture {
    public static IDisposable Add(ISnapContextSource s);
    public static IDisposable Add(IObjectSnapshotSource s);
    public static void AppendEvent(string kind, in EventPayload p);
    public static void Snap(string reason);
}

// 4. Experiments and tuning use explicit bindings, not reflection.
public static class Experiments {
    public static void Add(string id, Func<GameObject> open, Action<TuningScope> bind = null);
}
public static class Tuning {
    public static TuningSetting Float(string key, float min, float max,
        Func<float> get, Action<float> set, string unit = "");
    public static TuningSetting Bool(string key, Func<bool> get, Action<bool> set);
}
```

The game's composition root registers `GrabHooks.Use(...)` and `Capture.Add(...)`
with disposable lifetimes. Reset all static slots at `SubsystemRegistration`;
reload the sandbox twice in tests to catch duplicate listeners, recorders and
collision ignores with domain reload disabled. With no sink, a default sink
accepts fast impacts and raises `GrabbableProp.Impacted`.
Preserve hit order: obstacles may clear pre-solver direction without consuming
the hit window. Replay obstacle→target and ownerless-proxy cases against old and
new paths. Actors, contact policies, scene builders and capture adapters remain
game-owned. Extract hands from the source game's hands folder; preserve neutral
shape classifications without assigning gameplay consequences. Build headers
accept a product name; scene-specific logging policy stays game-side.

## Quality checks

Each validator needs a broken synthetic fixture it rejects and a valid lookalike
it accepts. No certification machinery; template primitives have valid specs.

| Check | Contract / fixtures | When |
|---|---|---|
| Throw replay | Real history→release→throw path; first physics-step velocity bands; early grip open 25–70 ms before peak, set-down, tracking loss, hand-off, teleport carry | Math each PR; physics on relevant changes; never quarantine |
| Mesh | Winding, outside rays, watertightness; reject inverted tetrahedron/missing face; accept declared open tube; import rejects non-finite, degenerate, negative-scale meshes | Changed models on Linux; import |
| Placement | Support gap ≤2 cm, facing error ≤2°; reject raised/reversed anchors | Scene/prefab PRs, EditMode |
| Feet | Idle drift ≤2 cm; injected slide fails, walking clip is exempt | Later character PRs |
| Release audit | No dev assemblies, dev components or kit-added permissions; allow declared game mic use | Every release; CI dev→release→dev |
| References | Missing scripts, GUID collisions and serialized inventory diff; fixtures missing script/duplicate GUID | Every PR; required on adoption |
| Outbox | Kill mid-chunk, offline, disk full, 401/429/5xx, duplicate ack; recover truncation, reject unknown schema; golden chunk shared with analyzer | Capture PRs |
| Installed identity | APK digest, versionCode, signer, game/kit commits and runtime stamp match; reject older version or wrong signer | Every install; one pending install; never uninstall |
| Test honesty | Host runs full kit suite; games run smoke + adapter tests; rerun labelled “rerun green”; reject flaky allowlist entries for throw/sign/strip tests | Every CI run |
| Performance | Static triangle/texture budgets and worn-check p95 CPU/GPU frame times; reject over-budget scene | Scene PRs and worn check; Quest 2 pending until measured |

Ship sets `YETIKIT_DEV` for dev builds, clears it before release compilation and
restores editor settings in `finally`. Dev references stay inside that boundary.
Upload credentials are revocable upload-only tokens, never administrative keys.
Runtime configuration and credentials are consumer-owned, never committed here.

## Day-0 template

A future template uses Unity 6000.6.6f1, URP, OpenXR + Meta, XRI 3.6, XR Hands,
72 fps, Quest 3/3S target and Quest 2 floor. Include pinned manifest + lockfile,
vendored tools, game config, runtime/dev assemblies, composition root, game build
entry point, sandbox, tuning preset, release notes, contribution rules and CI.
`new-game.sh --id --title` stamps identity and signer reference; reject placeholders.
Template assets are game-owned copies with fresh GUIDs, not reimportable samples.
The sandbox is a 6×6 m room: floor grid, height marker, recovery volume, ball,
offset-grip bottle, targets/sound, teleport pads, snap turn and wrist/start/tuning panels.

Day-0 evidence: clean-cache resolution and smoke/adapter tests; doctor plus safe
install/verify; correct title/build stamp; both hands ≥60 Hz and controller mode
switches; throw/impact event in fixture band; teleport/snap-turn events; direct
experiment boot; persistent slider override visible in capture context; local
photo saved; release audit and frame-time recording. Quest 2 remains pending
until tested. Upload is optional and needs a consumer-owned destination, scoped
token, size limits and retention. Voice is off unless enabled for that session.
Target ≤2 hours automation to local capture, ≤4 including release, and ≤10 minutes
of headset verification; report queue, cold import and device wait separately.

## Design-speed loop

Register an experiment prefab with `Experiments.Add`; dev launch selects its ID,
unknown IDs show a chooser/error, and release ignores the selection. Bind only
knobs needed for the current question. Wrist controls apply live, persist per
experiment and Reset; each value is marked preset or override. Captures and
session headers include build, kit tag, experiment, preset version and overrides.
Bake exports JSON tagged `bake: true`; reviewed PRs copy values into defaults.
Automatic preset rewriting waits for a real loading contract. A future session
analyzer shares the chunk schema and summarizes throws, performance and captures.

## Migration safety

Copy scripts with original `.cs.meta` GUIDs, changing only namespace to
`YetiKit.<Module>`; preserve class/file/field names. Scan consumer YAML for stored
type names before deciding whether compatibility attributes are needed; private
identifiers must not enter this public kit. Keep provenance and source commit
tracking in the consumer's private repo; port intervening fixes before adoption.
Each adoption is atomic: package pins, old script/metadata deletion, selective
import rewrite and adapters. Never leave duplicate GUIDs or a non-compiling
intermediate commit. Regenerate scenes against baseline: script references,
fields and component counts must match; missing scripts remain zero.
Rollback reverts adoption and installs a higher-versionCode build without
uninstalling. Keep writing the previous outbox/tuning format through the rollback
window; unknown schemas stay untouched, without parse/delete/retry loops.
Test old writes→new reads→old reads with uploads still pending.

## Business modules

Each service has a thin interface with platform backends, not an XR dependency.
Reuse neutral service/JSON conventions rather than another kit's code.

| Module | Quest | Mobile / policy |
|---|---|---|
| app.analytics | PostHog over HTTP | Same; `Analytics.Track(event, props)`, allowed events, off in dev; credentials supplied outside kit |
| app.telemetry | Firebase Crashlytics | Same; on by default, Settings opt-out; breadcrumbs share analytics events |
| app.store | Meta Platform IAP + entitlement check | RevenueCat; shared `Store.Buy/Owns/Restore`; no RevenueCat Quest-store backend |
| app.ads | None by default | AdMob interstitial/rewarded + Remove Ads; Quest needs permitted means/agreement and required ads label |
| app.review | No-op until supported API exists | iOS/Play native prompts after success, cooldown, never in dev |
| app.sunset | Hosted minimum-version check and update panel | Same; common sunset/release-notes JSON conventions |
| app.menus | World-space start/pause/settings, focus-loss pause, comfort/privacy controls | Screen-space renderer; shared persistent Menu/Settings model |

Roll out analytics, telemetry and menus first; store/review with the first paid
consumer, ads only for mobile unless platform policy changes. Verify provider
support and policy at implementation time; this design is not a policy guarantee.

## Governance

Maintain a separate kit backlog; consumer-critical work wins resource contention.
Use spare Linux capacity, one kit Unity job at a time; no headset assumption.
Requests include kit tag, minimal reproduction and preferably a failing fixture;
use neutral consumer labels without private product or person names.
Fix upstream, tag a patch and bump consumers with `kit-bump.sh`; never edit their
vendored/package code. Temporary local-package development must become a kit PR
and tag promptly; consumer main CI rejects `file:` refs (the kit host uses them).
Consumer rules: hooks only in the composition root, dev code only in its dev
assembly, coordinated pins, no private identifiers in public kit issues.
Every tag documents Added, Fixed, Behaviour changes and Adapter changes.
Before 1.0, breaking minors require explicit adapter notes; schema changes count.
Use small modular PRs, failing-first bug tests and the [review rules](../AGENTS.md).

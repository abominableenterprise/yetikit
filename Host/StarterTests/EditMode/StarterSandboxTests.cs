using System;
using System.Collections;
using System.Linq;
using Game.Starter;
using Game.Starter.Editor;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.TestTools;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using YetiKit.Interaction;

namespace YetiKit.Starter.HostTests
{
    [Category("Gfx")] // The test runs from EditMode but enters Play Mode for real runtime lifecycle callbacks.
    public sealed class StarterSandboxTests
    {
        const string OutputKey = "YetiKit.Starter.HostTests.Output";
        const string OutputParent = "Assets/StarterTests";
        static readonly string[] PropNames = { "Ball", "Offset Grip" };
        static readonly string[] TargetNames = { "Target 1", "Target 2", "Target 3" };

        [UnityTest]
        public IEnumerator GeneratedSandboxPersistsAndSupportsGrabRelease()
        {
            // The editor only allows additive creation with a previously saved scene open.
            var baseline = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Assert.That(EditorSceneManager.SaveScene(baseline, OutputParent + "/Baseline.unity"), Is.True);
            var outputName = "Bake-" + Guid.NewGuid().ToString("N");
            var output = $"{OutputParent}/{outputName}";
            SessionState.SetString(OutputKey, output);

            var active = SceneManager.GetActiveScene();
            var sceneCount = SceneManager.sceneCount;
            var buildScenes = EditorBuildSettings.scenes.Select(s => (s.path, s.enabled)).ToArray();
            var path = SandboxBuilder.Build(output);
            Assert.That(SceneManager.sceneCount, Is.EqualTo(sceneCount), "Build must close its additive scene.");
            Assert.That(SceneManager.GetActiveScene(), Is.EqualTo(active));
            Assert.That(EditorBuildSettings.scenes.Select(s => (s.path, s.enabled)), Is.EqualTo(buildScenes));
            Assert.That(path, Does.StartWith(output + "/").And.EndWith(".unity"));
            Assert.That(AssetDatabase.LoadAssetAtPath<SceneAsset>(path), Is.Not.Null);

            var saved = EditorSceneManager.OpenScene(path, OpenSceneMode.Single);
            AssertSavedAssets(saved, output);
            StarterLabChecks.AssertSavedScene(saved);

            yield return new EnterPlayMode();

            // The EditMode runner restores its own scene on entering Play Mode.
            var scene = EditorSceneManager.LoadSceneInPlayMode(SessionState.GetString(OutputKey, "") + "/Sandbox.unity",
                new LoadSceneParameters(LoadSceneMode.Single));
            yield return null;
            Assert.That(scene.IsValid() && scene.isLoaded, Is.True);
            var bindings = Bindings(scene);
            var recovery = ComponentOn<BoxCollider>(Root(scene, "Recovery Volume"));
            Physics.SyncTransforms();
            foreach (var name in PropNames)
            {
                var prop = ComponentOn<GrabbableProp>(Root(scene, name));
                Assert.That(prop.HitSink, Is.SameAs(bindings), name);
                Assert.That(prop.RespawnSettings.FallY, Is.EqualTo(recovery.bounds.max.y).Within(0.001f), name);
            }
            foreach (var name in TargetNames)
            {
                var target = Root(scene, name);
                Assert.That(bindings.ResolveTarget(ComponentOn<Collider>(target)), Is.SameAs(target.GetComponent<ImpactCue>()));
            }
            Assert.That(bindings.ResolveTarget(ComponentOn<Collider>(Root(scene, "Floor"))), Is.Null);

            GrabAndRelease(scene);
            AssertSyntheticImpact(scene);
            yield return StarterRigChecks.DriveRig(scene);
            yield return StarterLabChecks.DriveAndReload(scene.path);
            yield return new ExitPlayMode();
        }

        static void AssertSavedAssets(Scene scene, string output)
        {
            Root(scene, "Floor Grid");
            Root(scene, "Height Marker");
            StarterRigChecks.AssertSavedRig(scene, output);
            Assert.That(ComponentOn<BoxCollider>(Root(scene, "Recovery Volume")).isTrigger, Is.True);
            var floor = ComponentOn<BoxCollider>(Root(scene, "Floor"));
            Assert.That(floor.isTrigger, Is.False);
            Physics.SyncTransforms();
            Assert.That(floor.bounds.size.x, Is.EqualTo(6f).Within(0.001f));
            Assert.That(floor.bounds.size.z, Is.EqualTo(6f).Within(0.001f));
            var manager = ComponentOn<XRInteractionManager>(Root(scene, "Interaction Manager"));
            Bindings(scene);
            foreach (var name in PropNames)
            {
                var placed = Root(scene, name);
                var prop = ComponentOn<GrabbableProp>(placed);
                var grab = ComponentOn<PropGrabInteractable>(placed);
                Assert.That(grab.interactionManager, Is.EqualTo(manager), name);
                var prefab = PrefabUtility.GetCorrespondingObjectFromSource(placed);
                Assert.That(prefab, Is.Not.Null, $"{name} must retain its prefab link after reopening.");
                Assert.That(AssetDatabase.GetAssetPath(prefab), Does.StartWith(output + "/").And.EndWith(".prefab"));
                var prefabProp = ComponentOn<GrabbableProp>(prefab);
                ComponentOn<PropGrabInteractable>(prefab);
                if (name == "Offset Grip")
                {
                    Assert.That(prop.grip.center.sqrMagnitude, Is.GreaterThan(0f));
                    Assert.That(prop.grip.center, Is.EqualTo(prefabProp.grip.center));
                }
                var colliders = placed.GetComponentsInChildren<Collider>();
                Assert.That(colliders, Is.Not.Empty, name);
                foreach (var collider in colliders)
                {
                    Assert.That(collider.enabled && !collider.isTrigger, Is.True, collider.name);
                    Assert.That(collider.attachedRigidbody, Is.EqualTo(prop.Body), collider.name);
                    var source = PrefabUtility.GetCorrespondingObjectFromSource(collider);
                    Assert.That(source, Is.Not.Null, collider.name);
                    Assert.That(AssetDatabase.GetAssetPath(source), Is.EqualTo(AssetDatabase.GetAssetPath(prefab)));
                }
            }
            foreach (var name in TargetNames)
            {
                var target = Root(scene, name);
                var collider = ComponentOn<Collider>(target);
                Assert.That(collider.enabled && !collider.isTrigger, Is.True, name);
                ComponentOn<ImpactCue>(target);
                var clip = ComponentOn<AudioSource>(target).clip;
                Assert.That(clip, Is.Not.Null, name);
                Assert.That(AssetDatabase.GetAssetPath(clip), Does.StartWith("Assets/Starter/"));
            }
            foreach (var root in scene.GetRootGameObjects())
            foreach (var item in root.GetComponentsInChildren<Transform>(true))
                Assert.That(GameObjectUtility.GetMonoBehavioursWithMissingScriptCount(item.gameObject), Is.Zero, item.name);
        }

        static void GrabAndRelease(Scene scene)
        {
            var ball = Root(scene, "Ball");
            var prop = ball.GetComponent<GrabbableProp>();
            var grab = ball.GetComponent<PropGrabInteractable>();
            var manager = ComponentOn<XRInteractionManager>(Root(scene, "Interaction Manager"));
            var dummy = new GameObject("Synthetic interactor");
            try
            {
                dummy.SetActive(false);
                SceneManager.MoveGameObjectToScene(dummy, scene);
                dummy.transform.position = ball.transform.position;
                dummy.AddComponent<SphereCollider>().isTrigger = true;
                var interactor = dummy.AddComponent<XRDirectInteractor>();
                interactor.interactionManager = manager;
                interactor.interactionLayers = grab.interactionLayers;
                dummy.SetActive(true);

                var initialSequence = grab.ReleaseSequence;
                Assert.That(prop.Held, Is.False);
                manager.SelectEnter((IXRSelectInteractor)interactor, grab);
                Assert.That(prop.Held && interactor.hasSelection, Is.True);
                manager.SelectExit((IXRSelectInteractor)interactor, grab);
                grab.ProcessInteractable(XRInteractionUpdateOrder.UpdatePhase.Late);
                Assert.That(prop.Held || interactor.hasSelection, Is.False);
                Assert.That(grab.PendingLateRelease, Is.False);
                Assert.That(grab.ReleaseSequence, Is.EqualTo(initialSequence + 1));
            }
            finally { UnityEngine.Object.DestroyImmediate(dummy); }
        }

        static void AssertSyntheticImpact(Scene scene)
        {
            var prop = ComponentOn<GrabbableProp>(Root(scene, "Ball"));
            var target = ComponentOn<Collider>(Root(scene, "Target 1"));
            var secondTarget = ComponentOn<Collider>(Root(scene, "Target 2"));
            var floor = ComponentOn<Collider>(Root(scene, "Floor"));
            var velocity = Vector3.back * 5f;
            var now = Time.time;
            Assert.That(prop.Collided(target, velocity, target.bounds.center, now), Is.False, "Not yet thrown.");
            prop.Thrown(now);
            Assert.That(prop.Collided(floor, velocity, floor.bounds.center, now), Is.False, "Not a target.");
            Assert.That(prop.Collided(target, velocity, target.bounds.center, now), Is.True, "First eligible hit.");
            Assert.That(prop.Collided(secondTarget, velocity, secondTarget.bounds.center, now), Is.False, "One hit per throw.");
        }

        [UnityTearDown]
        public IEnumerator CleanBake()
        {
            if (EditorApplication.isPlaying) yield return new ExitPlayMode();
            StarterLabChecks.RestorePrefs();
            var output = SessionState.GetString(OutputKey, "");
            if (output.Length == 0) yield break;
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            SessionState.EraseString(OutputKey);
            AssetDatabase.DeleteAsset(OutputParent + "/Baseline.unity");
            if (AssetDatabase.IsValidFolder(output))
                Assert.That(AssetDatabase.DeleteAsset(output), Is.True, $"Could not delete {output}");
        }

        internal static GameObject Root(Scene scene, string name)
        {
            var matches = scene.GetRootGameObjects().Where(go => go.name == name).ToArray();
            Assert.That(matches, Has.Length.EqualTo(1), $"Expected exactly one '{name}' root.");
            return matches[0];
        }

        static SandboxBindings Bindings(Scene scene) => scene.GetRootGameObjects()
            .SelectMany(root => root.GetComponentsInChildren<SandboxBindings>(true)).Single();

        internal static T ComponentOn<T>(GameObject go) where T : Component
        {
            var component = go.GetComponent<T>();
            Assert.That(component, Is.Not.Null, $"{go.name} is missing {typeof(T).Name}.");
            return component;
        }
    }
}

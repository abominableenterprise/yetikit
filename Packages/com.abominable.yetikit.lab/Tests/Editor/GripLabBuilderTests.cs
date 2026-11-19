using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.TestTools;
using UnityEngine.XR.Interaction.Toolkit;
using YetiKit.Interaction;
using Object = UnityEngine.Object;

namespace YetiKit.Lab.Editor.Tests
{
    public sealed class GripLabBuilderTests
    {
        const string FolderKey = "YetiKit.Lab.Editor.Tests.GripLabBuilderTests.Folder";
        const string SceneFile = "/GripLab.unity";

        public enum ColliderSetup { Missing, Trigger, Disabled, InactiveChild, SeparateBody }

        sealed class Catalog : IInteractableCatalog
        {
            public IReadOnlyList<InteractableEntry> Entries { get; set; }
        }

        [UnityTest]
        public IEnumerator SavedSceneKeepsBakedPropsAndRigAndPopulatesOnStart()
        {
            var folder = CreateFixtureFolder();
            var prefab = MakePrefab(folder + "/Block.prefab", MakeBlock());
            var previous = OpenBaseScene(folder);
            var calls = 0;
            var catalog = new Catalog { Entries = new[] {
                new InteractableEntry("prefab-block", "Prefab block", prefab, "blocks"),
                new InteractableEntry("factory-block", "Factory block", () => {
                    calls++;
                    return MakeBlock(colliderOnChild: true);
                }, "blocks")
            }};
            var scene = GripLabBuilder.Build(catalog, target =>
            {
                Assert.That(SceneManager.GetActiveScene(), Is.EqualTo(target));
                var rig = new GameObject("Synthetic rig", typeof(XRInteractionManager));
                var head = new GameObject("Synthetic head").transform;
                head.SetParent(rig.transform, false);
                head.localPosition = Vector3.up * 1.6f;
                return head;
            });
            try
            {
                Assert.That(SceneManager.GetActiveScene(), Is.EqualTo(previous));
                Assert.That(scene.path, Is.Empty, "The caller saves the generated scene.");
                Assert.That(calls, Is.EqualTo(1));
                Assert.That(EditorSceneManager.SaveScene(scene, folder + SceneFile), Is.True);
            }
            finally { EditorSceneManager.CloseScene(scene, true); }
            var reloaded = EditorSceneManager.OpenScene(folder + SceneFile, OpenSceneMode.Additive);
            var station = FindStation(reloaded);
            Assert.That(station.Head, Is.EqualTo(reloaded.GetRootGameObjects()
                .Single(go => go.name == "Synthetic rig").transform.Find("Synthetic head")));
            Assert.That(station.Head.localPosition.y, Is.EqualTo(1.6f));
            var baked = station.GetComponentsInChildren<GrabbableProp>();
            Assert.That(baked.Select(prop => prop.name), Is.EqualTo(new[] { "Prefab block", "Factory block" }));
            Assert.That(PrefabUtility.GetCorrespondingObjectFromSource(baked[0].gameObject), Is.EqualTo(prefab));
            Assert.That(station.GetComponentsInChildren<GripLabSlot>(), Is.Empty, "Slots are runtime-only.");
            Assert.That(station.transform.position.y, Is.EqualTo(0.8f));
            Physics.SyncTransforms();
            Assert.That(Surface(reloaded, "Grip Lab Floor").bounds.max.y, Is.EqualTo(0).Within(0.001f));
            Assert.That(Surface(reloaded, "Grip Lab Table").bounds.max.y, Is.EqualTo(0.8f).Within(0.001f));

            yield return new EnterPlayMode();
            yield return null;

            var playing = SceneManager.GetSceneByPath(SessionState.GetString(FolderKey, "") + SceneFile);
            var runtimeStation = FindStation(playing);
            var slots = runtimeStation.GetComponentsInChildren<GripLabSlot>();
            Assert.That(slots.Select(slot => slot.Id), Is.EqualTo(new[] { "prefab-block", "factory-block" }));
            Assert.That(runtimeStation.GetComponentsInChildren<GrabbableProp>(), Has.Length.EqualTo(2));
            Assert.That(slots.All(slot => slot.IsFixedInSlot), Is.True);
            using var bootstrap = new SerializedObject(runtimeStation.GetComponent<GripLabScene>());
            var props = bootstrap.FindProperty("props");
            Assert.That(props.arraySize, Is.EqualTo(slots.Length));
            for (var i = 0; i < slots.Length; i++)
            {
                var entry = props.GetArrayElementAtIndex(i);
                Assert.That(entry.FindPropertyRelative("Instance").objectReferenceValue, Is.EqualTo(slots[i].gameObject));
                Assert.That(entry.FindPropertyRelative("Category").stringValue, Is.EqualTo("blocks"));
            }
            Physics.SyncTransforms();
            var table = Surface(playing, "Grip Lab Table").bounds;
            var first = slots[0].GetComponent<BoxCollider>().bounds;
            var childBox = slots[1].GetComponentInChildren<BoxCollider>();
            Assert.That(childBox.gameObject, Is.Not.EqualTo(slots[1].gameObject));
            Assert.That(childBox.attachedRigidbody, Is.EqualTo(slots[1].GetComponent<Rigidbody>()));
            var second = childBox.bounds;
            Assert.That(first.min.y, Is.EqualTo(table.max.y + 0.002f).Within(0.001f));
            Assert.That(second.min.z, Is.GreaterThan(first.max.z), "Wide props wrap onto a new row.");
            Assert.That(second.max.z, Is.LessThan(table.max.z), "The table accommodates both rows.");
        }

        [Test]
        public void RejectsHeadFromAnotherSceneAndClosesTheNewScene()
        {
            var previous = OpenBaseScene(CreateFixtureFolder());
            var foreignHead = new GameObject("Foreign head");
            var count = SceneManager.sceneCount;
            var called = false;
            try
            {
                Assert.Throws<InvalidOperationException>(() => GripLabBuilder.Build(
                    new Catalog { Entries = Array.Empty<InteractableEntry>() }, target =>
                    {
                        called = true;
                        new GameObject("Incomplete rig");
                        Assert.That(target, Is.Not.EqualTo(previous));
                        return foreignHead.transform;
                    }));
                Assert.That(called, Is.True);
                Assert.That(SceneManager.GetActiveScene(), Is.EqualTo(previous));
                Assert.That(SceneManager.sceneCount, Is.EqualTo(count));
            }
            finally { Object.DestroyImmediate(foreignHead); }
        }

        [TestCase(true, ColliderSetup.Missing)]
        [TestCase(true, ColliderSetup.Trigger)]
        [TestCase(true, ColliderSetup.Disabled)]
        [TestCase(true, ColliderSetup.InactiveChild)]
        [TestCase(true, ColliderSetup.SeparateBody)]
        [TestCase(false, ColliderSetup.Missing)]
        [TestCase(false, ColliderSetup.Trigger)]
        [TestCase(false, ColliderSetup.Disabled)]
        [TestCase(false, ColliderSetup.InactiveChild)]
        [TestCase(false, ColliderSetup.SeparateBody)]
        public void RejectsPropWithoutUsableColliderAndClosesTheNewScene(bool usePrefab, ColliderSetup setup)
        {
            var folder = CreateFixtureFolder();
            var previous = OpenBaseScene(folder);
            var existing = MakeBlock();
            var count = SceneManager.sceneCount;
            var target = default(Scene);
            GameObject valid = null, invalid = null;
            var badEntry = usePrefab
                ? new InteractableEntry("invalid", "Invalid", MakePrefab(folder + "/Invalid.prefab", MakeInvalidBlock(setup)))
                : new InteractableEntry("invalid", "Invalid", () => invalid = MakeInvalidBlock(setup));
            var catalog = new Catalog { Entries = new[] {
                new InteractableEntry("valid", "Valid", () => valid = MakeBlock()), badEntry
            }};
            try
            {
                var error = Assert.Throws<InvalidOperationException>(() => GripLabBuilder.Build(catalog, scene =>
                {
                    target = scene;
                    return new GameObject("Synthetic head").transform;
                }));
                Assert.That(error.Message, Does.Contain("'invalid'").And.Contain("enabled solid collider"));
                Assert.That(SceneManager.GetActiveScene(), Is.EqualTo(previous));
                Assert.That(SceneManager.sceneCount, Is.EqualTo(count));
                Assert.That(target.isLoaded, Is.False);
                Assert.That(previous.GetRootGameObjects(), Is.EqualTo(new[] { existing }));
                Assert.That(ReferenceEquals(valid, null), Is.False, "The earlier entry was created.");
                Assert.That(valid == null, Is.True, "The earlier baked prop was destroyed.");
                if (!usePrefab)
                {
                    Assert.That(ReferenceEquals(invalid, null), Is.False, "The invalid factory prop was created.");
                    Assert.That(invalid == null, Is.True, "The invalid factory prop was destroyed.");
                }
            }
            finally
            {
                if (target.IsValid() && target.isLoaded) EditorSceneManager.CloseScene(target, true);
            }
        }

        [UnityTearDown]
        public IEnumerator DeleteFixture()
        {
            if (EditorApplication.isPlaying) yield return new ExitPlayMode();
            var folder = SessionState.GetString(FolderKey, "");
            if (folder.Length == 0) yield break;
            var scene = SceneManager.GetSceneByPath(folder + SceneFile);
            if (scene.IsValid() && scene.isLoaded) EditorSceneManager.CloseScene(scene, true);
            var baseScene = SceneManager.GetSceneByPath(folder + "/Base.unity");
            if (baseScene.IsValid() && baseScene.isLoaded)
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            AssetDatabase.DeleteAsset(folder);
            SessionState.EraseString(FolderKey);
        }

        static string CreateFixtureFolder()
        {
            var name = "GripLabFixture-" + Guid.NewGuid().ToString("N");
            var folder = "Assets/" + name;
            AssetDatabase.CreateFolder("Assets", name);
            SessionState.SetString(FolderKey, folder);
            return folder;
        }

        static Scene OpenBaseScene(string folder)
        {
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Assert.That(EditorSceneManager.SaveScene(scene, folder + "/Base.unity"), Is.True);
            return scene;
        }

        static GripLabStation FindStation(Scene scene) =>
            scene.GetRootGameObjects().Select(go => go.GetComponent<GripLabStation>()).Single(station => station);

        static BoxCollider Surface(Scene scene, string name) =>
            scene.GetRootGameObjects().Single(go => go.name == name).GetComponent<BoxCollider>();

        static GameObject MakePrefab(string path, GameObject source)
        {
            try { return PrefabUtility.SaveAsPrefabAsset(source, path); }
            finally { Object.DestroyImmediate(source); }
        }

        static GameObject MakeBlock(bool colliderOnChild = false)
        {
            var block = new GameObject("Block");
            AddBox(block, colliderOnChild);
            block.AddComponent<GrabbableProp>();
            return block;
        }

        static GameObject MakeInvalidBlock(ColliderSetup setup)
        {
            var block = new GameObject("Invalid block", typeof(GrabbableProp));
            if (setup == ColliderSetup.Missing) return block;
            var box = AddBox(block, onChild: setup == ColliderSetup.InactiveChild || setup == ColliderSetup.SeparateBody);
            if (setup == ColliderSetup.Trigger) box.isTrigger = true;
            if (setup == ColliderSetup.Disabled) box.enabled = false;
            if (setup == ColliderSetup.InactiveChild) box.gameObject.SetActive(false);
            if (setup == ColliderSetup.SeparateBody) box.gameObject.AddComponent<Rigidbody>();
            return block;
        }

        static BoxCollider AddBox(GameObject block, bool onChild = false)
        {
            var target = block;
            if (onChild)
            {
                target = new GameObject("Collider child");
                target.transform.SetParent(block.transform, false);
            }
            var box = target.AddComponent<BoxCollider>();
            box.size = new Vector3(1.6f, 0.3f, 0.9f);
            return box;
        }
    }
}

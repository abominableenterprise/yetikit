using System;
using System.IO;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using YetiKit.Quality.Editor;
using Object = UnityEngine.Object;

namespace YetiKit.Quality.Tests
{
    public class AssetScanTests
    {
        string folder;
        [SetUp] public void SetUp()
        {
            folder = "Assets/QualityFixture-" + Guid.NewGuid().ToString("N");
            Directory.CreateDirectory(folder);
            AssetDatabase.Refresh();
        }
        [TearDown] public void TearDown() => AssetDatabase.DeleteAsset(folder);

        string Prefab(bool broken)
        {
            var root = new GameObject("Root");
            var child = new GameObject("Inactive");
            child.transform.SetParent(root.transform);
            child.SetActive(false);
            child.AddComponent<Rigidbody>();
            var path = folder + (broken ? "/Broken.prefab" : "/Clean.prefab");
            try { PrefabUtility.SaveAsPrefabAsset(root, path); }
            finally { Object.DestroyImmediate(root); }
            if (broken)
            {
                // Replace a native component document with a MonoBehaviour whose script GUID does not exist.
                var text = File.ReadAllText(path);
                var start = text.IndexOf("--- !u!54 &", StringComparison.Ordinal);
                var end = text.IndexOf("--- !u!", start + 1, StringComparison.Ordinal);
                var component = text.Substring(start, (end < 0 ? text.Length : end) - start);
                var header = component.Split('\n')[0].Replace("!u!54", "!u!114");
                var owner = component.Split('\n').First(line => line.Contains("m_GameObject:"));
                text = text.Replace(component, header + "\nMonoBehaviour:\n" + owner +
                    "\n  m_Enabled: 1\n  m_Script: {fileID: 11500000, guid: 11111111111111111111111111111111, type: 3}\n");
                File.WriteAllText(path, text);
                AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceUpdate);
            }
            return path;
        }

        [Test] public void MissingPrefabScriptIncludesInactivePathAndComponentIndex()
        {
            var path = Prefab(true);
            var result = MissingScriptScan.Find(new[] { path });
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].assetPath, Is.EqualTo(path));
            Assert.That(result[0].gameObjectPath, Is.EqualTo("Broken/Inactive"));
            Assert.That(result[0].componentIndex, Is.EqualTo(1));
            Assert.That(MissingScriptScan.FindInFolders(folder).Count, Is.EqualTo(1));
        }
        [Test] public void CleanPrefabHasNoMissingScripts() => Assert.IsEmpty(MissingScriptScan.Find(new[] { Prefab(false) }));

        [Test] public void StaleExplicitPrefabPathThrowsEvenAlongsideCleanPrefab()
        {
            var clean = Prefab(false);
            var stale = folder + "/Moved.prefab";
            var error = Assert.Throws<ArgumentException>(() => MissingScriptScan.Find(new[] { clean, stale }));
            StringAssert.Contains(stale, error.Message);
            StringAssert.Contains("load", error.Message);
        }

        [Test] public void SceneScanPreservesLoadedSceneAndFindsMissingScript()
        {
            var prefab = Prefab(true);
            var active = SceneManager.GetActiveScene();
            var path = folder + "/Broken.unity";
            // Scene and prefab objects share the serialized component format. No user scene is edited.
            File.Copy(prefab, path);
            AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceUpdate);
            var count = SceneManager.sceneCount;
            var result = MissingScriptScan.Find(new[] { path });
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(SceneManager.sceneCount, Is.EqualTo(count));
            Assert.That(SceneManager.GetActiveScene(), Is.EqualTo(active));
        }

        [Test] public void GuidCollisionsReadRawTextAndDeduplicateOverlappingRoots()
        {
            // No refresh: duplicate GUIDs must never be handed to Unity's importer.
            File.WriteAllText(folder + "/a.cs.meta", "fileFormatVersion: 2\nguid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");
            File.WriteAllText(folder + "/b.cs.meta", "guid: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n");
            Assert.IsEmpty(GuidCollisionCheck.Find(folder));
            File.WriteAllText(folder + "/b.cs.meta", "guid: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n");
            var result = GuidCollisionCheck.Find(folder, folder);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].guid, Is.EqualTo("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
            Assert.That(result[0].paths.Length, Is.EqualTo(2));
        }
    }
}

using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace YetiKit.Quality.Editor
{
    public static class MissingScriptScan
    {
        public static List<(string assetPath, string gameObjectPath, int componentIndex)> Find(IEnumerable<string> assetPaths)
        {
            var found = new List<(string, string, int)>();
            foreach (var path in assetPaths.Distinct())
            {
                if (Path.GetExtension(path).ToLowerInvariant() == ".unity")
                {
                    // Preview scenes do not replace, save, or close the user's loaded scenes.
                    var scene = EditorSceneManager.OpenPreviewScene(path);
                    try { foreach (var root in scene.GetRootGameObjects()) Scan(root, path, "", found); }
                    finally { EditorSceneManager.ClosePreviewScene(scene); }
                }
                else
                {
                    var root = AssetDatabase.LoadAssetAtPath<GameObject>(path);
                    if (!root) throw new System.ArgumentException("Cannot load prefab or model at asset path: " + path, nameof(assetPaths));
                    Scan(root, path, "", found);
                }
            }
            return found;
        }

        public static List<(string assetPath, string gameObjectPath, int componentIndex)> FindInFolders(params string[] folders)
        {
            if (folders == null || folders.Length == 0 || folders.Any(f => !AssetDatabase.IsValidFolder(f)))
                throw new System.ArgumentException("Supply existing asset folders.", nameof(folders));
            return Find(AssetDatabase.FindAssets("t:GameObject t:Scene", folders).Select(AssetDatabase.GUIDToAssetPath));
        }

        static void Scan(GameObject go, string asset, string parent, List<(string, string, int)> found)
        {
            var path = parent + go.name;
            var components = go.GetComponents<Component>();
            for (var i = 0; i < components.Length; i++)
                if (!components[i]) found.Add((asset, path, i));
            foreach (Transform child in go.transform) Scan(child.gameObject, asset, path + "/", found);
        }
    }
}

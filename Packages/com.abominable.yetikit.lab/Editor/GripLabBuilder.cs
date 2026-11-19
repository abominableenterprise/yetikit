using System;
using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using YetiKit.Interaction;

namespace YetiKit.Lab.Editor
{
    public static class GripLabBuilder
    {
        const float TableHeight = 0.8f, TableThickness = 0.08f;

        /// <summary>Build an unsaved additive scene. The caller decides whether and where to save it.</summary>
        /// <remarks>
        /// Save untitled scenes before calling. The rig hook runs with the new scene active
        /// and must return a head in that scene.
        /// Catalog prefabs must be prefab assets, and factories must create fresh root props in the new scene.
        /// Each prop needs an enabled solid collider on its rigidbody. The station places the baked props at runtime.
        /// </remarks>
        public static Scene Build(IInteractableCatalog catalog, Func<Scene, Transform> buildRig)
        {
            var entries = catalog?.Entries ?? throw new ArgumentNullException(nameof(catalog));
            if (buildRig == null) throw new ArgumentNullException(nameof(buildRig));

            var previous = SceneManager.GetActiveScene();
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Additive);
            try
            {
                SceneManager.SetActiveScene(scene);
                var head = buildRig(scene);
                if (!head || head.gameObject.scene != scene)
                    throw new InvalidOperationException("The rig hook must return a head in the new scene.");
                SceneManager.SetActiveScene(scene);

                Cube("Grip Lab Floor", new Vector3(20, 0.1f, 24), new Vector3(0, -0.05f, 0));
                var table = Cube("Grip Lab Table", new Vector3(2.8f, TableThickness, 1),
                    new Vector3(0, TableHeight - TableThickness / 2, 0.78f));
                var light = new GameObject("Grip Lab Light").AddComponent<Light>();
                light.type = LightType.Directional;
                light.transform.rotation = Quaternion.Euler(45, -25, 0);

                var station = new GameObject("Grip Lab Station").AddComponent<GripLabStation>();
                station.Head = head;
                station.transform.position = new Vector3(0, TableHeight, 0.28f);
                var props = BakeProps(entries, station.transform, scene);
                station.gameObject.AddComponent<GripLabScene>().Configure(station, table, props);
                return scene;
            }
            catch
            {
                if (scene.IsValid() && scene.isLoaded) EditorSceneManager.CloseScene(scene, true);
                throw;
            }
            finally
            {
                if (previous.IsValid() && previous.isLoaded) SceneManager.SetActiveScene(previous);
            }
        }

        static GripLabScene.BakedProp[] BakeProps(IReadOnlyList<InteractableEntry> entries, Transform parent, Scene scene)
        {
            var ids = new HashSet<string>(StringComparer.Ordinal);
            var props = new GripLabScene.BakedProp[entries.Count];
            for (var i = 0; i < props.Length; i++)
            {
                var entry = entries[i];
                if (entry == null || !ids.Add(entry.Id))
                    throw new ArgumentException("Entries must be non-null and have unique IDs.", nameof(entries));

                SceneManager.SetActiveScene(scene);
                var item = entry.Prefab ? (GameObject)PrefabUtility.InstantiatePrefab(entry.Prefab, scene) : entry.Spawn();
                if (!item || item.scene != scene || item.transform.parent ||
                    !item.TryGetComponent<GrabbableProp>(out var prop) || !prop.isActiveAndEnabled ||
                    item.GetComponent<GripLabSlot>())
                    throw new InvalidOperationException($"Catalog entry '{entry.Id}' must create an active root prop in the new scene without a lab slot.");

                // Match the station's runtime layout: only active, enabled solids on the prop's own body count.
                var body = prop.Body;
                if (!Array.Exists(item.GetComponentsInChildren<Collider>(),
                        collider => collider.enabled && !collider.isTrigger && collider.attachedRigidbody == body))
                    throw new InvalidOperationException($"Catalog entry '{entry.Id}' needs an enabled solid collider on its rigidbody.");

                item.name = entry.DisplayName;
                item.transform.SetParent(parent, true);
                props[i] = new GripLabScene.BakedProp
                {
                    Id = entry.Id, DisplayName = entry.DisplayName, Category = entry.Category, Instance = item
                };
            }
            return props;
        }

        static Transform Cube(string name, Vector3 size, Vector3 center)
        {
            var cube = GameObject.CreatePrimitive(PrimitiveType.Cube);
            cube.name = name;
            cube.transform.localScale = size;
            cube.transform.position = center;
            return cube.transform;
        }
    }
}

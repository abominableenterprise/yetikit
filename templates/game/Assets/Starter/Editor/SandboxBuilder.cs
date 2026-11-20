using System;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.XR.Interaction.Toolkit;
using YetiKit.Interaction;

namespace Game.Starter.Editor
{
    public static class SandboxBuilder
    {
        const string StarterFolder = "Assets/Starter";
        const float RoomSize = 6f, StandHeight = 0.8f, BallDiameter = 0.24f;
        static readonly Vector3 HandleCenter = new(0, 0.095f, 0);

        [MenuItem("Game/Build Starter Sandbox")]
        static void BuildFromMenu()
        {
            var output = StarterFolder + "/Sandbox";
            var path = AssetDatabase.IsValidFolder(output) ? output + "/Sandbox.unity" : Build(output);
            if (!AssetDatabase.LoadAssetAtPath<SceneAsset>(path))
                throw new InvalidOperationException("Remove or rename the incomplete Sandbox folder before building.");
            EditorGUIUtility.PingObject(AssetDatabase.LoadAssetAtPath<SceneAsset>(path));
        }

        // Bake game-owned prefabs and scene into a fresh folder, leaving the caller's scenes open.
        public static string Build(string output)
        {
            var prior = SceneManager.GetActiveScene();
            for (var i = 0; i < SceneManager.sceneCount; i++)
                if (SceneManager.GetSceneAt(i).isLoaded && string.IsNullOrEmpty(SceneManager.GetSceneAt(i).path))
                    throw new InvalidOperationException("Save or close untitled scenes before building the sandbox.");
            var clip = AssetDatabase.LoadAssetAtPath<AudioClip>(StarterFolder + "/Impact.wav");
            if (!clip) throw new InvalidOperationException("The generated impact clip is missing.");
            var parent = Path.GetDirectoryName(output)?.Replace('\\', '/');
            if (parent == null || !AssetDatabase.IsValidFolder(parent) || AssetDatabase.IsValidFolder(output))
                throw new ArgumentException("Choose a new asset folder under an existing folder.", nameof(output));
            var folder = AssetDatabase.CreateFolder(parent, Path.GetFileName(output));
            if (AssetDatabase.GUIDToAssetPath(folder) != output)
            {
                if (!string.IsNullOrEmpty(folder)) AssetDatabase.DeleteAsset(AssetDatabase.GUIDToAssetPath(folder));
                throw new IOException("Could not create the sandbox folder at the requested path.");
            }

            Scene scene = default;
            var complete = false;
            try
            {
                scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Additive);
                SceneManager.SetActiveScene(scene);
                var baseMaterial = Material(output, "Surface", new Color(0.27f, 0.31f, 0.34f));
                var marks = Material(output, "Marks", new Color(0.77f, 0.83f, 0.84f));
                var accent = Material(output, "Accent", new Color(0.92f, 0.55f, 0.19f));
                var recovery = BuildRoom(baseMaterial, marks);
                var manager = new GameObject("Interaction Manager").AddComponent<XRInteractionManager>();
                var ball = BuildProp(output, manager, "Ball", new Vector3(-0.35f, StandHeight + BallDiameter / 2, 0.5f), true, accent);
                var offset = BuildProp(output, manager, "Offset Grip", new Vector3(0.35f, StandHeight + 0.08f, 0.5f), false, accent);
                var targets = new ImpactCue[3];
                for (var i = 0; i < targets.Length; i++)
                {
                    var target = Shape($"Target {i + 1}", PrimitiveType.Cube, new Vector3(i - 1, 1.15f, 2.85f),
                        new Vector3(0.55f, 0.55f, 0.15f), accent);
                    var source = target.AddComponent<AudioSource>();
                    source.playOnAwake = false;
                    source.spatialBlend = 1f;
                    source.clip = clip;
                    targets[i] = target.AddComponent<ImpactCue>();
                }
                new GameObject("Sandbox Bindings").AddComponent<SandboxBindings>().Configure(recovery, new[] { ball, offset }, targets);
                var pads = Material(output, "Pads", new Color(0.12f, 0.65f, 0.72f));
                var arc = new Material(Shader.Find("Sprites/Default"));
                AssetDatabase.CreateAsset(arc, output + "/Aim.mat");
                var controllerMaterial = Material(output, "Controller", new Color(0.14f, 0.46f, 0.86f));
                var jointMaterial = Material(output, "Hand Joints", new Color(0.21f, 0.86f, 0.61f));
                SandboxRigBuilder.Build(manager, pads, arc, new SandboxRigVisuals(output, controllerMaterial, jointMaterial));
                BuildLight();
                var path = output + "/Sandbox.unity";
                if (!EditorSceneManager.SaveScene(scene, path)) throw new IOException("Could not save sandbox scene.");
                complete = true;
                return path;
            }
            finally
            {
                if (scene.IsValid() && scene.isLoaded) EditorSceneManager.CloseScene(scene, true);
                if (prior.IsValid() && prior.isLoaded) SceneManager.SetActiveScene(prior);
                if (!complete) AssetDatabase.DeleteAsset(output);
            }
        }

        static BoxCollider BuildRoom(Material surface, Material marks)
        {
            Shape("Floor", PrimitiveType.Cube, new Vector3(0, -0.05f, 0), new Vector3(RoomSize, 0.1f, RoomSize), surface);
            var grid = new GameObject("Floor Grid").transform;
            for (var m = -2; m <= 2; m++)
            {
                Detail(grid, "Grid X", new Vector3(m, 0.002f, 0), new Vector3(0.015f, 0.004f, RoomSize), marks);
                Detail(grid, "Grid Z", new Vector3(0, 0.005f, m), new Vector3(RoomSize, 0.004f, 0.015f), marks);
            }
            var marker = Shape("Height Marker", PrimitiveType.Cube, new Vector3(-2.6f, 1, 2.6f),
                new Vector3(0.08f, 2, 0.08f), surface);
            for (var i = 1; i <= 4; i++)
                Detail(marker.transform, $"{i * 50} cm", new Vector3(-2.6f, i * 0.5f, 2.6f), new Vector3(0.23f, 0.025f, 0.1f), marks);
            Shape("Prop Stand", PrimitiveType.Cube, new Vector3(0, StandHeight / 2, 0.5f),
                new Vector3(1.12f, StandHeight, 0.55f), surface);
            Shape("Target Backstop", PrimitiveType.Cube, new Vector3(0, 1, 3.05f), new Vector3(RoomSize, 2, 0.1f), surface);
            var recovery = new GameObject("Recovery Volume").AddComponent<BoxCollider>();
            recovery.transform.position = new Vector3(0, -1.5f, 0);
            recovery.size = new Vector3(RoomSize, 1, RoomSize);
            recovery.isTrigger = true;
            return recovery;
        }

        static GrabbableProp BuildProp(string output, XRInteractionManager manager, string name, Vector3 position,
            bool ball, Material material)
        {
            var root = new GameObject(name);
            if (ball)
                Model(root, "Shell", PrimitiveType.Sphere, Vector3.zero, Vector3.one * BallDiameter, material);
            else
            {
                Model(root, "Body", PrimitiveType.Cube, Vector3.zero, new Vector3(0.18f, 0.16f, 0.12f), material);
                Model(root, "Handle", PrimitiveType.Cylinder, HandleCenter, new Vector3(0.065f, 0.055f, 0.065f), material);
                // Unity's cylinder primitive uses a capsule collider. Fit a solid box to the handle.
                var handle = root.transform.Find("Handle").gameObject;
                UnityEngine.Object.DestroyImmediate(handle.GetComponent<Collider>());
                handle.AddComponent<BoxCollider>().size = new Vector3(1, 2, 1);
            }
            var prop = root.AddComponent<GrabbableProp>();
            prop.Body.collisionDetectionMode = CollisionDetectionMode.ContinuousDynamic;
            prop.grip = ball
                ? new GripSpec(GripKind.Cylinder, Vector3.up, Vector3.forward, Vector3.zero, BallDiameter / 2)
                : GripSpec.Oriented(GripKind.Cylinder, Vector3.up, Vector3.forward, HandleCenter, 0.0325f);
            root.GetComponent<PropGrabInteractable>().interactionLayers = SandboxRigBuilder.PropsMask;
            var prefab = PrefabUtility.SaveAsPrefabAsset(root, $"{output}/{name}.prefab");
            UnityEngine.Object.DestroyImmediate(root);
            if (!prefab) throw new IOException($"Could not save {name} prefab.");
            var instance = (GameObject)PrefabUtility.InstantiatePrefab(prefab);
            instance.transform.position = position;
            var grab = instance.GetComponent<PropGrabInteractable>();
            grab.interactionManager = manager;
            PrefabUtility.RecordPrefabInstancePropertyModifications(instance.transform);
            PrefabUtility.RecordPrefabInstancePropertyModifications(grab);
            return instance.GetComponent<GrabbableProp>();
        }

        static void BuildLight()
        {
            var light = new GameObject("Room Light").AddComponent<Light>();
            light.type = LightType.Directional;
            light.transform.rotation = Quaternion.Euler(45, -30, 0);
        }

        static Material Material(string output, string name, Color color)
        {
            var material = new Material(Shader.Find("Standard")) { color = color };
            AssetDatabase.CreateAsset(material, $"{output}/{name}.mat");
            return material;
        }

        static GameObject Shape(string name, PrimitiveType type, Vector3 center, Vector3 size, Material material)
        {
            var obj = GameObject.CreatePrimitive(type);
            obj.name = name;
            obj.transform.SetPositionAndRotation(center, Quaternion.identity);
            obj.transform.localScale = size;
            obj.GetComponent<Renderer>().sharedMaterial = material;
            return obj;
        }

        static void Detail(Transform parent, string name, Vector3 center, Vector3 size, Material material)
        {
            var obj = Shape(name, PrimitiveType.Cube, center, size, material);
            UnityEngine.Object.DestroyImmediate(obj.GetComponent<Collider>());
            obj.transform.SetParent(parent, true);
        }

        static void Model(GameObject root, string name, PrimitiveType type, Vector3 center, Vector3 size, Material material) =>
            Shape(name, type, center, size, material).transform.SetParent(root.transform, false);
    }
}

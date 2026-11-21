using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using YetiKit.Hands;

namespace Game.Starter.Editor
{
    sealed class SandboxRigVisuals
    {
        readonly Mesh controllerMesh, jointMesh;
        readonly GameObject leftController, rightController;
        readonly Material controllerMaterial, handMaterial;

        public SandboxRigVisuals(string output, Material handMaterial, Material controllerMaterial,
            GameObject leftController, GameObject rightController)
        {
            this.leftController = leftController;
            this.rightController = rightController;
            if (controllerMaterial)
                controllerMesh = SavePrimitive(PrimitiveType.Capsule, output + "/Controller Mesh.asset");
            jointMesh = SavePrimitive(PrimitiveType.Sphere, output + "/Hand Joint Mesh.asset");
            this.controllerMaterial = controllerMaterial;
            this.handMaterial = handMaterial;
        }

        public void Build(PlayerHand hand)
        {
            BuildController(hand);
            var model = Child(hand.transform, "Hand Visual");
            model.gameObject.SetActive(false);
            var joints = new Transform[XrHandTracking.AllJoints];
            for (var i = 0; i < joints.Length; i++)
            {
                joints[i] = Model(model, $"Joint {i}", jointMesh, handMaterial);
                // The first two pose slots are wrist and palm; use larger markers there.
                joints[i].localScale = Vector3.one * (i < 2 ? 0.029f : 0.014f);
            }
            var visual = hand.gameObject.AddComponent<TrackedHandVisual>();
            visual.Configure(model.gameObject, joints);
            using var serialized = new SerializedObject(hand);
            serialized.FindProperty("visual").objectReferenceValue = visual;
            serialized.ApplyModifiedPropertiesWithoutUndo();
        }

        void BuildController(PlayerHand hand)
        {
            // The controller root is already gated by ControllerTracking, not by grab or ray state.
            var prefab = hand.RightHand ? rightController : leftController;
            if (prefab)
            {
                var visual = (GameObject)PrefabUtility.InstantiatePrefab(prefab, hand.controller);
                visual.name = "Controller Visual";
                PrefabUtility.RecordPrefabInstancePropertyModifications(visual);
                return;
            }

            var controller = Child(hand.controller, "Controller Visual");
            var grip = Model(controller, "Grip", controllerMesh, controllerMaterial);
            grip.SetLocalPositionAndRotation(new Vector3(0f, -0.015f, -0.028f), Quaternion.Euler(55f, 0f, 0f));
            grip.localScale = new Vector3(0.043f, 0.055f, 0.043f);
        }

        static Transform Child(Transform parent, string name)
        {
            var child = new GameObject(name).transform;
            child.SetParent(parent, false);
            return child;
        }

        static Transform Model(Transform parent, string name, Mesh mesh, Material material)
        {
            var model = Child(parent, name);
            model.gameObject.AddComponent<MeshFilter>().sharedMesh = mesh;
            var renderer = model.gameObject.AddComponent<MeshRenderer>();
            renderer.sharedMaterial = material;
            renderer.shadowCastingMode = ShadowCastingMode.Off;
            renderer.receiveShadows = false;
            return model;
        }

        static Mesh SavePrimitive(PrimitiveType type, string path)
        {
            var primitive = GameObject.CreatePrimitive(type);
            try
            {
                var mesh = Object.Instantiate(primitive.GetComponent<MeshFilter>().sharedMesh);
                mesh.name = type.ToString();
                AssetDatabase.CreateAsset(mesh, path);
                return mesh;
            }
            finally { Object.DestroyImmediate(primitive); }
        }
    }
}

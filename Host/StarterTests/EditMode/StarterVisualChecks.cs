using System.Collections;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.SceneManagement;
using YetiKit.Hands;
using static YetiKit.Starter.HostTests.StarterRigChecks;
using static YetiKit.Starter.HostTests.StarterSandboxTests;

namespace YetiKit.Starter.HostTests
{
    internal static class StarterVisualChecks
    {
        public static void AssertSaved(Scene scene, string output)
        {
            foreach (var hand in Root(scene, "XR Origin").GetComponentsInChildren<PlayerHand>())
            {
                var controller = Visual(hand.controller, "Controller Visual");
                var joints = Visual(hand.transform, "Hand Visual");
                Assert.That(controller.activeSelf, Is.True, "The controller root owns visibility.");
                Assert.That(joints.activeSelf, Is.False, "No joint poses are available in the saved scene.");
                Assert.That(joints.transform.childCount, Is.EqualTo(XrHandTracking.AllJoints));
                Assert.That(hand.Visual, Is.Not.Null, "The saved rig must wire the pose callbacks.");
                const string sample = @"^Assets/Samples/XR Interaction Toolkit/[^/]+/Starter Assets/";
                var side = hand.RightHand ? "Right" : "Left";
                Assert.That(PrefabUtility.GetPrefabAssetPathOfNearestInstanceRoot(controller),
                    Does.Match(sample + $"Prefabs/Controllers/XR Controller {side}\\.prefab$"));
                var meshes = controller.GetComponentsInChildren<MeshFilter>(true);
                Assert.That(meshes, Is.Not.Empty, side);
                foreach (var mesh in meshes)
                    Assert.That(AssetDatabase.GetAssetPath(mesh.sharedMesh), Does.Match(sample + @"Models/UniversalController\.fbx$"));
                var materials = controller.GetComponentsInChildren<MeshRenderer>(true)
                    .SelectMany(renderer => renderer.sharedMaterials).Select(AssetDatabase.GetAssetPath).Distinct();
                Assert.That(materials, Has.Some.Matches<string>(path => path.EndsWith("/Materials/Controller_White.mat")));
                Assert.That(materials, Has.Some.Matches<string>(path => path.EndsWith("/Materials/Controller_Grey.mat")));
                var animator = controller.GetComponentsInChildren<MonoBehaviour>(true)
                    .SingleOrDefault(component => component && component.GetType().Name == "ControllerAnimator");
                Assert.That(animator, Is.Not.Null, side);
                Assert.That(animator.enabled, Is.True, side);
                Assert.That(AssetDatabase.GetAssetPath(MonoScript.FromMonoBehaviour(animator)),
                    Does.Match(sample + @"Scripts/ControllerAnimator\.cs$"));
                Assert.That(controller.GetComponentsInChildren<Collider>(true), Is.Empty);
                Assert.That(joints.GetComponentsInChildren<Collider>(true), Is.Empty);
                foreach (var mesh in joints.GetComponentsInChildren<MeshFilter>(true))
                {
                    Assert.That(AssetDatabase.GetAssetPath(mesh.sharedMesh), Does.StartWith(output + "/"));
                    var renderer = ComponentOn<MeshRenderer>(mesh.gameObject);
                    Assert.That(renderer.enabled, Is.True);
                    Assert.That(AssetDatabase.GetAssetPath(renderer.sharedMaterial), Does.StartWith(output + "/"));
                }
            }
        }

        public static IEnumerator Drive(Scene scene)
        {
            var hands = Root(scene, "XR Origin").GetComponentsInChildren<PlayerHand>();
            var left = hands.Single(h => !h.RightHand);
            var right = hands.Single(h => h.RightHand);
            AssertVisible(left, false, false);
            AssertVisible(right, false, false);
            var tracking = new SyntheticHands { Left = true };
            left.Tracking = right.Tracking = tracking;
            const string leftLayout = "StarterVisualLeft";
            const string rightLayout = "StarterVisualRight";
            var leftDevice = AddController(leftLayout, "LeftHand");
            var rightDevice = AddController(rightLayout, "RightHand");
            try
            {
                yield return Frames(3);
                AssertVisible(left, false, true);
                AssertVisible(right, false, false);
                AssertJointPoses(left, tracking);

                tracking.Right = true;
                var leftPose = new Vector3(-0.3f, 1.2f, 0.4f);
                SetController(leftDevice, leftPose, Quaternion.identity);
                yield return Frames(3);
                AssertVisible(left, true, false);
                AssertVisible(right, false, true);
                AssertJointPoses(right, tracking);

                var parts = Visual(left.controller, "Controller Visual").GetComponentsInChildren<Transform>();
                var stick = parts.Single(part => part.name == "ThumbStick");
                var trigger = parts.Single(part => part.name == "Trigger");
                var grip = parts.Single(part => part.name == "Bumper");
                var gripRest = grip.localPosition.x;
                SetController(leftDevice, leftPose, Quaternion.identity, trigger: true, stick: Vector2.up, grip: true);
                yield return Frames(3);
                Assert.That(Quaternion.Angle(stick.localRotation, Quaternion.Euler(-30f, 0f, 0f)), Is.LessThan(0.1f));
                Assert.That(Quaternion.Angle(trigger.localRotation, Quaternion.Euler(-15f, 0f, 0f)), Is.LessThan(0.1f));
                Assert.That(Mathf.Abs(grip.localPosition.x - gripRest), Is.GreaterThan(0.001f));

                tracking.Offset = 0.1f;
                SetController(leftDevice, Vector3.zero, Quaternion.identity, tracked: false);
                SetController(rightDevice, new Vector3(0.3f, 1.2f, 0.4f), Quaternion.identity);
                yield return Frames(3);
                AssertVisible(left, false, true);
                AssertVisible(right, true, false);
                AssertJointPoses(left, tracking);

                tracking.HasJoints = false;
                yield return Frames(3);
                Assert.That(left.HandTracked, Is.True);
                AssertVisible(left, false, false); // Never leave stale geometry at the previous pose.
                AssertVisible(right, true, false);
                tracking.HasJoints = true;
                yield return Frames(3);
                AssertVisible(left, false, true);

                tracking.Left = tracking.Right = false;
                SetController(rightDevice, Vector3.zero, Quaternion.identity, tracked: false);
                yield return Frames(3);
                AssertVisible(left, false, false);
                AssertVisible(right, false, false);
            }
            finally
            {
                InputSystem.RemoveDevice(leftDevice);
                InputSystem.RemoveDevice(rightDevice);
                InputSystem.RemoveLayout(leftLayout);
                InputSystem.RemoveLayout(rightLayout);
            }
        }

        static GameObject Visual(Transform owner, string name)
        {
            var visual = owner.Find(name);
            Assert.That(visual, Is.Not.Null, $"{owner.name} is missing its {name}.");
            return visual.gameObject;
        }

        static void AssertVisible(PlayerHand hand, bool controller, bool joints)
        {
            Assert.That(Visual(hand.controller, "Controller Visual").activeInHierarchy, Is.EqualTo(controller), hand.name);
            Assert.That(Visual(hand.transform, "Hand Visual").activeInHierarchy, Is.EqualTo(joints), hand.name);
        }

        static void AssertJointPoses(PlayerHand hand, SyntheticHands tracking)
        {
            var group = Visual(hand.transform, "Hand Visual").transform;
            for (var i = 0; i < group.childCount; i++)
            {
                var expected = tracking.Joint(hand.RightHand, i);
                Assert.That(Vector3.Distance(group.GetChild(i).position, hand.transform.parent.TransformPoint(expected.position)),
                    Is.LessThan(0.0001f), $"{hand.name}, joint {i}");
            }
        }

        sealed class SyntheticHands : IHandTracking, IHandJointPoses
        {
            public bool Left, Right, HasJoints = true;
            public float Offset;

            public Pose Joint(bool right, int i) => new(new Vector3(right ? 0.3f : -0.3f, 1.2f + Offset, 0.4f)
                + new Vector3((i % 5) * 0.02f, 0f, (i / 5) * 0.025f), Quaternion.identity);

            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                wrist = Joint(right, 0);
                for (var i = 0; i < points.Length; i++) points[i] = Joint(right, i).position;
                return right ? Right : Left;
            }

            public bool TryGetJointPoses(bool right, Pose[] poses)
            {
                if (!HasJoints || !(right ? Right : Left)) return false;
                for (var i = 0; i < poses.Length; i++) poses[i] = Joint(right, i);
                return true;
            }
        }
    }
}

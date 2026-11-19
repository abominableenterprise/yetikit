using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.XR.ARFoundation;
using YetiKit.Hands;

namespace YetiKit.Lab.Tests
{
    public sealed class GhostHandsOverlayTests
    {
        GameObject space;
        GhostHandsOverlay overlay;

        [TearDown]
        public void Cleanup()
        {
            if (overlay) Invoke("OnDisable");
            Object.DestroyImmediate(space);
        }

        [Test]
        public void GhostFollowsTrackedWristUsingTheRigVisualAndRestoresOpacity()
        {
            space = new GameObject("Tracking space");
            space.transform.SetPositionAndRotation(new Vector3(2, 3, 4), Quaternion.Euler(10, 25, 40));
            var hand = Child("Hand").AddComponent<PlayerHand>();
            var avatar = new Visual(Child("Avatar").transform);
            var tracking = new Tracking();
            hand.Visual = avatar;
            hand.Tracking = tracking;
            var camera = Child("Camera").AddComponent<Camera>();
            var manager = camera.gameObject.AddComponent<ARCameraManager>();
            manager.enabled = false;
            camera.clearFlags = CameraClearFlags.Skybox;
            camera.backgroundColor = Color.blue;

            overlay = Child("Optional overlay").AddComponent<GhostHandsOverlay>();
            var config = new SerializedObject(overlay);
            config.FindProperty("cameraManager").objectReferenceValue = manager;
            config.FindProperty("leftHand").objectReferenceValue = hand;
            config.ApplyModifiedPropertiesWithoutUndo();
            overlay.Opacity = 0.3f;
            Assert.That(manager.enabled, Is.False);
            Invoke("OnEnable");
            Assert.That(manager.enabled, Is.True);
            Assert.That(camera.clearFlags, Is.EqualTo(CameraClearFlags.SolidColor));
            Assert.That(camera.backgroundColor.a, Is.Zero);

            hand.Tick(1f);
            Invoke("LateUpdate");
            Assert.That(Vector3.Distance(avatar.Root.position, space.transform.TransformPoint(tracking.Wrist.position)), Is.LessThan(0.001f));
            Assert.That(Quaternion.Angle(avatar.Root.rotation, space.transform.rotation * tracking.Wrist.rotation), Is.LessThan(0.05f));
            Assert.That(avatar.Alpha, Is.EqualTo(0.3f));
            overlay.Opacity = 0.6f;
            Invoke("LateUpdate");
            Assert.That(avatar.Alpha, Is.EqualTo(0.6f));

            hand.controller = Child("Controller").transform;
            hand.Tick(2f);
            Invoke("LateUpdate");
            Assert.That(avatar.Alpha, Is.EqualTo(Visual.Original));
            hand.controller.gameObject.SetActive(false);
            hand.Tick(3f);
            Invoke("LateUpdate");
            Assert.That(avatar.Alpha, Is.EqualTo(0.6f));

            var replacement = new Visual(Child("Replacement avatar").transform);
            hand.Visual = replacement;
            Invoke("LateUpdate");
            Assert.That(avatar.Alpha, Is.EqualTo(Visual.Original));
            Assert.That(replacement.Alpha, Is.EqualTo(0.6f));

            Invoke("OnDisable");
            Assert.That(hand.Visual, Is.SameAs(replacement));
            Assert.That(replacement.Alpha, Is.EqualTo(Visual.Original));
            Assert.That(manager.enabled, Is.False);
            Assert.That(camera.clearFlags, Is.EqualTo(CameraClearFlags.Skybox));
            Assert.That(camera.backgroundColor, Is.EqualTo(Color.blue));
        }

        GameObject Child(string name)
        {
            var child = new GameObject(name);
            child.transform.SetParent(space.transform, false);
            return child;
        }

        void Invoke(string method) => typeof(GhostHandsOverlay)
            .GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(overlay, null);

        sealed class Visual : IHandVisualAlpha
        {
            public const float Original = 0.85f;
            public readonly Transform Root;
            public Visual(Transform root) => Root = root;
            public float Alpha { get; set; } = Original;
            public void OnPresence(bool present) { }
            public void OnControllerInput(float grip, float trigger) { }
            public void OnPose(Pose wrist, JointCurls curls, Pose[] joints) => Root.SetPositionAndRotation(wrist.position, wrist.rotation);
        }

        sealed class Tracking : IHandTracking
        {
            public readonly Pose Wrist = new Pose(new Vector3(0.3f, 1.2f, 0.4f), Quaternion.Euler(7, 5, 30));
            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                wrist = Wrist;
                for (var i = 0; i < points.Length; i++) points[i] = new Vector3(i % 5, i / 5, i * 0.2f);
                return true;
            }
        }
    }
}

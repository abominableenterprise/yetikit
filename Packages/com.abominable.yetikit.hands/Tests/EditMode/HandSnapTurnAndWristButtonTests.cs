using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Inputs.Readers;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;

namespace YetiKit.Hands.Tests
{
    public class HandSnapTurnAndWristButtonTests
    {
        GameObject root;

        [SetUp]
        public void SetUp() => root = new GameObject("Test rig");

        [TearDown]
        public void TearDown() => Object.DestroyImmediate(root);

        GameObject Child(string name, Transform parent = null)
        {
            var child = new GameObject(name);
            child.transform.SetParent(parent ? parent : root.transform, false);
            return child;
        }

        sealed class FakeTracking : IHandTracking
        {
            public Vector3[] Points;
            public bool Tracked = true;

            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                wrist = Pose.identity;
                if (!Tracked) return false;
                Points.CopyTo(points, 0);
                return true;
            }
        }

        static Vector3[] TurnPose(Vector3 direction)
        {
            var points = HandShapeTests.Hand(0f, 1f, 1f, 1f, 1f);
            for (var i = 0; i < HandCurls.PointsPerFinger; i++) points[i] = direction * (0.03f * i);
            return points;
        }

        [Test]
        public void SnapTurnPulsesTheProviderOncePerPoseAndHonorsCooldown()
        {
            var providerObject = Child("Snap-turn provider");
            providerObject.SetActive(false); // Exercise its input reader without starting XRI locomotion.
            var provider = providerObject.AddComponent<SnapTurnProvider>();
            var hand = Child("Tracked hand").AddComponent<PlayerHand>();
            var tracking = new FakeTracking { Points = TurnPose(Vector3.right) };
            hand.Tracking = tracking;
            var turn = hand.gameObject.AddComponent<HandSnapTurn>();
            turn.hand = hand;
            turn.provider = provider;
            var reader = provider.rightHandTurnInput;
            reader.inputSourceMode = XRInputValueReader.InputSourceMode.ManualValue;
            var stick = reader.manualValue = new Vector2(0.2f, 0.3f);
            turn.Attach();
            Assert.That(reader.bypass, Is.SameAs(turn.Input));
            Assert.That(reader.ReadValue(), Is.EqualTo(stick));

            int Step(float now)
            {
                hand.Tick(now);
                return turn.Tick(now, 0.02f, false);
            }

            Assert.That(Step(0f), Is.Zero);
            Assert.That(Step(0.25f), Is.Zero, "still dwelling");
            Assert.That(Step(0.31f), Is.EqualTo(1));
            Assert.That(reader.ReadValue(), Is.EqualTo(Vector2.right));
            Assert.That(reader.ReadValue(), Is.EqualTo(stick), "pulse is consumed once");

            tracking.Points = HandShapeTests.Hand(0f, 0f, 0f, 0f, 0f);
            Assert.That(Step(0.33f), Is.Zero);
            tracking.Points = TurnPose(Vector3.left);
            Assert.That(Step(0.35f), Is.Zero);
            Assert.That(Step(0.70f), Is.Zero, "the new pose has dwelled but is still on cooldown");
            Assert.That(reader.ReadValue(), Is.EqualTo(stick));
            Assert.That(Step(0.92f), Is.EqualTo(-1));
            Assert.That(reader.ReadValue(), Is.EqualTo(Vector2.left));
            Assert.That(Step(2f), Is.Zero, "a held pose cannot pulse again after cooldown");
            Assert.That(reader.ReadValue(), Is.EqualTo(stick));

            turn.provider = null;
            turn.Attach();
            Assert.That(reader.bypass, Is.Null);
        }

        [Test]
        public void FrozenTrackedSampleDoesNotAdvanceTurnDwell()
        {
            var hand = Child("Tracked hand").AddComponent<PlayerHand>();
            hand.Tracking = new FakeTracking { Points = TurnPose(Vector3.right) };
            var turn = hand.gameObject.AddComponent<HandSnapTurn>();
            turn.hand = hand;

            hand.Tick(0f);
            Assert.That(turn.Tick(0f, 0.02f, false), Is.Zero);
            Assert.That(hand.HandTracked, Is.True);
            Assert.That(turn.Tick(HandTurnGesture.HoldTime + 0.01f, 0.02f, false), Is.Zero,
                "an unchanged sample timestamp cannot complete the turn dwell");
            Assert.That(turn.Input.Pending, Is.Zero);

            hand.Tick(1f);
            Assert.That(turn.Tick(1f, 0.02f, false), Is.Zero, "dwell restarts on a fresh sample");
            var ready = 1f + HandTurnGesture.HoldTime + 0.01f;
            hand.Tick(ready);
            Assert.That(turn.Tick(ready, 0.02f, false), Is.EqualTo(1));
        }

        [Test]
        public void SnapTurnDiscardsProgressWhileTeleportIsBusyAndClearsPulsesOnHandLoss()
        {
            var hand = Child("Tracked hand").AddComponent<PlayerHand>();
            var tracking = new FakeTracking { Points = TurnPose(Vector3.right) };
            hand.Tracking = tracking;
            var teleport = hand.gameObject.AddComponent<HandTeleport>();
            var turn = hand.gameObject.AddComponent<HandSnapTurn>();
            turn.hand = hand;
            turn.teleport = teleport;

            int Step(float now)
            {
                hand.Tick(now);
                return turn.Tick(now, 0.02f, false);
            }

            Assert.That(Step(0f), Is.Zero);
            teleport.Gesture.Tick(true, true, true, 0f, 0f, false, 0f);
            teleport.Gesture.Tick(true, true, true, 0f, 0f, false, 0.31f);
            teleport.Gesture.Tick(true, true, true, 0f, 1f, false, 0.32f);
            Assert.That(teleport.Gesture.Busy, Is.True);
            Assert.That(teleport.Gesture.Aiming, Is.False, "the release latch alone blocks the turn");
            Assert.That(Step(0.35f), Is.Zero);
            teleport.Gesture.Reset();
            Assert.That(Step(0.4f), Is.Zero, "the turn dwell must restart");
            Assert.That(Step(0.75f), Is.EqualTo(1));
            Assert.That(turn.Input.Pending, Is.EqualTo(1));

            tracking.Tracked = false;
            Assert.That(Step(0.8f), Is.Zero);
            Assert.That(turn.Input.Pending, Is.Zero);
            tracking.Tracked = true;
            Assert.That(Step(1.5f), Is.Zero, "a dropout does not release the fired pose");

            turn.Input.Pulse(1);
            hand.enabled = false;
            Assert.That(Step(1.6f), Is.Zero);
            Assert.That(turn.Input.Pending, Is.Zero);
            Assert.That(turn.Gesture.Pose, Is.Zero);

            turn.Input.Pulse(1);
            turn.hand = null;
            Assert.That(Step(1.7f), Is.Zero);
            Assert.That(turn.Input.Pending, Is.Zero);
        }

        [Test]
        public void WristButtonLatchesAndRaisesBothEventsOnlyOnAcceptedPresses()
        {
            var wearer = Child("Wearer").AddComponent<PlayerHand>();
            wearer.rightHand = false;
            var wearerTracking = new FakeTracking { Points = HandShapeTests.Hand(0f, 0f, 0f, 0f, 0f) };
            wearer.Tracking = wearerTracking;
            var presser = Child("Presser").AddComponent<PlayerHand>();
            var presserTracking = new FakeTracking { Points = HandShapeTests.Hand(0f, 0f, 1f, 1f, 1f) };
            presser.Tracking = presserTracking;
            var button = Child("Wrist button", wearer.transform).AddComponent<WristButton>();
            button.wearer = wearer;
            button.presser = presser;
            button.visual = Child("Visual", button.transform);
            var actionCount = 0;
            var unityEventCount = 0;
            button.Pressed += () => actionCount++;
            button.onPressed.AddListener(() => unityEventCount++);
            var contact = presserTracking.Points[PinchStrength.IndexTip];

            bool Step(float now, float offset)
            {
                wearer.Tick(now);
                presser.Tick(now);
                button.transform.position = contact + Vector3.right * offset;
                return button.Tick(now);
            }

            Assert.That(Step(0f, 0f), Is.True);
            Assert.That(button.visual.activeSelf, Is.True);
            Assert.That(Step(0.1f, 0.025f), Is.False, "inside exit margin");
            Assert.That(Step(0.2f, 0f), Is.False);
            Assert.That(Step(0.3f, 0.04f), Is.False);
            Assert.That(Step(0.4f, 0f), Is.False, "entry during cooldown is consumed");
            Assert.That(Step(1f, 0f), Is.False, "expiration does not fire a held contact");
            Assert.That(actionCount, Is.EqualTo(1));
            Assert.That(unityEventCount, Is.EqualTo(1));

            wearerTracking.Tracked = false;
            Assert.That(Step(1.1f, 0f), Is.False);
            Assert.That(button.visual.activeSelf, Is.False);
            wearerTracking.Tracked = true;
            Assert.That(Step(1.2f, 0f), Is.True, "tracking loss releases the contact latch");
            Assert.That(button.visual.activeSelf, Is.True);
            Assert.That(actionCount, Is.EqualTo(2));
            Assert.That(unityEventCount, Is.EqualTo(2));
        }
    }
}

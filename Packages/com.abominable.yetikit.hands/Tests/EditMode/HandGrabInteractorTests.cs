using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Interactors;

namespace YetiKit.Hands.Tests
{
    public class HandGrabInteractorTests
    {
        GameObject rig;

        [TearDown]
        public void TearDown() => Object.DestroyImmediate(rig);

        [TestCase(false)]
        [TestCase(true)]
        public void TrackingLossDuringGripReleasesExactlyOnce(bool switchToController)
        {
            rig = new GameObject("Tracking space");
            var manager = rig.AddComponent<XRInteractionManager>();
            var root = Child("Hand", rig.transform);
            var tracking = new GripTracking();
            var hand = root.AddComponent<PlayerHand>();
            hand.Tracking = tracking;
            var grab = Child("Near grab", root.transform);
            grab.AddComponent<SphereCollider>().isTrigger = true;
            var interactor = grab.AddComponent<HandGrabInteractor>();
            interactor.interactionManager = manager;
            hand.grabber = interactor;
            var targetObject = Child("Target", rig.transform);
            targetObject.AddComponent<BoxCollider>();
            var target = targetObject.AddComponent<XRSimpleInteractable>();
            target.interactionManager = manager;
            // EditMode does not run XRI's play-mode registration callbacks.
            manager.RegisterInteractor((IXRInteractor)interactor);
            manager.RegisterInteractable((IXRInteractable)target);
            var releases = 0;
            var releasePosition = Vector3.zero;
            interactor.selectExited.AddListener(_ =>
            {
                releases++;
                releasePosition = hand.transform.position;
            });

            var now = Time.time;
            hand.Tick(now);
            interactor.PreprocessInteractor(XRInteractionUpdateOrder.UpdatePhase.Dynamic);
            Assert.That(interactor.transform.position, Is.EqualTo(hand.PalmPose.position));
            hand.GrabBlocked = true;
            Assert.That(interactor.isSelectActive, Is.False);
            hand.GrabBlocked = false;
            hand.FarInteraction.Hover(this, true);
            Assert.That(interactor.isSelectActive, Is.False);
            hand.FarInteraction.Hover(this, false);
            Assert.That(interactor.isSelectActive, Is.True, "fist can start a select");
            manager.SelectEnter((IXRSelectInteractor)interactor, target);
            Assert.That(interactor.hasSelection, Is.True);
            Assert.That(target.isSelected, Is.True);

            hand.GrabBlocked = true;
            hand.FarInteraction.Hover(this, true);
            var previousRoot = hand.transform.position;
            tracking.Tracked = false;
            hand.Tick(now + 0.01f);
            Assert.That(interactor.hasSelection && interactor.isSelectActive, Is.True, "keep the existing hold in grace");
            Assert.That(releases, Is.Zero);

            if (switchToController)
            {
                hand.controller = Child("Controller", rig.transform).transform;
                hand.controller.position = Vector3.right;
                hand.Sync();
                Assert.That(hand.Mode, Is.EqualTo(HandMode.Controller));
                Assert.That(hand.transform.position, Is.EqualTo(hand.controller.position));
            }
            else hand.Tick(now + HandGrabGesture.LostGrace + 0.02f);
            Assert.That(interactor.hasSelection, Is.False, "expiry must release the XRI selection");
            Assert.That(target.isSelected, Is.False);
            Assert.That(interactor.isSelectActive, Is.False);
            Assert.That(releases, Is.EqualTo(1));
            Assert.That(releasePosition, Is.EqualTo(previousRoot));
            hand.Tick(now + HandGrabGesture.LostGrace + 0.03f);
            Assert.That(releases, Is.EqualTo(1));
        }

        static GameObject Child(string name, Transform parent)
        {
            var child = new GameObject(name);
            child.transform.SetParent(parent, false);
            return child;
        }

        sealed class GripTracking : IHandTracking
        {
            readonly Vector3[] points = HandShapeTests.Hand(0f, 1f, 1f, 1f, 1f);
            public bool Tracked = true;

            public bool TryGetHand(bool right, Vector3[] into, out Pose wrist)
            {
                wrist = Pose.identity;
                if (!Tracked) return false;
                points.CopyTo(into, 0);
                return true;
            }
        }
    }
}

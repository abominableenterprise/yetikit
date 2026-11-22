using System;
using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using YetiKit.Hands;
using YetiKit.Interaction;
using Object = UnityEngine.Object;

namespace YetiKit.Playtest.XR.Tests
{
    public class XRProducerTests
    {
        GameObject root;

        [TearDown]
        public void TearDown()
        {
            if (root) Object.DestroyImmediate(root);
        }

        [Test]
        public void SamplesTrackedJointsThenFallsBackToControllerPose()
        {
            root = new GameObject("Tracking space");
            root.transform.position = Vector3.right * 2;
            var hand = Child("Hand").AddComponent<PlayerHand>();
            hand.controller = Child("Controller").transform;
            hand.controller.position = new Vector3(4, 5, 6);
            hand.controller.gameObject.SetActive(false);
            var tracking = new Tracking();
            hand.Tracking = tracking;
            hand.Tick(1f);
            hand.controller.gameObject.SetActive(true);

            var sampler = new HandSampler(right => right ? hand : null);
            var tracked = sampler.Sample();
            Assert.That(tracked, Does.Contain("\"L\":{\"mode\":\"none\"}"));
            Assert.That(tracked, Does.Contain("\"R\":{\"mode\":\"hand\""));
            Assert.That(tracked, Does.Contain("\"j\":[2,0,1,0,0,0,1"));

            tracking.Joints = false;
            var controller = sampler.Sample();
            Assert.That(controller, Does.Contain("\"R\":{\"mode\":\"ctl\",\"p\":[4,5,6]"));
            Assert.That(controller, Does.Not.Contain("\"j\""));
            hand.controller.gameObject.SetActive(false);
            Assert.That(sampler.Sample(), Does.Contain("\"R\":{\"mode\":\"hand\""));
            hand.enabled = false;
            Assert.That(sampler.Sample(), Does.Contain("\"R\":{\"mode\":\"none\"}"));
        }

        [UnityTest]
        public IEnumerator WritesGrabThenReleaseAndCommittedThrowThroughFlightLog()
        {
            yield return new EnterPlayMode();
            root = new GameObject("Synthetic interaction");
            var manager = root.AddComponent<XRInteractionManager>();
            var propObject = Child("Prop");
            propObject.AddComponent<BoxCollider>();
            propObject.AddComponent<Rigidbody>().useGravity = false;
            var prop = propObject.AddComponent<PropGrabInteractable>();
            prop.interactionManager = manager;
            prop.movementType = XRBaseInteractable.MovementType.VelocityTracking;
            prop.AddComponent<GrabbableProp>();
            var controller = Child("Controller");
            var motion = controller.AddComponent<ControllerMotion>();
            controller.AddComponent<SphereCollider>().isTrigger = true;
            var interactor = controller.AddComponent<XRDirectInteractor>();
            interactor.interactionManager = manager;

            var log = new FlightLog(() => 1);
            var events = new FlightEvents(prop, "test\"prop");
            using (log.Register(events))
            {
                Release(0);
                Release(4);
                Assert.That(log.Count("grab"), Is.EqualTo(2));
                Assert.That(log.Count("release"), Is.EqualTo(2));
                Assert.That(log.Count("throw"), Is.EqualTo(1), "a set-down is not a throw");
                var records = log.Buffer.ToString();
                Assert.That(records, Does.Contain("\"k\":\"grab\",\"id\":\"test\\\"prop\""));
                Assert.That(records, Does.Contain("\"k\":\"release\",\"id\":\"test\\\"prop\""));
                Assert.That(records, Does.Contain("\"k\":\"throw\",\"id\":\"test\\\"prop\",\"v\":["));
                Assert.That(records.LastIndexOf("\"release\"", StringComparison.Ordinal),
                    Is.LessThan(records.IndexOf("\"throw\"", StringComparison.Ordinal)));
            }
            Release(0);
            Assert.That(log.Count("grab"), Is.EqualTo(2));
            Object.DestroyImmediate(root);
            yield return new ExitPlayMode();

            void Release(float speed)
            {
                manager.SelectEnter(interactor, prop);
                motion.SampleThisFrame();
                motion.History.Clear();
                motion.History.Add(new ThrowSample(Time.time - 0.01f, Vector3.right * speed, Vector3.zero, ControllerMotion.FrameDelta));
                motion.History.Add(new ThrowSample(Time.time, Vector3.right * speed, Vector3.zero, ControllerMotion.FrameDelta));
                manager.SelectExit(interactor, prop);
                prop.FinishLateRelease();
                prop.ProcessInteractable(XRInteractionUpdateOrder.UpdatePhase.Late);
            }
        }

        GameObject Child(string name)
        {
            var child = new GameObject(name);
            child.transform.SetParent(root.transform, false);
            return child;
        }

        sealed class Tracking : IHandTracking, IHandJointPoses
        {
            public bool Joints = true;

            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                wrist = Pose.identity;
                for (var i = 0; i < points.Length; i++) points[i] = Vector3.forward * (i * 0.01f);
                return true;
            }

            public bool TryGetJointPoses(bool right, Pose[] poses)
            {
                for (var i = 0; i < poses.Length; i++) poses[i] = new Pose(Vector3.forward, Quaternion.identity);
                return Joints;
            }
        }
    }
}

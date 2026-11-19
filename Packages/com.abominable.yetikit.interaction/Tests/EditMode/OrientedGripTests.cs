using NUnit.Framework;
using UnityEngine;
using YetiKit.Hands;

namespace YetiKit.Interaction.Tests
{
    public class OrientedGripTests
    {
        [TestCase(HandMode.None, false, false)]
        [TestCase(HandMode.None, true, false)]
        [TestCase(HandMode.None, false, true)]
        [TestCase(HandMode.None, true, true)]
        [TestCase(HandMode.TrackedHand, false, false)]
        [TestCase(HandMode.TrackedHand, true, false)]
        [TestCase(HandMode.TrackedHand, false, true)]
        [TestCase(HandMode.TrackedHand, true, true)]
        public void HandedFlagsTurnTheLeftOrientedGripAboutTheGloveBasis(HandMode mode, bool handed, bool faceToWrist)
        {
            var propObject = new GameObject("Synthetic prop");
            var glove = new GameObject("Synthetic glove");
            try
            {
                propObject.SetActive(false);
                var prop = propObject.AddComponent<GrabbableProp>();
                prop.grip = GripSpec.Oriented(GripKind.Cylinder, new Vector3(1f, 2f, 0f),
                    new Vector3(1f, 0f, 3f), new Vector3(0.01f, 0.02f, -0.01f), 0.03f);
                var profile = GripSpec.Oriented(GripKind.Pinch, new Vector3(-1f, 3f, 1f),
                    new Vector3(0f, 1f, 2f), new Vector3(0.02f, -0.01f, 0.03f), 0.02f);
                prop.gripProfiles.hand = new GripProfile("synthetic", profile);
                prop.handed = handed;
                prop.faceToWrist = faceToWrist;

                var authored = mode == HandMode.TrackedHand ? profile : prop.grip;
                var model = glove.transform;
                model.SetPositionAndRotation(new Vector3(1f, 2f, 3f), Quaternion.Euler(20f, 40f, 15f));
                var knuckles = new Vector3(0.01f, 0.02f, 0.12f);
                CheckPose(prop.GripFor(true, mode), Quaternion.identity);

                model.localScale = new Vector3(-1f, 1f, 1f);
                // The flags are half-turns about the glove's thumb axis and palm normal, not the prop's tilted axes.
                var turn = Quaternion.identity;
                if (handed) turn = Quaternion.AngleAxis(180f, model.TransformVector(Vector3.up)) * turn;
                if (faceToWrist) turn = Quaternion.AngleAxis(180f, model.TransformVector(Vector3.right)) * turn;
                CheckPose(prop.GripFor(false, mode), turn);
                if (mode == HandMode.None) CheckPose(prop.GripFor(false), turn);

                void CheckPose(GripSpec resolved, Quaternion expectedTurn)
                {
                    var pose = GripPlacement.PropPose(model, knuckles, resolved);
                    Assert.That(Vector3.Distance(pose.rotation * Vector3.up,
                        expectedTurn * model.TransformVector(authored.handUp)), Is.LessThan(1e-4f), "prop +Y");
                    Assert.That(Vector3.Distance(pose.rotation * Vector3.forward,
                        expectedTurn * model.TransformVector(authored.handForward)), Is.LessThan(1e-4f), "prop +Z");
                    Assert.That(Vector3.Distance(pose.position + pose.rotation * authored.center,
                        model.TransformPoint(authored.ModelPoint(knuckles))), Is.LessThan(1e-4f), "grip center");
                }
            }
            finally
            {
                Object.DestroyImmediate(propObject);
                Object.DestroyImmediate(glove);
            }
        }
    }
}

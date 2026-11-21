using System;
using System.Collections;
using System.IO;
using System.Linq;
using Game.Dev;
using NUnit.Framework;
using Unity.XR.CoreUtils;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.SceneManagement;
using UnityEngine.UI;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;
using YetiKit.Interaction;
using YetiKit.Lab;
using static YetiKit.Starter.HostTests.StarterRigChecks;
using static YetiKit.Starter.HostTests.StarterSandboxTests;

namespace YetiKit.Starter.HostTests
{
    static class StarterWristChecks
    {
        public static IEnumerator Drive(string path)
        {
            StarterLabChecks.BackupPrefs();
            const string unreadable = "{broken";
            PlayerPrefs.SetString(StarterLabChecks.CompactKey, unreadable);
            var scene = StarterLabChecks.Load(path);
            yield return null;
            var lab = ComponentOn<StarterLab>(Root(scene, "Sandbox Bindings"));
            var wrist = lab.transform.Find("Starter Lab Wrist");
            Assert.That(wrist, Is.Not.Null, "Trackable starter rig must install a runtime wrist panel.");
            var canvas = wrist.GetComponentInChildren<Canvas>(true);
            Assert.That(canvas.renderMode, Is.EqualTo(RenderMode.WorldSpace));
            Assert.That(canvas.gameObject.activeSelf, Is.False, "No wrist pose on desktop.");
            var origin = ComponentOn<XROrigin>(Root(scene, "XR Origin"));
            var right = origin.GetComponentsInChildren<PlayerHand>().Single(h => h.RightHand);
            var space = right.transform.parent;
            var ray = right.GetComponent<PointPinchTeleport>().controllerRay;
            var direct = right.controller.GetComponent<XRDirectInteractor>();
            var prop = Root(scene, "Ball").GetComponent<GrabbableProp>();
            var pad = Root(scene, "Right Teleport Pad").GetComponent<TeleportationArea>();
            var landing = space.InverseTransformPoint(pad.transform.position + Vector3.up);
            var down = Quaternion.Euler(90, 0, 0);
            var teleports = 0;
            pad.teleporting.AddListener(_ => teleports++);

            const string layout = "StarterWristController";
            var leftDevice = AddController(layout, "LeftHand");
            var rightDevice = (UnityEngine.InputSystem.XR.XRController)InputSystem.AddDevice(layout);
            InputSystem.SetDeviceUsage(rightDevice, "RightHand");
            var leftPose = new Vector3(-0.14f, 1.28f, 0.55f);
            try
            {
                SetController(leftDevice, leftPose, Quaternion.identity);
                SetController(rightDevice, landing, down);
                yield return Frames(3);
                Assert.That(canvas.gameObject.activeSelf, Is.True);
                Assert.That(lab.CurrentId, Is.Null);
                Capture(origin.Camera, lab, "Wrist-Start");

                // A real XRI pad selection must be cancelled, not confirmed, when the trigger is dragged onto UI.
                SetController(rightDevice, landing, down, trigger: true);
                yield return Frames(3);
                Assert.That(ray.IsSelecting(pad), Is.True);
                Aim("Wide turn", trigger: true);
                yield return Frames(3);
                Assert.That(ray.isActiveAndEnabled, Is.False);
                Aim("Wide turn");
                yield return Frames(3);
                Assert.That(teleports, Is.Zero);
                Assert.That(lab.CurrentId, Is.Null, "A trigger press that began in the room is not an UI click.");

                // Put an actual prop within direct-grab range of the UI pointer.
                var wide = Center("Wide turn");
                var approach = wide - canvas.transform.forward * 0.18f;
                var propStart = prop.Body.position;
                prop.Body.isKinematic = true;
                prop.Body.position = approach;
                Physics.SyncTransforms();
                Aim("Wide turn", trigger: true, grip: true);
                yield return Frames(3);
                Assert.That(direct.allowSelect || prop.Held, Is.False);
                Assert.That(ray.isActiveAndEnabled, Is.False);
                Aim("Wide turn", grip: true);
                yield return Frames(3);
                Assert.That(lab.CurrentId, Is.EqualTo(StarterLab.Wide));
                Assert.That(lab.Angle.Get(), Is.EqualTo(45f));
                prop.transform.position = prop.Body.position = propStart;
                Physics.SyncTransforms();

                // Neither held button may leak into a fresh room select after leaving the panel.
                Aim("+5°", trigger: true, grip: true);
                yield return Frames(3);
                SetController(rightDevice, landing, down, trigger: true, grip: true);
                yield return Frames(3);
                Assert.That(direct.allowSelect || ray.isActiveAndEnabled, Is.False);
                SetController(rightDevice, landing, down);
                yield return Frames(3);
                Assert.That(direct.allowSelect && ray.isActiveAndEnabled, Is.True);
                Assert.That(teleports, Is.Zero);
                Assert.That(lab.Angle.Get(), Is.EqualTo(45f), "Dragging off cancels the edit.");

                yield return Click("+5°");
                Assert.That(lab.Angle.Get(), Is.EqualTo(50f));
                Assert.That(Status(), Does.Contain("50° (override)").And.Contain("default: 45°"));
                using (var photo = new StarterPhotoChecks(lab))
                {
                    yield return Click("Photo snap");
                    photo.AssertLocalSnap(lab, StarterLab.Wide, 50f, 45f, hasOverride: true);
                    Assert.That(canvas.GetComponentsInChildren<Text>().Single(text => text.name == "Photo status").text,
                        Is.EqualTo("Photo saved locally."));
                    Capture(origin.Camera, lab, "Wrist-Override");
                }

                Aim("Reset", trigger: true);
                yield return Frames(3);
                SetController(leftDevice, Vector3.zero, Quaternion.identity, tracked: false);
                yield return Frames(3);
                Assert.That(canvas.gameObject.activeSelf || ray.isActiveAndEnabled, Is.False);
                SetController(leftDevice, leftPose, Quaternion.identity);
                yield return Frames(3);
                Aim("Reset");
                yield return Frames(3);
                Assert.That(lab.Angle.Get(), Is.EqualTo(50f), "Tracking loss cancels a pending click.");

                // Hand tracking takes over and edits through the fingertip, not the UGUI callback fixture.
                var fingers = new FingerPose();
                right.Tracking = fingers;
                SetController(rightDevice, landing, down, tracked: false);
                fingers.Tip = space.InverseTransformPoint(Center("Reset") - canvas.transform.forward * 0.07f);
                yield return Frames(3);
                var aim = right.GetComponent<PointPinchTeleport>();
                Assert.That(right.HandTracked && right.FarInteraction.UiHover, Is.True);
                var grabEntries = 0;
                right.grabber.selectEntered.AddListener(_ => grabEntries++);
                // A touch near the card stays UI-owned, even if the thumb moves in.
                fingers.ThumbDown = true;
                fingers.Tip = space.InverseTransformPoint(Center("Reset"));
                yield return Frames(3);
                Assert.That(lab.Angle.Get(), Is.EqualTo(45f));
                Assert.That(right.Hammer, Is.GreaterThanOrEqualTo(HandTeleportGesture.ConfirmDrop));
                Assert.That(aim.Aiming || aim.Aim.HasTarget || right.grabber.hasSelection, Is.False);
                fingers.ThumbDown = false;
                fingers.Pinch = true;
                fingers.Tip = space.InverseTransformPoint(Center("Reset") + canvas.transform.right * 0.31f);
                yield return Frames(3);
                Assert.That(right.Grab.Pinching && right.FarInteraction.UiHover, Is.True,
                    "A pinch that leaves the card remains UI-owned until the hand opens.");
                Assert.That(right.grabber.isSelectActive, Is.False);
                fingers.Pinch = false;
                yield return Frames(3);
                Assert.That(right.FarInteraction.UiHover, Is.False);
                Assert.That(grabEntries, Is.Zero);

                // One continuous poke passes well behind the collider-free card, then returns through it.
                yield return PlaceTip(0.07f);
                yield return PlaceTip(0.01f);
                Assert.That(lab.Angle.Get(), Is.EqualTo(50f), "The approach activates +5°.");
                yield return PlaceTip(-0.07f);
                yield return PlaceTip(-0.20f); // Also leave the guard's reach, but on the back side.
                yield return PlaceTip(-0.01f);
                yield return PlaceTip(0.01f);
                yield return PlaceTip(0.07f);
                yield return new WaitForSecondsRealtime(0.5f);
                var savedAngle = 45f;
                new Tuning("starter-sandbox." + StarterLab.Wide).Float("Snap turn",
                    () => savedAngle, value => savedAngle = value, 45f, 15f, 90f, 5f);
                Capture(origin.Camera, lab, "Wrist-Poke");
                Assert.That(savedAngle, Is.EqualTo(50f), "One through-and-back poke must save just one +5° edit.");

                // A full withdrawal rearms; crossing only the inner threshold does not.
                yield return PlaceTip(0.01f);
                Assert.That(lab.Angle.Get(), Is.EqualTo(55f), "A new approach activates +5° again.");
                yield return PlaceTip(0.023f);
                yield return PlaceTip(0.01f);
                Assert.That(lab.Angle.Get(), Is.EqualTo(55f), "Jitter within the exit margin does not rearm.");
                yield return PlaceTip(0.04f);
                yield return PlaceTip(0.01f);
                Assert.That(lab.Angle.Get(), Is.EqualTo(60f), "Withdrawal within UI reach can rearm too.");

                IEnumerator PlaceTip(float frontDepth)
                {
                    fingers.Tip = space.InverseTransformPoint(Center("+5°") - canvas.transform.forward * frontDepth);
                    return Frames(3);
                }

                yield return Click("Compact turn");
                Assert.That(lab.CurrentId, Is.EqualTo(StarterLab.Compact));
                Assert.That(lab.Angle, Is.Null);
                Assert.That(Status(), Does.Contain("30° (default)").And.Contain("Persistence unavailable"));
                foreach (var control in new[] { "+5°", "−5°", "Reset" })
                {
                    Assert.That(Find(control).interactable, Is.False);
                    yield return Click(control);
                }
                Assert.That(PlayerPrefs.GetString(StarterLabChecks.CompactKey), Is.EqualTo(unreadable));
                Assert.That(teleports, Is.Zero);
            }
            finally
            {
                InputSystem.RemoveDevice(rightDevice);
                InputSystem.RemoveDevice(leftDevice);
                InputSystem.RemoveLayout(layout);
            }

            Button Find(string name) => canvas.GetComponentsInChildren<Button>().Single(button => button.name == name);
            string Status() => canvas.GetComponentsInChildren<Text>().Single(text => text.name == "Tuning status").text;
            Vector3 Center(string name)
            {
                var rect = (RectTransform)Find(name).transform;
                return rect.TransformPoint(rect.rect.center);
            }
            void Aim(string name, bool trigger = false, bool grip = false)
            {
                var point = Center(name);
                var toward = canvas.transform.forward;
                SetController(rightDevice, space.InverseTransformPoint(point - toward * 0.18f),
                    Quaternion.Inverse(space.rotation) * Quaternion.LookRotation(toward), trigger, grip: grip);
            }
            IEnumerator Click(string name)
            {
                Aim(name);
                yield return Frames(3);
                Aim(name, trigger: true);
                yield return Frames(3);
                Aim(name);
                yield return Frames(3);
            }
        }

        static void Capture(Camera camera, StarterLab lab, string fixture)
        {
            var dir = Environment.GetEnvironmentVariable("YETIKIT_STARTER_LAB_CAPTURE");
            if (string.IsNullOrEmpty(dir)) return;
            var desktop = lab.GetComponentsInChildren<Canvas>().Single(c => c.renderMode == RenderMode.ScreenSpaceOverlay);
            var target = RenderTexture.GetTemporary(768, 480, 24);
            var image = new Texture2D(target.width, target.height, TextureFormat.RGB24, false);
            var prior = RenderTexture.active;
            var fov = camera.fieldOfView;
            try
            {
                desktop.enabled = false;
                camera.fieldOfView = 43f;
                camera.targetTexture = target;
                Canvas.ForceUpdateCanvases();
                camera.Render();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0);
                image.Apply();
                File.WriteAllBytes(Path.Combine(dir, fixture + ".png"), image.EncodeToPNG());
            }
            finally
            {
                camera.fieldOfView = fov;
                camera.targetTexture = null;
                desktop.enabled = true;
                RenderTexture.active = prior;
                RenderTexture.ReleaseTemporary(target);
                UnityEngine.Object.Destroy(image);
            }
        }

        sealed class FingerPose : IHandTracking
        {
            public Vector3 Tip;
            public bool Pinch, ThumbDown;
            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                wrist = new Pose(Tip - Vector3.forward * 0.1f, Quaternion.identity);
                for (var finger = 0; finger < FingerCurls.Fingers; finger++)
                for (var joint = 0; joint < HandCurls.PointsPerFinger; joint++)
                    points[finger * HandCurls.PointsPerFinger + joint] = Tip +
                        Vector3.right * ((finger - FingerCurls.Index) * 0.05f) + Vector3.forward * ((joint - 4) * 0.025f);
                if (Pinch) points[PinchStrength.ThumbTip] = Tip;
                if (ThumbDown) points[PinchStrength.ThumbTip] = points[ThumbHammer.IndexProximal];
                return right;
            }
        }
    }
}

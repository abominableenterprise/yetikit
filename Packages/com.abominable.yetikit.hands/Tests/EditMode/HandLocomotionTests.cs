using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Inputs.Readers;

namespace YetiKit.Hands.Tests
{
    /// <summary>Teleport and turn gestures, arc sampling, and snap-turn input.</summary>
    public class HandLocomotionTests
    {
        // Tick(tracked, point, forward, hammer, pinch, holding, now): hammer = the thumb drop (ThumbHammer), pinch = the
        // thumb-index pinch (PinchStrength).

        [Test]
        public void APointHeldForTheArmTimeAimsAndAThumbDropConfirms()
        {
            var g = new HandTeleportGesture();
            Assert.That(g.Tick(true, true, true, 0f, 0f, false, 0f), Is.False);
            g.Tick(true, true, true, 0f, 0f, false, HandTeleportGesture.ArmTime - 0.05f);
            Assert.That(g.Aiming, Is.False, "not before 0.3 s");
            g.Tick(true, true, true, 0f, 0f, false, HandTeleportGesture.ArmTime + 0.01f);
            Assert.That(g.Aiming, Is.True);
            Assert.That(g.Tick(true, false, true, 0.6f, 0f, false, 0.4f), Is.False, "a dropping thumb may bend the index: still aiming");
            Assert.That(g.Aiming, Is.True);
            Assert.That(g.Tick(true, false, true, 0.9f, 0f, false, 0.45f), Is.True, "the thumb drop confirms once");
            Assert.That(g.Aiming, Is.False);
            Assert.That(g.Busy, Is.True, "until the thumb lifts");
        }

        [Test]
        public void AThumbDownPointNeverAims()
        {
            var g = new HandTeleportGesture();
            for (var t = 0f; t < 1f; t += 0.05f) Assert.That(g.Tick(true, true, true, 0.9f, 0f, false, t), Is.False);
            Assert.That(g.Aiming, Is.False, "a point with the thumb already down (a lazy point, a fist's trigger) never aims");
            for (var t = 1f; t < 2f; t += 0.05f) g.Tick(true, true, true, 0.6f, 0f, false, t);
            Assert.That(g.Aiming, Is.False, "a half-down thumb is not cocked either");
            g.Tick(true, true, true, 0.1f, 0f, false, 2f);
            g.Tick(true, true, true, 0.1f, 0f, false, 2f + HandTeleportGesture.ArmTime - 0.05f);
            Assert.That(g.Aiming, Is.False, "the arm time counts from the thumb going up");
            g.Tick(true, true, true, 0.1f, 0f, false, 2f + HandTeleportGesture.ArmTime + 0.01f);
            Assert.That(g.Aiming, Is.True, "thumb up: aims");
        }

        [Test]
        public void APinchDoesNotConfirm()
        {
            var g = new HandTeleportGesture();
            g.Tick(true, true, true, 0f, 0f, false, 0f);
            g.Tick(true, true, true, 0f, 0f, false, 0.31f);
            Assert.That(g.Aiming, Is.True);
            Assert.That(g.Tick(true, true, true, 0f, 0.6f, false, 0.35f), Is.False, "a half pinch does not confirm");
            Assert.That(g.Aiming, Is.True);
            Assert.That(g.Tick(true, false, true, 0f, 0.9f, false, 0.4f), Is.False, "a full pinch does not confirm");
            Assert.That(g.Aiming, Is.False, "the pinch ends the aim");
            Assert.That(g.Busy, Is.True, "and the grab stays blocked while it is closed (no pinch grab mid-aim)");
            for (var t = 0.45f; t < 1.5f; t += 0.05f)
                Assert.That(g.Tick(true, true, true, 0f, 0.9f, false, t) || g.Aiming, Is.False, "no aim while still pinched");
            g.Tick(true, true, true, 0f, 0f, false, 1.5f);
            Assert.That(g.Busy, Is.False, "the pinch opened");

            var p = new HandTeleportGesture();
            for (var t = 0f; t < 1f; t += 0.05f) Assert.That(p.Tick(true, true, true, 0f, 0.9f, false, t), Is.False);
            Assert.That(p.Aiming, Is.False, "a pinch made first never aims");
        }

        [Test]
        public void TheThumbMustLiftBeforeTheNextAim()
        {
            var g = new HandTeleportGesture();
            g.Tick(true, true, true, 0f, 0f, false, 0f);
            g.Tick(true, true, true, 0f, 0f, false, 0.31f);
            Assert.That(g.Tick(true, true, true, 1f, 0f, false, 0.35f), Is.True);
            for (var t = 0.4f; t < 1.5f; t += 0.05f)
                Assert.That(g.Tick(true, true, true, 1f, 0f, false, t) || g.Aiming, Is.False, "the thumb is still down: no new aim");
            for (var t = 1.5f; t < 2.5f; t += 0.05f)
                Assert.That(g.Tick(true, true, true, 0.6f, 0f, false, t) || g.Aiming, Is.False, "half up is not lifted");
            Assert.That(g.Busy, Is.True, "the grab stays blocked until the thumb lifts");
            g.Tick(true, true, true, 0.1f, 0f, false, 2.5f);
            Assert.That(g.Busy, Is.False, "lifted");
            g.Tick(true, true, true, 0.1f, 0f, false, 2.5f + HandTeleportGesture.ArmTime + 0.01f);
            Assert.That(g.Aiming, Is.True, "cocked again: the next aim");
            Assert.That(g.Tick(true, true, true, 1f, 0f, false, 3f), Is.True, "and the next confirmation");
        }

        [Test]
        public void TheArcIsFrozenDuringTheDrop()
        {
            var g = new HandTeleportGesture();
            g.Tick(true, true, true, 0f, 0f, false, 0f);
            g.Tick(true, true, true, 0f, 0f, false, 0.31f);
            Assert.That(g.Aiming && !g.Dropping, Is.True, "thumb up: the arc follows the index");
            g.Tick(true, true, true, 0.3f, 0f, false, 0.35f);
            Assert.That(g.Dropping, Is.False, "a thumb wobble under the stay threshold does not freeze it");
            g.Tick(true, true, true, HandTeleportGesture.CockedBelow + 0.05f, 0f, false, 0.4f);
            Assert.That(g.Aiming && g.Dropping, Is.True, "the thumb started dropping: frozen");
            g.Tick(true, false, true, 0.7f, 0f, false, 0.5f);
            Assert.That(g.Aiming && g.Dropping, Is.True, "still frozen, even if the drop bends the index out of the point");
            g.Tick(true, true, true, 0.1f, 0f, false, 0.55f);
            Assert.That(g.Aiming && !g.Dropping, Is.True, "the thumb went back up: the arc follows again");
        }

        [Test]
        public void DroppingThePointCancelsAfterTheGrace()
        {
            var g = new HandTeleportGesture();
            g.Tick(true, true, true, 0f, 0f, false, 0f);
            g.Tick(true, true, true, 0f, 0f, false, 0.31f);
            Assert.That(g.Aiming, Is.True);
            g.Tick(true, false, true, 0f, 0f, false, 0.35f);
            Assert.That(g.Aiming, Is.True, "a one-frame drop keeps the aim");
            g.Tick(true, true, true, 0f, 0f, false, 0.4f);
            g.Tick(true, false, true, 0f, 0f, false, 0.45f);
            g.Tick(true, false, true, 0f, 0f, false, 0.45f + HandTeleportGesture.DropGrace + 0.01f);
            Assert.That(g.Aiming, Is.False, "relaxing the point cancels without a teleport");

            var p = new HandTeleportGesture();
            for (var t = 0f; t < 1f; t += 0.05f) p.Tick(true, true, false, 0f, 0f, false, t);
            Assert.That(p.Aiming, Is.False, "a point toward the head never aims");
            for (var t = 1f; t < 2f; t += 0.05f) p.Tick(true, true, true, 0f, 0f, true, t);
            Assert.That(p.Aiming, Is.False, "holding a prop never aims");
            Assert.That(p.Tick(true, true, true, 1f, 0f, true, 2f), Is.False, "nor teleports");
        }

        [Test]
        public void AHalfDropHeldPastTheGraceCancelsAndAFullDropThenDoesNotTeleport()
        {
            var g = new HandTeleportGesture();
            g.Tick(true, true, true, 0f, 0f, false, 0f);
            g.Tick(true, true, true, 0f, 0f, false, 0.31f);
            Assert.That(g.Aiming, Is.True);
            // the thumb sags halfway (between CockedBelow and ConfirmDrop) and stays there
            g.Tick(true, true, true, 0.6f, 0f, false, 0.4f);
            Assert.That(g.Aiming, Is.True, "a dropping thumb keeps the aim briefly");
            // loop well past the 0.5 s HalfDropGrace (to 1.2 s) so float steps can't land on the boundary
            for (var i = 9; i <= 24; i++)
                g.Tick(true, true, true, 0.6f, 0f, false, i * 0.05f);
            Assert.That(g.Aiming, Is.False, "a half drop held past the grace cancels");
            Assert.That(g.Busy, Is.False, "the grab is no longer blocked");
            Assert.That(g.Tick(true, true, true, 0.9f, 0f, false, 1.3f), Is.False, "a later full drop does not teleport");
            Assert.That(g.Aiming, Is.False);
        }

        [Test]
        public void TheThumbHammerReadsAThumbsUpAsCockedAndTheThumbOnTheSideOfTheHandAsDown()
        {
            Assert.That(ThumbHammer.FromDistance(0.07f), Is.Zero, "a thumbs-up over a point (5-8 cm)");
            Assert.That(ThumbHammer.FromDistance(ThumbHammer.Up), Is.Zero);
            Assert.That(ThumbHammer.FromDistance(0.015f), Is.EqualTo(1f), "the thumb on the side of the hand (1-2 cm)");
            Assert.That(ThumbHammer.FromDistance(0.025f), Is.GreaterThanOrEqualTo(ThumbHammer.Enter), "2.5 cm: dropped");
            Assert.That(ThumbHammer.FromDistance(0.035f), Is.EqualTo(ThumbHammer.Stay).Within(1e-4f), "3.5 cm: the stay edge");

            var point = Point;
            Assert.That(ThumbHammer.From(point), Is.LessThan(ThumbHammer.Stay), "the fixture's point is cocked");
            Assert.That(ThumbHammer.From(PointWithThumbDown), Is.EqualTo(1f).Within(1e-4f), "thumb on the side of the index base");
            var onMiddle = Point;
            onMiddle[ThumbHammer.ThumbTip] = onMiddle[ThumbHammer.MiddleIntermediate] + Vector3.right * 0.012f;
            Assert.That(ThumbHammer.From(onMiddle), Is.EqualTo(1f).Within(1e-4f), "thumb on the curled middle finger");
            var up = Point;
            up[ThumbHammer.ThumbTip] = up[ThumbHammer.IndexProximal] + Vector3.up * 0.065f;
            Assert.That(ThumbHammer.From(up), Is.Zero, "thumb straight up over the index base");
            Assert.That(ThumbHammer.From(PointPinched), Is.LessThan(ThumbHammer.Stay), "a pinch is not a drop");
            Assert.That(PinchStrength.From(PointWithThumbDown), Is.Zero, "and the drop is not a pinch");
        }

        [Test]
        public void TheHitchhikerTurnsOncePerPoseAndCooldown()
        {
            var g = new HandTurnGesture();
            Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, 0f), Is.Zero);
            Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, HandTurnGesture.HoldTime - 0.01f), Is.Zero, "held too briefly");
            Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, HandTurnGesture.HoldTime + 0.01f), Is.EqualTo(1), "thumb right turns right");
            for (var t = 0.35f; t < 2f; t += 0.05f) Assert.That(g.Tick(true, true, 0.1f, 0.7f, 0.08f, 0f, false, t), Is.Zero, "once per pose (hysteresis keeps it)");
            g.Tick(true, true, 0.8f, 0.7f, 0.08f, 0f, false, 2f); // thumb tucked: pose left
            Assert.That(g.Pose, Is.Zero);
            g.Tick(true, true, 0f, -0.9f, 0.08f, 0f, false, 2.05f);
            Assert.That(g.Tick(true, true, 0f, -0.9f, 0.08f, 0f, false, 2.4f), Is.EqualTo(-1), "thumb left turns left");
            g.Tick(true, true, 0.8f, 0f, 0.08f, 0f, false, 2.45f);
            g.Tick(true, true, 0f, 0.9f, 0.08f, 0f, false, 2.5f);
            Assert.That(g.Tick(true, true, 0f, 0.9f, 0.08f, 0f, false, 2.85f), Is.Zero, "inside the cooldown after the last turn");
            Assert.That(g.Tick(true, true, 0f, 0.9f, 0.08f, 0f, false, 2.4f + HandTurnGesture.Cooldown + 0.01f), Is.EqualTo(1));
        }

        [Test]
        public void ATrackingDropoutMidHoldDoesNotTurnAgain()
        {
            var g = new HandTurnGesture();
            g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, 0f);
            Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, HandTurnGesture.HoldTime + 0.01f), Is.EqualTo(1));
            Assert.That(g.Tick(false, false, 0f, 0f, 0f, 0f, false, 0.4f), Is.Zero, "one frame without tracking");
            for (var t = 0.42f; t < 3f; t += 0.02f)
                Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, t), Is.Zero, "still the same held pose: no second turn");
            for (var t = 3f; t < 3.2f; t += 0.02f) g.Tick(false, false, 0f, 0f, 0f, 0f, false, t); // a longer dropout
            for (var t = 3.2f; t < 4f; t += 0.02f)
                Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, t), Is.Zero, "a dropout is not a release");
            g.Tick(true, true, 0.8f, 0.7f, 0.08f, 0f, false, 4f); // a tracked release: thumb tucked
            Assert.That(g.Pose, Is.Zero);
            g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, 4.05f);
            Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, false, 4.4f), Is.EqualTo(1), "made again: turns again");

            var h = new HandTurnGesture(); // an unfired hold that drops out starts over
            h.Tick(true, true, 0f, 1f, 0.08f, 0f, false, 0f);
            h.Tick(false, false, 0f, 0f, 0f, 0f, false, 0.2f);
            Assert.That(h.Tick(true, true, 0f, 1f, 0.08f, 0f, false, 0.32f), Is.Zero, "the hold restarted after the dropout");
            Assert.That(h.Tick(true, true, 0f, 1f, 0.08f, 0f, false, 0.32f + HandTurnGesture.HoldTime), Is.EqualTo(1));
        }

        [Test]
        public void APunchAnOpenHandOrAForwardThumbNeverTurns()
        {
            var g = new HandTurnGesture();
            for (var t = 0f; t < 2f; t += 0.02f) Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 2.5f, false, t), Is.Zero, "a moving fist (a punch)");
            for (var t = 2f; t < 4f; t += 0.02f) Assert.That(g.Tick(true, false, 0f, 1f, 0.08f, 0f, false, t), Is.Zero, "open, point or middle-only: not a fist");
            for (var t = 4f; t < 6f; t += 0.02f) Assert.That(g.Tick(true, true, 0f, 0.3f, 0.08f, 0f, false, t), Is.Zero, "a fist's thumb forward");
            for (var t = 6f; t < 8f; t += 0.02f) Assert.That(g.Tick(true, true, 0.9f, 1f, 0.08f, 0f, false, t), Is.Zero, "a tucked thumb");
            for (var t = 8f; t < 10f; t += 0.02f) Assert.That(g.Tick(true, true, 0f, 1f, 0.08f, 0f, true, t), Is.Zero, "holding a prop");
            for (var t = 10f; t < 12f; t += 0.02f) Assert.That(g.Tick(true, true, 0.2f, 1f, 0.025f, 0f, false, t), Is.Zero, "a thumb resting across the fist");
            for (var t = 12f; t < 14f; t += 0.02f) Assert.That(g.Tick(false, true, 0f, 1f, 0.08f, 0f, false, t), Is.Zero, "not tracked");
        }

        [Test]
        public void TheTurnInputPulsesOnceAndOtherwiseReadsTheStick()
        {
            var reader = new XRInputValueReader<Vector2>("Test",
                XRInputValueReader.InputSourceMode.ManualValue)
            { manualValue = new Vector2(0f, 0.3f) };
            var input = new HandTurnInput();
            input.Attach(reader);
            Assert.That(reader.ReadValue(), Is.EqualTo(new Vector2(0f, 0.3f)), "the controller stick passes through");
            input.Pulse(-1);
            Assert.That(reader.ReadValue(), Is.EqualTo(new Vector2(-1f, 0f)));
            Assert.That(reader.ReadValue(), Is.EqualTo(new Vector2(0f, 0.3f)), "one frame only");
            input.Detach();
            Assert.That(reader.bypass, Is.Null);
        }

        [Test]
        public void TheArcStartsAtTheOriginAndFallsUnderGravity()
        {
            var origin = new Vector3(1f, 2f, 3f);
            var points = new Vector3[TeleportArc.Segments + 1];
            TeleportArc.Sample(origin, Vector3.forward * 2f, 8f, 8f, points);

            Assert.That(points[0], Is.EqualTo(origin));
            var midpoint = points[points.Length / 2];
            var end = points[points.Length - 1];
            // Over 2.5 s, horizontal distance doubles from the midpoint while vertical drop quadruples.
            Assert.That(midpoint.z - origin.z, Is.EqualTo(10f).Within(1e-4f));
            Assert.That(origin.y - midpoint.y, Is.EqualTo(6.25f).Within(1e-4f));
            Assert.That(end.z - origin.z, Is.EqualTo(20f).Within(1e-4f));
            Assert.That(origin.y - end.y, Is.EqualTo(25f).Within(1e-4f));
        }

        /// <summary>A point with the thumb held aside (the fixture's straight thumb lies along the index: a pinch).</summary>
        static Vector3[] Point
        {
            get
            {
                var p = HandShapeTests.Hand(0f, 0f, 1f, 1f, 1f);
                for (var i = 0; i < HandCurls.PointsPerFinger; i++) p[i] += new Vector3(0.06f, 0f, -0.03f);
                return p;
            }
        }

        /// <summary>A point with the thumb tip down on the side of the index base.</summary>
        static Vector3[] PointWithThumbDown
        {
            get
            {
                var p = Point;
                Drop(p, 0.01f);
                return p;
            }
        }

        /// <summary>Put the thumb tip <paramref name="gap"/> m beside the index's proximal joint (the side of the index
        /// base, away from the other fingers).</summary>
        static void Drop(Vector3[] points, float gap) =>
            points[ThumbHammer.ThumbTip] = points[ThumbHammer.IndexProximal] + Vector3.left * gap;

        static Vector3[] PointPinched
        {
            get
            {
                var p = Point;
                HandGrabTests.Pinch(p, 0.01f);
                return p;
            }
        }
    }
}

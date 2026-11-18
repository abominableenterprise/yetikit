using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Hands.Tests
{
    /// <summary>Grab and trigger gestures, hysteresis, and tracking loss.</summary>
    public class HandGrabTests
    {
        [Test]
        public void PinchStrengthGoesFromOpenToClosed()
        {
            Assert.That(PinchStrength.FromDistance(0.06f), Is.Zero);
            Assert.That(PinchStrength.FromDistance(PinchStrength.Open), Is.Zero);
            Assert.That(PinchStrength.FromDistance(0.03f), Is.EqualTo(0.5f).Within(1e-4f));
            Assert.That(PinchStrength.FromDistance(PinchStrength.Closed), Is.EqualTo(1f).Within(1e-5f));
            Assert.That(PinchStrength.FromDistance(0f), Is.EqualTo(1f));
        }

        [Test]
        public void AFistGrabsWithHysteresis()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 0.55f, 0f, 0f, 0f);
            Assert.That(g.Selecting, Is.False, "0.55 is below the strict fist threshold");
            g.Tick(true, 0.65f, 0f, 0f, 0.01f);
            Assert.That(g.Selecting && g.Fist, Is.True);
            g.Tick(true, 0.5f, 0f, 0f, 0.02f);
            Assert.That(g.Selecting, Is.True, "jitter down to 0.5 keeps the prop");
            g.Tick(true, 0.4f, 0f, 0f, 0.03f);
            Assert.That(g.Selecting, Is.False, "an opened hand lets go");
        }

        [Test]
        public void APinchGrabsWithHysteresis()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 0f, 0.7f, 0f, 0f);
            Assert.That(g.Selecting, Is.False);
            g.Tick(true, 0f, 0.85f, 0f, 0.01f);
            Assert.That(g.Selecting && g.Pinching, Is.True);
            g.Tick(true, 0f, 0.55f, 0f, 0.02f);
            Assert.That(g.Selecting, Is.True, "a loosened pinch holds");
            g.Tick(true, 0f, 0.45f, 0f, 0.03f);
            Assert.That(g.Selecting, Is.False);
        }

        [Test]
        public void LostTrackingKeepsTheGrabForTheGraceThenLetsGo()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 1f, 0f, 0f, 0f);
            g.Tick(false, 0f, 0f, 0f, 0.1f);
            Assert.That(g.Selecting && g.InGrace, Is.True);
            var beforeExpiry = 0.1f + HandGrabGesture.LostGrace - 0.01f;
            g.Tick(false, 0f, 0f, 0f, beforeExpiry);
            Assert.That(g.Selecting, Is.True, "still inside the grace");
            Assert.That(g.CanStart(beforeExpiry), Is.False, "no new grab while lost");
            g.Tick(true, 1f, 0f, 0f, beforeExpiry + 0.005f);
            Assert.That(g.Selecting && !g.InGrace, Is.True, "tracking back in time: still holding");
            g.Tick(false, 0f, 0f, 0f, 0.3f);
            g.Tick(false, 0f, 0f, 0f, 0.3f + HandGrabGesture.LostGrace + 0.01f);
            Assert.That(g.Selecting, Is.False, "lost for longer than the grace: let go");
        }

        [Test]
        public void ANewGrabOnlyStartsRightAfterTheGesture()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 1f, 0f, 0f, 1f);
            Assert.That(g.CanStart(1f + HandGrabGesture.StartWindow - 0.01f), Is.True);
            Assert.That(g.CanStart(1f + HandGrabGesture.StartWindow + 0.05f), Is.False, "a fist swept into a prop later does not take it");
        }

        [Test]
        public void ThumbPressGoesFromThumbUpToPressedOntoTheIndex()
        {
            Assert.That(ThumbPress.FromDistance(0.07f), Is.Zero);
            Assert.That(ThumbPress.FromDistance(ThumbPress.Up), Is.Zero);
            Assert.That(ThumbPress.FromDistance(0.03f), Is.EqualTo(0.5f).Within(1e-4f));
            Assert.That(ThumbPress.FromDistance(ThumbPress.Pressed), Is.EqualTo(1f).Within(1e-5f));
            Assert.That(ThumbPress.FromDistance(0f), Is.EqualTo(1f));

            var fist = HandShapeTests.Hand(0f, 1f, 1f, 1f, 1f);
            ThumbUp(fist);
            Assert.That(ThumbPress.From(fist), Is.Zero, "a thumbs-up fist: trigger 0");
            Press(fist, 0.01f);
            Assert.That(ThumbPress.From(fist), Is.EqualTo(1f), "the thumb pressed onto the curled index: 1");
            Press(fist, 0.03f);
            Assert.That(ThumbPress.From(fist), Is.EqualTo(0.5f).Within(1e-3f), "halfway down: half");
            // on the proximal phalanx (the side of the fist near the knuckle) counts too
            fist[ThumbPress.ThumbTip] = Vector3.Lerp(fist[ThumbPress.IndexProximal], fist[ThumbPress.IndexIntermediate], 0.3f)
                + Vector3.left * 0.01f;
            Assert.That(ThumbPress.From(fist), Is.EqualTo(1f));
            // a pinch (the thumb tip on the index tip) is not a press
            var pinch = HandShapeTests.Hand(0f, 0.3f, 1f, 1f, 1f);
            Pinch(pinch, 0.005f);
            Assert.That(PinchStrength.From(pinch), Is.EqualTo(1f));
            Assert.That(ThumbPress.From(pinch), Is.LessThan(HandGrabGesture.PressStay));
        }

        [Test]
        public void TheThumbPressIsTheTriggerWhileAFistHoldsWithHysteresis()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 1f, 0f, 0f, 0f);
            Assert.That(g.Selecting && g.Armed, Is.True, "a thumbs-up fist grab is armed at once");
            Assert.That(g.Trigger, Is.Zero);
            g.Tick(true, 1f, 0f, 0.7f, 0.01f);
            Assert.That(g.Trigger, Is.Zero, "0.7 is below the strict press threshold");
            g.Tick(true, 1f, 0f, 0.9f, 0.02f);
            Assert.That(g.Trigger, Is.EqualTo(0.9f), "fist holds, thumb pressed: the trigger");
            g.Tick(true, 1f, 0f, 0.6f, 0.03f);
            Assert.That(g.Trigger, Is.EqualTo(0.6f), "hysteresis: a loosened press stays on and still scales");
            g.Tick(true, 1f, 0f, 0.4f, 0.04f);
            Assert.That(g.Trigger, Is.Zero, "the thumb lifts: off");
            g.Tick(true, 1f, 0f, 0.6f, 0.05f);
            Assert.That(g.Trigger, Is.Zero, "and it needs the strict threshold again: no chatter");
            g.Tick(true, 1f, 0.9f, 0f, 0.06f);
            Assert.That(g.Trigger, Is.Zero, "the index pinch is no longer the trigger");
        }

        [Test]
        public void AGrabWithTheThumbAlreadyDownFiresOnlyAfterTheThumbLiftsOnce()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 0.7f, 0.9f, 0f, 0f);    // pinched it up (the other fingers curled too)
            Assert.That(g.Armed, Is.False);
            g.Tick(true, 0.7f, 0.2f, 0.9f, 0.05f); // the thumb slides from the index tip onto its side: pressed
            Assert.That(g.Selecting, Is.True);
            Assert.That(g.Trigger, Is.Zero, "the pickup press does not activate the trigger");
            g.Tick(true, 0.7f, 0.2f, 0.1f, 0.1f);  // the thumb lifts, the fist keeps it
            Assert.That(g.Armed, Is.True);
            g.Tick(true, 0.7f, 0.2f, 0.9f, 0.2f);
            Assert.That(g.Trigger, Is.EqualTo(0.9f), "a new press activates the trigger");

            var w = new HandGrabGesture();
            w.Tick(true, 0.9f, 0f, 0.95f, 0f);   // a fist with the thumb wrapped over it
            Assert.That(w.Trigger, Is.Zero, "a fist made with the thumb down is no pull");
            w.Tick(true, 0.9f, 0f, 0.3f, 0.1f);
            w.Tick(true, 0.9f, 0f, 0.95f, 0.2f);
            Assert.That(w.Trigger, Is.EqualTo(0.95f));
        }

        [Test]
        public void ABriefTrackingLossWithTheThumbDownNeverArmsTheTrigger()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 0.9f, 0f, 0.9f, 0f);    // a fist made with the thumb wrapped down onto the index
            g.Took();
            Assert.That(g.Pressing && !g.Armed, Is.True);
            g.Tick(false, 0f, 0f, 0f, 0.05f);    // tracking drops for a moment, inside the grace
            Assert.That(g.InGrace, Is.True);
            Assert.That(g.Pressing, Is.True, "the press keeps its hysteresis through the grace");
            Assert.That(g.Trigger, Is.Zero, "no trigger while untracked");
            var between = (HandGrabGesture.PressStay + HandGrabGesture.PressEnter) / 2f;
            g.Tick(true, 0.9f, 0f, between, 0.1f); // back with the thumb still down (between stay and enter)
            Assert.That(g.Pressing, Is.True, "still down: not a lift");
            Assert.That(g.Armed, Is.False, "re-acquiring is not a thumb-up");
            g.Tick(true, 0.9f, 0f, 0.95f, 0.15f); // pressing harder is still the same pickup press
            Assert.That(g.Trigger, Is.Zero, "no trigger without a tracked lift");
            g.Tick(false, 0f, 0f, 0f, 0.2f);     // lost again: still no trigger, still not armed
            g.Tick(true, 0.9f, 0f, 0.95f, 0.25f);
            Assert.That(g.Armed || g.Trigger > 0f, Is.False);
            g.Tick(true, 0.9f, 0f, 0.2f, 0.3f);  // a tracked lift arms it
            Assert.That(g.Armed, Is.True);
            g.Tick(true, 0.9f, 0f, 0.95f, 0.35f);
            Assert.That(g.Trigger, Is.EqualTo(0.95f), "now it is the trigger");
            g.Tick(false, 0f, 0f, 0f, 0.4f);
            Assert.That(g.Trigger, Is.Zero, "pressing and armed, but untracked: no output");
            Assert.That(g.Armed && g.Pressing, Is.True, "kept through the grace");
        }

        [Test]
        public void AThumbThatClosesOnContactIsPartOfThePickup()
        {
            var g = new HandGrabGesture();
            g.Tick(true, 0.9f, 0f, 0f, 0f);    // a thumbs-up fist made before reaching the object
            Assert.That(g.Armed, Is.True);
            g.Tick(true, 0.9f, 0f, 0.9f, 0.1f); // the thumb closes on contact, inside the start window
            Assert.That(g.CanStart(0.1f), Is.True);
            g.Took();                            // the grab takes the object now
            Assert.That(g.Armed, Is.False, "re-armed from the thumb at select time");
            Assert.That(g.Trigger, Is.Zero, "the pickup press does not activate the trigger");
            g.Tick(true, 0.9f, 0f, 0.9f, 0.15f);
            Assert.That(g.Trigger, Is.Zero, "still the pickup press");
            g.Tick(true, 0.9f, 0f, 0.2f, 0.3f);  // the thumb lifts, the fist keeps it
            g.Tick(true, 0.9f, 0f, 0.9f, 0.4f);
            Assert.That(g.Trigger, Is.EqualTo(0.9f), "now it is the trigger");

            var f = new HandGrabGesture(); // a plain thumbs-up fist pickup is armed at once
            f.Tick(true, 0.9f, 0f, 0f, 0f);
            f.Took();
            f.Tick(true, 0.9f, 0f, 0.9f, 0.1f);
            Assert.That(f.Trigger, Is.EqualTo(0.9f));
        }

        /// <summary>Put the thumb tip <paramref name="gap"/> m beside the curled index's middle joint (on the side of the
        /// fist; the synthetic hand's fingers curl in the y-z plane, so this is square to both phalanges).</summary>
        static void Press(Vector3[] points, float gap) =>
            points[ThumbPress.ThumbTip] = points[ThumbPress.IndexIntermediate] + Vector3.left * gap;

        /// <summary>A thumbs-up: the thumb tip 7 cm away from the index's middle joint.</summary>
        static void ThumbUp(Vector3[] points) => Press(points, 0.07f);

        /// <summary>Put the thumb tip <paramref name="gap"/> m from the index tip.</summary>
        public static void Pinch(Vector3[] points, float gap) =>
            points[PinchStrength.ThumbTip] = points[PinchStrength.IndexTip] + Vector3.right * gap;
    }
}

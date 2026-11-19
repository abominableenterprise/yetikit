using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    /// <summary>Regrab protection and catch assist.</summary>
    public class HandOffTests
    {
        static readonly object Left = new object(), Right = new object();

        [Test]
        public void TheThrowerCannotRegrabInsideTheGuardButTheOtherHandCan()
        {
            Assert.That(HandOffRules.Guarded(Right, 1f, Right, 1.1f), Is.True, "the thrower, 0.1 s after");
            Assert.That(HandOffRules.Guarded(Right, 1f, Right, 1f + HandOffRules.RegrabGuard + 0.01f), Is.False, "after the guard");
            Assert.That(HandOffRules.Guarded(Right, 1f, Left, 1.05f), Is.False, "the other hand any time");
            Assert.That(HandOffRules.Guarded(null, 1f, Right, 1.05f), Is.False, "never thrown");
            Assert.That(HandOffRules.RegrabGuard, Is.EqualTo(0.2f).Within(0.05f));
        }

        [Test]
        public void TheCatchAssistTakesAPropWithin15cmOfItsPathInTheWindow()
        {
            var at = new Vector3(0f, 1.2f, 0.4f);
            var v = new Vector3(-2f, 1f, 0f); // a soft underhand toss to the left
            Assert.That(HandOffRules.Catches(at, at, v), Is.True, "on the prop");
            Assert.That(HandOffRules.Catches(at + v * 0.1f + Vector3.forward * 0.12f, at, v), Is.True, "12 cm off the path ahead");
            Assert.That(HandOffRules.Catches(at + v * 0.1f + Vector3.forward * 0.2f, at, v), Is.False, "20 cm off the path");
            Assert.That(HandOffRules.Catches(at + v * 0.5f, at, v), Is.False, "far down the path: not there yet");
            Assert.That(HandOffRules.PathDistance(at - v * 0.05f + Vector3.forward * 0.1f, at, v), Is.EqualTo(0.1f).Within(1e-4f), "behind it");
            Assert.That(HandOffRules.InCatchWindow(1f, 1.5f), Is.True);
            Assert.That(HandOffRules.InCatchWindow(1f, 1f + HandOffRules.CatchWindow + 0.01f), Is.False);
            Assert.That(HandOffRules.CatchRadius, Is.EqualTo(0.15f));
        }

        [Test]
        public void TheLogIsRateLimitedPerEvent()
        {
            var prefix = System.Guid.NewGuid().ToString();
            var firstEvent = prefix + ":first";
            Assert.That(GrabLog.Due(firstEvent, 100f), Is.True);
            Assert.That(GrabLog.Due(firstEvent, 100.1f), Is.False, "0.1 s later: limited");
            Assert.That(GrabLog.Due(prefix + ":second", 100.1f), Is.True, "another event is not limited");
            Assert.That(GrabLog.Due(firstEvent, 100f + GrabLog.Interval), Is.True);
        }
    }
}

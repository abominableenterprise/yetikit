using System.Linq;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Playtest.Tests
{
    public sealed class PolaroidTests
    {
        [Test]
        public void EarlyAcknowledgementWaitsForShrinkThenFliesOut()
        {
            var card = new PolaroidCard();
            Assert.That(card.Visible, Is.False);
            card.Start("snap-a", 12);
            var full = card.Tick(12);
            Assert.That(card.SetStatus("snap-a", SnapStatus.Queued, 12.1), Is.True);
            Assert.That(card.SetStatus("snap-a", SnapStatus.Sent, 12.2), Is.True);
            Assert.That(card.SetStatus("snap-a", SnapStatus.Queued, 12.3), Is.False);
            Assert.That(card.Tick(12.3).Width, Is.LessThan(full.Width));
            Assert.That(card.State, Is.EqualTo(PolaroidState.Capturing));
            var small = card.Tick(12.4);
            Assert.That(card.State, Is.EqualTo(PolaroidState.Sent));
            Assert.That(small.Offset.x, Is.LessThan(0));
            Assert.That(card.Tick(12.8).Offset.y, Is.GreaterThan(small.Offset.y));
            Assert.That(card.Tick(12.901).Alpha, Is.Zero);
            Assert.That(card.Visible, Is.False);
        }

        [TestCase(SnapStatus.Queued, PolaroidState.Queued)]
        [TestCase(SnapStatus.Local, PolaroidState.Local)]
        public void SavedCardFadesInPlace(SnapStatus status, PolaroidState expected)
        {
            var card = new PolaroidCard();
            card.Start("snap-a", 0);
            Assert.That(card.SetStatus("snap-a", status, 1), Is.True);
            var shown = card.Tick(1);
            var fading = card.Tick(4.2);
            Assert.That(card.State, Is.EqualTo(expected));
            Assert.That(shown.Alpha, Is.EqualTo(1));
            Assert.That(fading.Alpha, Is.EqualTo(0.5f).Within(0.001f));
            Assert.That(fading.Offset, Is.EqualTo(shown.Offset));
            Assert.That(card.SetStatus("snap-a", status, 4.25), Is.False);
            Assert.That(card.SetStatus("snap-a", SnapStatus.Sent, 4.5), Is.False);
            Assert.That(card.Visible, Is.False);
        }

        [Test]
        public void AcknowledgementCanInterruptQueuedFade()
        {
            var card = new PolaroidCard();
            card.Start("snap-a", 0);
            card.SetStatus("snap-a", SnapStatus.Queued, 1);
            Assert.That(card.Tick(4.1).Alpha, Is.LessThan(1));
            Assert.That(card.SetStatus("snap-a", SnapStatus.Sent, 4.1), Is.True);
            Assert.That(card.Tick(4.1).Alpha, Is.EqualTo(1));
            Assert.That(card.State, Is.EqualTo(PolaroidState.Sent));
        }

        [Test]
        public void ReplacementIgnoresStaleResultsAndFailureDroopsAndFades()
        {
            var card = new PolaroidCard();
            card.Start("snap-a", 0);
            card.SetStatus("snap-a", SnapStatus.Sent, 0.25);
            card.Start("snap-b", 1);
            Assert.That(card.SetStatus("snap-a", SnapStatus.Failed, 1.1), Is.False);
            var hover = card.Tick(1.5);
            Assert.That(card.State, Is.EqualTo(PolaroidState.Hovering));
            Assert.That(card.SetStatus("snap-b", SnapStatus.Queued, 1.6), Is.True);
            Assert.That(card.SetStatus("snap-b", SnapStatus.Failed, 2), Is.True);
            var failed = card.Tick(3.7);
            Assert.That(card.State, Is.EqualTo(PolaroidState.Failed));
            Assert.That(failed.Offset.y, Is.LessThan(hover.Offset.y));
            Assert.That(failed.Red, Is.EqualTo(1));
            Assert.That(failed.Alpha, Is.EqualTo(0.5f).Within(0.001f));
            Assert.That(card.SetStatus("snap-b", SnapStatus.Sent, 3.75), Is.False);
            Assert.That(card.Tick(4).Alpha, Is.Zero);
        }

        [Test]
        public void TimeoutUsesTheShrinkDeadlineEvenIfNoFramesWereDrawn()
        {
            var card = new PolaroidCard();
            card.Start("snap-a", 10);
            var end = 10 + PolaroidCard.ShrinkSeconds + PolaroidCard.HoverTimeout;
            Assert.That(card.Tick(end - 0.2).Alpha, Is.EqualTo(0.5f).Within(0.001f));
            Assert.That(card.Tick(end).Alpha, Is.Zero);
            Assert.That(card.State, Is.EqualTo(PolaroidState.Gone));
        }

        [Test]
        public void WhooshIsDeterministicBoundedAndSilentAtTheEnds()
        {
            var samples = PolaroidWhoosh.Samples();
            Assert.That(samples.Length, Is.EqualTo((int)(PolaroidWhoosh.Rate * PolaroidCard.FlySeconds)));
            Assert.That(samples[0], Is.Zero);
            Assert.That(samples[samples.Length - 1], Is.Zero);
            Assert.That(samples.Max(sample => Mathf.Abs(sample)), Is.InRange(0.1f, 0.55f));
            Assert.That(samples, Is.EqualTo(PolaroidWhoosh.Samples()));
        }
    }
}

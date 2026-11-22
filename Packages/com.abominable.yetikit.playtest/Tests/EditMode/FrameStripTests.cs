using System;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Playtest.Tests
{
    public class FrameStripTests
    {
        [Test]
        public void RingWrapsAndPrefersLatestInsertionOnTies()
        {
            var ring = new FrameSelection<string>(3);
            Assert.That(ring.TryNewest(out _), Is.False);
            ring.Add(0, "evicted");
            ring.Add(4, "older");
            ring.Add(2, "earlier time");
            ring.Add(4, "latest");
            Assert.That(ring.TryAt(0, out _), Is.False);
            Assert.That(ring.TryAt(4, out var exact), Is.True);
            Assert.That(exact, Is.EqualTo("latest"));
            Assert.That(ring.TryClosest(3, out var closest, out var time), Is.True);
            Assert.That((closest, time), Is.EqualTo(("latest", 4d)));
            var window = new List<double> { 99 };
            ring.Window(2, 4, window);
            Assert.That(window, Is.EqualTo(new[] { 2d, 4d, 4d }));
            Assert.That(ring.WouldEvict(4), Is.True);
            Assert.That(ring.WouldEvict(5), Is.False);
            ring.Clear();
            Assert.That(ring.TryClosest(3, out _, out _), Is.False);
        }

        [TestCase(false)]
        [TestCase(true)]
        public void SourceFallsBackWhenUnavailable(bool available)
        {
            var source = new Source { Available = available };
            Assert.That(FrameSourceSelection.TryCopy(source, null), Is.EqualTo(available));
            Assert.That(FrameSourceSelection.TryCopy(null, null), Is.False);
        }

        [Test]
        public void StripWaitsProtectsWindowAndOmitsFailedFrames()
        {
            var frames = new Frames();
            foreach (var time in new[] { 6d, 7d, 10d, 12d }) frames.Ring.Add(time, time);
            var strip = new StripCapture(frames, "snap-token", 10, 10);
            Assert.That(frames.Held, Is.EqualTo(7));
            strip.Tick();
            Assert.That(frames.Attempts, Is.Empty);
            frames.Ring.Add(13.25, 13.25); // First ready frame lies outside the window.
            strip.Tick();
            Assert.That(frames.Attempts, Is.EqualTo(new[] { 7d }));
            Assert.That(frames.Held, Is.EqualTo(10));
            strip.Tick();
            strip.Tick();
            Assert.That(strip.Finished, Is.True);
            Assert.That(frames.Held, Is.EqualTo(double.PositiveInfinity));
            Assert.That(frames.Attempts, Is.EqualTo(new[] { 7d, 10d, 12d }));
            Assert.That(strip.Files.Keys, Is.EquivalentTo(new[] { "snap-token-s01.jpg", "snap-token-s02.jpg" }));
            Assert.That(strip.Files["snap-token-s01.jpg"], Is.EqualTo(new byte[] { 10 }));
            Assert.That(strip.MainIndex, Is.Zero);
            Assert.That(strip.Entries.Count, Is.EqualTo(2));
            Assert.That((strip.Entries[0].file, strip.Entries[0].t, strip.Entries[0].dt), Is.EqualTo(("snap-token-s01.jpg", 10d, 0d)));
            Assert.That((strip.Entries[1].file, strip.Entries[1].t, strip.Entries[1].dt), Is.EqualTo(("snap-token-s02.jpg", 12d, 2d)));
            Assert.That(JsonUtility.ToJson(strip.Entries[0]), Does.Contain("\"file\":\"snap-token-s01.jpg\""));
        }

        [Test]
        public void ClosingTakesPartialWindowAndCutReleasesWithoutMoreWrites()
        {
            var frames = new Frames();
            frames.Ring.Add(8, 8);
            frames.Ring.Add(9, 9);
            var strip = new StripCapture(frames, "snap-token", 10, double.NaN);
            strip.Tick(closing: true);
            strip.Cut();
            strip.Tick(closing: true);
            Assert.That(strip.Finished, Is.True);
            Assert.That(frames.Held, Is.EqualTo(double.PositiveInfinity));
            Assert.That(frames.Attempts, Is.EqualTo(new[] { 8d }));
            Assert.That(strip.Files.Keys, Is.EqualTo(new[] { "snap-token-s00.jpg" }));
            Assert.That(strip.MainIndex, Is.EqualTo(-1));
            Assert.That(strip.Entries[0].t, Is.EqualTo(8));
            Assert.That(strip.Entries[0].dt, Is.EqualTo(-2d));
        }

        sealed class Frames : IStripFrames
        {
            public readonly FrameSelection<double> Ring = new FrameSelection<double>(26);
            public readonly List<double> Attempts = new List<double>();
            public double Held;
            public bool TryNewest(out double time) => Ring.TryNewest(out time);
            public void Window(double from, double to, List<double> times) => Ring.Window(from, to, times);
            public byte[] Encode(double time, int quality)
            {
                Attempts.Add(time);
                Assert.That(quality, Is.EqualTo(75));
                return time != 7 && Ring.TryAt(time, out _) ? new[] { (byte)time } : null;
            }
            public void Hold(double from) => Held = from;
        }

        sealed class Source : IFrameSource
        {
            public bool Available;
            public bool TryCopy(RenderTexture destination) => Available;
        }
    }
}

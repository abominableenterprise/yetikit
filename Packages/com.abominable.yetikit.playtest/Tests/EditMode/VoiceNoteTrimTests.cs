using System;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class VoiceNoteTrimTests
    {
        [TestCase(16000, 1)]
        [TestCase(44100, 2)]
        public void TrimsWholeFramesAndPadsBothTriggerEdges(int rate, int channels)
        {
            var pcm = new short[rate * channels];
            Array.Fill(pcm, (short)123);
            var lead = new NoteTriggerRange(0, rate / 5);
            var tail = new NoteTriggerRange(rate * 4 / 5, rate);
            int pad = rate * VoiceNoteTrim.PadMilliseconds / 1000;
            int cut = (rate / 5 + pad) * channels;
            Assert.That(VoiceNoteTrim.Select(pcm, rate, channels, leading: lead), Is.EqualTo((cut, pcm.Length - cut, true)));
            Assert.That(VoiceNoteTrim.Select(pcm, rate, channels, trailing: tail), Is.EqualTo((0, pcm.Length - cut, true)));
            Assert.That(VoiceNoteTrim.Select(pcm, rate, channels, lead, tail), Is.EqualTo((cut, pcm.Length - 2 * cut, true)));
            Assert.That(pcm, Is.All.EqualTo((short)123));
        }

        [Test]
        public void ClipsIntersectingSpansButIgnoresDisjointOrInvalidSpans()
        {
            const int rate = 16000;
            var pcm = new short[rate];
            var lead = new NoteTriggerRange(long.MinValue, 10);
            var tail = new NoteTriggerRange(rate - 10, long.MaxValue);
            int cut = 10 + rate * VoiceNoteTrim.PadMilliseconds / 1000;
            Assert.That(VoiceNoteTrim.Select(pcm, rate, 1, lead, tail), Is.EqualTo((cut, rate - 2 * cut, true)));
            Assert.That(VoiceNoteTrim.Select(pcm, rate, 1, new NoteTriggerRange(-20, 0), new NoteTriggerRange(rate, rate + 20)),
                Is.EqualTo((0, rate, false)));
            Assert.That(VoiceNoteTrim.Select(pcm, rate, 1, new NoteTriggerRange(30, 10), new NoteTriggerRange(5, 5)),
                Is.EqualTo((0, rate, false)));
        }

        [TestCase(10000, 6000)] // overlapping
        [TestCase(8000, 9600)] // padding closes the gap exactly
        [TestCase(2000, 7599)] // one frame shy of minimum after padding
        [TestCase(16000, 16000)] // a single trigger covers the whole note
        public void FallsBackToOriginalWhenTooLittleWouldRemain(int leadEnd, int tailStart)
        {
            const int rate = 16000;
            var pcm = new short[rate];
            Assert.That(VoiceNoteTrim.Select(pcm, rate, 1, new NoteTriggerRange(0, leadEnd), new NoteTriggerRange(tailStart, rate)),
                Is.EqualTo((0, rate, false)));
        }

        [Test]
        public void KeepsExactlyTheMinimumAndDoesNotCreateAnEmptyClip()
        {
            const int rate = 16000;
            int minimum = rate * VoiceNoteTrim.MinimumMilliseconds / 1000;
            int cut = rate - minimum;
            int leadEnd = cut - rate * VoiceNoteTrim.PadMilliseconds / 1000;
            Assert.That(VoiceNoteTrim.Select(new short[rate], rate, 1, new NoteTriggerRange(0, leadEnd)), Is.EqualTo((cut, minimum, true)));
            Assert.That(VoiceNoteTrim.Select(new short[1], rate, 1, new NoteTriggerRange(0, 1)), Is.EqualTo((0, 1, false)));
        }
    }
}

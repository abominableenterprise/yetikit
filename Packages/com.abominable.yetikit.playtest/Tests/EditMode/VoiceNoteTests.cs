using System;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public class VoiceNoteTests
    {
        const int Rate = 16000, Frame = 160;

        [Test]
        public void ActivityReportsTheFirstOnsetAcrossSplitFrames()
        {
            var vad = new VoiceActivity();
            var pcm = new short[62 * Frame];
            Fill(pcm, 30 * Frame + 7, Frame - 7);
            Fill(pcm, 61 * Frame, Frame);
            Assert.IsFalse(vad.Process(pcm, 0, 31 * Frame - 1, out var onset));
            Assert.AreEqual(-1, onset);
            Assert.AreEqual(31 * Frame - 1, vad.SamplesProcessed);
            Assert.IsTrue(vad.Process(pcm, 31 * Frame - 1, 31 * Frame + 1, out onset));
            Assert.AreEqual(30 * Frame + 7, onset);
            Assert.AreEqual(pcm.Length, vad.SamplesProcessed);
        }

        [TestCase(0)]
        [TestCase(29)]
        public void VoiceWithoutThreeHundredMillisecondsOfObservedQuietHasNoOnset(int quietFrames)
        {
            var vad = new VoiceActivity();
            var pcm = new short[(quietFrames + 1) * Frame];
            Fill(pcm, quietFrames * Frame, Frame);
            Assert.IsTrue(vad.Process(pcm, 0, pcm.Length, out var onset));
            Assert.AreEqual(-1, onset);
        }

        [TestCase(1)]
        [TestCase(733)]
        [TestCase(100000)]
        public void SilenceEndsAtTheSameSampleRegardlessOfBlockSize(int blockSize)
        {
            var note = new VoiceNote();
            note.Start(phraseDetected: true);
            var pcm = new short[4 * Rate];
            Fill(pcm, 0, Frame);
            // A later voiced frame in the same submitted block cannot prevent an earlier stop.
            Fill(pcm, Frame + 3 * Rate, Frame);
            int offset = 0;
            NoteEnd end = NoteEnd.None;
            while (offset < pcm.Length && end == NoteEnd.None)
            {
                end = note.Process(pcm, offset, Math.Min(blockSize, pcm.Length - offset));
                if (end == NoteEnd.None) offset = note.SamplesConsumed;
            }
            Assert.AreEqual(NoteEnd.Silence, end);
            Assert.AreEqual(Frame + 3 * Rate, note.SamplesConsumed);
            Assert.IsFalse(note.Active);
            Assert.AreEqual(NoteEnd.None, note.Process(pcm, offset, 1));
            Assert.AreEqual(Frame + 3 * Rate, note.SamplesConsumed);
        }

        [Test]
        public void BackupRequiresEightQuietSecondsWithoutARecognizedPhrase()
        {
            var note = new VoiceNote();
            note.Start();
            var pcm = new short[Frame + 8 * Rate + 1];
            Fill(pcm, 0, Frame);
            Assert.AreEqual(NoteEnd.None, note.Process(pcm, 0, pcm.Length - 2));
            Assert.AreEqual(NoteEnd.Backup, note.Process(pcm, pcm.Length - 2, 2));
            Assert.AreEqual(pcm.Length - 1, note.SamplesConsumed);
        }

        [Test]
        public void PhraseResetsQuietDeadlineAtAnUnalignedSample()
        {
            var note = new VoiceNote();
            note.Start();
            var pcm = new short[7 * Rate];
            int mark = 3 * Rate + 1;
            Assert.AreEqual(NoteEnd.None, note.Process(pcm, 0, mark));
            note.MarkPhrase();
            Assert.AreEqual(NoteEnd.Silence, note.Process(pcm, mark, pcm.Length - mark));
            Assert.AreEqual(mark + 3 * Rate, note.SamplesConsumed);
        }

        [Test]
        public void MaximumClipsOverlongInputEvenWithContinuousSpeech()
        {
            var note = new VoiceNote();
            note.Start();
            var pcm = new short[90 * Rate + 31];
            Fill(pcm, 0, pcm.Length);
            int beforeLimit = 90 * Rate - 1;
            Assert.AreEqual(NoteEnd.None, note.Process(pcm, 0, beforeLimit));
            Assert.AreEqual(NoteEnd.Maximum, note.Process(pcm, beforeLimit, pcm.Length - beforeLimit));
            Assert.AreEqual(90 * Rate, note.SamplesConsumed);
        }

        [Test]
        public void ExplicitSendStopsAtTheCurrentCursorAndStartClearsIt()
        {
            var note = new VoiceNote();
            note.Start();
            Assert.AreEqual(NoteEnd.None, note.Process(new short[17], 0, 17));
            Assert.AreEqual(NoteEnd.SendIt, note.Send());
            Assert.AreEqual(17, note.SamplesConsumed);
            Assert.AreEqual(NoteEnd.None, note.Send());
            note.Start();
            Assert.AreEqual(0, note.SamplesConsumed);
            Assert.IsTrue(note.Active);
        }

        [Test]
        public void WaveEncodesOnlyTheRequestedSliceInLittleEndian()
        {
            var pcm = new short[] { 1, short.MinValue, -1, 0x1234, short.MaxValue, 2 };
            CollectionAssert.AreEqual(new byte[]
            {
                0x52, 0x49, 0x46, 0x46, 44, 0, 0, 0, // RIFF and file size minus eight
                0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20, // WAVEfmt
                16, 0, 0, 0, 1, 0, 1, 0, // PCM, mono
                0x80, 0x3e, 0, 0, 0x00, 0x7d, 0, 0, // 16 kHz, 32,000 bytes per second
                2, 0, 16, 0, 0x64, 0x61, 0x74, 0x61, 8, 0, 0, 0, // alignment, bits, and data
                0x00, 0x80, 0xff, 0xff, 0x34, 0x12, 0xff, 0x7f
            }, WaveEncoder.Encode(pcm, 1, 4));
            var empty = WaveEncoder.Encode(pcm, pcm.Length, 0);
            Assert.AreEqual(44, empty.Length);
            Assert.AreEqual(36, empty[4]);
            Assert.AreEqual(0, empty[40]);
            Assert.Throws<ArgumentOutOfRangeException>(() => WaveEncoder.Encode(pcm, pcm.Length, 1));
        }

        static void Fill(short[] pcm, int offset, int count)
        {
            for (int i = offset; i < offset + count; i++) pcm[i] = short.MinValue;
        }
    }
}

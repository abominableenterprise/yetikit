using System;
using System.Threading;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class VoiceRecognitionTests
    {
        static RecognitionPhrase Phrase(string text, long id, bool final = false) => new RecognitionPhrase(text, final, id, -1, 0);

        [TestCase("restart")]
        [TestCase("please start")]
        [TestCase("start now")]
        [TestCase("[unk] start")]
        [TestCase("send it later")]
        public void CommandsRequireWholePhrase(string text) =>
            Assert.That(new PhraseRules().Match(Phrase(text, 0, true), 0), Is.EqualTo(PhraseTrigger.None));

        [Test]
        public void PartialsAndFinalsShareOneTriggerAndDebounceIsPerCommand()
        {
            var rules = new PhraseRules();
            Assert.That(rules.Match(Phrase(" START ", 0), 0), Is.EqualTo(PhraseTrigger.Start));
            Assert.That(rules.Match(Phrase("send it", 0, true), 4), Is.EqualTo(PhraseTrigger.None));
            Assert.That(rules.Match(Phrase("start", 1), 1), Is.EqualTo(PhraseTrigger.None));
            Assert.That(rules.Match(Phrase("start", 1, true), 3), Is.EqualTo(PhraseTrigger.None));
            Assert.That(rules.Match(Phrase("send\t it", 2, true), 3), Is.EqualTo(PhraseTrigger.SendIt));
            Assert.That(rules.Match(Phrase("start", 3, true), 3), Is.EqualTo(PhraseTrigger.Start));
            Assert.That(rules.Match(Phrase("start", 2, true), 9), Is.EqualTo(PhraseTrigger.None));
        }

        [Test]
        public void EmptyFinalClosesUtterance()
        {
            var rules = new PhraseRules();
            Assert.That(rules.Match(Phrase("", 2, true), 0), Is.EqualTo(PhraseTrigger.None));
            Assert.That(rules.Match(Phrase("start", 2), 1), Is.EqualTo(PhraseTrigger.None));
            Assert.That(rules.Match(Phrase("start", 3), 1), Is.EqualTo(PhraseTrigger.Start));
        }

        sealed class CustomGrammar : IPhraseGrammar
        {
            public System.Collections.Generic.IReadOnlyList<string> StartPhrases { get; } = new[] { "begin note" };
            public System.Collections.Generic.IReadOnlyList<string> SendPhrases { get; } = new[] { "finish note" };
        }

        [Test]
        public void KeyboardDispatchesHostCommandThroughWorkerAndRules()
        {
            using var ready = new ManualResetEventSlim();
            var keyboard = new KeyboardPhraseSpotter();
            using var worker = new RecognitionWorker(keyboard);
            var observed = default(RecognitionPhrase);
            var callbackThread = 0;
            worker.Phrase += phrase =>
            {
                observed = phrase;
                callbackThread = Thread.CurrentThread.ManagedThreadId;
                ready.Set();
            };
            Assert.That(new PhraseRules(new CustomGrammar()).Match(Phrase("start", 0, true), 0), Is.EqualTo(PhraseTrigger.None));
            // Include 300 ms of quiet and one voiced frame in a single submission.
            Assert.That(keyboard.TryFire("begin note"), Is.True);
            var pcm = new short[4800 + VoiceActivity.FrameSamples];
            Array.Fill(pcm, (short)2000, 4800, VoiceActivity.FrameSamples);
            Assert.That(worker.TryEnqueue(pcm), Is.True);
            Array.Clear(pcm, 0, pcm.Length);
            Assert.That(ready.Wait(3000), Is.True, "No phrase from worker");
            Assert.That(worker.Stop(3000), Is.True);
            Assert.That(worker.Failure, Is.Null);
            Assert.That(callbackThread, Is.Not.EqualTo(Thread.CurrentThread.ManagedThreadId));
            Assert.That(observed.IsFinal, Is.True);
            Assert.That(observed.UtteranceId, Is.Zero);
            Assert.That(observed.OnsetSample, Is.EqualTo(4800));
            Assert.That(observed.SamplesProcessed, Is.EqualTo(pcm.Length));
            Assert.That(new PhraseRules(new CustomGrammar()).Match(observed, 0), Is.EqualTo(PhraseTrigger.Start));
        }
    }
}

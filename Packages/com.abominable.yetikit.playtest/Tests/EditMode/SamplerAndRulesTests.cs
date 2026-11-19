using System;
using System.Linq;
using NUnit.Framework;
using UnityEngine;
using YetiKit.Core;

namespace YetiKit.Playtest.Tests
{
    public class SamplerAndRulesTests
    {
        [Test]
        public void ThirtyHzSamplerTakesThirtySamplesASecondAtAnyFrameRate()
        {
            foreach (var fps in new[] { 72.0, 90.0, 120.0, 30.0 })
            {
                var sampler = new FixedRateSampler(30);
                var taken = 0;
                for (var i = 0; i < fps * 10; i++) if (sampler.Tick(1.0 / fps)) taken++;
                Assert.That(taken, Is.InRange(299, 300), $"{fps} fps");
            }
        }

        [Test]
        public void SamplerTakesAtMostOnePerFrameAndDropsTheBacklogAfterAHitch()
        {
            var sampler = new FixedRateSampler(30);
            Assert.IsTrue(sampler.Tick(2.0)); // a 2 s hitch: one sample, not 60
            Assert.IsFalse(sampler.Tick(0.001));
            var taken = 0;
            for (var i = 0; i < 72; i++) if (sampler.Tick(1 / 72.0)) taken++;
            Assert.That(taken, Is.InRange(29, 31));
        }

        [Test]
        public void SessionIdIsUtcTimeAndFourHex()
        {
            var id = SessionRules.NewId(new DateTime(2026, 10, 29, 7, 5, 3, DateTimeKind.Utc), 0x1abcd);
            Assert.AreEqual("20261029-070503-abcd", id);
            Assert.IsTrue(SessionRules.IsId(id));
            Assert.IsFalse(SessionRules.IsId("20261029-070503-ABCD"));
            Assert.IsFalse(SessionRules.IsId("chunk-0001"));
            Assert.IsFalse(SessionRules.IsId("20261399-070503-abcd"));
        }

        [Test]
        public void ANewSessionStartsOnlyAfterMoreThanFiveMinutesPaused()
        {
            Assert.IsFalse(SessionRules.NewSessionOnResume(10));
            Assert.IsFalse(SessionRules.NewSessionOnResume(300));
            Assert.IsTrue(SessionRules.NewSessionOnResume(301));
        }

        [Test]
        public void ShortEmptySessionsAreNotKept()
        {
            Assert.IsFalse(SessionRules.Keep(19.9, 0));
            Assert.IsTrue(SessionRules.Keep(19.9, 1));
            Assert.IsTrue(SessionRules.Keep(20, 0));
        }

        [Test]
        public void BackoffDoublesFromFiveSecondsToFiveMinutes()
        {
            Assert.AreEqual(0, Backoff.Delay(0));
            CollectionAssert.AreEqual(new[] { 5.0, 10, 20, 40, 80, 160, 300, 300 },
                new[] { 1, 2, 3, 4, 5, 6, 7, 50 }.Select(Backoff.Delay));
        }

        [Test]
        public void ErrorGatePassesErrorsOnlyAndFiveASecond()
        {
            Assert.IsTrue(ErrorGate.Wanted(LogType.Error));
            Assert.IsTrue(ErrorGate.Wanted(LogType.Exception));
            Assert.IsTrue(ErrorGate.Wanted(LogType.Assert));
            Assert.IsFalse(ErrorGate.Wanted(LogType.Warning));
            Assert.IsFalse(ErrorGate.Wanted(LogType.Log));
            var gate = new ErrorGate();
            var passed = 0;
            for (var i = 0; i < 20; i++) if (gate.Allow(10 + i * 0.01)) passed++;
            Assert.AreEqual(5, passed);
            Assert.AreEqual(15, gate.Dropped);
            Assert.IsTrue(gate.Allow(11.1));
            Assert.AreEqual("a\nb\nc", ErrorGate.Trim("a\r\n\nb\nc\nd\n"));
        }

        [Test]
        public void ErrorGateStartsOverForANewSession()
        {
            var gate = new ErrorGate();
            for (var i = 0; i < 20; i++) gate.Allow(600 + i * 0.01);
            gate.Reset();
            Assert.IsTrue(gate.Allow(0.5), "not held back by the old session's window");
            Assert.AreEqual(0, gate.Dropped);
        }
    }
}

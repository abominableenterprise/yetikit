using System;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Core.Tests
{
    public class BuildInfoTests
    {
        static readonly DateTime Utc = new DateTime(2026, 11, 1, 23, 30, 0, DateTimeKind.Utc);
        static readonly TimeZoneInfo Pacific = TimeZoneInfo.CreateCustomTimeZone("Test Pacific", TimeSpan.FromHours(-7), "Test Pacific", "Test Pacific");

        [Test]
        public void FormatAndParseRoundTrip()
        {
            var info = new BuildInfo(141, "d3050c5", Utc, new[] { "Pick who's playing", "Build number \"b141\"" });
            var back = BuildInfo.Parse(info.ToJson());
            Assert.AreEqual(141, back.Number);
            Assert.AreEqual("d3050c5", back.Sha);
            Assert.AreEqual("2026-11-01T23:30:00Z", back.Date, "the full UTC time is baked");
            CollectionAssert.AreEqual(info.Notes, back.Notes);
            Assert.IsTrue(back.Known);
            Assert.AreEqual(Application.productName + " \u00b7 Build 141 (d3050c5) \u00b7 Nov 1, 4:30 PM", back.Header(Pacific));
            Assert.AreEqual(Application.productName + " \u00b7 Build 141 (d3050c5) \u00b7 Nov 1, 11:30 PM UTC", back.Header(zone: null));
        }

        [Test]
        public void HeaderUsesTheSuppliedProductNameForKnownAndDevelopmentBuilds()
        {
            var info = new BuildInfo(141, "d3050c5", Utc, null);
            Assert.AreEqual("Sample Product \u00b7 Build 141 (d3050c5) \u00b7 Nov 1, 4:30 PM",
                info.Header("Sample Product", Pacific));
            Assert.AreEqual("Sample Product \u00b7 Build 141 (d3050c5) \u00b7 Nov 1, 11:30 PM UTC",
                info.Header("Sample Product"));
            Assert.AreEqual("Sample Product \u00b7 dev build", BuildInfo.Unknown.Header("Sample Product"));
            Assert.AreEqual(info.Header(Application.productName), info.Header());
        }

        [Test]
        public void AnOldDateOnlyBuildStillReads()
        {
            var old = BuildInfo.Parse("{\"number\":173,\"sha\":\"41983e1\",\"date\":\"2026-11-02\",\"notes\":[\"a\"]}");
            Assert.AreEqual("b173-41983e1", old.Id);
            Assert.AreEqual(Application.productName + " \u00b7 Build 173 (41983e1) \u00b7 Nov 2", old.Header(Pacific));
            var noDate = BuildInfo.Parse("{\"number\":173,\"sha\":\"41983e1\"}");
            Assert.AreEqual(Application.productName + " \u00b7 Build 173 (41983e1)", noDate.Header(Pacific));
        }

        [TestCase(null)]
        [TestCase("")]
        [TestCase("not json {")]
        public void MissingOrBrokenJsonIsUnknown(string json)
        {
            var info = BuildInfo.Parse(json);
            Assert.IsFalse(info.Known);
            Assert.AreEqual("dev", info.Sha);
            Assert.IsEmpty(info.Notes);
            Assert.AreEqual(Application.productName + " \u00b7 dev build", info.Header(Pacific));
        }

        [Test]
        public void TheEditorHasNoBakedFileAndIsUnknown() => Assert.IsFalse(BuildInfo.Current.Known);

        [Test]
        public void BuildIdIsTheNumberAndShaWhenKnownElseVersionAndGuid()
        {
            var known = new BuildInfo(141, "d3050c5", Utc, null);
            Assert.AreEqual("b141-d3050c5", BuildInfo.BuildId(known, "1.0.141", "0123456789abcdef"));
            Assert.AreEqual("1.0-01234567", BuildInfo.BuildId(BuildInfo.Unknown, "1.0", "0123456789abcdef"));
            Assert.AreEqual("1.0-editor", BuildInfo.BuildId(null, "1.0", ""));
            var gitFailed = new BuildInfo(0, null, Utc, null);
            Assert.AreEqual("1.0-01234567", BuildInfo.BuildId(gitFailed, "1.0", "0123456789abcdef"), "git failed: the old form");
        }
    }
}

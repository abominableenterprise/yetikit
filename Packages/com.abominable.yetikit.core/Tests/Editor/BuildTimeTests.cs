using System;
using NUnit.Framework;

namespace YetiKit.Core.Tests
{
    public class BuildTimeTests
    {
        static readonly TimeZoneInfo Pacific = TimeZoneInfo.CreateCustomTimeZone("Test Pacific", TimeSpan.FromHours(-7), "Test Pacific", "Test Pacific");
        static readonly TimeZoneInfo Tokyo = TimeZoneInfo.CreateCustomTimeZone("Test Tokyo", TimeSpan.FromHours(9), "Test Tokyo", "Test Tokyo");

        [Test]
        public void TheStampIsIso8601UtcToTheSecond()
        {
            Assert.AreEqual("2026-11-02T03:55:07Z", BuildTime.Stamp(new DateTime(2026, 11, 2, 3, 55, 7, 900, DateTimeKind.Utc)));
            var local = new DateTime(2026, 11, 2, 3, 55, 0, DateTimeKind.Utc).ToLocalTime();
            Assert.AreEqual("2026-11-02T03:55:00Z", BuildTime.Stamp(local), "a local time is stamped as UTC");
        }

        [Test]
        public void UtcIsShownInTheGivenZoneWithTheTimeOfDay()
        {
            Assert.AreEqual("Nov 1, 8:55 PM", BuildTime.Label("2026-11-02T03:55:00Z", Pacific), "back across midnight");
            Assert.AreEqual("Nov 2, 12:55 PM", BuildTime.Label("2026-11-02T03:55:00Z", Tokyo));
            Assert.AreEqual("Nov 2, 3:55 AM", BuildTime.Label("2026-11-02T03:55:00Z", TimeZoneInfo.Utc));
            Assert.AreEqual("Nov 2, 3:55 AM UTC", BuildTime.Label("2026-11-02T03:55:00Z", null), "no zone yet: marked UTC");
        }

        [Test]
        public void AFailedZoneLookupKeepsTheUtcMarker()
        {
            var zone = BuildTime.ResolveZone(() => throw new TimeZoneNotFoundException("unavailable"));
            Assert.IsNull(zone, "a failed local lookup is not a resolved UTC zone");
            Assert.AreEqual("Nov 2, 3:55 AM UTC", BuildTime.Label("2026-11-02T03:55:00Z", zone));
        }

        [Test]
        public void AResolvedUtcZoneIsLocalTimeWithoutTheFallbackMarker()
        {
            var zone = BuildTime.ResolveZone(() => TimeZoneInfo.Utc);
            Assert.AreSame(TimeZoneInfo.Utc, zone);
            Assert.AreEqual("Nov 2, 3:55 AM", BuildTime.Label("2026-11-02T03:55:00Z", zone));
        }

        [TestCase("2026-11-02", "Nov 2")]
        [TestCase(" 2026-01-09 ", "Jan 9")]
        public void AnOldDateOnlyValueIsThatDayUnshifted(string baked, string shown)
        {
            Assert.AreEqual(shown, BuildTime.Label(baked, Pacific), "never moved to the day before: its time is unknown");
            Assert.AreEqual(shown, BuildTime.Label(baked, Tokyo));
        }

        [TestCase(null, "")]
        [TestCase("", "")]
        [TestCase("yesterday", "yesterday")]
        [TestCase("a very long and unexpected build date value", "a very long and unex")]
        public void NothingOrSomethingElseIsShownAsIsAndShort(string baked, string shown) =>
            Assert.AreEqual(shown, BuildTime.Label(baked, Pacific));

        [Test]
        public void TheLongestLabelFitsMaxLabelLength()
        {
            // longest month, two-digit day and hour, PM, plus " UTC" when no zone is known
            var longest = BuildTime.Stamp(new DateTime(2026, 9, 30, 12, 59, 0, DateTimeKind.Utc));
            Assert.AreEqual("Sep 30, 12:59 PM UTC", BuildTime.Label(longest, null));
            Assert.AreEqual(BuildTime.MaxLabelLength, BuildTime.Label(longest, null).Length);
            for (var month = 1; month <= 12; month++)
            {
                var stamp = BuildTime.Stamp(new DateTime(2026, month, 28, 23, 59, 0, DateTimeKind.Utc));
                foreach (var zone in new[] { Pacific, Tokyo, TimeZoneInfo.Utc, null })
                    Assert.LessOrEqual(BuildTime.Label(stamp, zone).Length, BuildTime.MaxLabelLength, stamp);
            }
        }
    }
}

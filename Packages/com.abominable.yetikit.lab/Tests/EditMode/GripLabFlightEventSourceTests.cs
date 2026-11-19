using NUnit.Framework;
using UnityEngine;
using YetiKit.Hands;
using YetiKit.Playtest;

namespace YetiKit.Lab.Tests
{
    public sealed class GripLabFlightEventSourceTests
    {
        [TestCase(false, HandMode.Controller, "L", "controller")]
        [TestCase(true, HandMode.TrackedHand, "R", "tracked_hand")]
        public void RecordsV1GoldenLine(bool rightHand, HandMode mode, string side, string modeName)
        {
            var source = new GripLabFlightEventSource();
            double now = 8;
            var log = new FlightLog(() => now);
            now = 9.25;

            var head = new Pose(new Vector3(1, 2, 3), new Quaternion(0, 1, 0, 0));
            var wrist = new Pose(new Vector3(3, 5, 7), new Quaternion(0, 0, 1, 0));
            var attach = new Pose(new Vector3(4.23456f, 7, 4), Quaternion.identity);
            using (log.Register(source))
                source.Record("sample\"prop", rightHand, mode, "sample\ngrip", attach, wrist, head);

            Assert.AreEqual(1, log.Count("griplab"));
            Assert.AreEqual(
                "{\"t\":1.25,\"k\":\"griplab\",\"v\":1,\"prop\":\"sample\\\"prop\",\"side\":\"" + side
                + "\",\"mode\":\"" + modeName + "\",\"grip\":\"sample\\ngrip\","
                + "\"attach\":[-1.235,-2,-3,0,0,-1,0],\"wrist\":[-2,3,-4,-1,0,0,0]}\n",
                log.Buffer.ToString());
        }

        [Test]
        public void DoesNotRecordWithoutAnActiveInputMode()
        {
            var source = new GripLabFlightEventSource();
            var log = new FlightLog(() => 0);
            using (log.Register(source))
                source.Record("sample", false, HandMode.None, "default", Pose.identity, Pose.identity, Pose.identity);

            Assert.AreEqual(0, log.Lines);
        }
    }
}

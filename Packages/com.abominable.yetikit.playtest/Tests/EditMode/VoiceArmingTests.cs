using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public class VoiceArmingTests
    {
        sealed class Permission : IMicrophonePermission
        {
            public bool IsGranted { get; set; }
            public int Requests { get; private set; }
            public void Request() => Requests++;
        }

        sealed class Capture : IMicrophoneCapture
        {
            public bool CanStart { get; set; } = true;
            public int Starts { get; private set; }
            public int Stops { get; private set; }

            public bool TryStart()
            {
                Starts++;
                return CanStart;
            }

            public void Stop() => Stops++;
        }

        [Test]
        public void DelayedGrantStartsOnceWithoutReprompting()
        {
            var permission = new Permission();
            var capture = new Capture();
            var arming = new MicrophoneArming(permission, capture);

            arming.Arm();
            arming.Poll();
            arming.Arm();
            arming.Poll();
            Assert.AreEqual(1, permission.Requests);
            Assert.AreEqual(0, capture.Starts);
            Assert.IsFalse(arming.IsCapturing);

            permission.IsGranted = true;
            arming.Poll();
            arming.Poll();
            Assert.IsTrue(arming.IsCapturing);
            Assert.AreEqual(1, capture.Starts);
        }

        [Test]
        public void StopWhileWaitingCancelsLateGrantAndPreservesPromptBudget()
        {
            var permission = new Permission();
            var capture = new Capture();
            var arming = new MicrophoneArming(permission, capture);

            arming.Arm();
            arming.Stop();
            arming.Arm();
            Assert.AreEqual(1, permission.Requests);
            arming.Stop();
            permission.IsGranted = true;
            arming.Poll();
            Assert.AreEqual(0, capture.Starts);
            Assert.AreEqual(0, capture.Stops);
        }

        [TestCase(false)]
        [TestCase(true)]
        public void StopOrRevocationEndsCaptureOnceAndRequiresRearming(bool revoke)
        {
            var permission = new Permission { IsGranted = true };
            var capture = new Capture();
            var arming = new MicrophoneArming(permission, capture);

            arming.Poll();
            arming.Arm();
            Assert.AreEqual(0, capture.Starts);
            Assert.AreEqual(0, permission.Requests);
            arming.Poll();
            Assert.IsTrue(arming.IsCapturing);
            if (revoke)
            {
                permission.IsGranted = false;
                arming.Poll();
            }
            else arming.Stop();
            Assert.AreEqual(1, capture.Stops);
            Assert.IsFalse(arming.IsCapturing);

            permission.IsGranted = true;
            arming.Poll();
            arming.Stop();
            Assert.AreEqual(1, capture.Starts);
            Assert.AreEqual(1, capture.Stops);

            arming.Arm();
            arming.Poll();
            Assert.IsTrue(arming.IsCapturing);
            Assert.AreEqual(2, capture.Starts);
            arming.Stop();
        }

        [Test]
        public void FailedStartDoesNotReportCaptureOrRetryUntilRearmed()
        {
            var permission = new Permission { IsGranted = true };
            var capture = new Capture { CanStart = false };
            var arming = new MicrophoneArming(permission, capture);

            arming.Arm();
            arming.Poll();
            capture.CanStart = true;
            arming.Poll();
            Assert.IsFalse(arming.IsCapturing);
            Assert.AreEqual(1, capture.Starts);
            arming.Stop();
            Assert.AreEqual(0, capture.Stops);

            arming.Arm();
            arming.Poll();
            Assert.IsTrue(arming.IsCapturing);
            Assert.AreEqual(2, capture.Starts);
            arming.Stop();
        }
    }
}

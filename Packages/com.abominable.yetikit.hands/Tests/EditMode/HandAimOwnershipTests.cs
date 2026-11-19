using NUnit.Framework;

namespace YetiKit.Hands.Tests
{
    public class HandAimOwnershipTests
    {
        [Test]
        public void OnlyTheOwnerCanReleaseAndPreemptionCallsCancellationOnce()
        {
            var lease = new HandAimOwnership();
            var first = new object();
            var next = new object();
            var cancelled = 0;
            Assert.That(lease.Claim(first, () => { cancelled++; lease.Release(first); }), Is.True);
            lease.Release(next);
            Assert.That(lease.Claim(next, null), Is.False);
            Assert.That(lease.Claim(next, null, _ => false), Is.False);
            Assert.That(cancelled, Is.Zero);
            Assert.That(lease.Claim(next, null, incumbent => ReferenceEquals(incumbent, first)), Is.True);
            Assert.That(cancelled, Is.EqualTo(1));
            Assert.That(lease.Claim(first, null), Is.False);
            lease.Release(next);
            Assert.That(lease.Claim(first, null), Is.True);
        }
    }
}

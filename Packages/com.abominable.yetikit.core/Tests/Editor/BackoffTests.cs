using NUnit.Framework;
using System.Linq;

namespace YetiKit.Core.Tests
{
    public class BackoffTests
    {
        [Test]
        public void BackoffDoublesFromFiveSecondsToFiveMinutes()
        {
            Assert.AreEqual(0, Backoff.Delay(0));
            CollectionAssert.AreEqual(new[] { 5.0, 10, 20, 40, 80, 160, 300, 300 },
                new[] { 1, 2, 3, 4, 5, 6, 7, 50 }.Select(Backoff.Delay));
        }
    }
}

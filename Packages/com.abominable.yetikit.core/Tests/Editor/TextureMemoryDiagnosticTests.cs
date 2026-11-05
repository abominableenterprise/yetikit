using NUnit.Framework;

namespace YetiKit.Core.Tests
{
    public class TextureMemoryDiagnosticTests
    {
        [Test]
        public void HighMemoryDiagnosticsAreThresholdedAndRateLimited()
        {
            var limit = TextureMemoryDiagnostic.WarningBytes;
            Assert.IsFalse(TextureMemoryDiagnostic.ShouldCapture(limit, 60f, 0f));
            Assert.IsFalse(TextureMemoryDiagnostic.ShouldCapture(limit + 1, 59f, 0f));
            Assert.IsTrue(TextureMemoryDiagnostic.ShouldCapture(limit + 1, 60f, 0f));
            Assert.IsTrue(TextureMemoryDiagnostic.ShouldCapture(limit + 1, 0f, float.NegativeInfinity));
        }
    }
}

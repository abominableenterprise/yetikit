using System;
using System.Threading.Tasks;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class FlightEventSourceTests
    {
        sealed class Source : IFlightEventSource
        {
            public event Action<string, string> Event;
            public void Emit() => Event?.Invoke("test", "{\"value\":1}");
        }

        [Test]
        public void RegisteredSourceCanEmitFromMultipleThreadsUntilDisposed()
        {
            var source = new Source();
            var log = new FlightLog(() => 0);
            using (log.Register(source)) Parallel.For(0, 100, _ => source.Emit());
            source.Emit();
            Assert.AreEqual(100, log.Count("test"));
            var lines = log.Buffer.ToString().Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
            Assert.AreEqual(100, lines.Length);
            foreach (var line in lines) Assert.AreEqual("{\"t\":0,\"k\":\"test\",\"value\":1}", line);
        }
    }
}

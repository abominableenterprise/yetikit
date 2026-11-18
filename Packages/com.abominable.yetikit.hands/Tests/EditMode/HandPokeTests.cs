using NUnit.Framework;

namespace YetiKit.Hands.Tests
{
    public sealed class HandPokeTests
    {
        [Test]
        public void AnEntryDuringCooldownStillLatchesUntilTheFingerLeaves()
        {
            const float radius = 0.02f;
            var poke = new HandPoke(0.25f);
            Assert.That(poke.Tick(radius, radius, 0f), Is.True);
            Assert.That(poke.Tick(radius + HandPoke.ExitMargin / 2f, radius, 0.05f), Is.False);
            Assert.That(poke.Inside, Is.True);

            Assert.That(poke.Tick(radius + 2f * HandPoke.ExitMargin, radius, 0.1f), Is.False);
            Assert.That(poke.Inside, Is.False);
            Assert.That(poke.Tick(radius, radius, 0.15f), Is.False);
            Assert.That(poke.Inside, Is.True);
            Assert.That(poke.Tick(radius, radius, 0.5f), Is.False);

            poke.Release();
            Assert.That(poke.Tick(radius, radius, 0.6f), Is.True);
        }
    }
}

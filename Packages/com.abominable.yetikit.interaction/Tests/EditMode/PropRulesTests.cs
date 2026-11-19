using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class PropRespawnRulesTests
    {
        static readonly Vector3 Home = Vector3.up;
        static readonly PropRespawnSettings Defaults = PropRespawnSettings.Default;

        static RespawnReason Check(Vector3 position, Vector3 home, float idleSeconds = 0f,
            bool inHomeArea = false, float outOfAreaSeconds = 0f) =>
            PropRespawnRules.Check(position, home, idleSeconds, inHomeArea, outOfAreaSeconds, true, Defaults);

        [Test]
        public void APropAtHomeDoesNotRespawnFromIdling() =>
            Assert.That(Check(Home + Vector3.up * 0.1f, Home, 10000f), Is.EqualTo(RespawnReason.None));

        [Test]
        public void FallingOutOfTheWorldRespawnsAtOnceEvenInView()
        {
            var reason = Check(new Vector3(0f, -2.5f, 0f), Home);
            Assert.That(reason, Is.EqualTo(RespawnReason.Fell));
            Assert.That(PropRespawnRules.PopNow(reason, inView: true), Is.True);
        }

        [Test]
        public void FlyingTooFarRespawnsAtOnce()
        {
            Assert.That(Check(Home + Vector3.right * 59f, Home), Is.EqualTo(RespawnReason.None));
            var reason = Check(Home + Vector3.right * 61f, Home);
            Assert.That(reason, Is.EqualTo(RespawnReason.TooFar));
            Assert.That(PropRespawnRules.PopNow(reason, inView: true), Is.True);
        }

        [Test]
        public void LeftLyingElsewhereGoesHomeAfterTwoMinutesWhenNotWatched()
        {
            var away = Home + new Vector3(3f, -0.9f, 1f);
            Assert.That(Check(away, Home, 119f), Is.EqualTo(RespawnReason.None));
            var reason = Check(away, Home, 120f);
            Assert.That(reason, Is.EqualTo(RespawnReason.Idle));
            Assert.That(PropRespawnRules.PopNow(reason, inView: true), Is.False);
            Assert.That(PropRespawnRules.PopNow(reason, inView: false), Is.True);
        }

        [Test]
        public void HomeAreaExemptsIdlePropsButNotFallsOrExcessDistance()
        {
            var inArea = Home + new Vector3(5f, 0f, 3f);
            Assert.That(Check(inArea, Home, 1000f, inHomeArea: true), Is.EqualTo(RespawnReason.None));
            Assert.That(Check(inArea, Home, 120f), Is.EqualTo(RespawnReason.Idle));
            Assert.That(Check(new Vector3(0f, -2.5f, 0f), Home, inHomeArea: true), Is.EqualTo(RespawnReason.Fell));
            Assert.That(Check(Home + Vector3.right * 61f, Home, inHomeArea: true), Is.EqualTo(RespawnReason.TooFar));
        }

        [Test]
        public void OutsideAnOffsetAreaUsesHorizontalDistanceAndCustomGrace()
        {
            var settings = PropRespawnSettings.Default;
            settings.AreaOrigin = new Vector3(10f, 2f, -12f);
            settings.AreaRadius = 5f;
            settings.OutOfAreaSeconds = 1.25f;
            var home = settings.AreaOrigin;
            var over = home + new Vector3(0f, 16f, -6f);
            var outside = home + new Vector3(4f, 0f, 4f);
            var inside = home + new Vector3(3f, 16f, 3f);
            Assert.That(PropRespawnRules.OutOfArea(over, settings), Is.True);
            Assert.That(PropRespawnRules.OutOfArea(outside, settings), Is.True);
            Assert.That(PropRespawnRules.OutOfArea(inside, settings), Is.False);
            Assert.That(PropRespawnRules.Check(outside, home, 0f, false, 1.24f, true, settings), Is.EqualTo(RespawnReason.None));
            var reason = PropRespawnRules.Check(outside, home, 0f, false, 1.25f, true, settings);
            Assert.That(reason, Is.EqualTo(RespawnReason.OutOfArea));
            Assert.That(PropRespawnRules.PopNow(reason, inView: true), Is.True);
            Assert.That(PropRespawnRules.Check(inside, home, 0f, false, 100f, true, settings), Is.EqualTo(RespawnReason.None),
                "the timer only counts outside");
            Assert.That(PropRespawnRules.Check(outside, outside, 0f, false, 100f, true, settings), Is.EqualTo(RespawnReason.None),
                "a prop whose home is outside the area is exempt from the boundary rule");
        }

        [Test]
        public void CustomHomeToleranceAndIdleTimeAreUsedTogether()
        {
            var settings = PropRespawnSettings.Default;
            settings.HomeTolerance = 1f;
            settings.IdleSeconds = 5f;
            var near = Home + Vector3.right * 0.75f;
            var away = Home + Vector3.right * 1.25f;
            Assert.That(PropRespawnRules.AtHome(near, Home, settings), Is.True);
            Assert.That(PropRespawnRules.Away(near, Home, false, settings), Is.False);
            Assert.That(PropRespawnRules.Away(near, Home, true, settings), Is.True);
            Assert.That(PropRespawnRules.Away(away, Home, false, settings), Is.True);
            Assert.That(PropRespawnRules.Check(near, Home, 5f, false, 0f, true, settings), Is.EqualTo(RespawnReason.None));
            Assert.That(PropRespawnRules.Check(away, Home, 4.9f, false, 0f, true, settings), Is.EqualTo(RespawnReason.None));
            Assert.That(PropRespawnRules.Check(away, Home, 5f, false, 0f, true, settings), Is.EqualTo(RespawnReason.Idle));
        }

        [Test]
        public void CustomFallHeightAppliesEvenWhenOrdinaryReturnsAreDisabled()
        {
            var settings = PropRespawnSettings.Default;
            settings.FallY = -5f;
            settings.MaxDistance = 10f;
            var aboveFloor = new Vector3(0f, -4f, 0f);
            var belowFloor = new Vector3(0f, -6f, 0f);
            var far = Home + Vector3.right * 11f;
            Assert.That(PropRespawnRules.Check(aboveFloor, Home, 0f, false, 0f, true, settings), Is.EqualTo(RespawnReason.None));
            Assert.That(PropRespawnRules.Check(belowFloor, Home, 0f, false, 0f, false, settings), Is.EqualTo(RespawnReason.Fell));
            Assert.That(PropRespawnRules.Check(far, Home, 0f, false, 0f, true, settings), Is.EqualTo(RespawnReason.TooFar));
            Assert.That(PropRespawnRules.Check(far, Home, 0f, false, 0f, false, settings), Is.EqualTo(RespawnReason.None));
        }

        [Test]
        public void ViewConeCheck()
        {
            Assert.That(PropRespawnRules.InView(Vector3.zero, Vector3.forward, Vector3.forward * 5f, Defaults), Is.True);
            Assert.That(PropRespawnRules.InView(Vector3.zero, Vector3.forward, Vector3.back * 5f, Defaults), Is.False);

            var settings = PropRespawnSettings.Default;
            settings.ViewHalfAngle = 30f;
            var at45Degrees = Vector3.forward + Vector3.right;
            Assert.That(PropRespawnRules.InView(Vector3.zero, Vector3.forward, at45Degrees, Defaults), Is.True);
            Assert.That(PropRespawnRules.InView(Vector3.zero, Vector3.forward, at45Degrees, settings), Is.False);
        }
    }

    public class PropHitFilterTests
    {
        [Test]
        public void OnlyFastThrownImpactsCountAndOnlyOncePerThrow()
        {
            var filter = new PropHitFilter();
            filter.Thrown(10f);
            Assert.That(filter.Accept(2f, 10.3f), Is.False, "too slow");
            Assert.That(filter.Accept(4f, 10.4f), Is.True, "the hit");
            Assert.That(filter.Accept(4f, 10.5f), Is.False, "the bounce after it");
        }

        [Test]
        public void ThePropMustHaveBeenThrownInTheLastThreeSeconds()
        {
            var filter = new PropHitFilter();
            Assert.That(filter.Accept(10f, 1f), Is.False, "never thrown");
            filter.Thrown(5f);
            Assert.That(filter.Accept(10f, 8.5f), Is.False, "too long after the throw");
            filter.Thrown(20f);
            Assert.That(filter.Accept(PropHitFilter.MinSpeed, 22.9f), Is.True);
        }

        [Test]
        public void PickingItUpAgainCancelsTheThrow()
        {
            var filter = new PropHitFilter();
            filter.Thrown(1f);
            filter.Reset();
            Assert.That(filter.Accept(10f, 1.2f), Is.False);
        }
    }
}

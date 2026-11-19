using System;
using System.IO;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    sealed class TestEventClassification : IEventClassification
    {
        public EventClass Classify(string kind)
        {
            switch (kind)
            {
                case "test_sample": return EventClass.Sample;
                case "test_frame": return EventClass.Frame;
                case "test_status": return EventClass.Bookkeeping;
                case "test_impulse": return EventClass.Throw;
                case "test_fault": return EventClass.Error;
                default: return EventClass.Meaningful;
            }
        }
    }

    public class RecordingSessionTests
    {
        const string Id = "20261029-070503-abcd", NextId = "20261029-070503-ef01";
        static readonly DateTime Start = new DateTime(2026, 10, 29, 7, 5, 3, DateTimeKind.Utc);
        double clock;
        DateTime Utc => Start + TimeSpan.FromTicks((long)Math.Round(clock * TimeSpan.TicksPerSecond));

        sealed class TestIdentity : ISessionMetadataSource, IBuildIdentity, IPlayerIdentity
        {
            public string Unity => "test-unity";
            public string Device => "test-device";
            public string Scene => "test-scene";
            public float RefreshRate => 72.5f;
            public string Build => "test-build";
            public string BuildGuid => "test-build-id";
            public string AppVersion => "1.0-test";
            public string Player => "test-player";
        }

        RecordingSession Make(FileChunkStore store, ChunkPump pump, out FlightLog log, string id = Id)
        {
            clock = 0;
            log = new FlightLog(() => clock, new TestEventClassification());
            var identity = new TestIdentity();
            var meta = new SessionMeta(id, metadata: identity, build: identity, player: identity);
            return new RecordingSession(log, pump, store, meta, () => Utc);
        }

        void Advance(double seconds) => clock += seconds;

        [Test]
        public void ASessionWritesMetaChunksAndTheDoneMarker()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var store = new FileChunkStore(tmp.Path);
                var session = Make(store, pump, out var log);
                Assert.IsTrue(session.Begin(100));
                Assert.IsTrue(pump.Drain(5000));
                var dir = store.SessionOutbox(Id);
                var meta = Path.Combine(dir, FileChunkStore.MetaFile);
                StringAssert.Contains("\"end\":null", File.ReadAllText(meta));
                for (var i = 0; i < 61 * 30; i++)
                {
                    Advance(1 / 30.0);
                    log.AppendEvent("test_frame", null);
                    session.Tick(100 + i);
                }
                log.AppendEvent("test_impulse", "{\"speed\":3}");
                log.AppendEvent("test_fault", null);
                Assert.IsTrue(pump.Drain(5000));
                var first = Path.Combine(dir, "chunk-0001.jsonl.gz");
                Assert.IsTrue(File.Exists(first), "rotated at 60 s");
                Assert.IsTrue(session.End(2000));
                Assert.IsTrue(pump.Drain(5000));
                StringAssert.StartsWith("{\"t\":0,\"k\":\"start\",\"session\":\"" + Id + "\"", TempDir.Gunzip(first));
                var last = TempDir.Gunzip(Path.Combine(dir, "chunk-0002.jsonl.gz"));
                StringAssert.Contains("\"k\":\"test_impulse\",\"speed\":3}", last);
                var text = File.ReadAllText(meta);
                StringAssert.Contains("\"end\":\"2026-10-29T07:06:04.000Z\"", text);
                StringAssert.Contains("\"frames\":1900,", text);
                StringAssert.Contains("\"samples\":1830,", text);
                StringAssert.Contains("\"throws\":1,", text);
                StringAssert.Contains("\"errors\":1,", text);
                StringAssert.Contains("\"lost\":{\"count\":0,\"first\":null,\"last\":null,\"torn\":0}", text);
                var marker = DoneMarker.Parse(File.ReadAllText(Path.Combine(dir, DoneMarker.FileName)));
                Assert.IsNotNull(marker);
                Assert.AreEqual(Id, marker.session);
                Assert.AreEqual("test-player", marker.player);
                Assert.AreEqual("test-build", marker.build);
                Assert.AreEqual(1, marker.context.throws);
                Assert.AreEqual(1, marker.context.errors);
                Assert.AreEqual(0, marker.context.lost);
                Assert.That(marker.context.minutes, Is.EqualTo(61 / 60f).Within(0.01f));
            }
        }

        [Test]
        public void MetadataUsesInjectedSources()
        {
            var identity = new TestIdentity();
            var meta = new SessionMeta(Id, metadata: identity, build: identity, player: identity) { StartUtc = Start };
            var text = meta.ToJson(null);
            StringAssert.Contains("\"session\":\"" + Id + "\"", text);
            StringAssert.Contains("\"unity\":\"test-unity\"", text);
            StringAssert.Contains("\"device\":\"test-device\"", text);
            StringAssert.Contains("\"scene\":\"test-scene\"", text);
            StringAssert.Contains("\"refreshRate\":72.5,", text);
            StringAssert.Contains("\"build\":\"test-build\"", text);
            StringAssert.Contains("\"buildGuid\":\"test-build-id\"", text);
            StringAssert.Contains("\"version\":\"1.0-test\"", text);
            StringAssert.Contains("\"player\":\"test-player\"", text);
        }

        [Test]
        public void AShortSessionWithOnlySamplesAndBookkeepingIsDeleted()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var store = new FileChunkStore(tmp.Path);
                var session = Make(store, pump, out var log);
                Assert.IsTrue(session.Begin(0));
                Advance(10);
                log.AppendEvent("test_frame", null);
                log.AppendEvent("test_sample", null);
                log.AppendEvent("test_status", null);
                Assert.IsFalse(session.End(300));
                Assert.IsTrue(pump.Drain(5000));
                Assert.IsFalse(Directory.Exists(store.SessionOutbox(Id)));
            }
        }

        [Test]
        public void AShortSessionWithAnEventIsKept()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var store = new FileChunkStore(tmp.Path);
                var session = Make(store, pump, out var log);
                Assert.IsTrue(session.Begin(0));
                Advance(5);
                log.AppendEvent("test_action", null);
                Assert.IsTrue(session.End(100));
                Assert.IsTrue(pump.Drain(5000));
                Assert.IsTrue(File.Exists(Path.Combine(store.SessionOutbox(Id), DoneMarker.FileName)));
            }
        }

        [Test]
        public void AShortPauseResumesTheSessionALongOneEndsIt()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var store = new FileChunkStore(tmp.Path);
                var session = Make(store, pump, out _);
                Assert.IsTrue(session.Begin(0));
                var dir = store.SessionOutbox(Id);
                Advance(30);
                session.Pause(900, 5000);
                Assert.IsTrue(File.Exists(Path.Combine(dir, "chunk-0001.jsonl.gz")), "pause publishes");
                Advance(299);
                Assert.IsTrue(session.Resume(), "under 5 min: same session");
                Assert.IsFalse(session.Paused);
                Advance(10);
                session.Pause(1200, 5000);
                Advance(301);
                Assert.IsFalse(session.Resume(), "over 5 min: a new session");
                Assert.IsTrue(session.End(1200));
                Assert.IsTrue(pump.Drain(5000));
                var lines = TempDir.Gunzip(Path.Combine(dir, "chunk-0002.jsonl.gz"));
                StringAssert.Contains("\"k\":\"resume\",\"paused\":299", lines);
                StringAssert.Contains("\"k\":\"pause\"", lines);
                StringAssert.Contains("\"end\":\"2026-10-29T07:10:42.000Z\"", File.ReadAllText(Path.Combine(dir, FileChunkStore.MetaFile)),
                    "the end is the pause, not the resume");
            }
        }

        [Test]
        public void ALongPauseIsNotPlayTime()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var store = new FileChunkStore(tmp.Path);
                var session = Make(store, pump, out _);
                Assert.IsTrue(session.Begin(0));
                Advance(5);
                session.Pause(300, 5000);
                Advance(400);
                Assert.IsFalse(session.Resume());
                Assert.IsFalse(session.End(300), "5 s and empty: still too short to keep");
                Assert.IsTrue(pump.Drain(5000));
                Assert.IsFalse(Directory.Exists(store.SessionOutbox(Id)));

                var next = Make(store, pump, out var log, NextId);
                Assert.IsTrue(next.Begin(0));
                Advance(40);
                log.AppendEvent("test_action", null);
                next.Pause(1200, 5000);
                Advance(400);
                Assert.IsFalse(next.Resume());
                Assert.IsTrue(next.End(1200));
                Assert.IsTrue(pump.Drain(5000));
                StringAssert.Contains("\"seconds\":40,", File.ReadAllText(Path.Combine(store.SessionOutbox(NextId), FileChunkStore.MetaFile)));
                Assert.That(next.Meta.Context().minutes, Is.EqualTo(40 / 60f).Within(0.01f));
            }
        }

        [Test]
        public void ShortPausesAreNotPlayTimeEither()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var store = new FileChunkStore(tmp.Path);
                var session = Make(store, pump, out var log);
                Assert.IsTrue(session.Begin(0));
                Advance(5);
                session.Pause(300, 5000);
                Advance(299);
                Assert.IsTrue(session.Resume());
                Advance(1);
                Assert.IsFalse(session.Keep, "6 s of play, not 305");
                Advance(20);
                log.AppendEvent("test_action", null);
                Assert.IsTrue(session.End(400));
                Assert.IsTrue(pump.Drain(5000));
                StringAssert.Contains("\"seconds\":26,", File.ReadAllText(Path.Combine(store.SessionOutbox(Id), FileChunkStore.MetaFile)));
            }
        }
    }
}

using System;
using System.Collections;
using System.IO;
using System.IO.Compression;
using System.Linq;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace YetiKit.Playtest.XR.Tests
{
    public class RecorderSessionTests
    {
        sealed class Identity : IPlayerIdentity, IBuildIdentity
        {
            public string Player { get; set; } = "tester";
            public string Build => "build-1";
            public string BuildGuid => "synthetic-guid";
            public string AppVersion => "1.2.3";
        }

        sealed class Source : IFlightEventSource
        {
            public event Action<string, string> Event;
            public int Subscribers => Event?.GetInvocationList().Length ?? 0;
            public void Emit(string state) => Event?.Invoke("action", "{\"state\":\"" + state + "\"}");
        }

        [Test]
        public void KeepsCadenceIdentityAndEventPayloadAcrossPause()
        {
            var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
            var time = 0.0;
            var epoch = new DateTime(2025, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            var samples = 0;
            var identity = new Identity();
            var source = new Source();
            var store = new FileChunkStore(root);
            string dir;
            try
            {
                using (var recorder = new RecorderSession(store, () => time, () => epoch.AddSeconds(time),
                    () => { samples++; return "{\"pose\":1}"; }, identity, identity, new[] { source }))
                {
                    long frame = 0;
                    void Tick(double delta, bool paused = false)
                    {
                        time += delta;
                        recorder.Tick(frame++, delta, paused);
                    }

                    Tick(0, true);
                    Assert.That(recorder.Session, Is.Null);
                    Tick(0);
                    var first = recorder.Session;
                    dir = first.Dir;
                    Assert.That(source.Subscribers, Is.EqualTo(1));
                    source.Emit("before");
                    Tick(0.02);
                    Assert.That(samples, Is.Zero);
                    Tick(0.02);
                    Assert.That(samples, Is.EqualTo(1));
                    Tick(1);
                    Assert.That(samples, Is.EqualTo(2), "a hitch must not burst samples");
                    Tick(0, true);
                    Assert.That(first.Paused, Is.True);
                    Assert.That(source.Subscribers, Is.Zero);
                    source.Emit("ignored");
                    Tick(15, true);
                    Tick(1);
                    Assert.That(first.Paused, Is.False);
                    Assert.That(recorder.Session, Is.SameAs(first));
                    Assert.That(samples, Is.EqualTo(2));
                    Assert.That(source.Subscribers, Is.EqualTo(1));
                    Tick(0.04);
                    Assert.That(samples, Is.EqualTo(3));
                    source.Emit("after");
                    Tick(0, true);
                    identity.Player = "other-tester";
                    Tick(SessionRules.ResumeGapSeconds + 1);
                    Assert.That(first.Ended, Is.True);
                    Assert.That(recorder.Session.Id, Is.Not.EqualTo(first.Id));
                    Assert.That(recorder.Session.Meta.Player, Is.EqualTo("other-tester"));
                    Assert.That(source.Subscribers, Is.EqualTo(1));
                }

                Assert.That(source.Subscribers, Is.Zero);
                var meta = File.ReadAllText(Path.Combine(dir, FileChunkStore.MetaFile));
                foreach (var field in new[] { "\"player\":\"tester\"", "\"build\":\"build-1\"", "\"buildGuid\":\"synthetic-guid\"",
                    "\"version\":\"1.2.3\"", "\"samples\":3" }) Assert.That(meta, Does.Contain(field));
                var records = string.Concat(Directory.GetFiles(dir, "*.jsonl.gz").OrderBy(path => path).Select(ReadChunk));
                foreach (var fragment in new[] { "\"k\":\"pause\"", "\"k\":\"resume\"", "\"k\":\"action\",\"state\":\"before\"",
                    "\"k\":\"action\",\"state\":\"after\"", "\"k\":\"f\",\"pose\":1" }) Assert.That(records, Does.Contain(fragment));
                Assert.That(records, Does.Not.Contain("ignored"));
            }
            finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }

        [UnityTest]
        public IEnumerator DisablingTheRecorderPausesAndReenablingResumesRecording()
        {
            yield return new EnterPlayMode();
            var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
            var host = new GameObject("Synthetic recorder");
            try
            {
                var source = new Source();
                using var recorder = new RecorderSession(new FileChunkStore(path), () => 0, () => DateTime.UtcNow,
                    () => "{}", null, null, new[] { source });
                host.AddComponent<FlightRecorder>().Recording = recorder;
                recorder.Tick(Time.frameCount, 0, false);
                var session = recorder.Session;
                Assert.That(source.Subscribers, Is.EqualTo(1));

                host.SetActive(false);
                Assert.That(session.Paused, Is.True);
                Assert.That(source.Subscribers, Is.Zero);

                host.SetActive(true);
                yield return null; // Let FlightRecorder.LateUpdate resume the session.
                Assert.That(recorder.Session, Is.SameAs(session));
                Assert.That(session.Paused, Is.False);
                Assert.That(source.Subscribers, Is.EqualTo(1));
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(host);
                if (Directory.Exists(path)) Directory.Delete(path, true);
            }
            yield return new ExitPlayMode();
        }

        static string ReadChunk(string path)
        {
            using var file = File.OpenRead(path);
            using var stream = new GZipStream(file, CompressionMode.Decompress);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
    }
}

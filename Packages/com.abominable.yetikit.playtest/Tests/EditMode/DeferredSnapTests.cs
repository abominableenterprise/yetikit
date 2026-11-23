using System.IO;
using System.Linq;
using System.Threading;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

namespace YetiKit.Playtest.Tests
{
    [Category("Gfx")]
    public sealed class DeferredSnapTests
    {
        const string Session = "20260101-010101-0001";
        const double Now = 10, Timeout = 2;
        const int WaitMs = 5000;
        TempDir temp;
        GameObject view;
        Camera head;
        SnitchFrames frames;
        SnitchCam cam;
        FileChunkStore store;
        SnapOutcome outcomes;

        [SetUp]
        public void SetUp()
        {
            temp = new TempDir();
            store = new FileChunkStore(temp.Path);
            outcomes = new SnapOutcome();
            view = new GameObject("Test capture view");
            head = view.AddComponent<Camera>();
            head.enabled = false;
            head.clearFlags = CameraClearFlags.SolidColor;
            head.cullingMask = 0;
            frames = new SnitchFrames();
            cam = CreateCam(store);
        }

        [TearDown]
        public void TearDown()
        {
            cam.TryShutdown(WaitMs);
            frames.Dispose();
            Object.DestroyImmediate(view);
            temp.Dispose();
        }

        SnitchCam CreateCam(FileChunkStore fileStore) =>
            new(frames, new Context(), new SnapDelivery(fileStore, new Settings()), outcomes, noteTimeoutSeconds: Timeout);

        [Test]
        public void CapturesCurrentFrameImmediatelyAndPublishesWithLateNote()
        {
            head.backgroundColor = Color.red;
            cam.Tick(head, Now - 0.1);
            head.backgroundColor = Color.blue;
            var pending = cam.BeginSnap(head, Now);
            Assert.That(pending, Is.Not.Null);
            var dir = Directory.GetDirectories(store.Outbox).Single();
            var photo = Directory.GetFiles(dir, "*.jpg").Single();
            var image = new Texture2D(2, 2);
            try
            {
                Assert.That(image.LoadImage(File.ReadAllBytes(photo)), Is.True);
                Assert.That(image.GetPixel(0, 0).b, Is.GreaterThan(0.8f), "Do not use the red history frame");
            }
            finally { Object.DestroyImmediate(image); }
            Assert.That(new Outbox(store).Next("p1").manifest, Is.Null);
            Assert.That(cam.BeginSnap(head, Now), Is.Null);
            Assert.That(cam.TrySnap(head, Now, Now), Is.False);
            var wave = WaveEncoder.Encode(new short[] { 1, 2 });
            var expected = (byte[])wave.Clone();
            Assert.That(pending.AttachNote(wave), Is.True);
            wave[0] = 0;
            Assert.That(pending.Publish(), Is.True);
            Assert.That(pending.Cancel(), Is.False);
            Assert.That(cam.TryShutdown(WaitMs), Is.True);
            var (published, manifest) = new Outbox(store).Next("p1");
            Assert.That(manifest.kind, Is.EqualTo("snap"));
            Assert.That(manifest.files, Is.EqualTo(new[] { ".jpg", ".json", ".wav" }.Select(ext => Session + "/" + pending.Id + ext)));
            Assert.That(File.ReadAllBytes(Path.Combine(published, pending.Id + ".wav")), Is.EqualTo(expected));
            Assert.That(JsonUtility.FromJson<SnapContext>(File.ReadAllText(Path.Combine(published, pending.Id + ".json"))).t, Is.EqualTo(Now));
        }

        [TestCase(9.125, 9.25, "onset", 125)]
        [TestCase(8.5, Now, "fresh", 1500)]
        [TestCase(11, Now, "fresh", -1000)]
        [TestCase(null, Now, "fresh", 0)]
        public void StagesAnchoredStillOrFallsBackToFresh(double? anchor, double frameTime, string source, double offsetMs)
        {
            head.backgroundColor = Color.green;
            cam.Tick(head, 9);
            head.backgroundColor = Color.red;
            cam.Tick(head, 9.25);
            head.backgroundColor = Color.blue;
            var pending = cam.BeginSnap(head, Now, "capture", anchor: anchor);
            Assert.That(pending, Is.Not.Null);
            var dir = Directory.GetDirectories(store.Outbox).Single();
            var image = new Texture2D(2, 2);
            try
            {
                Assert.That(image.LoadImage(File.ReadAllBytes(Path.Combine(dir, pending.Id + ".jpg"))), Is.True);
                var pixel = image.GetPixel(0, 0);
                Assert.That(source == "onset" ? pixel.r : pixel.b, Is.GreaterThan(0.8f));
            }
            finally { Object.DestroyImmediate(image); }
            var data = JsonUtility.FromJson<SnapContext>(File.ReadAllText(Path.Combine(dir, pending.Id + ".json")));
            Assert.That((data.t, data.triggerT, data.anchor, data.anchorOffsetMs), Is.EqualTo((frameTime, Now, source, offsetMs)));
        }

        [TestCase(9.125, 9.25, "onset", 125)]
        [TestCase(8.5, Now, "fresh", 1500)]
        [TestCase(null, Now, "fresh", 0)]
        public void OneShotPublishesAnchorMetadata(double? anchor, double frameTime, string source, double offsetMs)
        {
            cam.Tick(head, 9);
            cam.Tick(head, 9.25);
            Assert.That(cam.TrySnap(head, Now, anchor: anchor), Is.True);
            Assert.That(cam.TryShutdown(WaitMs), Is.True);
            var (dir, _) = new Outbox(store).Next("p1");
            var data = JsonUtility.FromJson<SnapContext>(File.ReadAllText(Directory.GetFiles(dir, "*.json").Single()));
            Assert.That((data.t, data.triggerT, data.anchor, data.anchorOffsetMs), Is.EqualTo((frameTime, Now, source, offsetMs)));
        }

        [Test]
        public void AnchorFallsBackToFreshWithNoHistory()
        {
            var pending = cam.BeginSnap(head, Now, anchor: Now - 1);
            Assert.That(pending, Is.Not.Null);
            var dir = Directory.GetDirectories(store.Outbox).Single();
            var data = JsonUtility.FromJson<SnapContext>(File.ReadAllText(Path.Combine(dir, pending.Id + ".json")));
            Assert.That((data.t, data.anchor, data.anchorOffsetMs), Is.EqualTo((Now, "fresh", 1000d)));
        }

        [Test]
        public void TimeoutPublishesWithoutAnUnsubmittedNote()
        {
            var pending = cam.BeginSnap(head, Now);
            Assert.That(pending.AttachNote(WaveEncoder.Encode(new short[] { 1 })), Is.True);
            cam.Tick(null, Now + Timeout - 0.1);
            Assert.That(new Outbox(store).Next("p1").manifest, Is.Null);
            cam.Tick(null, Now + Timeout);
            Assert.That(pending.Publish(), Is.False);
            Assert.That(cam.TryShutdown(WaitMs), Is.True);
            Assert.That(new Outbox(store).Next("p1").manifest.files.Length, Is.EqualTo(2));
        }

        [Test]
        public void CancelIsTerminalAndDoesNotRecover()
        {
            var pending = cam.BeginSnap(head, Now);
            Assert.That(pending.Cancel(), Is.True);
            Assert.That(pending.Publish(), Is.False);
            Assert.That(pending.AttachNote(WaveEncoder.Encode(new short[] { 1 })), Is.False);
            var outbox = new Outbox(store);
            outbox.Recover();
            Assert.That(outbox.Next("p1").manifest, Is.Null);
            Assert.That(Directory.GetDirectories(store.Outbox), Is.Empty);
            Assert.That(cam.BeginSnap(head, Now), Is.Not.Null);
        }

        [Test]
        public void RestartPublishesOrphanEvenWithPartiallyPublishedNote()
        {
            var pending = cam.BeginSnap(head, Now);
            var dir = Directory.GetDirectories(store.Outbox).Single();
            var wave = Path.Combine(dir, pending.Id + ".wav");
            File.WriteAllBytes(wave, WaveEncoder.Encode(new short[] { 1 }));
            File.WriteAllText(Path.Combine(dir, "snap.done.tmp"), "torn marker");
            var outbox = new Outbox(new FileChunkStore(temp.Path));
            Assert.That(outbox.Next("p1").manifest, Is.Null);
            outbox.Recover();
            outbox.Recover();
            var (published, manifest) = outbox.Next("p1");
            Assert.That(manifest.files, Is.EqualTo(new[] { ".jpg", ".json" }.Select(ext => Session + "/" + pending.Id + ext)));
            Assert.That(File.Exists(Path.Combine(published, pending.Id + ".wav")), Is.False);
            Assert.That(Directory.GetDirectories(store.Outbox), Is.EqualTo(new[] { published }));
        }

        [Test]
        public void LocalOnlyOrphanIsRecoveredWithoutAnUploader()
        {
            cam = new SnitchCam(frames, new Context(), new SnapDelivery(store), outcomes);
            var pending = cam.BeginSnap(head, Now);
            Assert.That(pending, Is.Not.Null);
            new FileChunkStore(temp.Path).RecoverChunks();
            var dir = Directory.GetDirectories(store.Outbox).Single();
            Assert.That(dir, Does.EndWith(".local"));
            Assert.That(File.Exists(Path.Combine(dir, pending.Id + ".jpg")), Is.True);
            Assert.That(File.Exists(Path.Combine(dir, pending.Id + ".json")), Is.True);
            Assert.That(new Outbox(store).Next("p1").manifest, Is.Null);
        }

        [Test]
        public void ShutdownDefersQuitUntilDeferredSnapIsPublished()
        {
            using var release = new ManualResetEventSlim();
            var pause = false;
            store = new FileChunkStore(temp.Path, long.MaxValue, null, _ =>
            {
                if (pause && !release.Wait(WaitMs * 2)) throw new IOException("Test publication timed out.");
            });
            cam = CreateCam(store);
            Assert.That(cam.BeginSnap(head, Now), Is.Not.Null);
            pause = true;
            try { Assert.That(cam.TryShutdown(0), Is.False); }
            finally { release.Set(); }
            Assert.That(cam.TryShutdown(WaitMs), Is.True);
            Assert.That(new Outbox(store).Next("p1").manifest.files.Length, Is.EqualTo(2));
        }

        sealed class Context : ISnapContextProvider
        {
            public SnapContext CaptureContext() => new() { session = Session, scene = "fixture" };
        }

        sealed class Settings : IUploadSettings
        {
            public string Endpoint => "https://example.invalid";
            public string PlayerTag => "p1";
            public string UploadKey => "synthetic-key";
            public bool Enabled => true;
        }
    }
}

using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

namespace YetiKit.Playtest.Tests
{
    [Category("Gfx")]
    public class SnitchFramesRenderTests
    {
        [Test]
        public void EncodesSelectedAppFrameAndRestoresGraphicsState()
        {
            var go = new GameObject("Test capture view");
            var head = go.AddComponent<Camera>();
            var original = RenderTexture.GetTemporary(32, 32);
            var active = RenderTexture.active;
            var decoded = new Texture2D(2, 2);
            var metrics = new Metrics();
            var frames = new SnitchFrames(metrics);
            try
            {
                head.enabled = false;
                head.clearFlags = CameraClearFlags.SolidColor;
                head.cullingMask = 0;
                head.targetTexture = original;
                RenderTexture.active = original;
                head.backgroundColor = Color.red;
                frames.Tick(head, 1);
                head.backgroundColor = Color.blue;
                frames.Tick(head, 1.1);
                frames.Tick(head, 1.25);
                Assert.That(metrics.Samples, Is.EqualTo(2));
                Assert.That(head.targetTexture, Is.SameAs(original));
                int previews = 0;
                var jpeg = frames.Capture(1.05, out var time, texture =>
                {
                    Assert.That(texture, Is.TypeOf<RenderTexture>());
                    Assert.That(RenderTexture.active, Is.SameAs(original));
                    previews++;
                });
                Assert.That(jpeg, Is.Not.Null);
                Assert.That(time, Is.EqualTo(1d));
                Assert.That(previews, Is.EqualTo(1));
                Assert.That(RenderTexture.active, Is.SameAs(original));
                Assert.That(jpeg[0], Is.EqualTo(0xff));
                Assert.That(jpeg[1], Is.EqualTo(0xd8));
                Assert.That(decoded.LoadImage(jpeg), Is.True);
                Assert.That(decoded.width, Is.EqualTo(SnitchFrames.Size));
                var color = decoded.GetPixel(decoded.width / 2, decoded.height / 2);
                Assert.That(color.r, Is.GreaterThan(0.8f));
                Assert.That(color.b, Is.LessThan(0.2f));
                Assert.That(frames.Encode(1.1, 75), Is.Null);
                Assert.That(decoded.LoadImage(frames.Encode(1.25, 75)), Is.True);
                Assert.That(decoded.GetPixel(decoded.width / 2, decoded.height / 2).b, Is.GreaterThan(0.8f));
                frames.Dispose();
                frames.Tick(head, 2);
                Assert.That(frames.Capture(2, out time, _ => Assert.Fail("Preview after disposal")), Is.Null);
                Assert.That(double.IsNaN(time), Is.True);
            }
            finally
            {
                frames.Dispose();
                RenderTexture.active = active;
                Object.DestroyImmediate(decoded);
                Object.DestroyImmediate(go);
                RenderTexture.ReleaseTemporary(original);
            }
        }

        [TestCase(false)]
        [TestCase(true)]
        public void ShutdownPublishesAllAvailableStripFrames(bool encodingStarted)
        {
            var go = new GameObject("Test capture view");
            try
            {
                var head = go.AddComponent<Camera>();
                head.enabled = false;
                head.clearFlags = CameraClearFlags.SolidColor;
                head.cullingMask = 0;
                using var frames = new SnitchFrames();
                var store = new Publication();
                var outcomes = new SnapOutcome();
                using var cam = new SnitchCam(frames, store, store, outcomes);
                cam.Tick(head, 6);
                cam.Tick(head, 7);
                cam.Tick(head, 10);
                Assert.That(cam.TrySnap(head, 10, 10), Is.True);
                if (encodingStarted)
                {
                    cam.Tick(head, 10.25);
                    cam.Tick(head, 13.25); // Window closes and one frame is encoded.
                }

                try
                {
                    Assert.That(cam.TryShutdown(0), Is.False, "Shutdown must not acknowledge an unpublished snap");
                    frames.Dispose(); // Shutdown has already finished using the frame history.
                    Assert.That(store.Batch.Task.Wait(5000), Is.True, "Snap did not reach the publication store");
                }
                finally { store.Release(); }
                Assert.That(cam.TryShutdown(5000), Is.True);
                Assert.That(outcomes.TryTake(out var result), Is.True);
                Assert.That(result.Status, Is.EqualTo(SnapStatus.Local));
                var (context, files) = store.Batch.Task.Result;
                var expected = encodingStarted ? new[] { 7d, 10d, 10.25d } : new[] { 7d, 10d };
                Assert.That(context.strip.Select(frame => frame.t), Is.EqualTo(expected));
                Assert.That(context.stripMain, Is.EqualTo(1));
                Assert.That(files.Keys, Is.EquivalentTo(new[] { context.snap + ".jpg", context.snap + ".json" }
                    .Concat(expected.Select((_, i) => context.snap + "-s0" + i + ".jpg"))));
                foreach (var frame in context.strip) Assert.That(files[frame.file], Is.Not.Empty);
            }
            finally { Object.DestroyImmediate(go); }
        }

        [Test]
        public void ShutdownDrainsPublicationAlreadyRunningWhenDisposed()
        {
            var go = new GameObject("Test capture view");
            var store = new Publication();
            try
            {
                var head = go.AddComponent<Camera>();
                head.enabled = false;
                head.clearFlags = CameraClearFlags.SolidColor;
                head.cullingMask = 0;
                using var frames = new SnitchFrames();
                var outcomes = new SnapOutcome();
                using var cam = new SnitchCam(frames, store, store, outcomes);
                cam.Tick(head, 10);
                Assert.That(cam.TrySnap(head, 10, 10), Is.True);
                cam.Tick(null, 14); // Window expired; the single history frame is enough to publish.
                try
                {
                    Assert.That(store.Batch.Task.Wait(5000), Is.True, "Expected an in-flight publication before disposal");
                    cam.Dispose();
                    Assert.That(cam.TryShutdown(0), Is.False);
                    Assert.That(outcomes.TryTake(out _), Is.False);
                }
                finally { store.Release(); }
                Assert.That(cam.TryShutdown(5000), Is.True);
                Assert.That(outcomes.TryTake(out var result), Is.True);
                Assert.That(result.Snap, Is.EqualTo(store.Batch.Task.Result.Item1.snap));
                Assert.That(result.Status, Is.EqualTo(SnapStatus.Local));
                Assert.That(cam.TryShutdown(0), Is.True);
                Assert.That(cam.TrySnap(head, 14, 14), Is.False);
            }
            finally { Object.DestroyImmediate(go); }
        }

        sealed class Publication : ISnapContextProvider, ISnapPublicationStore
        {
            public readonly TaskCompletionSource<(SnapContext, IReadOnlyDictionary<string, byte[]>)> Batch = new();
            readonly TaskCompletionSource<bool> released = new();
            public void Release() => released.TrySetResult(true);
            public SnapContext CaptureContext() => new() { session = "20260101-000000-0000" };
            public SnapStatus Publish(SnapContext context, IReadOnlyDictionary<string, byte[]> files)
            {
                Batch.SetResult((context, files));
                return released.Task.Wait(15000) ? SnapStatus.Local : SnapStatus.Failed;
            }
        }

        sealed class Metrics : IRecorderMetrics
        {
            public int Samples;
            public void NoteFrameRender(double milliseconds)
            {
                Assert.That(milliseconds, Is.GreaterThanOrEqualTo(0));
                Samples++;
            }
        }
    }
}

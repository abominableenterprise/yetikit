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
                Assert.That(frames.LastCaptureSource, Is.EqualTo("virtual-head"));
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

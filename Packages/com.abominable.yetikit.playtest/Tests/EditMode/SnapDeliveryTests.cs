using System.IO;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Playtest.Tests
{
    public sealed class SnapDeliveryTests
    {
        const string Session = "20260101-010101-0001", Snap = "snap-00000000000000000000000000000001";
        static readonly SnapContext Context = new() { session = Session, build = "b1", scene = "fixture", snap = Snap };
        static Dictionary<string, byte[]> Files() => new() { [Snap + ".jpg"] = new byte[] { 1 },
            [Snap + "-s00.jpg"] = new byte[] { 2 }, [Snap + ".wav"] = new byte[] { 3 }, [Snap + ".json"] = new byte[] { 4 } };

        sealed class Settings : IUploadSettings
        {
            public string Endpoint => "https://example.invalid";
            public string PlayerTag => "p1";
            public string UploadKey => "synthetic-key";
            public bool Enabled => true;
        }

        sealed class Sender : IHttpSender
        {
            public readonly List<HttpRequest> Requests = new();
            public Task<HttpResponse> SendAsync(HttpRequest request, CancellationToken cancellationToken)
            {
                if (request.Method == "PUT") Assert.That(File.Exists(request.FilePath));
                Requests.Add(request);
                return Task.FromResult(new HttpResponse(200));
            }
        }

        [Test]
        public async Task SnapUploadsCompleteFileSetWithoutWaitingForSessionEnd()
        {
            using var temp = new TempDir();
            var store = new FileChunkStore(temp.Path);
            store.CreateSession(Session);
            var settings = new Settings();
            var delivery = new SnapDelivery(store, settings);
            var files = Files();
            Assert.That(delivery.Publish(Context, files), Is.EqualTo(SnapStatus.Queued));
            Assert.That(delivery.Publish(Context, files), Is.EqualTo(SnapStatus.Failed), "first publication wins");
            var sender = new Sender();
            var outbox = new Outbox(store);
            outbox.Recover();
            double now = 0;
            var outcomes = new SnapOutcome();
            var uploader = new Uploader(outbox, settings, sender, 1, () => now) { SnapOutcomes = outcomes };
            for (; now < 5; now++) await uploader.TickAsync();
            var requests = sender.Requests;
            Assert.That(requests.Count, Is.EqualTo(5));
            var post = requests[4];
            Assert.That(post.Method, Is.EqualTo("POST"));
            Assert.That(post.Url, Is.EqualTo(settings.Endpoint + "/done"));
            var payload = JsonUtility.FromJson<DonePayload>(post.Body);
            Assert.That(payload.kind, Is.EqualTo("snap"));
            Assert.That(payload.player, Is.EqualTo("p1"));
            Assert.That(payload.session, Is.EqualTo(Session));
            Assert.That(payload.build, Is.EqualTo("b1"));
            Assert.That(post.Body, Does.Contain("\"scene\":\"fixture\""));
            Assert.That(post.Headers["Idempotency-Key"], Is.EqualTo(payload.id));
            var names = new[] { Snap + "-s00.jpg", Snap + ".jpg", Snap + ".json", Snap + ".wav" };
            var types = new[] { "image/jpeg", "image/jpeg", "application/json", "audio/wav" };
            for (int i = 0; i < names.Length; i++)
            {
                Assert.That(payload.files[i], Is.EqualTo(Session + "/" + names[i]));
                Assert.That(requests[i].Url, Is.EqualTo(settings.Endpoint + "/u/" + payload.files[i]));
                Assert.That(requests[i].Headers["Content-Type"], Is.EqualTo(types[i]));
            }
            Assert.That(outcomes.TryTake(out var result));
            Assert.That(result.Snap, Is.EqualTo(Snap));
            Assert.That(result.Status, Is.EqualTo(SnapStatus.Sent));
            Assert.That(Directory.GetDirectories(store.Outbox), Is.EqualTo(new[] { store.SessionOutbox(Session) }));
        }

        [Test]
        public void PartialAndLocalSnapsAreNotUploadable()
        {
            using var temp = new TempDir();
            var store = new FileChunkStore(temp.Path);
            var outbox = new Outbox(store);
            var files = Files();
            files.Remove(Snap + ".jpg");
            Assert.That(new SnapDelivery(store, new Settings()).Publish(Context, files), Is.EqualTo(SnapStatus.Failed));
            Assert.That(new SnapDelivery(store).Publish(Context, Files()), Is.EqualTo(SnapStatus.Local));
            var partial = Path.Combine(store.Outbox, Session + "." + Snap + ".partial.tmp");
            Directory.CreateDirectory(partial);
            File.WriteAllBytes(Path.Combine(partial, Snap + ".jpg"), new byte[] { 1 });
            Assert.That(outbox.Next("p1").manifest, Is.Null);
        }

        [Test]
        public async Task OutcomeLatchRetainsWorkerTransitionsUntilConsumed()
        {
            var outcomes = new SnapOutcome();
            await Task.Run(() =>
            {
                outcomes.Post((Session, Snap, SnapStatus.Queued));
                outcomes.Post((Session, Snap, SnapStatus.Sent));
            });
            Assert.That(outcomes.TryTake(out var queued));
            Assert.That(queued.Status, Is.EqualTo(SnapStatus.Queued));
            Assert.That(outcomes.TryTake(out var sent));
            Assert.That(sent.Status, Is.EqualTo(SnapStatus.Sent));
            Assert.That(outcomes.TryTake(out _), Is.False);
        }
    }
}

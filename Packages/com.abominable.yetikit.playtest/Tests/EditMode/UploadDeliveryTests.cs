using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace YetiKit.Playtest.Tests
{
    public sealed class UploadDeliveryTests
    {
        const string Id = "20260101-010101-0001";
        const string Chunk = "chunk-0001.jsonl.gz";
        const string Key = "synthetic-secret";
        sealed class Settings : IUploadSettings
        {
            public string Endpoint => "https://example.invalid";
            public string PlayerTag { get; set; } = "p1";
            public string UploadKey => Key;
            public bool Enabled { get; set; } = true;
        }

        sealed class Sender : IHttpSender
        {
            public readonly List<HttpRequest> Requests = new();
            public Func<Task<HttpResponse>> Respond = () => Task.FromResult(new HttpResponse(200));
            public Task<HttpResponse> SendAsync(HttpRequest request, CancellationToken cancellationToken)
            {
                Requests.Add(request);
                return Respond();
            }
        }

        static void Seed(FileChunkStore store, bool complete = true)
        {
            store.CreateSession(Id);
            var dir = store.SessionOutbox(Id);
            File.WriteAllText(Path.Combine(dir, "meta.json"), new SessionMeta { Session = Id, Build = "b1", Seconds = 33 }.ToJson(null));
            File.WriteAllBytes(Path.Combine(dir, Chunk), new byte[] { 1, 2 });
            if (complete) File.WriteAllText(Path.Combine(dir, DoneMarker.FileName), new DoneMarker { session = Id, build = "b1" }.ToJson());
        }

        [Test]
        public async Task RetriesThrottlesAndKeepsTheSameCompletionIdAcrossProcessRestart()
        {
            using var temp = new TempDir();
            var store = new FileChunkStore(temp.Path);
            Seed(store);
            var settings = new Settings();
            var sender = new Sender();
            double now = 0;
            var upload = new Uploader(new Outbox(store), settings, sender, 1, () => now);
            sender.Respond = () => throw new IOException(Key);
            await upload.TickAsync();
            now = 4.999;
            await upload.TickAsync();
            Assert.AreEqual(1, sender.Requests.Count);
            now = 5;
            sender.Respond = () => Task.FromResult(new HttpResponse(503, Key));
            await upload.TickAsync();
            now = 14.999;
            await upload.TickAsync();
            Assert.AreEqual(2, sender.Requests.Count);
            now = 15;
            sender.Respond = () => Task.FromResult(new HttpResponse(200));
            await upload.TickAsync();
            now = 15.9;
            await upload.TickAsync();
            Assert.AreEqual(3, sender.Requests.Count);
            now = 16;
            await upload.TickAsync();
            now = 17;
            sender.Respond = () => Task.FromResult(new HttpResponse(502));
            await upload.TickAsync();
            now = 21.999;
            await upload.TickAsync();
            Assert.AreEqual(5, sender.Requests.Count);
            now = 22;
            await upload.TickAsync();
            Assert.AreEqual(6, sender.Requests.Count);
            var post = sender.Requests[4];
            Assert.AreEqual("POST", post.Method);
            Assert.AreEqual(settings.Endpoint + "/done", post.Url);
            Assert.AreEqual(post.Body, sender.Requests[5].Body);
            Assert.AreEqual(post.Headers["Idempotency-Key"], sender.Requests[5].Headers["Idempotency-Key"]);
            Assert.IsTrue(Directory.Exists(store.SessionOutbox(Id)));

            store = new FileChunkStore(temp.Path);
            var recovered = new Outbox(store);
            recovered.Recover();
            sender = new Sender();
            upload = new Uploader(recovered, settings, sender, 1, () => now);
            for (var i = 0; i < 4; i++, now++) await upload.TickAsync();
            Assert.AreEqual(3, sender.Requests.Count);
            Assert.AreEqual(settings.Endpoint + "/u/" + Id + "/meta.json", sender.Requests[0].Url);
            Assert.AreEqual("application/json", sender.Requests[0].Headers["Content-Type"]);
            Assert.AreEqual("application/gzip", sender.Requests[1].Headers["Content-Type"]);
            Assert.AreEqual(post.Body, sender.Requests[2].Body);
            var manifest = JsonUtility.FromJson<DonePayload>(post.Body);
            Assert.AreEqual("session", manifest.kind);
            Assert.AreEqual("p1", manifest.player);
            Assert.AreEqual(post.Headers["Idempotency-Key"], manifest.id);
            CollectionAssert.AreEqual(new[] { Id + "/meta.json", Id + "/" + Chunk }, manifest.files);
            Assert.IsTrue(sender.Requests.TrueForAll(request => request.Headers["X-Upload-Key"] == Key));
            Assert.IsFalse(post.Body.Contains(Key));
            Assert.IsFalse(Directory.Exists(store.SessionOutbox(Id)));
            LogAssert.NoUnexpectedReceived();
        }

        [Test]
        public void OfflineRecoveryFinalizesAbandonedSessionAndHonorsBudget()
        {
            using var temp = new TempDir();
            var store = new FileChunkStore(temp.Path);
            Seed(store, complete: false);
            var outbox = new Outbox(store);
            Assert.IsNull(outbox.Next("p1").manifest);
            outbox.Recover();
            Assert.IsTrue(outbox.Next("p1").manifest.context.recovered);
            Assert.AreEqual("b1", outbox.Next("p1").manifest.build);
            new Outbox(new FileChunkStore(temp.Path, 0)).Recover();
            Assert.IsFalse(Directory.Exists(store.SessionOutbox(Id)));
        }

        [Test]
        public async Task AttachUploadsOnlyOnceRecordingHasFinalized()
        {
            using var temp = new TempDir();
            var store = new FileChunkStore(temp.Path);
            double now = 0;
            using var pump = new ChunkPump(store: store);
            var log = new FlightLog(() => now);
            var session = new RecordingSession(log, pump, store, new SessionMeta(Id), () => DateTime.UtcNow);
            var sender = new Sender();
            var upload = PlaytestUpload.Attach(session, new Settings(), sender, clock: () => now);
            Assert.IsTrue(session.Begin(0));
            await upload.TickAsync();
            Assert.IsEmpty(sender.Requests);
            now = 30;
            Assert.IsTrue(session.End(1));
            Assert.IsTrue(pump.Drain(2000));
            for (var i = 0; i < 4; i++, now++) await upload.TickAsync();
            Assert.AreEqual(3, sender.Requests.Count);
            Assert.AreEqual("POST", sender.Requests[2].Method);
        }

        [TestCase("../p")]
        [TestCase("p/q")]
        [TestCase("p%2Fq")]
        [TestCase(".p")]
        [TestCase("p\n")]
        [TestCase("pÉ")]
        public async Task RejectsUnsafePlayerBeforeNetwork(string player)
        {
            using var temp = new TempDir();
            var store = new FileChunkStore(temp.Path);
            Seed(store);
            var sender = new Sender();
            await new Uploader(new Outbox(store), new Settings { PlayerTag = player }, sender, 1, () => 0).TickAsync();
            Assert.IsEmpty(sender.Requests);
            Assert.IsTrue(UploadValidation.IsSegment(new string('a', 121)));
            Assert.IsFalse(UploadValidation.IsSegment(new string('a', 122)));
        }
    }
}

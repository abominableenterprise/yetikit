using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class UploadSeamTests
    {
        const string BaseUrl = "https://example.invalid";
        const string FixtureKey = "synthetic-test-key";

        [Test]
        public async Task MissingConfigDisablesNetwork()
        {
            using var dir = new TempDir();
            var settings = PlaytestJsonSettings.LoadPaths(new[] { Path.Combine(dir.Path, "missing") });
            var sender = new FakeSender();
            Assert.IsFalse(settings.Enabled);
            Assert.IsNull(settings.UploadKey);
            Assert.IsFalse(await NetWarmup.PingAsync(settings, sender));
            await new LiveTuningClient(settings, sender).RefreshAsync();
            Assert.IsEmpty(sender.Requests);
        }

        [Test]
        public void FirstReadableFileThenPairedEditorOverride()
        {
            using var dir = new TempDir();
            var primary = Path.Combine(dir.Path, "primary");
            var fallback = Path.Combine(dir.Path, "fallback");
            File.WriteAllText(fallback, "{\"endpoint\":\"" + BaseUrl + "/\",\"uploadKey\":\"" + FixtureKey + "\",\"player\":\"p1\"}");
            var paths = new[] { primary, fallback };
            var settings = PlaytestJsonSettings.LoadPaths(paths, name => name == PlaytestJsonSettings.EnvKey ? "unpaired" : null);
            Assert.IsTrue(settings.Enabled);
            Assert.AreEqual(BaseUrl, settings.Endpoint);
            Assert.AreEqual(FixtureKey, settings.UploadKey);
            settings = PlaytestJsonSettings.LoadPaths(paths, name => name == PlaytestJsonSettings.EnvEndpoint ? BaseUrl + "/dev/" :
                name == PlaytestJsonSettings.EnvKey ? "override" : "p2");
            Assert.AreEqual(BaseUrl + "/dev", settings.Endpoint);
            Assert.AreEqual("override", settings.UploadKey);
            Assert.AreEqual("p2", settings.PlayerTag);
            File.WriteAllText(primary, "{");
            Assert.IsFalse(PlaytestJsonSettings.LoadPaths(paths).Enabled);
            Assert.IsFalse(settings.ToString().Contains(settings.UploadKey));
        }

        [TestCase("http://example.invalid")]
        [TestCase("https://fixture@example.invalid")]
        [TestCase("https://example.invalid/?")]
        [TestCase("https://example.invalid/#")]
        public async Task RejectsUnsafeEndpointEvenWithEnabledCustomSettings(string endpoint)
        {
            var settings = new Settings { Endpoint = endpoint };
            var sender = new FakeSender();
            Assert.IsFalse(UploadValidation.TryGetEndpoint(settings, out _));
            Assert.IsFalse(await NetWarmup.PingAsync(settings, sender));
            await new LiveTuningClient(settings, sender).RefreshAsync();
            Assert.IsEmpty(sender.Requests);
        }

        [Test]
        public async Task WarmupIsAnonymousAndIgnoresTransportErrors()
        {
            var sender = new FakeSender(new HttpResponse(204));
            var settings = new Settings { Endpoint = "http://127.0.0.1:8080/base/" };
            Assert.IsTrue(await NetWarmup.PingAsync(settings, sender));
            Assert.AreEqual("http://127.0.0.1:8080/base/ping", sender.Requests[0].Url);
            Assert.AreEqual("GET", sender.Requests[0].Method);
            Assert.IsEmpty(sender.Requests[0].Headers);
            settings.UploadKey = null;
            Assert.IsFalse(UploadValidation.TryGetEndpoint(settings, out _));
            Assert.IsFalse(await NetWarmup.PingAsync(settings, sender));
        }

        [Test]
        public async Task RevalidationKeepsOn304AndClearsOn404()
        {
            var sender = new FakeSender(new HttpResponse(200, "{}", "\"v1\""), new HttpResponse(304),
                new HttpResponse(503), new HttpResponse(404), new HttpResponse(200, "[]", "\"v2\""));
            var client = new LiveTuningClient(new Settings(), sender, TimeSpan.FromSeconds(7));
            var changes = new List<string>();
            client.Changed += changes.Add;
            for (var i = 0; i < 5; ++i) await client.RefreshAsync();
            Assert.AreEqual(TimeSpan.FromSeconds(7), client.PollInterval);
            Assert.AreEqual(BaseUrl + "/t/p1", sender.Requests[0].Url);
            Assert.IsTrue(sender.Requests.TrueForAll(request => request.Headers["X-Upload-Key"] == FixtureKey));
            Assert.IsFalse(sender.Requests[0].Headers.ContainsKey("If-None-Match"));
            for (var i = 1; i <= 3; ++i) Assert.AreEqual("\"v1\"", sender.Requests[i].Headers["If-None-Match"]);
            Assert.IsFalse(sender.Requests[4].Headers.ContainsKey("If-None-Match"));
            CollectionAssert.AreEqual(new[] { "{}", null, "[]" }, changes);
            Assert.AreEqual("[]", client.CurrentJson);
        }

        [Test]
        public async Task ChangingPlayerDropsCacheAndRejectsInvalidSegments()
        {
            var settings = new Settings();
            var sender = new FakeSender(new HttpResponse(200, "{}", "\"v1\""), new HttpResponse(404));
            var client = new LiveTuningClient(settings, sender);
            await client.RefreshAsync();
            settings.PlayerTag = "p2";
            await client.RefreshAsync();
            Assert.AreEqual(BaseUrl + "/t/p2", sender.Requests[1].Url);
            Assert.IsFalse(sender.Requests[1].Headers.ContainsKey("If-None-Match"));
            Assert.IsNull(client.CurrentJson);
            settings.PlayerTag = "../p1";
            await client.RefreshAsync();
            Assert.AreEqual(2, sender.Requests.Count);
            Assert.IsFalse(UploadValidation.IsSegment("p1\n"));
        }

        [Test]
        public void CancellationPreventsSendsAndDtosDoNotPrintSecrets()
        {
            var sender = new FakeSender();
            var settings = new Settings();
            var token = new CancellationToken(true);
            Assert.CatchAsync<OperationCanceledException>(() => NetWarmup.PingAsync(settings, sender, token));
            Assert.CatchAsync<OperationCanceledException>(() => new LiveTuningClient(settings, sender).PollAsync(token));
            Assert.IsEmpty(sender.Requests);
            var request = new HttpRequest("POST", BaseUrl + "/done") { Body = FixtureKey };
            request.Headers["X-Upload-Key"] = FixtureKey;
            Assert.IsFalse(request.ToString().Contains(FixtureKey));
            Assert.IsFalse(new HttpResponse(200, FixtureKey, FixtureKey).ToString().Contains(FixtureKey));
        }

        sealed class Settings : IUploadSettings
        {
            public string Endpoint { get; set; } = BaseUrl;
            public string UploadKey { get; set; } = FixtureKey;
            public string PlayerTag { get; set; } = "p1";
            public bool Enabled => true;
        }

        sealed class FakeSender : IHttpSender
        {
            readonly Queue<HttpResponse> responses;
            public readonly List<HttpRequest> Requests = new();
            public FakeSender(params HttpResponse[] responses) => this.responses = new(responses);
            public Task<HttpResponse> SendAsync(HttpRequest request, CancellationToken cancellationToken)
            {
                Requests.Add(request);
                if (responses.Count == 0) throw new InvalidOperationException(FixtureKey);
                return Task.FromResult(responses.Dequeue());
            }
        }
    }
}

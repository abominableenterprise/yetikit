using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class PlaytestEnrollmentTests
    {
        const string Nonce = "0123456789abcdef0123456789abcdef";
        const string Config = "{\n \"endpoint\": \"https://example.invalid\", \"uploadKey\": \"synthetic\", \"player\": \"test-device\"\n}\n";
        const string Existing = "previous config";
        static readonly TimeSpan Timeout = TimeSpan.FromSeconds(3);

        [TestCase(false)]
        [TestCase(true)]
        public async Task SendsExactHandshakeAndPublishesExactBytes(bool replace)
        {
            using var dir = new TempDir();
            using var host = new Host();
            var path = Path.Combine(dir.Path, "playtest.json");
            if (replace) File.WriteAllText(path, Existing);
            var payload = Encoding.UTF8.GetBytes(Config.PadRight(16 * 1024));
            var response = host.ReplyAsync(payload);
            Assert.IsTrue(PlaytestEnrollment.TryInstall(host.Port, Nonce, path, Timeout));
            CollectionAssert.AreEqual(Encoding.ASCII.GetBytes(Nonce + "\n"), await response);
            CollectionAssert.AreEqual(payload, File.ReadAllBytes(path));
            Assert.That(Directory.GetFileSystemEntries(dir.Path), Is.EqualTo(new[] { path }));
        }

        [TestCase("")]
        [TestCase("{\"endpoint\":")]
        [TestCase("{\"endpoint\":\"http://127.0.0.1\",\"uploadKey\":\"synthetic\",\"player\":\"test-device\"}")]
        [TestCase("{\"endpoint\":\"https://example.invalid\",\"uploadKey\":\"synthetic\",\"player\":\"../invalid\"}")]
        [TestCase("{\"endpoint\":\"https://example.invalid\",\"player\":\"test-device\"}")]
        public async Task RejectedPayloadPreservesInstalledFile(string json)
        {
            await RejectAndPreserve(Encoding.UTF8.GetBytes(json));
        }

        [Test]
        public async Task OversizePayloadPreservesInstalledFile()
        {
            await RejectAndPreserve(Encoding.UTF8.GetBytes(Config.PadRight(16 * 1024 + 1)));
        }

        static async Task RejectAndPreserve(byte[] payload)
        {
            using var dir = new TempDir();
            using var host = new Host();
            var path = Path.Combine(dir.Path, "playtest.json");
            File.WriteAllText(path, Existing);
            var response = host.ReplyAsync(payload);
            Assert.IsFalse(PlaytestEnrollment.TryInstall(host.Port, Nonce, path, Timeout));
            await response;
            Assert.AreEqual(Existing, File.ReadAllText(path));
            Assert.That(Directory.GetFileSystemEntries(dir.Path), Is.EqualTo(new[] { path }));
        }

        [TestCase(null)]
        [TestCase("")]
        [TestCase("0123456789ABCDEF0123456789ABCDEF")]
        [TestCase("0123456789abcdef0123456789abcdef\n")]
        public void MalformedNonceNeverConnects(string nonce)
        {
            using var dir = new TempDir();
            using var host = new Host();
            Assert.IsFalse(PlaytestEnrollment.TryInstall(host.Port, nonce, Path.Combine(dir.Path, "playtest.json"), Timeout));
            Assert.IsFalse(host.Listener.Pending());
            Assert.IsEmpty(Directory.GetFileSystemEntries(dir.Path));
        }

        [Test]
        public async Task NoEofBeforeDeadlineLeavesFileUntouched()
        {
            using var dir = new TempDir();
            using var host = new Host();
            var path = Path.Combine(dir.Path, "playtest.json");
            File.WriteAllText(path, Existing);
            var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var response = host.ReplyAsync(Encoding.UTF8.GetBytes(Config), release.Task);
            var watch = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                Assert.IsFalse(PlaytestEnrollment.TryInstall(host.Port, Nonce, path, TimeSpan.FromMilliseconds(400)));
                Assert.That(watch.Elapsed, Is.LessThan(TimeSpan.FromSeconds(3)));
                Assert.AreEqual(Existing, File.ReadAllText(path));
            }
            finally { release.SetResult(true); }
            await response;
        }

        sealed class Host : IDisposable
        {
            public readonly TcpListener Listener = new(IPAddress.Loopback, 0);
            public Host() => Listener.Start();
            public int Port => ((IPEndPoint)Listener.LocalEndpoint).Port;

            public Task<byte[]> ReplyAsync(byte[] payload, Task release = null) => Task.Run(async () =>
            {
                using var peer = await Listener.AcceptTcpClientAsync().ConfigureAwait(false);
                using var stream = peer.GetStream();
                stream.ReadTimeout = (int)Timeout.TotalMilliseconds;
                var handshake = new byte[33];
                for (var offset = 0; offset < handshake.Length;)
                {
                    var size = stream.Read(handshake, offset, handshake.Length - offset);
                    if (size == 0) throw new EndOfStreamException();
                    offset += size;
                }
                stream.Write(payload, 0, payload.Length);
                if (release != null) await release.ConfigureAwait(false);
                return handshake;
            });

            public void Dispose() => Listener.Stop();
        }
    }
}

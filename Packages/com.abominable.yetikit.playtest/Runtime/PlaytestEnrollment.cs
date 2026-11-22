using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace YetiKit.Playtest
{
    internal static class PlaytestEnrollment
    {
        const int MaxConfigBytes = 16 * 1024;
        static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);

        internal static bool TryInstall(int port, string nonce, string path, TimeSpan timeout)
        {
            if (port <= 0 || port > ushort.MaxValue || !IsNonce(nonce) || timeout <= TimeSpan.Zero) return false;
            try
            {
                var payload = Receive(port, nonce, timeout);
                if (payload == null || !PlaytestJsonSettings.IsEnrollmentConfig(StrictUtf8.GetString(payload))) return false;
                Publish(path, payload);
                return true;
            }
            catch (Exception e) when (e is IOException || e is SocketException || e is TimeoutException ||
                e is UnauthorizedAccessException || e is ArgumentException || e is NotSupportedException)
            {
                return false;
            }
        }

        static bool IsNonce(string nonce)
        {
            if (nonce?.Length != 32) return false;
            foreach (var c in nonce)
                if (!(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')) return false;
            return true;
        }

        static byte[] Receive(int port, string nonce, TimeSpan timeout)
        {
            var elapsed = Stopwatch.StartNew();
            using var client = new TcpClient(AddressFamily.InterNetwork);
            var connection = Connect(client, port);
            if (!connection.Wait(Remaining(elapsed, timeout)) || !connection.Result) return null;
            using var stream = client.GetStream();
            var handshake = Encoding.ASCII.GetBytes(nonce + "\n");
            stream.WriteTimeout = Remaining(elapsed, timeout);
            stream.Write(handshake, 0, handshake.Length);

            // The extra byte distinguishes an exact-limit payload followed by EOF from oversize input.
            var bytes = new byte[MaxConfigBytes + 1];
            var length = 0;
            while (length < bytes.Length)
            {
                stream.ReadTimeout = Remaining(elapsed, timeout);
                var count = stream.Read(bytes, length, bytes.Length - length);
                if (count == 0) return length == 0 ? null : new ArraySegment<byte>(bytes, 0, length).ToArray();
                length += count;
            }
            return null;
        }

        // Catch connection failure here even if the startup thread already timed out and closed the client.
        static async Task<bool> Connect(TcpClient client, int port)
        {
            try
            {
                await client.ConnectAsync(IPAddress.Loopback, port).ConfigureAwait(false);
                return true;
            }
            catch (SocketException) { return false; }
            catch (ObjectDisposedException) { return false; }
        }

        static int Remaining(Stopwatch elapsed, TimeSpan timeout)
        {
            var milliseconds = (timeout - elapsed.Elapsed).TotalMilliseconds;
            if (milliseconds <= 0) throw new TimeoutException();
            return (int)Math.Min(int.MaxValue, Math.Ceiling(milliseconds));
        }

        static void Publish(string path, byte[] payload)
        {
            var directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            var temporary = Path.Combine(directory, ".playtest-enroll-" + Guid.NewGuid().ToString("N"));
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    file.Write(payload, 0, payload.Length);
                    file.Flush(flushToDisk: true);
                }
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally
            {
                try { File.Delete(temporary); }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { }
            }
        }
    }
}

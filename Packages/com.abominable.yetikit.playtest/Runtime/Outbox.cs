using System;
using System.IO;
using System.Linq;
using System.Text;
using UnityEngine;
using static YetiKit.Playtest.FileChunkStore;

namespace YetiKit.Playtest
{
    // A published done marker commits an immutable batch.
    internal sealed class Outbox
    {
        const string Delivered = ".delivered", Rejected = ".rejected";
        readonly FileChunkStore store;

        internal Outbox(FileChunkStore store) => this.store = store;

        // Startup only, before the recording pump starts using this root. No network required.
        internal void Recover()
        {
            store.RecoverChunks();
            foreach (var dir in Directories())
            {
                var id = Path.GetFileName(dir);
#if UNITY_EDITOR || YETIKIT_DEV
                if (SnapDelivery.IsStaging(id) || (id.EndsWith(Delivered, StringComparison.Ordinal) &&
                    SnapDelivery.Split(id[..^Delivered.Length], out _, out _))) { DeleteDelivered(dir); continue; }
#endif
                if (id.EndsWith(Delivered, StringComparison.Ordinal) && SessionRules.IsId(id[..^Delivered.Length]))
                    DeleteDelivered(dir);
                else if (SessionRules.IsId(id)) RecoverMarker(dir, id);
            }
            store.PrunePending();
        }

        internal (string dir, DonePayload manifest) Next(string player)
        {
            foreach (var dir in Directories().OrderBy(path => path, StringComparer.Ordinal))
            {
                var id = Path.GetFileName(dir);
#if UNITY_EDITOR || YETIKIT_DEV
                if (!File.Exists(Path.Combine(dir, Rejected)) && SnapDelivery.Read(dir) is { } snap) return (dir, snap);
#endif
                var markerPath = Path.Combine(dir, DoneMarker.FileName);
                if (!SessionRules.IsId(id) || !File.Exists(markerPath) || IsLink(markerPath)) continue;
                var marker = DoneMarker.Parse(File.ReadAllText(markerPath));
                if (marker?.session != id) continue;
                var names = Names(dir);
                if (names.Contains(Rejected) || names.Any(IsPending)) continue;
                var files = names.Where(name => name == MetaFile || ChunkIndex(name) > 0)
                    .OrderBy(ChunkIndex).ThenBy(name => name, StringComparer.Ordinal).ToArray();
                if (files.Length == 0 || files[0] != MetaFile ||
                    files.Any(name => !UploadValidation.IsSegment(name) || IsLink(Path.Combine(dir, name))) ||
                    !CanRecover(Path.Combine(dir, MetaFile))) continue;
                return (dir, DonePayload.Session(marker, player, files));
            }
            return default;
        }

        // Marker existence is enough; keep the original files and ID for inspection or manual retry.
        internal void Reject(string dir) { using var marker = new FileStream(Path.Combine(dir, Rejected), FileMode.CreateNew); }

        internal void Complete(string dir)
        {
            // Take the whole batch out of the queue before recursive deletion, even if cleanup is interrupted.
            Directory.Move(dir, dir + Delivered);
            DeleteDelivered(dir + Delivered);
        }

        System.Collections.Generic.IEnumerable<string> Directories() => !Directory.Exists(store.Outbox) || IsLink(store.Outbox)
            ? Array.Empty<string>() : Directory.EnumerateDirectories(store.Outbox).Where(dir => !IsLink(dir));

        static string[] Names(string dir) => Directory.GetFiles(dir).Select(Path.GetFileName).ToArray();

        void DeleteDelivered(string dir)
        {
            try { store.DeleteDir(dir); }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { /* Retry on startup. */ }
        }

        [Serializable] sealed class Checkpoint
        {
            public string session, player, build;
            public float seconds;
            public int events;
        }

        void RecoverMarker(string dir, string id)
        {
            var marker = Path.Combine(dir, DoneMarker.FileName);
            var meta = Path.Combine(dir, MetaFile);
            if (File.Exists(marker) || !File.Exists(meta) || IsLink(meta) || !CanRecover(meta)) return;
            var names = Names(dir);
            if (names.Any(IsPending)) return;
            var data = JsonUtility.FromJson<Checkpoint>(File.ReadAllText(meta));
            if (data?.session != id || !(names.Any(name => ChunkIndex(name) > 0) || SessionRules.Keep(data.seconds, data.events))) return;
            var done = new DoneMarker { session = id, player = data.player, build = data.build,
                context = new DoneContext { recovered = true, minutes = data.seconds / 60 } };
            store.PublishFinalFile(marker, Encoding.UTF8.GetBytes(done.ToJson()));
        }

        static bool IsPending(string name) => name.EndsWith(TmpSuffix, StringComparison.Ordinal) ||
            name.EndsWith(ChunkJournal.Suffix, StringComparison.Ordinal) ||
            name.EndsWith(ChunkJournal.Suffix + JournalRollback.Suffix, StringComparison.Ordinal);
    }
}

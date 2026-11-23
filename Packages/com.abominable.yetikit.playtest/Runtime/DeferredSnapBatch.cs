#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEngine;
using static YetiKit.Playtest.FileChunkStore;

namespace YetiKit.Playtest
{
    // The directory name is the commit boundary. A .pending batch is never uploaded,
    // even if a crash occurred after writing its final manifest but before renaming it.
    internal sealed class DeferredSnapBatch
    {
        const string PendingSuffix = ".pending";
        const string DiscardedSuffix = ".delivered";
        readonly FileChunkStore store;
        internal SnapContext Context { get; }
        readonly string player, dir, batchName;
        readonly string jpeg, json, wav;

        DeferredSnapBatch(FileChunkStore store, SnapContext context, string player)
        {
            (this.store, Context, this.player) = (store, context, player);
            batchName = context.session + "." + context.snap;
            dir = Path.Combine(store.Outbox, batchName + PendingSuffix);
            (jpeg, json, wav) = (context.snap + ".jpg", context.snap + ".json", context.snap + ".wav");
        }

        internal static DeferredSnapBatch Stage(FileChunkStore store, SnapContext context, string player, byte[] photo)
        {
            if (!SnapDelivery.ValidContext(context) || !SnapDelivery.ValidBytes(photo)) return null;
            var batch = new DeferredSnapBatch(store, context, player);
            var stage = Path.Combine(store.Outbox, batch.batchName + TmpSuffix);
            try
            {
                var outbox = Path.GetFullPath(store.Outbox);
                Directory.CreateDirectory(outbox);
                if (IsLink(outbox) || Directory.Exists(stage) || Directory.Exists(batch.dir)) return null;
                // Flush the parent too: this can be the first batch in a new outbox.
                DirectoryDurability.Sync(Path.GetDirectoryName(outbox));
                Directory.CreateDirectory(stage);
                store.PublishFinalFile(Path.Combine(stage, batch.jpeg), photo);
                store.PublishFinalFile(Path.Combine(stage, batch.json), Encoding.UTF8.GetBytes(JsonUtility.ToJson(context)));
                SnapDelivery.WriteMarker(store, stage, context, player, new[] { batch.jpeg, batch.json });
                batch.Move(stage, batch.dir);
                return batch;
            }
            catch (Exception error) when (IsStorageError(error)) { return null; }
        }

        internal SnapStatus Publish(byte[] note, double trimLeadMs = 0, double trimTailMs = 0)
        {
            var context = Context;
            (context.noteTrimLeadMs, context.noteTrimTailMs) = note == null ? (0d, 0d) : (trimLeadMs, trimTailMs);
            try
            {
                var names = new List<string> { jpeg, json };
                var wavePath = Path.Combine(dir, wav);
                if (note != null)
                {
                    store.PublishFinalFile(wavePath, note);
                    names.Add(wav);
                }
                else File.Delete(wavePath);
                File.Delete(wavePath + TmpSuffix);
                // Rewrite while still pending so recovery can also clear trim metadata from an interrupted note.
                store.PublishFinalFile(Path.Combine(dir, json), Encoding.UTF8.GetBytes(JsonUtility.ToJson(context)));
                SnapDelivery.WriteMarker(store, dir, context, player, names);
                var queued = UploadValidation.IsSegment(player);
                Move(dir, Path.Combine(store.Outbox, batchName + (queued ? "" : ".local")));
                return queued ? SnapStatus.Queued : SnapStatus.Local;
            }
            catch (Exception error) when (IsStorageError(error)) { return SnapStatus.Failed; }
        }

        internal bool Cancel()
        {
            var discarded = Path.Combine(store.Outbox, batchName + DiscardedSuffix);
            try
            {
                if (Directory.Exists(dir)) Directory.Move(dir, discarded);
                SyncOutbox();
            }
            catch (Exception error) when (IsStorageError(error)) { return false; }
            try { store.DeleteDir(discarded); }
            catch (Exception error) when (IsStorageError(error)) { /* The tombstone is inert and can be cleaned up on startup. */ }
            return true;
        }

        // Startup only. Do not turn interrupted note writes into attachments.
        internal static void Recover(FileChunkStore store, string path)
        {
            var name = Path.GetFileName(path);
            if (!name.EndsWith(PendingSuffix, StringComparison.Ordinal) ||
                !SnapDelivery.Split(name[..^PendingSuffix.Length], out var session, out var stem)) return;
            try
            {
                if (IsLink(path) || Directory.GetFileSystemEntries(path).Any(IsLink)) return;
                var marker = Path.Combine(path, SnapDelivery.Marker);
                var data = JsonUtility.FromJson<SnapDelivery.Manifest>(File.ReadAllText(marker));
                if (data?.kind != "snap" || data.session != session || data.id != stem + "-" + session ||
                    data.context.session != session || data.context.snap != stem) return;
                var batch = new DeferredSnapBatch(store, data.context, data.player);
                if (!File.Exists(Path.Combine(path, batch.jpeg)) || !File.Exists(Path.Combine(path, batch.json))) return;
                batch.Publish(null);
            }
            catch (Exception error) when (IsStorageError(error) || error is ArgumentException) { /* Preserve for inspection or retry. */ }
        }

        void Move(string from, string to)
        {
            Directory.Move(from, to);
            SyncOutbox();
        }
        void SyncOutbox() => DirectoryDurability.Sync(Path.GetFullPath(store.Outbox));
        static bool IsStorageError(Exception error) => error is IOException || error is UnauthorizedAccessException;
    }
}
#endif

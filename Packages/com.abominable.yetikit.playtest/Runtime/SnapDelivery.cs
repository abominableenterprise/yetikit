#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using UnityEngine;
using static YetiKit.Playtest.FileChunkStore;
namespace YetiKit.Playtest
{
    public interface ISnapPublicationStore { SnapStatus Publish(SnapContext context, IReadOnlyDictionary<string, byte[]> files); }
    /// <summary>Each snap is a separate immutable outbox batch, even if its session has been delivered.</summary>
    public sealed class SnapDelivery : ISnapPublicationStore
    {
        const string Marker = "snap.done";
        static readonly Regex Stem = new(@"\Asnap-[a-f0-9]{32}\z"), Suffix = new(@"\A(?:-s[0-9]{2}\.jpg|\.(?:jpg|wav|json))\z");
        readonly FileChunkStore store;
        readonly IUploadSettings upload;
        public SnapDelivery(FileChunkStore store, IUploadSettings upload = null) => (this.store, this.upload) = (store, upload);
        static bool Valid(string stem, IEnumerable<string> names) => names.Contains(stem + ".jpg") &&
            names.All(n => n.StartsWith(stem, StringComparison.Ordinal) && Suffix.IsMatch(n.Substring(stem.Length)));
        static string[] Paths(string session, IEnumerable<string> names) => names.OrderBy(n => n, StringComparer.Ordinal).Select(n => session + "/" + n).ToArray();
        public SnapStatus Publish(SnapContext context, IReadOnlyDictionary<string, byte[]> files)
        {
            var stem = context.snap;
            if (!SessionRules.IsId(context.session) || !Stem.IsMatch(stem ?? "") || !Valid(stem, files.Keys) ||
                files.Values.Any(b => b == null || b.Length is 0 or > 50 * 1024 * 1024)) return SnapStatus.Failed;
            var player = UploadValidation.TryGetEndpoint(upload, out _) ? upload.PlayerTag : null;
            var queued = UploadValidation.IsSegment(player);
            var dir = Path.Combine(store.Outbox, context.session + "." + stem + (queued ? "" : ".local"));
            var stage = dir + "." + Guid.NewGuid().ToString("N") + TmpSuffix;
            Directory.CreateDirectory(store.Outbox);
            if (IsLink(store.Outbox)) return SnapStatus.Failed;
            Directory.CreateDirectory(stage);
            try
            {
                foreach (var file in files) store.PublishFinalFile(Path.Combine(stage, file.Key), file.Value);
                var marker = new Manifest { id = stem + "-" + context.session, session = context.session, build = context.build,
                    player = player, files = Paths(context.session, files.Keys), context = context };
                store.PublishFinalFile(Path.Combine(stage, Marker), Encoding.UTF8.GetBytes(JsonUtility.ToJson(marker)));
                Directory.Move(stage, dir);
                DirectoryDurability.Sync(Path.GetFullPath(store.Outbox));
                return queued ? SnapStatus.Queued : SnapStatus.Local;
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { return SnapStatus.Failed; }
            finally { try { store.DeleteDir(stage); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
        }
        [Serializable] sealed class Manifest { public string id, kind = "snap", session, player, build; public string[] files; public SnapContext context; }
        internal static bool Split(string name, out string session, out string stem)
        {
            var parts = Path.GetFileName(name).Split('.');
            (session, stem) = parts.Length == 2 ? (parts[0], parts[1]) : (null, null);
            return session != null && SessionRules.IsId(session) && Stem.IsMatch(stem);
        }
        internal static DonePayload Read(string dir, string session, string stem)
        {
            var marker = Path.Combine(dir, Marker);
            if (!File.Exists(marker) || IsLink(marker)) return null;
            var json = File.ReadAllText(marker);
            DonePayload result;
            try { result = JsonUtility.FromJson<DonePayload>(json); } catch (ArgumentException) { return null; }
            var names = Directory.GetFiles(dir).Where(p => p != marker && !IsLink(p)).Select(Path.GetFileName).ToArray();
            if (result?.kind != "snap" || result.session != session || result.id != stem + "-" + session ||
                !UploadValidation.IsSegment(result.player) || !Valid(stem, names) || result.files == null ||
                !result.files.SequenceEqual(Paths(session, names))) return null;
            result.snapJson = json;
            return result;
        }
    }
}
#endif

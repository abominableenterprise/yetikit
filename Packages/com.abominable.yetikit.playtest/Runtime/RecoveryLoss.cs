using System.IO;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Xml;

namespace YetiKit.Playtest
{
    internal static class RecoveryLoss
    {
        // Persist the journal index with the count so a kill between metadata publication and journal deletion
        // doesn't count the same tail twice. Recovery walks journals in index order and stops on IO failure.
        internal static void Record(FileChunkStore store, string dir, int index)
        {
            var path = Path.Combine(dir, FileChunkStore.MetaFile);
            var source = File.Exists(path) ? path : path + FileChunkStore.TmpSuffix;
            var doc = new XmlDocument();
            using (var json = JsonReaderWriterFactory.CreateJsonReader(File.Exists(source) ? File.ReadAllBytes(source) :
                Encoding.UTF8.GetBytes(new SessionMeta(Path.GetFileName(dir)).ToJson(null)), XmlDictionaryReaderQuotas.Max))
                doc.Load(json);
            var root = doc.DocumentElement;
            var lost = root["lost"];
            if (lost?.GetAttribute("type") != "object")
            {
                if (lost != null) root.RemoveChild(lost);
                lost = doc.CreateElement("lost");
                lost.SetAttribute("type", "object");
                root.AppendChild(lost);
                Add(lost, "count", "0", "number");
                Add(lost, "first", "", "null");
                Add(lost, "last", "", "null");
            }
            if (int.TryParse(lost["recoveredThrough"]?.InnerText, out var through) && through >= index) return;
            long.TryParse(lost["torn"]?.InnerText, out var torn);
            Add(lost, "torn", XmlConvert.ToString(torn + 1), "number");
            Add(lost, "recoveredThrough", XmlConvert.ToString(index), "number");
            using (var output = new MemoryStream())
            {
                using (var json = JsonReaderWriterFactory.CreateJsonWriter(output, Encoding.UTF8, false)) doc.WriteContentTo(json);
                store.PublishFile(path, output.ToArray());
            }
        }

        static void Add(XmlElement parent, string key, string value, string type)
        {
            var field = parent[key] ?? (XmlElement)parent.AppendChild(parent.OwnerDocument.CreateElement(key));
            field.SetAttribute("type", type);
            field.InnerText = value;
        }
    }
}

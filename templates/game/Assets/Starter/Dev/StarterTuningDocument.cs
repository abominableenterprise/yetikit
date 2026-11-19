using System;
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Game.Dev
{
    // The starter's pinned Lab treats rejected documents as live-only, but does not expose that state.
    // Mirror its v1 read checks here; Tuning still owns loading values, saving and reset.
    static class StarterTuningDocument
    {
        internal static bool CanPersist(string experimentId)
        {
            var key = "YetiKit.Lab.Tuning." + experimentId;
            if (!PlayerPrefs.HasKey(key)) return true;
            var body = PlayerPrefs.GetString(key);
            if (string.IsNullOrWhiteSpace(body)) return false;
            try
            {
                using var reader = new JsonTextReader(new StringReader(body)) { DateParseHandling = DateParseHandling.None };
                var doc = JObject.Load(reader);
                if (reader.Read() || !JToken.DeepEquals(doc["v"], new JValue(1)) || !(doc["values"] is JArray entries)) return false;
                var ids = new HashSet<string>(StringComparer.Ordinal);
                foreach (var entry in entries)
                {
                    if (!(entry is JObject row) || row["id"]?.Type != JTokenType.String) return false;
                    var id = (string)row["id"];
                    var number = row["value"];
                    if (string.IsNullOrWhiteSpace(id) || !ids.Add(id) ||
                        (number?.Type != JTokenType.Integer && number?.Type != JTokenType.Float)) return false;
                    var value = (float)number;
                    if (float.IsNaN(value) || float.IsInfinity(value)) return false;
                }
                return true;
            }
            catch (JsonException) { return false; }
        }
    }
}

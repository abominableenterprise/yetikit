using UnityEngine;

namespace YetiKit.Lab
{
    public interface ITuningStore
    {
        /// <summary>Returns the stored document, or null when no document exists.</summary>
        string Load(string experimentId);
        void Save(string experimentId, string body);
    }

    internal sealed class PlayerPrefsTuningStore : ITuningStore
    {
        private static string Key(string id) => "YetiKit.Lab.Tuning." + id;
        public string Load(string experimentId)
        {
            var key = Key(experimentId);
            return PlayerPrefs.HasKey(key) ? PlayerPrefs.GetString(key) : null;
        }
        public void Save(string experimentId, string body)
        {
            PlayerPrefs.SetString(Key(experimentId), body);
            PlayerPrefs.Save();
        }
    }
}

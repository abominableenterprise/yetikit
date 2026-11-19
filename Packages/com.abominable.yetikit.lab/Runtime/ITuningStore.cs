using UnityEngine;

namespace YetiKit.Lab
{
    public interface ITuningStore
    {
        string Load(string experimentId);
        void Save(string experimentId, string body);
    }

    internal sealed class PlayerPrefsTuningStore : ITuningStore
    {
        private static string Key(string id) => "YetiKit.Lab.Tuning." + id;
        public string Load(string experimentId) => PlayerPrefs.GetString(Key(experimentId));
        public void Save(string experimentId, string body)
        {
            PlayerPrefs.SetString(Key(experimentId), body);
            PlayerPrefs.Save();
        }
    }
}

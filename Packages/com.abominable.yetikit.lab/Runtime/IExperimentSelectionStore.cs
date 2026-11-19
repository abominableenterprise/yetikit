using UnityEngine;

namespace YetiKit.Lab
{
    public interface IExperimentSelectionStore
    {
        string Load(string labId);
        void Save(string labId, string experimentId);
    }

    public sealed class PlayerPrefsExperimentSelectionStore : IExperimentSelectionStore
    {
        const string Prefix = "YetiKit.Lab.Selection.";
        public string Load(string labId) => PlayerPrefs.GetString(Prefix + labId, "");
        public void Save(string labId, string experimentId)
        {
            PlayerPrefs.SetString(Prefix + labId, experimentId);
            PlayerPrefs.Save();
        }
    }
}

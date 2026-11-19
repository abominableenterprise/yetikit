using System;
using UnityEngine;
using YetiKit.Hands;

namespace YetiKit.Lab
{
    /// <summary>Local persistence for one catalog. Use a stable scope unique to that catalog.</summary>
    public sealed class PlayerPrefsGripOverrideStore : IGripOverrideStore
    {
        readonly string prefix;

        public PlayerPrefsGripOverrideStore(string scope)
        {
            if (string.IsNullOrWhiteSpace(scope)) throw new ArgumentException("Scope is required.", nameof(scope));
            prefix = $"YetiKit.Lab.Grips.{scope.Length}:{scope}.";
        }

        public string Load(string propId, HandMode mode)
        {
            var key = Key(propId, mode);
            return PlayerPrefs.HasKey(key) ? PlayerPrefs.GetString(key) : null;
        }

        public void Save(string propId, HandMode mode, string body)
        {
            var key = Key(propId, mode);
            if (body == null) PlayerPrefs.DeleteKey(key);
            else PlayerPrefs.SetString(key, body);
            PlayerPrefs.Save();
        }

        string Key(string propId, HandMode mode) => prefix + (mode switch
        {
            HandMode.Controller => "controller.",
            HandMode.TrackedHand => "tracked_hand.",
            _ => throw new ArgumentOutOfRangeException(nameof(mode)),
        }) + propId;
    }
}

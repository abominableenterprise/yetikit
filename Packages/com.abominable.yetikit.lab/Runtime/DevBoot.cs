using System;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace YetiKit.Lab
{
    /// <summary>Consumers call Launch once at startup with their own development launch policy.</summary>
    public static class DevBoot
    {
        static (string Scene, string Experiment) pending;

        public static bool Launch(Func<(string Scene, string Experiment)> policy, Action<string> loadScene = null)
        {
            var target = policy();
            if (string.IsNullOrWhiteSpace(target.Scene)) return false;
            pending = target;
            try
            {
                if (loadScene == null) SceneManager.LoadScene(target.Scene);
                else loadScene(target.Scene);
            }
            catch { Reset(); throw; }
            return true;
        }

        /// <summary>Only the target scene can consume the one-shot, non-persisted selection.</summary>
        public static string Consume(string scene)
        {
            if (pending.Scene == null || pending.Scene != scene) return null;
            var id = pending.Experiment;
            Reset();
            return id;
        }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void Reset() => pending = default;
    }
}

#if UNITY_ANDROID && !UNITY_EDITOR
using System;
using UnityEngine;
using UnityEngine.Android;

namespace YetiKit.Playtest
{
    internal static class PlaytestEnrollmentStartup
    {
        const string PortExtra = "yetikit_enroll_port", NonceExtra = "yetikit_enroll_nonce";
        static bool checkedLaunch;

        // A second caller (including LoadDefault from an earlier startup callback) must not reconnect.
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        internal static void TryInstall()
        {
            if (checkedLaunch) return;
            checkedLaunch = true;
            var installed = false;
            try
            {
                // Unity's current-activity API avoids relying on a particular launcher activity class.
                using var intent = AndroidApplication.currentActivity?.Call<AndroidJavaObject>("getIntent");
                if (intent == null) return;
                var hasPort = intent.Call<bool>("hasExtra", PortExtra);
                var hasNonce = intent.Call<bool>("hasExtra", NonceExtra);
                if (!hasPort && !hasNonce) return;
                try
                {
                    if (hasPort && hasNonce)
                    {
                        var port = intent.Call<int>("getIntExtra", PortExtra, 0);
                        var nonce = intent.Call<string>("getStringExtra", NonceExtra);
                        installed = PlaytestEnrollment.TryInstall(port, nonce, PlaytestJsonSettings.ExternalPath(), TimeSpan.FromSeconds(3));
                    }
                }
                finally
                {
                    RemoveExtra(intent, PortExtra);
                    RemoveExtra(intent, NonceExtra);
                }
            }
            catch (AndroidJavaException) { }
            if (installed) Debug.Log("YetiKitPlaytest: enroll ok");
            else Debug.LogWarning("YetiKitPlaytest: enroll failed");
        }

        static void RemoveExtra(AndroidJavaObject intent, string name)
        {
            try { intent.Call("removeExtra", name); }
            catch (AndroidJavaException) { }
        }
    }
}
#endif

using UnityEngine;

namespace YetiKit.Host.Editor
{
    /// <summary>Schema placeholder only; the test Host does not build a player.</summary>
    public static class HostBuild
    {
        public static void DevelopmentApk()
        {
            Debug.Log("[YetiKit] The Host is a test project; no APK is produced.");
        }
    }
}

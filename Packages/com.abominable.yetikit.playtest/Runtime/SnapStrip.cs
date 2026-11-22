#if UNITY_EDITOR || YETIKIT_DEV
using System.Globalization;
namespace YetiKit.Playtest
{
    public static class SnapStrip
    {
        public const double Before = 3, After = 3;
        public const int Quality = 75, MaxFrames = 100;
        internal static string Suffix(int index) => "-s" + index.ToString("D2", CultureInfo.InvariantCulture);
    }
}
#endif

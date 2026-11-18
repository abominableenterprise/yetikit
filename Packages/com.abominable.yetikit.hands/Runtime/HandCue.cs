using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>
    /// Plays a short audio cue as an alternative to controller haptics. Amplitude sets the volume and
    /// selects a soft or strong cue at <see cref="StrongAmplitude"/>. Soft and strong cues are rate-limited
    /// independently by <see cref="SoftInterval"/> and <see cref="StrongInterval"/>.
    /// </summary>
    public sealed class HandCue : MonoBehaviour
    {
        public const float StrongAmplitude = 0.5f;
        public const float SoftInterval = 0.25f, StrongInterval = 0.1f;
        public const float MinVolume = 0.1f, MaxVolume = 0.45f;

        [Tooltip("3D source on the hand root (quiet, short range).")]
        public AudioSource source;
        public AudioClip tick, thump;

        float lastSoft = float.NegativeInfinity, lastStrong = float.NegativeInfinity;

        /// <summary>Cues played (tests).</summary>
        public int Played { get; private set; }

        public static bool Strong(float amplitude) => amplitude >= StrongAmplitude;
        public static float Volume(float amplitude) => Mathf.Lerp(MinVolume, MaxVolume, Mathf.Clamp01(amplitude));

        /// <summary>The cue for a haptic impulse of <paramref name="amplitude"/> at <paramref name="now"/>; false when
        /// rate-limited.</summary>
        public bool Play(float amplitude, float now)
        {
            var strong = Strong(amplitude);
            if (strong ? now - lastStrong < StrongInterval : now - Mathf.Max(lastSoft, lastStrong) < SoftInterval) return false;
            if (strong) lastStrong = now;
            else lastSoft = now;
            Played++;
            var clip = strong ? thump : tick;
            if (source && clip && source.isActiveAndEnabled) source.PlayOneShot(clip, Volume(amplitude));
            return true;
        }
    }
}

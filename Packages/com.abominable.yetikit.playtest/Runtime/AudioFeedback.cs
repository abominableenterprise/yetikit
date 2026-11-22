using UnityEngine;

namespace YetiKit.Playtest
{
    /// <summary>Main-thread clip factories. The caller owns playback and must destroy the returned clips.</summary>
    public static class AudioFeedback
    {
        const int Rate = 48000;

        public static AudioClip CreateStartClip() => Build("Voice note start", 740, 1110);
        public static AudioClip CreateTickClip() => Build("Voice note confirmation", 1110, 740);

        static AudioClip Build(string name, int firstHz, int secondHz)
        {
            const int half = Rate / 20;
            var data = new float[2 * half];
            for (int i = 0; i < data.Length; i++)
            {
                float phase = (i % half) / (float)(half - 1);
                int hz = i < half ? firstHz : secondHz;
                data[i] = 0.25f * Mathf.Sin(Mathf.PI * phase) * Mathf.Sin(2 * Mathf.PI * hz * phase / 20);
            }
            var clip = AudioClip.Create(name, data.Length, 1, Rate, false);
            clip.SetData(data, 0);
            return clip;
        }
    }
}

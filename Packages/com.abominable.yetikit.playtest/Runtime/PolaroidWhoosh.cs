#if UNITY_EDITOR || YETIKIT_DEV
using UnityEngine;
namespace YetiKit.Playtest
{
    public static class PolaroidWhoosh
    {
        public const int Rate = 22050;
        public static float[] Samples()
        {
            var data = new float[(int)(Rate * PolaroidCard.FlySeconds)];
            var noise = new System.Random(4820);
            for (int i = 1; i < data.Length - 1; i++)
                data[i] = (0.55f - 1.1f * (float)noise.NextDouble()) * Mathf.Sin(Mathf.PI * Mathf.Sqrt(i / (float)(data.Length - 1)));
            return data;
        }
    }
}
#endif

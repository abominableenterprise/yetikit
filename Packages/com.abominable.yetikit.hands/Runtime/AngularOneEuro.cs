using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>One Euro angle filter with held-input tremor rejection and unwrapped output, in degrees.</summary>
    public sealed class AngularOneEuro
    {
        public const float MinCutoffHz = 3f;
        public const float Beta = 4f;
        public const float DerivativeCutoffHz = 1f;
        public const float TremorDegrees = 0.3f;
        public const float ResetGapSeconds = 0.25f;
        public const float SustainedOffsetSeconds = 0.05f;
        const float StableOffsetDegrees = 0.1f;
        const float MotionThreshold = TremorDegrees + 0.0001f;

        float accepted, derivative, heldMinimum, heldMaximum;
        float stableOffset, stableSeconds;
        public float Value { get; private set; }

        /// <summary>Seed the filter with the first angle of a new aim.</summary>
        public void Reset(float angle)
        {
            heldMinimum = heldMaximum = accepted = Value = angle;
            derivative = stableSeconds = 0f;
        }

        /// <summary>Filter an angle in degrees using elapsed time <paramref name="dt"/> in seconds.</summary>
        public float Step(float angle, float dt)
        {
            if (!(dt > 0f) || float.IsInfinity(dt) || float.IsNaN(angle) || float.IsInfinity(angle)) return Value;
            var delta = Mathf.DeltaAngle(accepted, angle);
            var raw = accepted + delta;
            // Once there is a rejected spread, include the sample before measuring from its centre.
            // Without a spread, a deliberate small step can pass immediately.
            if (heldMaximum > heldMinimum) ExtendEnvelope(raw);
            var heldCentre = (heldMinimum + heldMaximum) * 0.5f;
            var outside = Mathf.Abs(delta) > MotionThreshold;
            var moving = outside && Mathf.Abs(raw - heldCentre) > MotionThreshold;
            if (!moving && outside)
            {
                // Let sustained offsets through, but don't age out alternating tremor extremes.
                if (stableSeconds == 0f || Mathf.Abs(raw - stableOffset) > StableOffsetDegrees)
                {
                    stableOffset = raw;
                    stableSeconds = dt;
                }
                else stableSeconds += dt;
                moving = stableSeconds >= SustainedOffsetSeconds;
            }
            if (moving || !outside) stableSeconds = 0f;

            var next = moving ? raw : accepted;
            if (dt >= ResetGapSeconds) { Reset(next); return Value; }
            if (moving) heldMinimum = heldMaximum = next;
            else ExtendEnvelope(raw);
            derivative = Mathf.Lerp(derivative, (next - accepted) / dt, Alpha(DerivativeCutoffHz, dt));
            accepted = next;
            Value = Mathf.Lerp(Value, accepted, Alpha(MinCutoffHz + Beta * Mathf.Abs(derivative), dt));
            return Value;
        }

        void ExtendEnvelope(float raw)
        {
            heldMinimum = Mathf.Min(heldMinimum, raw);
            heldMaximum = Mathf.Max(heldMaximum, raw);
        }

        static float Alpha(float cutoff, float dt) => 1f / (1f + 1f / (2f * Mathf.PI * cutoff * dt));
    }
}

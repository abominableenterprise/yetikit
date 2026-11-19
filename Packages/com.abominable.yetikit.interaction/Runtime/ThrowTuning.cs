using System;
using System.Globalization;
using System.Text;

namespace YetiKit.Interaction
{
    /// <summary>Session-only throw settings. No Unity objects, persistence or per-frame lookups.
    /// Release players always read compiled defaults; Editor/development players may tune them.</summary>
    public static class ThrowTuning
    {
        public const string PowerId = "power", TopSpeedId = "top_speed",
            ForgivenessId = "forgiveness", AimHelpId = "aim_help";
        public const float DefaultPower = 1.5f, DefaultTopSpeed = 16f,
            DefaultForgiveness = 0.15f, DefaultAimHelp = 1f;
        public const float MinPower = 0.8f, MaxPower = 2.5f, PowerStep = 0.05f;
        public const float MinTopSpeed = 8f, MaxTopSpeed = 30f, TopSpeedStep = 1f;
        public const float MinForgiveness = 0.05f, MaxForgiveness = 0.30f, ForgivenessStep = 0.01f;
        public const float MinAimHelp = 0f, MaxAimHelp = 2f, AimHelpStep = 0.1f;

        static readonly Setting power = new Setting(PowerId, DefaultPower, MinPower, MaxPower, PowerStep);
        static readonly Setting topSpeed = new Setting(TopSpeedId, DefaultTopSpeed, MinTopSpeed, MaxTopSpeed, TopSpeedStep);
        static readonly Setting forgiveness = new Setting(ForgivenessId, DefaultForgiveness, MinForgiveness, MaxForgiveness, ForgivenessStep);
        static readonly Setting aimHelp = new Setting(AimHelpId, DefaultAimHelp, MinAimHelp, MaxAimHelp, AimHelpStep);
        static readonly Setting[] settings = { power, topSpeed, forgiveness, aimHelp };

#if UNITY_EDITOR || DEVELOPMENT_BUILD
        public static float Power => power.Value;
        public static float TopSpeed => topSpeed.Value;
        public static float Forgiveness => forgiveness.Value;
        public static float AimHelp => aimHelp.Value;
#else
        public static float Power => DefaultPower;
        public static float TopSpeed => DefaultTopSpeed;
        public static float Forgiveness => DefaultForgiveness;
        public static float AimHelp => DefaultAimHelp;
#endif
        public static event Action Changed;
        public static bool IsDefault => Power == DefaultPower && TopSpeed == DefaultTopSpeed &&
            Forgiveness == DefaultForgiveness && AimHelp == DefaultAimHelp;

        /// <summary>Clamp only; step constants are for UI dials. Unknown IDs and nonfinite values are ignored.
        /// Returns true only when a stored value changed. Call from the main thread.</summary>
        public static bool Set(string id, float value)
        {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
            if (!float.IsFinite(value)) return false;
            foreach (var setting in settings)
            {
                if (setting.Id != id) continue;
                if (!setting.Set(value)) return false;
                Changed?.Invoke();
                return true;
            }
#endif
            return false;
        }

        /// <summary>Restore all four defaults, notifying once (only if anything changed).</summary>
        public static void Reset()
        {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
            if (IsDefault) return;
            foreach (var setting in settings) setting.Set(setting.Default);
            Changed?.Invoke();
#endif
        }

        /// <summary>A stable, invariant-culture JSON object, optionally omitting unchanged defaults.</summary>
        public static string Json(bool nonDefaults = false)
        {
            var json = new StringBuilder("{");
            foreach (var setting in settings)
            {
                if (nonDefaults && setting.Value == setting.Default) continue;
                if (json.Length > 1) json.Append(',');
                json.Append('"').Append(setting.Id).Append("\":")
                    .Append(setting.Value.ToString("R", CultureInfo.InvariantCulture));
            }
            return json.Append('}').ToString();
        }

        sealed class Setting
        {
            public readonly string Id;
            public readonly float Default;
#if UNITY_EDITOR || DEVELOPMENT_BUILD
            readonly float min, max;
            float value;
            public float Value => value;
#else
            public float Value => Default;
#endif
            public Setting(string id, float defaultValue, float min, float max, float step)
            {
                Id = id;
                Default = defaultValue;
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                value = defaultValue;
                this.min = min;
                this.max = max;
#endif
            }

#if UNITY_EDITOR || DEVELOPMENT_BUILD
            public bool Set(float input)
            {
                var clamped = Math.Max(min, Math.Min(max, input));
                if (value == clamped) return false;
                value = clamped;
                return true;
            }
#endif
        }
    }
}

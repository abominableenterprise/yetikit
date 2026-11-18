using System;
using UnityEngine;

namespace YetiKit.Interaction
{
    [Serializable]
    public struct PropRespawnSettings
    {
        public Vector3 AreaOrigin;
        public float AreaRadius;
        public float FallY;
        public float MaxDistance;
        public float IdleSeconds;
        public float OutOfAreaSeconds;
        public float HomeTolerance;
        public float ViewHalfAngle;

        public static PropRespawnSettings Default => new PropRespawnSettings
        {
            AreaOrigin = Vector3.zero,
            AreaRadius = 43.1f + 1f,
            FallY = -2f,
            MaxDistance = 60f,
            IdleSeconds = 120f,
            OutOfAreaSeconds = 3f,
            HomeTolerance = 0.35f,
            ViewHalfAngle = 65f
        };
    }
}

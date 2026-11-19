using UnityEngine;

namespace YetiKit.Interaction
{
    public enum RespawnReason { None, Fell, TooFar, Idle, OutOfArea }

    /// <summary>Decides when a loose prop should return home, without moving it.</summary>
    public static class PropRespawnRules
    {
        /// <summary>Is the prop horizontally beyond the area boundary, at any height?</summary>
        public static bool OutOfArea(Vector3 position, in PropRespawnSettings settings)
        {
            var offset = position - settings.AreaOrigin;
            return offset.x * offset.x + offset.z * offset.z > settings.AreaRadius * settings.AreaRadius;
        }

        public static bool AtHome(Vector3 position, Vector3 home, in PropRespawnSettings settings) =>
            (position - home).sqrMagnitude < settings.HomeTolerance * settings.HomeTolerance;

        /// <summary>A stuck prop always counts as away for the respawn rules.</summary>
        public static bool Away(Vector3 position, Vector3 home, bool stuck, in PropRespawnSettings settings) =>
            stuck || !AtHome(position, home, settings);

        /// <summary>Falling always requires recovery. Other checks apply only if ordinary returns are enabled.</summary>
        /// <param name="position">The prop's world position.</param>
        /// <param name="home">The prop's home position.</param>
        /// <param name="idleSeconds">How long the prop has been idle.</param>
        /// <param name="inHomeArea">Whether the prop is inside its designated home area.</param>
        /// <param name="outOfAreaSeconds">Time continuously outside the boundary.</param>
        /// <param name="respawns">Enable ordinary returns.</param>
        /// <param name="settings">The consumer's respawn policy.</param>
        public static RespawnReason Check(Vector3 position, Vector3 home, float idleSeconds, bool inHomeArea,
            float outOfAreaSeconds, bool respawns, in PropRespawnSettings settings)
        {
            if (position.y < settings.FallY) return RespawnReason.Fell;
            if (!respawns) return RespawnReason.None;
            if ((position - home).sqrMagnitude > settings.MaxDistance * settings.MaxDistance) return RespawnReason.TooFar;
            if (outOfAreaSeconds >= settings.OutOfAreaSeconds && OutOfArea(position, settings) && !OutOfArea(home, settings))
                return RespawnReason.OutOfArea;
            if (!inHomeArea && !AtHome(position, home, settings) && idleSeconds >= settings.IdleSeconds) return RespawnReason.Idle;
            return RespawnReason.None;
        }

        /// <summary>Lost props return immediately; idle props return only when out of view.</summary>
        public static bool PopNow(RespawnReason reason, bool inView) =>
            reason == RespawnReason.Fell || reason == RespawnReason.TooFar || reason == RespawnReason.OutOfArea
            || (reason == RespawnReason.Idle && !inView);

        /// <summary>Is the target inside the view cone?</summary>
        public static bool InView(Vector3 eye, Vector3 forward, Vector3 target, in PropRespawnSettings settings) =>
            Vector3.Angle(forward, target - eye) < settings.ViewHalfAngle;
    }
}

using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Computes launch velocities from tracked motion. The centre-of-mass lever contributes forward tangential
    /// speed (ω × r), and throw tuning scales the resulting linear velocity. Spin uses <see cref="AngularScale"/>.
    /// </summary>
    public static class PropThrow
    {
        public const float VelocityScale = 1.5f;
        public const float AngularScale = 1f;
        public const float MaxSpeed = 30f;        // m/s: tracking glitches never launch a prop across the map
        /// <summary>Default launch cap for tracked-hand throws, in m/s.</summary>
        public const float MaxHandSpeed = 16f;
        public const float MaxAngularSpeed = 20f; // rad/s, the physics default cap
        public const float LinearDamping = 0.05f;
        public const float AngularDamping = 0.3f;

        /// <summary>Launch velocity for <paramref name="peak"/>. Tracked palms also use <see cref="ThrowTuning.TopSpeed"/>.</summary>
        public static Vector3 Launch(ThrowSample peak, Vector3 lever)
        {
            var v = Linear(peak.Linear, peak.Angular, lever);
            return peak.Source == ThrowSources.HandPalm ? Vector3.ClampMagnitude(v, ThrowTuning.TopSpeed) : v;
        }

        public static Vector3 Linear(Vector3 controller) => Vector3.ClampMagnitude(controller * ThrowTuning.Power, MaxSpeed);

        /// <summary>
        /// The launch velocity of a prop whose centre of mass is <paramref name="lever"/> from the sampled point in
        /// world space (palm or controller), moving at <paramref name="controller"/> and spinning at
        /// <paramref name="angular"/> rad/s. The ω × r term adds only its forward component to a moving throw.
        /// </summary>
        public static Vector3 Linear(Vector3 controller, Vector3 angular, Vector3 lever)
        {
            var tangential = Vector3.Cross(angular, lever);
            var speed = controller.magnitude;
            if (speed < 1e-4f) return Linear(tangential); // rotation alone
            var dir = controller / speed;
            return Linear(dir * (speed + Mathf.Max(0f, Vector3.Dot(tangential, dir))));
        }

        /// <summary>
        /// Where the hand holds a prop's centre of mass (world): the prop posed so its attach point (prop-local
        /// <paramref name="attachLocal"/>) sits on the interactor's <paramref name="interactorAttach"/>. The
        /// velocity-tracked body itself lags a frame or two behind the hand, so its own position is not the lever.
        /// </summary>
        public static Vector3 HeldCenter(Pose interactorAttach, Pose attachLocal, Vector3 localCenterOfMass)
        {
            var rotation = interactorAttach.rotation * Quaternion.Inverse(attachLocal.rotation);
            var position = interactorAttach.position - rotation * attachLocal.position;
            return position + rotation * localCenterOfMass;
        }

        /// <summary>Final boundary after assist (also used by history-free hand releases).</summary>
        public static Vector3 Bound(Vector3 velocity, float maxSpeed)
        {
            if (!float.IsFinite(velocity.x) || !float.IsFinite(velocity.y) || !float.IsFinite(velocity.z) ||
                !float.IsFinite(velocity.sqrMagnitude)) return Vector3.zero;
            return Vector3.ClampMagnitude(velocity, maxSpeed);
        }

        public static Vector3 Angular(Vector3 controller) => Bound(controller * AngularScale, MaxAngularSpeed);
    }
}

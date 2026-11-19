using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>A grip-open swing can ride the controller until its first slowdown, but never longer than 80 ms.</summary>
    public sealed class LateRelease
    {
        public const float Max = 0.08f;
        public const float MinSpeed = 1.5f;

        readonly float openedAt;
        Vector3 peak;
        bool waiting, completed;

        public LateRelease(float openedAt, Vector3 velocity, float previousSpeed = 0f)
        {
            this.openedAt = openedAt;
            peak = velocity;
            waiting = velocity.magnitude > MinSpeed && velocity.magnitude > previousSpeed;
        }

        public bool ShouldWait(float now) => waiting && !completed && now - openedAt < Max;
        public Vector3 Peak => peak;

        /// <summary>The carrying rig snap-turned: keep the observed world-space peak in its new direction.</summary>
        public void Rotate(Quaternion rotation) => peak = rotation * peak;

        public void Add(float now, Vector3 velocity)
        {
            if (!ShouldWait(now)) return;
            if (velocity.sqrMagnitude < peak.sqrMagnitude) waiting = false;
            else peak = velocity;
        }

        public bool TryComplete(float now, out Vector3 velocity)
        {
            velocity = peak;
            if (completed || ShouldWait(now)) return false;
            completed = true;
            return true;
        }

        public void Cancel() { waiting = false; completed = true; }
    }
}

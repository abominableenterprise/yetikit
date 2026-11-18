using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Bounded launch correction for nearby aim points. The assist compares the throw direction against
    /// the low ballistic arc, leads targets with reliable motion, and can boost speed if the arc falls short.
    /// </summary>
    public static class ThrowAssist
    {
        /// <summary>Degrees: the throw's direction must be this close to the hitting arc for the assist to apply.</summary>
        public const float Cone = 8f;
        /// <summary>Degrees: the most the assist turns the launch direction.</summary>
        public const float MaxNudge = 5f;
        /// <summary>m: targets further than this (from the prop), where they are now or where the lead predicts them,
        /// are never assisted.</summary>
        public const float Range = 8f;
        /// <summary>The most the assist multiplies the launch speed by (only when the arc would fall short).</summary>
        public const float MaxBoost = 1.15f;
        /// <summary>m/s: slower releases (a drop, a pass) are never assisted.</summary>
        public const float MinSpeed = 2f;

        /// <summary>m/s: a target whose velocity is unknown (<see cref="ThrowTarget.Known"/> false) moving faster than
        /// this is never assisted: without a lead the nudge would pull a correctly led throw back behind it.</summary>
        public const float MaxUnledSpeed = 0.3f;
        /// <summary>Lead passes: each re-times the flight to the target's predicted spot (two converge to millimetres at
        /// walking speed).</summary>
        public const int LeadPasses = 2;

        /// <summary>
        /// The assisted launch velocity of a prop leaving <paramref name="from"/> at <paramref name="velocity"/> under
        /// <paramref name="gravity"/> (m/s², positive), given stationary aim points <paramref name="targets"/>.
        /// <paramref name="applied"/> says whether it changed anything (the throw log's assist column).
        /// </summary>
        public static Vector3 Apply(Vector3 from, Vector3 velocity, IReadOnlyList<Vector3> targets, float gravity, out bool applied)
        {
            still.Clear();
            if (targets != null) foreach (var t in targets) still.Add(new ThrowTarget(t, Vector3.zero, true));
            return ApplyMoving(from, velocity, targets == null ? null : still, gravity, out applied);
        }

        static readonly List<ThrowTarget> still = new List<ThrowTarget>();

        /// <summary>Apply assist using the currently registered target source, if any.</summary>
        public static Vector3 ApplyMoving(Vector3 from, Vector3 velocity, float gravity, out bool applied) =>
            ApplyMoving(from, velocity, ThrowTargetSource.Current?.Targets, gravity, out applied);

        /// <summary>
        /// <see cref="Apply(Vector3, Vector3, IReadOnlyList{Vector3}, float, out bool)"/> for targets that may be moving:
        /// each is aimed at where it will be when the prop gets there (<see cref="Lead"/>), so a led throw is
        /// not pulled back toward the target’s current position.
        /// </summary>
        public static Vector3 ApplyMoving(Vector3 from, Vector3 velocity, IReadOnlyList<ThrowTarget> targets, float gravity, out bool applied)
        {
            applied = false;
            var strength = ThrowTuning.AimHelp;
            if (strength == 0f) return velocity;
            var speed = velocity.magnitude;
            if (targets == null || speed < MinSpeed || gravity <= 0f) return velocity;
            var dir = velocity / speed;
            var bestAngle = Cone * strength + 1e-3f;
            var bestAim = Vector3.zero;
            var bestTarget = Vector3.zero;
            for (var i = 0; i < targets.Count; i++)
            {
                var target = targets[i];
                if (!target.Known && target.Velocity.sqrMagnitude > MaxUnledSpeed * MaxUnledSpeed) continue;
                // Out of range now: never assisted, even when the target is predicted to move into range.
                if ((target.Position - from).sqrMagnitude > Range * Range) continue;
                var at = Lead(from, target, dir, speed);
                var to = at - from;
                if (to.sqrMagnitude > Range * Range || to.sqrMagnitude < 0.01f) continue;
                var aim = Aim(to, speed, gravity);
                var angle = Vector3.Angle(dir, aim);
                if (angle >= bestAngle) continue;
                bestAngle = angle;
                bestAim = aim;
                bestTarget = at;
            }
            if (bestAim == Vector3.zero) return velocity;
            var turned = Vector3.RotateTowards(dir, bestAim, MaxNudge * strength * Mathf.Deg2Rad, 0f);
            var needed = SpeedToReach(bestTarget - from, turned, gravity);
            // Preserve the original multiplier exactly at the default strength.
            var boost = strength == 1f ? MaxBoost : 1f + .15f * strength;
            var newSpeed = needed > speed ? Mathf.Min(needed, speed * boost) : speed;
            applied = bestAngle > 1e-3f || newSpeed > speed;
            return turned * newSpeed;
        }

        /// <summary>
        /// Where <paramref name="target"/> will be when a prop thrown from <paramref name="from"/> along
        /// <paramref name="dir"/> at <paramref name="speed"/> reaches it: its position plus its velocity times the flight
        /// time, the horizontal distance over the throw's horizontal speed (speed · cos θ). A still target (or an
        /// unknown velocity) stays where it is.
        /// </summary>
        public static Vector3 Lead(Vector3 from, ThrowTarget target, Vector3 dir, float speed)
        {
            if (!target.Known || target.Velocity.sqrMagnitude < 1e-6f) return target.Position;
            var flat = speed * new Vector3(dir.x, 0f, dir.z).magnitude;
            if (flat < 1e-3f) return target.Position;
            var at = target.Position;
            for (var k = 0; k < LeadPasses; k++)
            {
                var to = at - from;
                var time = new Vector3(to.x, 0f, to.z).magnitude / flat;
                at = target.Position + target.Velocity * time;
            }
            return at;
        }

        /// <summary>
        /// The launch direction that reaches <paramref name="to"/> at <paramref name="speed"/> on the low arc, or, when
        /// the speed cannot reach it, the direction that needs the least speed (45° above the slope to it).
        /// </summary>
        public static Vector3 Aim(Vector3 to, float speed, float gravity)
        {
            var flat = new Vector3(to.x, 0f, to.z);
            var x = flat.magnitude;
            if (x < 1e-3f) return to.normalized;
            var y = to.y;
            var v2 = speed * speed;
            var disc = v2 * v2 - gravity * (gravity * x * x + 2f * y * v2);
            var angle = disc >= 0f
                ? Mathf.Atan((v2 - Mathf.Sqrt(disc)) / (gravity * x))
                : 0.25f * Mathf.PI + 0.5f * Mathf.Atan2(y, x);
            return (flat / x * Mathf.Cos(angle) + Vector3.up * Mathf.Sin(angle)).normalized;
        }

        /// <summary>The launch speed along <paramref name="dir"/> whose arc passes through <paramref name="to"/>
        /// (+infinity when that direction can never get there: aimed below the target or straight up).</summary>
        public static float SpeedToReach(Vector3 to, Vector3 dir, float gravity)
        {
            var flatDir = new Vector3(dir.x, 0f, dir.z);
            var cos = flatDir.magnitude;
            var x = new Vector3(to.x, 0f, to.z).magnitude;
            if (cos < 1e-3f) return float.PositiveInfinity;
            var tan = dir.y / cos;
            var drop = x * tan - to.y;
            if (drop <= 1e-4f) return float.PositiveInfinity;
            return Mathf.Sqrt(gravity * x * x / (2f * cos * cos * drop));
        }
    }
}

using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// A rigid change in tracking space, such as a teleport or snap turn. Carrying a held object's pose with
    /// the rig prevents a velocity-tracked body from treating the pose jump as physical motion.
    /// </summary>
    public readonly struct RigCarry
    {
        public readonly Vector3 FromPosition, ToPosition;
        public readonly Quaternion FromRotation, ToRotation;

        public RigCarry(Vector3 fromPosition, Quaternion fromRotation, Vector3 toPosition, Quaternion toRotation)
        {
            FromPosition = fromPosition;
            FromRotation = fromRotation;
            ToPosition = toPosition;
            ToRotation = toRotation;
        }

        /// <summary>The world rotation of the move.</summary>
        public Quaternion Rotation => ToRotation * Quaternion.Inverse(FromRotation);
        /// <summary>A world point that rode along with the space.</summary>
        public Vector3 Point(Vector3 p) => ToPosition + Rotation * (p - FromPosition);
        /// <summary>A world rotation that rode along with the space.</summary>
        public Quaternion Turn(Quaternion r) => Rotation * r;
        public Pose Carry(Pose p) => new Pose(Point(p.position), Turn(p.rotation));
    }

    /// <summary>Watches one tracking space and reports when it moved since the last look.</summary>
    public sealed class RigFollow
    {
        public const float MinMove = 1e-5f;   // m
        public const float MinTurn = 0.01f;   // degrees

        Transform space;
        Vector3 position;
        Quaternion rotation;

        public Transform Space => space;

        /// <summary>Watch <paramref name="tracking"/> from its pose now (null: nothing).</summary>
        public void Track(Transform tracking)
        {
            space = tracking;
            if (!space) return;
            position = space.position;
            rotation = space.rotation;
        }

        /// <summary>True (and the move) when the space moved since the last look; the new pose is the next baseline.</summary>
        public bool Moved(out RigCarry carry)
        {
            carry = default;
            if (!space) return false;
            var p = space.position;
            var r = space.rotation;
            if ((p - position).sqrMagnitude < MinMove * MinMove && Quaternion.Angle(r, rotation) < MinTurn) return false;
            carry = new RigCarry(position, rotation, p, r);
            position = p;
            rotation = r;
            return true;
        }
    }
}

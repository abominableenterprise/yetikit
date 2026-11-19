using System;
using UnityEngine;

namespace YetiKit.Interaction
{
    public enum GripKind
    {
        /// <summary>A bottle or can: a fist around it, its long axis across the palm like a handle.</summary>
        Cylinder,
        /// <summary>A hotdog or bun: lying across the fingers, further out than a handle.</summary>
        Lengthwise,
        /// <summary>A bag, newspaper, cup or peel: held loosely between the thumb and the fingertips.</summary>
        Pinch,
        /// <summary>A firecracker: one end pinched between the thumb tip and the index fingertip, the rest sticking
        /// out of the hand.</summary>
        Fingertips,
        /// <summary>A lighter: the fingers round its body like a small bottle, the thumb not round it but on its top
        /// (<see cref="GripSpec.thumbAt"/>, the flint wheel), the top just out of the fist.</summary>
        ThumbTop,
        /// <summary>A spray can: the index fingertip rests on the cap; other fingers wrap the body.</summary>
        IndexTop,
    }

    /// <summary>
    /// How a prop sits in the glove. The prop's local
    /// <see cref="axis"/> lies across the palm (the glove model's thumb axis, +Y), its local <see cref="palm"/> side
    /// faces the palm (perpendicular to the axis), <see cref="center"/> (prop local) sits at the grip point of
    /// <see cref="kind"/>, and <see cref="radius"/> is how thick the held part is from the centre to the palm.
    /// </summary>
    [Serializable]
    public struct GripSpec
    {
        public GripKind kind;
        public Vector3 axis, palm, center;
        public float radius;
        /// <summary><see cref="GripKind.ThumbTop"/>: the prop-local point the thumb's pad rests on (unused otherwise).</summary>
        public Vector3 thumbAt;
        /// <summary><see cref="GripKind.ThumbTop"/>: a prop-local point (a lighter's nozzle) whose column straight up the
        /// prop's +Y the thumb keeps out of, so the flame shows.</summary>
        public Vector3 keepClear;
        /// <summary>IndexTop: prop-local cap contact point for the index fingertip.</summary>
        public Vector3 indexAt;
        /// <summary>Set (non-zero): the prop's +Y and +Z point these ways in the glove model's frame (fingers +Z, thumb
        /// +Y, back of the hand +X) instead of <see cref="axis"/>/<see cref="palm"/>; the mirrored left glove mirrors
        /// them, so a lighter's top tilts toward the fingers in either hand.</summary>
        public Vector3 handUp, handForward;
        /// <summary>Added to the grip point in the glove model's frame (<see cref="ModelPoint"/>): e.g. a lighter moved
        /// toward the thumb.</summary>
        public Vector3 shift;

        public GripSpec(GripKind kind, Vector3 axis, Vector3 palm, Vector3 center, float radius)
        {
            this.kind = kind;
            this.axis = axis;
            this.palm = palm;
            this.center = center;
            this.radius = radius;
            thumbAt = keepClear = indexAt = handUp = handForward = shift = Vector3.zero;
        }

        /// <summary>A grip whose prop's +Y points along <paramref name="up"/> and its +Z along <paramref name="forward"/>
        /// in the glove model's frame (<see cref="handUp"/>).</summary>
        public static GripSpec Oriented(GripKind kind, Vector3 up, Vector3 forward, Vector3 center, float radius, Vector3 thumbAt = default, Vector3 keepClear = default)
        {
            forward = forward.normalized;
            up = Vector3.ProjectOnPlane(up, forward).normalized; // forward is kept exactly (a firecracker's fuse direction)
            var inv = Quaternion.Inverse(Quaternion.LookRotation(forward, up));
            return new GripSpec(kind, inv * Vector3.up, inv * Vector3.right, center, radius)
                { thumbAt = thumbAt, keepClear = keepClear, handUp = up, handForward = forward };
        }

        public bool IsOriented => handUp.sqrMagnitude > 1e-6f && handForward.sqrMagnitude > 1e-6f;

        // The glove model's frame: wrist at the origin, fingers +Z, thumb +Y, back of the hand +X (palm -X). Offsets
        // are from the knuckle line (the mean of the four finger knuckle joints).
        public const float PalmSkin = 0.014f; // m from the knuckle joints' centre line to the palm skin (-X)

        public const float FingerThickness = 0.016f; // m: a curled first finger bone, palm side to back

        /// <summary>
        /// Along the fingers (+Z) from the knuckle line to where the prop's grip centre goes. A handle sits in the
        /// hollow between the palm and the first finger bones curled to ~90°, so its centre is one finger thickness
        /// plus its radius behind the knuckles; lengthwise food lies across the first finger bones; a pinch is out at
        /// the fingertips.
        /// </summary>
        public float Reach() => kind switch
        {
            GripKind.Cylinder or GripKind.ThumbTop or GripKind.IndexTop => -(FingerThickness * 0.5f + radius),
            GripKind.Lengthwise => 0.02f,
            _ => 0.06f,
        };

        /// <summary>Where the thumb tip and the index fingertip meet as they close, from the knuckle line: out from the palm, toward the thumb, and a
        /// little back toward the wrist.</summary>
        public static readonly Vector3 FingertipsPoint = new Vector3(-0.08f, 0.045f, -0.01f);

        /// <summary>Where the prop's grip centre goes in the glove model's frame, given its knuckle line.</summary>
        public Vector3 ModelPoint(Vector3 knuckles) => shift + (kind == GripKind.Fingertips
            ? knuckles + FingertipsPoint
            : new Vector3(knuckles.x - PalmSkin - radius, knuckles.y, knuckles.z + Reach()));

        /// <summary>The middle of the palm's hollow (where a fist closes), independent of any prop: a check for
        /// <see cref="ModelPoint"/>.</summary>
        public static Vector3 PalmCenter(Vector3 knuckles) => knuckles + new Vector3(-0.045f, 0f, -0.035f);
    }
}

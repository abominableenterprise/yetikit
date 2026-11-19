using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Where a held prop goes (pure geometry): its <see cref="GripSpec.center"/> at <see cref="GripSpec.ModelPoint"/>
    /// in the glove model's frame, its axis along the model's thumb axis and its palm side toward the palm. Built from
    /// the model's world directions, so the mirrored left glove gets a proper (unmirrored) rotation too.
    /// </summary>
    public static class GripPlacement
    {
        /// <summary>World pose of the prop's transform held by the glove <paramref name="model"/> (an
        /// <see cref="GripSpec.IsOriented"/> grip: its +Y/+Z along the model's <see cref="GripSpec.handUp"/>/<see cref="GripSpec.handForward"/>).</summary>
        public static Pose PropPose(Transform model, Vector3 knuckles, GripSpec spec)
        {
            var grip = model.TransformPoint(spec.ModelPoint(knuckles));
            if (spec.IsOriented)
            {
                // Model-frame directions through the (maybe mirrored) model: LookRotation keeps the result proper.
                var fwd = model.TransformVector(spec.handForward).normalized;
                var up = model.TransformVector(spec.handUp).normalized;
                var r = Quaternion.LookRotation(fwd, up);
                return new Pose(grip - r * spec.center, r);
            }
            var thumb = model.TransformVector(Vector3.up).normalized;
            var back = model.TransformVector(Vector3.right).normalized;
            var world = Quaternion.LookRotation(back, thumb);   // +Z to the back of the hand, +Y along the thumb
            var axis = spec.axis.normalized;
            var palm = Vector3.ProjectOnPlane(spec.palm, axis).normalized;
            var local = Quaternion.LookRotation(palm, axis);    // the prop's palm side and axis, the same way
            var rotation = world * Quaternion.Inverse(local);
            return new Pose(grip - rotation * spec.center, rotation);
        }
    }
}

using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>Optional grip fitting and finger wrap supplied by the hand's visual or a hand hierarchy component.</summary>
    public interface IHeldVisual
    {
        /// <summary>Prepare the contact geometry and provide its model frame and model-local knuckle coordinates.</summary>
        bool TryGetGripFrame(out Transform model, out Vector3 knuckles);

        /// <summary>Clear and seat the authored world pose against the contact geometry before adjustments.</summary>
        Pose FitGrip(PropGrabInteractable prop, GripSpec grip, Pose authoredPose);

        /// <summary>Wrap the fingers around the final world pose, also called on a refit.</summary>
        void Hold(PropGrabInteractable prop, GripSpec grip, Pose heldPose);
        void Release(PropGrabInteractable prop);

        /// <summary>Raised when geometry changes and the held grip needs to be fitted again.</summary>
        event System.Action GripChanged;
    }
}

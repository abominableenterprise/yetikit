using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactors;

namespace YetiKit.Hands
{
    /// <summary>Direct interactor on a child of the hand root; its trigger and default attach follow the palm.</summary>
    public sealed class HandGrabInteractor : XRDirectInteractor
    {
        public const float Radius = 0.07f;
        public const float PalmDepth = 0.025f;
        public const float PalmAlong = 0.55f;

        public PlayerHand hand;
        PlayerHand Hand => hand ? hand : hand = GetComponentInParent<PlayerHand>(true);

        public override bool isSelectActive
        {
            get
            {
                if (!allowSelect) return false;
                if (isPerformingManualInteraction) return true;
                var h = Hand;
                if (!h || !h.GrabberActive) return false;
                if (!hasSelection && (h.GrabBlocked || h.FarInteraction.UiHover)) return false;
                var grab = h.Grab;
                return grab.Selecting && (hasSelection || grab.CanStart(Time.time));
            }
        }

        protected override void OnSelectEntering(SelectEnterEventArgs args)
        {
            var h = Hand;
            if (h) h.Grab.Took();
            base.OnSelectEntering(args);
        }

        public override void PreprocessInteractor(XRInteractionUpdateOrder.UpdatePhase updatePhase)
        {
            if (updatePhase == XRInteractionUpdateOrder.UpdatePhase.Dynamic) FollowPalm();
            base.PreprocessInteractor(updatePhase);
        }

        /// <summary>Update the attach position only when free; a hold keeps its child offset as the root moves.</summary>
        public void FollowPalm()
        {
            var h = Hand;
            if (!h || !h.Present || hasSelection) return;
            var palm = h.PalmPose;
            transform.SetPositionAndRotation(palm.position, palm.rotation);
        }
    }
}

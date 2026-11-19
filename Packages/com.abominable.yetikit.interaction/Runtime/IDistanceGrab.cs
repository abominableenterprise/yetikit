using UnityEngine.XR.Interaction.Toolkit.Interactors;

namespace YetiKit.Interaction
{
    /// <summary>Optional per-prop distance policy. The host owns targeting, selection and any summon motion.</summary>
    public interface IDistanceGrab
    {
        /// <summary>Maximum near reach from the hand to the prop's closest collider point, in metres.</summary>
        float NearReach { get; }

        /// <summary>Attach ease-in time in seconds for a far selection, including a host-initiated summon.</summary>
        float EaseInTime(IXRSelectInteractor interactor);
    }
}

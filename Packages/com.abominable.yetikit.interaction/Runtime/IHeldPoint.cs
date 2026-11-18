using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Supplies a grabbable's world-space hold point when it differs from the centre of mass.
    /// A distance grab can use this point to determine when the object reaches the palm.
    /// </summary>
    public interface IHeldPoint
    {
        Vector3 HeldPoint { get; }
    }
}

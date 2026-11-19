
namespace YetiKit.Interaction
{
    /// <summary>Optional hand-tracking pose; controller placement continues to use IGripSource.</summary>
    public interface ITrackedGripSource
    {
        GripSpec TrackedGripFor(bool rightHand);
    }

    /// <summary>
    /// Where the glove holds a <see cref="PropGrabInteractable"/> (<see cref="GripSpec"/>, mirrored for the left hand as
    /// it likes). A <see cref="GrabbableProp"/> or another selectable object may provide one.
    /// Without one the prop is held where the hand closed on it.
    /// </summary>
    public interface IGripSource
    {
        GripSpec GripFor(bool rightHand);
    }
}

using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>Estimates a palm normal from Dynamic joints and points from the shoulder through the pinch.</summary>
    public static class PointPinchPalm
    {
        public const float ShoulderDrop = 0.20f, ShoulderSide = 0.17f;
        const int Index = HandCurls.PointsPerFinger + 1;
        const int Middle = 2 * HandCurls.PointsPerFinger + 1;
        const int Pinky = 4 * HandCurls.PointsPerFinger + 1;

        public static Vector3 Normal(PlayerHand hand)
        {
            var across = hand.Joint(Pinky) - hand.Joint(Index);
            var forward = hand.Joint(Middle) - hand.Joint(0);
            return (hand.RightHand ? Vector3.Cross(across, forward) : Vector3.Cross(forward, across)).normalized;
        }

        public static Vector3 Direction(Vector3 eyes, Vector3 flatForward, bool right, Vector3 midpoint)
        {
            var side = Vector3.Cross(Vector3.up, flatForward) * (right ? ShoulderSide : -ShoulderSide);
            var offset = midpoint - (eyes + Vector3.down * ShoulderDrop + side);
            return offset.sqrMagnitude > 1e-8f ? offset.normalized : flatForward;
        }
    }
}

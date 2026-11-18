using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>Optional rendering callbacks. Pose and controller input callbacks identify the active source.</summary>
    public interface IHandVisual
    {
        void OnPresence(bool present);

        /// <summary>Tracked wrist and joint poses in world space. Joints may be null; curls and joints are borrowed buffers.</summary>
        void OnPose(Pose wrist, JointCurls curls, Pose[] joints);

        void OnControllerInput(float grip, float trigger);
    }
}

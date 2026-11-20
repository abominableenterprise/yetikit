using UnityEngine;
using YetiKit.Hands;

namespace Game.Starter
{
    // Only the joint group is toggled; the hand root still owns gameplay and pose callbacks.
    public sealed class TrackedHandVisual : MonoBehaviour, IHandVisual
    {
        [SerializeField] GameObject model;
        [SerializeField] Transform[] joints;

        public void Configure(GameObject jointModel, Transform[] jointTransforms)
        {
            model = jointModel;
            joints = jointTransforms;
        }

        public void OnPose(Pose wrist, JointCurls curls, Pose[] poses)
        {
            if (!isActiveAndEnabled || poses == null)
            {
                model.SetActive(false);
                return;
            }

            // PlayerHand supplies world poses, even though this group is under its moving wrist.
            for (var i = 0; i < joints.Length; i++)
                joints[i].SetPositionAndRotation(poses[i].position, poses[i].rotation);
            model.SetActive(true);
        }

        public void OnPresence(bool present)
        {
            if (!present) model.SetActive(false);
        }

        // Presence can stay true during a direct hand-to-controller takeover.
        public void OnControllerInput(float grip, float trigger) => model.SetActive(false);

        void OnDisable()
        {
            if (model) model.SetActive(false);
        }
    }
}

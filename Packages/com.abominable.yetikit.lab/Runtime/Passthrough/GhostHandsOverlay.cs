using UnityEngine;
using UnityEngine.XR.ARFoundation;
using YetiKit.Hands;

namespace YetiKit.Lab
{
    /// <summary>Opt-in passthrough for a Lab rig. PlayerHand continues to drive the avatar from tracked poses.</summary>
    [DisallowMultipleComponent]
    public sealed class GhostHandsOverlay : MonoBehaviour
    {
        [SerializeField] ARCameraManager cameraManager;
        [SerializeField] PlayerHand leftHand, rightHand;
        [SerializeField, Range(0f, 1f)] float opacity = 0.5f;

        readonly Ghost left = new Ghost(), right = new Ghost();
        ARCameraManager activeManager;
        Camera activeCamera;
        CameraClearFlags originalFlags;
        Color originalBackground;
        bool managerWasEnabled;

        public float Opacity { get => opacity; set => opacity = Mathf.Clamp01(value); }

        void OnEnable()
        {
            if (!cameraManager || !cameraManager.TryGetComponent(out activeCamera)) return;
            activeManager = cameraManager;
            originalFlags = activeCamera.clearFlags;
            originalBackground = activeCamera.backgroundColor;
            managerWasEnabled = activeManager.enabled;
            activeCamera.clearFlags = CameraClearFlags.SolidColor;
            activeCamera.backgroundColor = Color.clear;
            activeManager.enabled = true;
        }

        void LateUpdate()
        {
            var active = activeManager && activeManager.isActiveAndEnabled;
            left.Update(active ? leftHand : null, opacity);
            right.Update(active && rightHand != leftHand ? rightHand : null, opacity);
        }

        void OnDisable()
        {
            left.Update(null, opacity);
            right.Update(null, opacity);
            if (activeManager) activeManager.enabled = managerWasEnabled;
            if (activeCamera)
            {
                activeCamera.clearFlags = originalFlags;
                activeCamera.backgroundColor = originalBackground;
            }
            activeManager = null;
            activeCamera = null;
        }

        sealed class Ghost
        {
            IHandVisualAlpha visual;
            float originalAlpha;

            public void Update(PlayerHand hand, float alpha)
            {
                var tracked = hand && hand.isActiveAndEnabled && hand.HandTracked ? hand.Visual as IHandVisualAlpha : null;
                if (!ReferenceEquals(tracked, visual))
                {
                    if (visual != null && !(visual is Object obj && !obj)) visual.Alpha = originalAlpha;
                    visual = tracked;
                    if (visual != null) originalAlpha = visual.Alpha;
                }
                if (visual != null && visual.Alpha != alpha) visual.Alpha = alpha;
            }
        }
    }
}
